# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "open3"
require "securerandom"
require "tmpdir"

module SpecrelayRunner
  # The work a provider paused on, kept where any eligible machine can reach it: one snapshot
  # commit per changed repository, pushed to an immutable `runner-checkpoints/<id>` ref on that
  # repository's OWN origin. Platform stores only the small manifest naming those refs.
  #
  # Five operations, one rule each:
  #
  #   capture  — inventory every repository in the task workspace, never the executor's selection,
  #              build each changed one's snapshot through a TEMPORARY index with its recorded base
  #              as sole parent, and push it; the asking worktree's branch, HEAD, index and files
  #              are never touched;
  #   withdraw — remove the refs a capture created when Platform refuses its question;
  #   check    — prove the manifest is the recorded one, reading no repository;
  #   restore  — prove every entry against its remote ref and its destination checkout, and only
  #              when ALL of them pass, place each on its base and write the snapshot as dirty work;
  #   discard  — remove a consumed checkpoint's refs, best effort.
  #
  # The same restore runs on the machine that asked and on any other: a local worktree is a
  # destination, never the source of the work. It fails CLOSED, every refusal names the term that
  # failed, and nothing here resets or overwrites a checkout that holds anything but this work.
  module Checkpoint
    FORMAT = "specrelay-checkpoint-2"
    # The manifest is metadata about refs, never source, so its bound is small.
    MAX_BYTES = 64 * 1024
    MAX_REPOSITORIES = 20
    # The assignment contract's bound on every free-text entry field.
    MAX_TEXT = 200
    REF_NAMESPACE = "refs/heads/runner-checkpoints/"
    ENTRY_FIELDS = %w[base_ref base_sha change_digest checkpoint_ref origin path snapshot_sha].freeze

    COMMIT_MESSAGE = "Portable uncommitted-work checkpoint"

    # The snapshot commit's identity, fixed so the same tree on the same base always produces the
    # same commit id — which is what makes a retried push of the same capture idempotent.
    COMMIT_IDENTITY = {
      "GIT_AUTHOR_NAME" => "SpecRelay", "GIT_AUTHOR_EMAIL" => "runner@specrelay.invalid",
      "GIT_AUTHOR_DATE" => "1970-01-01T00:00:00+0000",
      "GIT_COMMITTER_NAME" => "SpecRelay", "GIT_COMMITTER_EMAIL" => "runner@specrelay.invalid",
      "GIT_COMMITTER_DATE" => "1970-01-01T00:00:00+0000"
    }.freeze

    COMMIT_SHA = /\A[0-9a-f]{40}\z/
    DIGEST = /\A[0-9a-f]{64}\z/
    CHECKPOINT_REF = %r{\A#{Regexp.escape(REF_NAMESPACE)}\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z}

    # The captured manifest, or the ONE reason no question may be stored. `created` holds the
    # `[root, entry]` of every ref THIS capture pushed, so a refused question removes only those.
    Captured = Struct.new(:checkpoint, :error, :created, keyword_init: true) do
      def ok? = error.nil?
    end

    Result = Struct.new(:ok, :reason, keyword_init: true) do
      def ok? = ok
    end

    # One located repository, or the reason it is not the recorded one.
    Located = Struct.new(:path, :reason, keyword_init: true) do
      def ok? = reason.nil?
    end

    module_function

    # Every changed repository in `task_root`, captured and pushed, or the reason nothing may be
    # stored. `reviewed` are the claim's reviewed targets, whose exact heads are their bases; the
    # caller has already proved them against their pull requests.
    #
    # `decided`, when given, is the base placement DECIDED for every contained repository
    # ({PreviousAcceptedPackage::Result#bases}), and then no base is read from an origin at all:
    # the set must name each contained repository exactly once, by its own identity.
    #
    # The manifest is sealed and checked against the contract's bounds BEFORE anything is pushed.
    # All or nothing: when one push fails, the refs this capture created are removed, and any that
    # cannot be removed are named as orphans.
    def capture(task_root:, reviewed: [], decided: nil, id: SecureRandom.uuid)
      contained = ContainedRepositories.discover(task_root)
      return refuse_capture(contained.error) unless contained.ok?

      bases = decided_bases(decided, contained, task_root)
      return refuse_capture(bases) if bases.is_a?(String)

      heads = reviewed_bases(reviewed, task_root)
      return refuse_capture(heads) if heads.is_a?(String)

      bases = bases.merge(heads)

      snapshots = []
      contained.roots.each do |root|
        snapshot = snapshot(root, task_root, bases, "#{REF_NAMESPACE}#{id}")
        return refuse_capture(snapshot) if snapshot.is_a?(String)

        snapshots << snapshot if snapshot
      end
      return refuse_capture("#{snapshots.length} repositories changed; a checkpoint holds at most #{MAX_REPOSITORIES}") if
        snapshots.length > MAX_REPOSITORIES

      sealed = seal(snapshots.map(&:last))
      return sealed unless sealed.ok?

      created = publish(snapshots)
      created.is_a?(String) ? refuse_capture(created) : Captured.new(checkpoint: sealed.checkpoint, created: created)
    end

    # Remove the refs a capture created, once Platform has refused the question they were pushed
    # for: no stored question names them. A ref the capture found already in place is not its own
    # and is kept. Returns the refs that could not be removed.
    def withdraw(captured) = remove(Array(captured&.created))

    # The manifest proven to be the recorded one, reading no repository: the closed metadata the
    # assignment carries, and the downloaded bytes Platform stored beside it.
    def check(checkpoint, payload:)
      entries = recorded_entries(checkpoint)
      return refuse(entries) if entries.is_a?(String)

      mismatch = manifest_mismatch(checkpoint.to_h, entries, payload)
      mismatch ? refuse(mismatch) : Result.new(ok: true)
    end

    # Reconstruct the recorded work in `task_root`, on `branch`, or refuse with nothing changed.
    #
    # Every entry is proved first — its ref, its snapshot's parent and digest, and its destination
    # checkout — and every repository the manifest does not name must be clean. The block, when
    # given, is the caller's own proof that the recorded bases are the claim's inputs; it runs
    # after all of these and before any repository is placed. Objects fetched during the proof may remain; no
    # ref, HEAD, index or file changes until the whole set has passed.
    #
    # `created` says THIS attempt built the task workspace, so a clean checkout in it holds nothing
    # of anyone's and may be put on its recorded base. A checkout this attempt found must already
    # be clean at that base, or hold exactly the recorded work.
    def restore(checkpoint, payload:, task_root:, branch:, created:)
      checked = check(checkpoint, payload: payload)
      return checked unless checked.ok?

      plans = []
      checkpoint["repositories"].each do |entry|
        plan = prove(entry, task_root, branch, created)
        return refuse(plan) if plan.is_a?(String)

        plans << plan
      end
      failure = unrecorded_refusal(task_root, plans)
      return refuse(failure) if failure

      targets = block_given? ? yield : nil
      return refuse(targets.reason) if targets && !targets.ok?

      failure = plans.lazy.map { |plan| place(plan, branch) || confirm(plan, task_root, branch) }.find(&:itself)
      failure ? refuse(failure) : Result.new(ok: true)
    end

    # Remove the refs of a checkpoint whose answers a fresh session has received. Best effort: the
    # refs that could not be removed are returned for the operator, and nothing fails because of
    # them.
    def discard(checkpoint, task_root:)
      Array(checkpoint.to_h["repositories"]).filter_map do |entry|
        located = locate(entry, task_root)
        named(entry) unless located.ok? && delete_ref(located.path, entry)
      end
    end

    def refuse_capture(reason) = Captured.new(checkpoint: nil, error: reason)
    def refuse(reason) = Result.new(ok: false, reason: reason)

    # ---------------------------------------------------------------- capture internals

    # The reviewed head of each reviewed target, by the checkout {Review::Checkout.resolve} locates
    # for it — the same locator the reviewed-target proof uses.
    def reviewed_bases(reviewed, task_root)
      Array(reviewed).each_with_object({}) do |repository, bases|
        resolution = Review::Checkout.resolve(repository, task_root, Review::Checkout::Git)
        return resolution.refusal.reason if resolution.refusal

        bases[real(resolution.root)] = [ repository["head_commit"].to_s.downcase, "refs/heads/#{repository['branch']}" ]
      end
    end

    # The decided base of every contained repository, keyed like {reviewed_bases}, or the reason the
    # set cannot be trusted. A missing, repeated or foreign entry, or one whose checkout declares
    # another identity, refuses: guessing a base for it is how a snapshot drops commits.
    def decided_bases(decided, contained, task_root)
      return {} if decided.nil?

      bases = Array(decided).each_with_object({}) do |base, acc|
        root = real(base[:path])
        subject = quoted(base[:repository])
        return "the base decided for #{subject} is malformed" unless
          COMMIT_SHA.match?(base[:commit].to_s) && base[:ref].to_s.start_with?("refs/heads/")
        return "the base decided for #{subject} is not a repository of the task workspace" unless contained.roots.include?(root)

        local = quoted(relative(task_root, root))
        return "two bases were decided for #{local}" if acc.key?(root)
        return "the origin of #{local} is not #{subject}, the repository its base was decided for" unless
          GithubRemote.slug(capture_git(root, %w[remote get-url origin])).to_s.casecmp?(base[:repository].to_s)

        acc[root] = [ base[:commit], base[:ref] ]
      end
      missing = contained.roots.find { |root| !bases.key?(root) }
      missing ? "no base was decided for #{quoted(relative(task_root, missing))}" : bases
    end

    # `[root, entry]` for a changed repository, nil for an unchanged one, or the reason this
    # repository cannot be checkpointed — which refuses the whole question, because silently
    # omitting a changed repository would lose its work.
    def snapshot(root, task_root, bases, ref)
      relative = relative(task_root, root)
      origin = GithubRemote.slug(capture_git(root, %w[remote get-url origin]))
      return "#{quoted(relative)} has no supported GitHub 'origin' remote" if origin.nil?

      base_sha, base_ref = bases[real(root)] || remote_base(root)
      return "could not resolve the base of #{quoted(relative)} from its origin" unless COMMIT_SHA.match?(base_sha.to_s)
      return "could not fetch the base #{base_sha[0, 12]} of #{quoted(relative)}" unless base_present?(root, base_sha, base_ref)

      tree = working_tree(root)
      return "could not read the working tree of #{quoted(relative)}" if tree.nil?
      return nil if unchanged?(root, tree, base_sha)
      # The snapshot's tree replaces everything on its base, so a base this checkout does not
      # descend from would silently revert the base's commits that never reached it.
      return "#{quoted(relative)} does not contain its base #{base_ref} at #{base_sha[0, 12]}; a checkpoint " \
             "on that base would drop those commits" unless ancestor?(root, base_sha, "HEAD")

      entry(root, relative, origin, [ base_sha, base_ref ], tree, ref)
    end

    # Nothing to keep: the working tree IS the base, or the checkout is untouched — no edit, and no
    # commit the base does not already hold — and only its origin has moved on.
    def unchanged?(root, tree, base)
      return true if tree == capture_git(root, [ "rev-parse", "#{base}^{tree}" ])

      tree == capture_git(root, %w[rev-parse HEAD^{tree}]) && ancestor?(root, "HEAD", base)
    end

    def ancestor?(path, ancestor, descendant) = git(path, [ "merge-base", "--is-ancestor", ancestor, descendant ]).first

    def entry(root, relative, origin, base, tree, ref)
      commit = snapshot_commit(root, tree, base[0])
      digest = change_digest(root, base[0], tree)
      return "could not build a checkpoint of #{quoted(relative)}" if commit.nil? || digest.nil?

      [ root, { "path" => relative, "origin" => origin, "base_ref" => base[1], "base_sha" => base[0],
                "checkpoint_ref" => ref, "snapshot_sha" => commit, "change_digest" => digest } ]
    end

    # The base of a repository with no reviewed pull request: the SHA its origin advertises for the
    # configured upstream branch, or — only when no upstream is configured — the origin's default
    # branch. Never a local branch or local HEAD.
    def remote_base(root)
      branch = capture_git(root, %w[symbolic-ref --quiet --short HEAD])
      remote = branch && capture_git(root, [ "config", "branch.#{branch}.remote" ])
      return default_base(root) if remote.nil?

      merge = capture_git(root, [ "config", "branch.#{branch}.merge" ]).to_s
      return nil unless remote == Review::Checkout::Git::REMOTE && merge.start_with?("refs/heads/")

      sha = Review::Checkout::Git.remote_head(root, merge.delete_prefix("refs/heads/")).to_s.downcase
      [ sha, merge ] if COMMIT_SHA.match?(sha)
    end

    def default_base(root)
      branch, sha = PreviousAcceptedPackage.default_branch_tip(root, Review::Checkout::Git)
      [ sha, "refs/heads/#{branch}" ] if sha
    end

    # The base must be a local object for the snapshot to name it as parent; a missing one is
    # fetched from the origin by its ref, without updating any local ref.
    def base_present?(root, sha, ref)
      return true if commit?(root, sha)

      fetched = git(root, [ "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--refmap=",
                            Review::Checkout::Git::REMOTE, ref ]).first
      fetched && commit?(root, sha)
    end

    # The tree git sees in this working copy — HEAD's tree with every tracked edit, deletion, mode
    # change and non-ignored untracked file staged over it — written through a TEMPORARY index, so
    # the real index is never opened for writing. Ignored files are never added.
    def working_tree(path)
      Dir.mktmpdir("specrelay-checkpoint-index-") do |dir|
        index = { "GIT_INDEX_FILE" => File.join(dir, "index") }
        next nil unless git(path, %w[read-tree HEAD], env: index).first
        next nil unless git(path, %w[add --all], env: index).first

        written = git(path, %w[write-tree], env: index)
        written.first ? written.last.strip : nil
      end
    end

    def snapshot_commit(root, tree, base)
      built = git(root, [ "commit-tree", tree, "-p", base, "-m", COMMIT_MESSAGE ], env: COMMIT_IDENTITY)
      built.first ? built.last.strip : nil
    end

    # The digest of the change set from the base to a tree: measured the same way when the
    # snapshot is taken, when the manifest's ref is proved, and after the work is restored.
    def change_digest(path, base, tree)
      ok, diff = git(path, [ "diff", "--binary", "--full-index", "--no-renames", "--no-ext-diff", "--no-textconv",
                             base, tree ])
      ok ? Digest::SHA256.hexdigest(diff) : nil
    end

    # The `[root, entry]` of every ref this capture created, or the reason it failed with those
    # refs removed again.
    def publish(snapshots)
      created = []
      snapshots.each do |root, entry|
        outcome = push(root, entry)
        next created << [ root, entry ] if outcome == :created
        next if outcome == :existing

        return failed_publication(outcome, created)
      end
      created
    end

    # The ref is immutable: absent, it is created without force; already at this snapshot, it is
    # the same capture; at any other commit, it is somebody else's and is never replaced.
    def push(root, entry)
      ref = entry["checkpoint_ref"]
      sha = entry["snapshot_sha"]
      subject = "#{ref} on the origin of #{quoted(entry['path'])}"
      observed = remote_ref(root, ref)
      return "could not read #{subject}" if observed.nil?
      return :existing if observed == sha
      return "#{subject} already names another commit; it is never replaced" unless observed.empty?
      return "could not push #{subject}" unless git(root, [ "push", "--quiet", Review::Checkout::Git::REMOTE, "#{sha}:#{ref}" ]).first

      remote_ref(root, ref) == sha ? :created : "#{subject} does not hold the pushed commit"
    end

    def failed_publication(reason, created)
      orphans = remove(created)
      orphans.empty? ? reason : "#{reason}; these checkpoint refs could not be removed: #{orphans.join(', ')}"
    end

    # The named refs of the `[root, entry]` pairs that could not be removed.
    def remove(created) = created.filter_map { |root, entry| named(entry) unless delete_ref(root, entry) }

    def delete_ref(root, entry) =
      git(root, [ "push", "--quiet", Review::Checkout::Git::REMOTE, "--delete", entry["checkpoint_ref"].to_s ]).first

    def named(entry) = "#{quoted(entry['path'])} #{entry['checkpoint_ref']}"

    def remote_ref(path, ref) = Review::Checkout::Git.remote_head(path, ref.delete_prefix("refs/heads/"))&.downcase

    # The bounded transport document: the closed metadata Platform validates and stores, and the
    # same manifest as the bytes it serves back on the claim-bound download. Proved against the
    # same rules a resume applies, so a manifest no machine could accept is never published.
    def seal(entries)
      recorded = { "format" => FORMAT, "repositories" => entries }
      invalid = recorded_entries(recorded)
      return refuse_capture(invalid) if invalid.is_a?(String)

      bytes = JSON.generate(recorded).b
      return refuse_capture("the checkpoint manifest is too large (#{bytes.bytesize} bytes)") if bytes.bytesize > MAX_BYTES

      Captured.new(checkpoint: recorded.merge("byte_size" => bytes.bytesize, "digest" => Digest::SHA256.hexdigest(bytes),
                                              "payload" => Base64.strict_encode64(bytes)))
    rescue JSON::GeneratorError, EncodingError
      refuse_capture("the checkpoint manifest is not valid UTF-8")
    end

    # ---------------------------------------------------------------- check internals

    # The recorded entries, or the reason they cannot be acted on.
    def recorded_entries(checkpoint)
      recorded = checkpoint.to_h
      return "the recorded checkpoint is not a #{FORMAT} manifest" unless recorded["format"] == FORMAT

      entries = recorded["repositories"]
      return "the recorded checkpoint lists no repositories" unless entries.is_a?(Array)
      return "the recorded checkpoint lists more than #{MAX_REPOSITORIES} repositories" if entries.length > MAX_REPOSITORIES

      malformed = entries.find { |entry| !well_formed?(entry) }
      return "the checkpoint entry #{quoted(malformed.to_h['path'])} is malformed" if malformed

      %w[path origin].each do |field|
        values = entries.map { |entry| entry[field].downcase }
        return "the recorded checkpoint names the same #{field} twice" if values.uniq.length != values.length
      end
      entries
    end

    def well_formed?(entry)
      entry.is_a?(Hash) && entry.keys.sort == ENTRY_FIELDS && entry.values.all?(String) &&
        !entry["path"].empty? && !entry["origin"].empty? && entry["base_ref"].start_with?("refs/heads/") &&
        entry.values_at("path", "origin", "base_ref").all? { |value| value.length <= MAX_TEXT } &&
        COMMIT_SHA.match?(entry["base_sha"]) && COMMIT_SHA.match?(entry["snapshot_sha"]) &&
        DIGEST.match?(entry["change_digest"]) && CHECKPOINT_REF.match?(entry["checkpoint_ref"])
    end

    def manifest_mismatch(recorded, entries, payload)
      bytes = decode(payload)
      return "the checkpoint manifest is not readable" if bytes.nil?
      return "the checkpoint manifest is #{bytes.bytesize} bytes; #{recorded['byte_size']} were recorded" unless
        bytes.bytesize == recorded["byte_size"]
      return "the checkpoint manifest does not match its recorded checksum" unless
        Digest::SHA256.hexdigest(bytes) == recorded["digest"]
      return nil if JSON.parse(bytes) == { "format" => FORMAT, "repositories" => entries }

      "the checkpoint manifest does not match the assignment"
    rescue JSON::ParserError
      "the checkpoint manifest is not readable"
    end

    def decode(value)
      Base64.strict_decode64(value.to_s).b
    rescue ArgumentError
      nil
    end

    # ---------------------------------------------------------------- restore internals

    # One entry proved without changing any checked-out state, or the reason it may not be
    # restored. Remote facts first, then the fetched snapshot, then the checkout it would land in.
    def prove(entry, task_root, branch, created)
      located = locate(entry, task_root)
      return located.reason unless located.ok?

      path = located.path
      refusal = ref_refusal(path, entry) || snapshot_refusal(path, entry) || destination_refusal(path, entry, branch, created)
      refusal || { "entry" => entry, "path" => path }
    end

    def ref_refusal(path, entry)
      subject = "the checkpoint ref of #{quoted(entry['path'])}"
      observed = remote_ref(path, entry["checkpoint_ref"])
      return "could not read #{subject} from its origin" if observed.nil?
      return "#{subject} no longer exists on its origin" if observed.empty?
      return nil if observed == entry["snapshot_sha"]

      "#{subject} moved from #{entry['snapshot_sha'][0, 12]} to #{observed[0, 12]}"
    end

    # The snapshot, fetched by its exact ref into the object database only — no FETCH_HEAD, and no
    # remote-tracking ref — and proved to be the recorded work on the recorded base.
    def snapshot_refusal(path, entry)
      subject = quoted(entry["path"])
      snapshot = entry["snapshot_sha"]
      git(path, [ "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--refmap=",
                  Review::Checkout::Git::REMOTE, entry["checkpoint_ref"] ])
      return "the checkpoint of #{subject} could not be fetched from its origin" unless commit?(path, snapshot)
      return "the checkpoint of #{subject} does not have its recorded base as its sole parent" unless
        capture_git(path, [ "rev-list", "--parents", "-n", "1", snapshot ]).to_s.split == [ snapshot, entry["base_sha"] ]
      return nil if change_digest(path, entry["base_sha"], "#{snapshot}^{tree}") == entry["change_digest"]

      "the change_digest of #{subject} does not match its checkpoint"
    end

    # The checkout the work would land in, proved to hold nothing of anyone else's: on the task
    # branch, or detached in a workspace this attempt built; and clean at its base, clean in a
    # workspace this attempt built, or already holding exactly this snapshot's tree.
    def destination_refusal(path, entry, branch, created)
      subject = quoted(entry["path"])
      observed = capture_git(path, %w[symbolic-ref --quiet --short HEAD])
      return "#{subject} is checked out on '#{observed}', not the task branch '#{branch}'" unless
        observed == branch || (observed.nil? && created)

      status = git(path, %w[status --porcelain --untracked-files=all])
      return "the state of #{subject} could not be read" unless status.first

      clean = status.last.strip.empty?
      return placement(path, entry, branch)&.reason if observed.nil? && clean
      return nil if clean && (created || capture_git(path, %w[rev-parse HEAD]) == entry["base_sha"])
      return nil if !observed.nil? && working_tree(path) == capture_git(path, [ "rev-parse", "#{entry['snapshot_sha']}^{tree}" ])

      "#{subject} has local changes that are not the recorded work; preserve or release them before retrying"
    end

    # A detached checkout of a workspace this attempt built gets the task branch at the recorded
    # base through {BranchPlacement}, which never moves an existing ref. Returns the refusal, or nil.
    def placement(path, entry, branch)
      planned = BranchPlacement.new(root: path, branch: branch, commit: entry["base_sha"], subject: quoted(entry["path"]),
                                    noun: "recorded", target: "recorded base").plan
      planned.is_a?(BranchPlacement::Refusal) ? planned : nil
    end

    # Every repository the manifest does not name must be clean: an edit there is unrelated work
    # the continuation would otherwise hand to the provider as if it were recorded.
    def unrecorded_refusal(task_root, plans)
      contained = ContainedRepositories.discover(task_root)
      return contained.error unless contained.ok?

      contained.roots.each do |root|
        next if plans.any? { |plan| real(plan["path"]) == real(root) }

        status = git(root, %w[status --porcelain --untracked-files=all])
        subject = quoted(relative(task_root, root))
        return "the state of #{subject} could not be read" unless status.first
        next if status.last.strip.empty?

        return "#{subject} has uncommitted changes that no checkpoint recorded; preserve or release them before retrying"
      end
      nil
    end

    # The one mutation: the checkout on its recorded base, then the snapshot written over it as
    # UNCOMMITTED work. A detached checkout gets the task branch there; one already on the task
    # branch is reset to the base, which the proof above has shown discards nothing but this work.
    def place(plan, branch)
      entry = plan["entry"]
      path = plan["path"]
      subject = quoted(entry["path"])
      if capture_git(path, %w[symbolic-ref --quiet --short HEAD]).nil?
        planned = BranchPlacement.new(root: path, branch: branch, commit: entry["base_sha"], subject: subject,
                                      noun: "recorded", target: "recorded base").plan
        return planned.reason if planned.is_a?(BranchPlacement::Refusal)

        refusal = planned.put
        return refusal.reason if refusal
      elsif !git(path, [ "reset", "--quiet", "--hard", entry["base_sha"] ]).first
        return "could not put #{subject} on its recorded base"
      end
      materialize(path, entry["snapshot_sha"]) ? nil : "the recorded work could not be written into #{subject}"
    end

    # The snapshot's tree written into the working copy through a temporary index seeded from HEAD,
    # so the real index still describes the base: tracked changes are unstaged and new files stay
    # untracked.
    def materialize(path, commit)
      Dir.mktmpdir("specrelay-checkpoint-index-") do |dir|
        index = { "GIT_INDEX_FILE" => File.join(dir, "index") }
        next false unless git(path, %w[read-tree HEAD], env: index).first

        git(path, [ "read-tree", "-u", "--reset", commit ], env: index).first
      end
    end

    # The restored repository, measured again: still where it was recorded, on the task branch at
    # its base, holding exactly the recorded change set.
    def confirm(plan, task_root, branch)
      entry = plan["entry"]
      subject = quoted(entry["path"])
      located = locate(entry, task_root)
      return located.reason unless located.ok?
      return "#{subject} is not on the task branch at its recorded base after the restore" unless
        capture_git(located.path, %w[symbolic-ref --quiet --short HEAD]) == branch &&
        capture_git(located.path, %w[rev-parse HEAD]) == entry["base_sha"]

      tree = working_tree(located.path)
      return nil if tree && change_digest(located.path, entry["base_sha"], tree) == entry["change_digest"]

      "the change_digest of #{subject} does not match the recorded checkpoint after the restore"
    end

    # The repository this entry names, inside the task workspace and on the recorded origin, or the
    # reason it is not. Containment comes first, then git, then identity, so a refusal names the
    # most specific cause rather than a consequence of it.
    def locate(entry, task_root)
      relative = entry["path"].to_s
      outside = "the recorded path #{quoted(relative)} is not inside the task workspace"
      return unlocated(outside) if rooted?(relative)

      # Lexically first, so a traversing entry is refused for what it IS; then again on the
      # resolved paths, which is what a symlink pointing out of the workspace would defeat.
      expanded = File.expand_path(relative, task_root.to_s)
      return unlocated(outside) unless inside?(File.expand_path(task_root.to_s), expanded)

      root = real(task_root)
      resolved = real(expanded)
      return unlocated("no git repository at the recorded path #{quoted(relative)}") if resolved.nil? || root.nil?
      return unlocated(outside) unless inside?(root, resolved)

      toplevel = capture_git(resolved, %w[rev-parse --show-toplevel])
      return unlocated("no git repository at the recorded path #{quoted(relative)}") if toplevel.nil?
      return unlocated("the recorded path #{quoted(relative)} is not a git repository root") unless real(toplevel) == resolved
      return Located.new(path: resolved) if
        GithubRemote.slug(capture_git(resolved, %w[remote get-url origin])).to_s.casecmp?(entry["origin"].to_s)

      unlocated("the origin of #{quoted(relative)} is not the recorded repository")
    end

    def unlocated(reason) = Located.new(reason: reason)

    # ---------------------------------------------------------------- git and paths

    # ONE binary-safe git call: an argv array, never a shell line, with an optional per-call
    # environment and optional standard input.
    #
    # Its own adapter rather than {Workspace}'s or {Review::Checkout::Git}'s because neither can
    # carry `GIT_INDEX_FILE` or return an unbounded diff to digest: both bound their captured
    # output for operator text.
    def git(path, args, env: {}, stdin: nil)
      out, _err, status = Open3.capture3(env, "git", "-C", path.to_s, *args,
                                         stdin_data: stdin.to_s, binmode: true)
      [ status.success?, out.b ]
    rescue SystemCallError
      [ false, "".b ]
    end

    # Trimmed output of a successful read-only query, or nil. A failed query is never an empty
    # answer: every caller turns nil into a refusal rather than into a default.
    def capture_git(path, args)
      ok, out = git(path, args)
      return nil unless ok

      value = out.to_s.strip
      value.empty? ? nil : value
    end

    def commit?(path, sha) = git(path, [ "cat-file", "-e", "#{sha}^{commit}" ]).first

    def relative(task_root, root)
      base = real(task_root).to_s
      resolved = real(root).to_s
      resolved == base ? "." : resolved.delete_prefix("#{base}#{File::SEPARATOR}")
    end

    def rooted?(relative) = relative.start_with?("/", "~") || File.absolute_path?(relative)

    def inside?(root, resolved) = resolved == root || resolved.start_with?("#{root}#{File::SEPARATOR}")

    def real(path)
      File.realpath(path.to_s)
    rescue SystemCallError
      nil
    end

    # Recorded paths reach an operator-facing reason, so they are quoted and redacted: a
    # checkpoint that recorded something unexpected is exactly where that text must stay safe.
    def quoted(value) = Redaction.redact(value.to_s).inspect
  end
end
