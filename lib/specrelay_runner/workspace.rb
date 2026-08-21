# frozen_string_literal: true

require "shellwords"

module SpecrelayRunner
  # Local worktree operations for the standalone runner (MVP-0010) — a runner/
  # operator responsibility, not Platform's. It runs the workspace's configured
  # `worktree_create_command` (received in the run payload) verbatim as an argv
  # array in the operator's local workspace root, locates the created worktree by
  # matching the run's canonical branch, and captures the git diff/changed files
  # the executor produced.
  #
  # Platform never learns or depends on these physical paths; they travel only in
  # the report's worktree_identity audit evidence.
  class Workspace
    Error = Class.new(StandardError)

    # MAPIAI-87 — `created` says whether THIS call built the task workspace or found the exact
    # clean one already there. Reconstructing from an older accepted package is only ever correct
    # for a workspace that did not exist a moment ago: a reused one may already hold this run's
    # own partial publication, rework, restart or answered-resume state.
    Info = Struct.new(:path, :base_commit, :created, keyword_init: true) do
      def created? = created ? true : false
    end

    # `measurement_error` is set when the change set could not be established at all.
    # It is NOT the same as "no files changed", and callers must not conflate them:
    # on the success path an unmeasurable worktree has to fail the run, because
    # reporting `changed: false` would tell Jira "no code changes" while the
    # executor's diff sits on disk (review-002 finding N1).
    Changes = Struct.new(:changed_files, :diff, :head_commit, :measurement_error, keyword_init: true) do
      def measured? = measurement_error.nil?
    end

    # MAPIAI-84 — one repository the executor selected, verified and measured on its own terms.
    #
    # `id` is the normalized GitHub identity ({GithubRemote}), which is also what `gh` is asked
    # about and what a pull-request URL must belong to. Everything else is read from the
    # repository itself rather than declared by Platform: this struct is the whole of what
    # publication is allowed to know about a repository.
    Repository = Struct.new(:id, :relative_path, :path, :clone_url, :default_branch, :branch,
                            :base_commit, :head_commit, :changed_files, :diff, keyword_init: true) do
      # MAPIAI-93 — everything about this repository that publication will WRITE and the report
      # will DESCRIBE, as one comparable value.
      #
      # It exists because verification runs between measurement and publication: a selected
      # command can succeed and still rewrite a tracked file, move HEAD, or undo the change it
      # was verifying. Comparing this before and after replay is what proves the tree that was
      # verified is the tree that gets published (CR-001 F1).
      #
      # `base_commit` carries the measured HEAD, so commit movement is included. `head_commit` is
      # deliberately absent: publication assigns it afterwards, so it is nil on both sides and
      # comparing it would prove nothing.
      def publishable_state = [ id, relative_path, base_commit, Array(changed_files), diff.to_s ]
    end

    # The verified selection, or ONE refusal. It is deliberately not a per-entry result list:
    # publication is all-or-fail, so a selection with any unsafe entry must stop the attempt
    # before an external write rather than publish the acceptable part of it.
    Selection = Struct.new(:repositories, :error, keyword_init: true) do
      def ok? = error.nil?
    end

    # The project's own task-environment command, relative to the connected checkout root.
    PROJECT_COMMAND = File.join("bin", "worktree")

    def initialize(root:, canonical_branch:, create_command:, task_id: nil, env: {})
      @root = root.to_s
      @canonical_branch = canonical_branch.to_s
      @create_command = create_command.to_s
      @task_id = task_id.to_s
      @env = { "PATH" => ENV["PATH"].to_s }.merge(env)
    end

    def create
      if (existing = locate(required: false))
        status = git(existing, %w[status --porcelain])
        raise Error, "existing worktree for #{canonical_branch} could not be inspected" unless status.success?
        unless status.stdout.to_s.strip.empty?
          raise Error, "existing worktree for #{canonical_branch} has uncommitted changes; " \
                       "preserve or release it before retrying"
        end

        return Info.new(path: existing, base_commit: rev_parse(existing, "HEAD"), created: false)
      end

      result = run(create_argv)
      unless result.success?
        raise Error, "worktree create failed (exit #{result.exit_code}): #{first_line(result.stderr, result.stdout)}"
      end

      path = locate
      Info.new(path: path, base_commit: rev_parse(path, "HEAD"), created: true)
    end

    # MAPIAI-84 — HOW the one task workspace is constructed.
    #
    # When the connected checkout owns `bin/worktree`, that command is the single authority for
    # building its task environment, and the runner invokes it exactly once. A project whose task
    # environment is several independent repositories can only be assembled by the project itself;
    # a runner that assembled one instead would be maintaining a second repository-layout
    # convention, which is precisely what this ticket removes.
    #
    # Otherwise the existing native single-repository path stands, verbatim from the assignment.
    #
    # Either way the workspace is then LOCATED by asking git which worktree holds the canonical
    # branch — see #locate. That is why no layout convention is needed and why the project-owned
    # command's own output is not parsed: git already knows the answer.
    def create_argv
      project = File.join(root, PROJECT_COMMAND)
      return [ project, "create", task_id ] if !task_id.empty? && File.executable?(project)

      Shellwords.split(create_command)
    end

    # The worktree this canonical branch is ALREADY checked out in, or nil (MVP-0036 Stage 2a).
    #
    # A sibling of `create`, never a mode of it. `create` refuses an existing worktree that has
    # uncommitted changes, because an ordinary attempt must never start on top of work it did
    # not do — and that is exactly the state a resume requires, since those changed files are
    # the thing it is continuing. Reading is all this does: nothing is created, reset or cleaned.
    def existing
      path = locate(required: false)
      return nil if path.to_s.empty?

      Info.new(path: path, base_commit: rev_parse(path, "HEAD"), created: false)
    end

    # Capture changed files (tracked + untracked via intent-to-add) and a unified
    # diff vs HEAD.
    #
    # Never raises — that is load-bearing, not a convenience: the executor-failure
    # path calls this to describe a broken attempt before uploading a FAILED report,
    # and raising there crashed the runner and left the run stuck (QUALITY-0002).
    #
    # But "did not raise" must never be confused with "measured zero changes". When
    # the change set cannot be established the result carries a `measurement_error`
    # and an EMPTY file list, and the caller decides: truthful on the failure path,
    # fatal on the success path. Returning a bare empty list here is what let a
    # single transient spawn error be announced to Jira as "no code changes"
    # (review-002 finding N1).
    def capture_changes(path)
      status = git(path, %w[status --porcelain])
      return unmeasured("git status failed: #{first_line(status.stderr, status.stdout)}") unless status.success?

      git(path, %w[add -A -N])
      diff = git(path, %w[diff HEAD]).stdout.to_s
      Changes.new(changed_files: parse_changed(status.stdout), diff: diff,
                  head_commit: rev_parse(path, "HEAD"), measurement_error: nil)
    rescue SystemCallError => e
      # Process.spawn failures only: Errno::ENOENT/ENOTDIR for an unusable directory,
      # but also transient conditions such as EMFILE/EAGAIN/ENOMEM. None of them tells
      # us anything about the diff, so none may be reported as "unchanged".
      unmeasured("could not run git in the worktree: #{e.class}")
    end

    # MAPIAI-84 — verify and measure every repository the executor reported, or refuse.
    #
    # `task_root` is the prepared task workspace; `relative_paths` are the executor's reported
    # entries in its own order. Nothing here trusts the executor: it proves each entry is a real,
    # unique, correctly-branched git repository with a supported GitHub remote and a measurable
    # change of its own, and it does so BEFORE any external write.
    #
    # It is mechanical on purpose. It never asks whether a selected repository was the right
    # business choice — that decision belongs to the executor and is not reviewable here — only
    # whether it is safe and coherent to publish.
    def select(task_root, relative_paths)
      root = real(task_root)
      return Selection.new(repositories: [], error: "the prepared task workspace could not be resolved") if root.nil?

      repositories = []
      relative_paths.each do |relative|
        verified = verify(root, relative)
        return Selection.new(repositories: [], error: verified) if verified.is_a?(String)

        duplicate = duplicate_of(verified, repositories)
        return Selection.new(repositories: [], error: duplicate) if duplicate

        repositories << verified
      end
      Selection.new(repositories: repositories)
    end

    private

    attr_reader :root, :canonical_branch, :create_command, :task_id, :env

    # One entry, or the first fact about it that failed. The order is deliberate: containment
    # before git, git before the remote, and the change set last, so a refusal names the cheapest
    # and most specific cause rather than a consequence of it.
    def verify(task_root, relative)
      return "selected repository #{quoted(relative)} must be a path relative to the task workspace" if rooted?(relative)

      resolved = real(File.expand_path(relative, task_root))
      return "no git repository at the selected path #{quoted(relative)}" if resolved.nil?
      return "the selected path #{quoted(relative)} is not inside the task workspace" unless inside?(task_root, resolved)

      toplevel = capture(resolved, %w[rev-parse --show-toplevel])
      return "no git repository at the selected path #{quoted(relative)}" if toplevel.nil?
      return "the selected path #{quoted(relative)} is not a git repository root" unless real(toplevel) == resolved

      identify(relative, resolved)
    end

    def identify(relative, resolved)
      # The configured remote is read HERE and nowhere else. It may carry credential userinfo, so
      # what travels on is {GithubRemote}'s canonical url, derived from the validated slug.
      origin = capture(resolved, %w[remote get-url origin])
      id = GithubRemote.slug(origin)
      return "the selected repository #{quoted(relative)} has no supported GitHub 'origin' remote" if id.nil?

      clone_url = GithubRemote.clone_url(origin)
      default_branch = default_branch_of(resolved)
      return "could not establish the default branch of #{quoted(relative)}; run `git remote set-head origin --auto` there" if default_branch.nil?
      return "refusing to publish #{quoted(relative)} onto #{default_branch}, which is that repository's default branch" if default_branch == canonical_branch
      return "the selected repository #{quoted(relative)} is not on the run's canonical branch #{canonical_branch}" unless capture(resolved, %w[symbolic-ref --quiet --short HEAD]) == canonical_branch

      measure(relative, resolved, id, clone_url, default_branch)
    end

    def measure(relative, resolved, id, clone_url, default_branch)
      changes = capture_changes(resolved)
      return "could not determine what changed in #{quoted(relative)}: #{changes.measurement_error}" unless changes.measured?

      changes = committed_changes(resolved, default_branch) if changes.changed_files.empty?
      if changes.nil? || changes.changed_files.empty?
        return "the selected repository #{quoted(relative)} reports no change to publish"
      end

      Repository.new(id: id, relative_path: relative, path: resolved, clone_url: clone_url,
                     default_branch: default_branch, branch: canonical_branch,
                     base_commit: changes.head_commit, changed_files: changes.changed_files,
                     diff: changes.diff)
    end

    # The SAME-WORKSPACE RETRY path. After a partial publication failure every selected repository
    # is already committed, so its working tree is clean and worktree-versus-HEAD measurement sees
    # nothing — and without this the missing pull request could never be completed here.
    #
    # The change has not disappeared; it moved into the branch. What this reads is exactly what
    # the pull request contains: the task branch measured against the repository's default branch,
    # which is the base `gh pr create` is given. No runner-side state is retained to make that
    # possible, and nothing is re-established that git did not already know.
    #
    # It does not weaken the ordinary rule. A repository the executor never touched is level with
    # its default branch, so base and head are the same commit and it is still refused.
    def committed_changes(path, default_branch)
      base = merge_base(path, default_branch)
      return nil if base.nil? || base == rev_parse(path, "HEAD")

      range = "#{base}..HEAD"
      Changes.new(changed_files: limit(capture(path, [ "diff", "--name-only", range ]).to_s.each_line.map(&:chomp)),
                  diff: capture(path, [ "diff", range ]).to_s, head_commit: base, measurement_error: nil)
    end

    # The commit this branch and the repository's default branch last shared. The default branch
    # is resolved from the repository's own refs — its remote-tracking ref when it has one, its
    # local branch otherwise — because a task worktree may have either and neither is a guess.
    def merge_base(path, default_branch)
      default = [ "refs/remotes/origin/#{default_branch}", "refs/heads/#{default_branch}" ]
                .lazy.filter_map { |ref| capture(path, [ "rev-parse", "--verify", "--quiet", ref ]) }.first
      default && capture(path, [ "merge-base", default, "HEAD" ])
    end

    # Two entries naming ONE repository, by either measure. The git root catches two spellings of
    # the same working tree; the normalized remote catches two different working trees of the same
    # GitHub repository — the shape that produced the duplicate-pull-request failure.
    def duplicate_of(repository, accepted)
      same_tree = accepted.find { |other| other.path == repository.path }
      return "selected repositories #{quoted(same_tree.relative_path)} and #{quoted(repository.relative_path)} are the same repository" if same_tree

      # GitHub owner and repository names are case-insensitive, so two remotes differing only in
      # case are ONE repository. Compared on the normalized id rather than by re-parsing the url,
      # so this answer cannot disagree with the one `gh` was given.
      same_remote = accepted.find { |other| other.id.casecmp?(repository.id) }
      return nil if same_remote.nil?

      "selected repositories #{quoted(same_remote.relative_path)} and #{quoted(repository.relative_path)} " \
        "resolve to the same repository #{repository.id}"
    end

    # The repository's own default branch, read from git rather than from configuration: it is the
    # branch publication must never push onto, so the repository is the only honest source.
    def default_branch_of(path)
      symbolic = capture(path, %w[symbolic-ref --short refs/remotes/origin/HEAD])
      return nil if symbolic.nil?

      name = symbolic.split("/", 2).last.to_s
      name.empty? ? nil : name
    end

    def rooted?(relative) = relative.to_s.start_with?("/", "~") || File.absolute_path?(relative.to_s)

    def inside?(task_root, resolved) = resolved == task_root || resolved.start_with?("#{task_root}#{File::SEPARATOR}")

    def real(path)
      File.realpath(path.to_s)
    rescue SystemCallError
      nil
    end

    # Trimmed stdout of a successful read-only git query, or nil. A failed query is never an
    # empty answer: every caller turns nil into a refusal rather than into a default.
    def capture(path, args)
      result = git(path, args)
      return nil unless result.success?

      value = result.stdout.to_s.strip
      value.empty? ? nil : value
    rescue SystemCallError
      nil
    end

    # Selected paths reach an operator-facing reason, so they are quoted and redacted: an executor
    # that reported something unexpected is exactly the case where this text must stay safe.
    def quoted(relative) = Redaction.redact(relative.to_s).inspect

    def unmeasured(reason)
      Changes.new(changed_files: [], diff: "", head_commit: nil, measurement_error: reason)
    end

    def locate(required: true)
      listing = git(root, %w[worktree list --porcelain])
      raise Error, "could not list git worktrees in #{root}" unless listing.success?

      path = parse_worktree_for_branch(listing.stdout)
      if required && path.to_s.empty?
        raise Error, "no worktree found for branch #{canonical_branch} after create"
      end

      path
    end

    def parse_worktree_for_branch(porcelain)
      current = {}
      porcelain.to_s.each_line do |line|
        line = line.chomp
        if line.empty?
          return current[:worktree] if current[:branch] == "refs/heads/#{canonical_branch}"

          current = {}
        elsif line.start_with?("worktree ")
          current[:worktree] = line.delete_prefix("worktree ")
        elsif line.start_with?("branch ")
          current[:branch] = line.delete_prefix("branch ")
        end
      end
      current[:branch] == "refs/heads/#{canonical_branch}" ? current[:worktree] : nil
    end

    def parse_changed(porcelain)
      limit(porcelain.to_s.each_line.filter_map do |line|
        line = line.chomp
        next if line.empty?

        path = line[3..].to_s
        path.include?(" -> ") ? path.split(" -> ").last : path
      end)
    end

    # One bound on a reported change set, wherever it was measured from.
    def limit(files) = files.reject(&:empty?).uniq.first(500)

    def rev_parse(path, ref)
      result = git(path, [ "rev-parse", ref ])
      result.success? ? result.stdout.to_s.strip : nil
    end

    # Runs in `dir` as well as targeting it with `-C`, so a git query about a
    # worktree never depends on the workspace root being usable.
    def git(dir, args) = run([ "git", "-C", dir.to_s, *args ], chdir: dir)

    def run(argv, chdir: root) = CommandRunner.run(argv, chdir: chdir, env: env, timeout_seconds: 300)

    def first_line(*candidates)
      candidates.map { |c| c.to_s.strip }.find { |s| !s.empty? }.to_s.each_line.first.to_s.strip
    end
  end
end
