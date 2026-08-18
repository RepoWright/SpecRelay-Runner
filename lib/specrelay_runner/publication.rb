# frozen_string_literal: true

module SpecrelayRunner
  # MVP-0014 — publishes ONE verified repository's output to GitHub: commit, push the canonical
  # task branch, and create or reuse a draft pull request.
  #
  # Ownership boundary. MAPIAI-84 moved WHICH repositories are published out of Platform and into
  # the executor's own selection, verified locally by {Workspace#select}. What still arrives in
  # the assignment is HOW to publish — access, whether a pull request is required, whether it is a
  # draft (`repository_policy`) — and the canonical branch every repository of the task workspace
  # is on. This class executes one repository's local git/gh operations and reports facts back. It
  # holds no policy, no Jira authority, no credentials of its own, and no opinion about whether
  # the executor chose the right repositories.
  #
  # It is ONE INSTANCE PER REPOSITORY. That is what makes independent per-repository mechanics
  # true by construction rather than by care: nothing in here can leak one repository's worktree,
  # change set, commit or pull request into another's, because it only ever has one.
  #
  # Credentials stay on this host. Pushing uses the operator's existing git
  # credential setup (SSH agent, credential helper, or `gh` git protocol); pull
  # requests use the operator's `gh` session. Nothing is read from Platform and
  # nothing secret is ever logged, committed, or put in a pull-request body — every
  # command's output passes through Redaction before it is surfaced.
  #
  # It fails CLOSED. Any failure becomes a `publication_error` string on the
  # repository result, never an exception that aborts the attempt and never a silent
  # success — Platform then refuses to call the run successful and leaves Jira alone.
  #
  # Idempotency. Every step is safe to repeat: the commit is skipped when the working
  # tree is already clean at the expected head, the push is a no-op when the remote
  # already has the commit, and the pull request is looked up by branch before being
  # created. A retried publication reuses the same branch and the same pull request.
  class Publication
    GIT_TIMEOUT_SECONDS = 300
    # A git object name, matching the shape Platform validates on ingest.
    COMMIT_PATTERN = /\A[0-9a-f]{40,64}\z/
    GH_TIMEOUT_SECONDS = 120
    COMMIT_AUTHOR_NAME = "SpecRelay Runner"
    COMMIT_AUTHOR_EMAIL = "runner@specrelay.local"
    READ_ACCESS = "read"
    WRITE_ACCESS = "write"
    REMOTE = "origin"
    MAX_BODY_FILES = 25

    # One repository's publication facts, in terminal-result shape.
    #
    # `publication_error` and `publication_skipped_reason` are deliberately separate
    # fields for two different outcomes, because Platform must not treat them alike:
    #
    #   publication_error          publication was ATTEMPTED and FAILED -> the run is
    #                              not reviewable, Platform blocks finalization.
    #   publication_skipped_reason publication was NOT ATTEMPTED BY POLICY (read-only
    #                              repository) -> a normal, non-fatal outcome that
    #                              must not fail the run (review-001 finding 3).
    Result = Struct.new(:id, :clone_url, :default_branch, :changed, :base_commit, :head_commit,
                        :branch, :pull_request_url, :publication_error, :publication_skipped_reason,
                        keyword_init: true)

    def initialize(payload:, repository:, test:, env: {}, io: $stdout, publish: true)
      @payload = payload
      @repository = repository
      @test = test || {}
      @env = env
      @io = io
      @publish = publish
    end

    # Publishes this repository and returns its one Result.
    def call = publish

    private

    attr_reader :payload, :repository, :test, :env, :io

    # A failed attempt reports its repository but publishes nothing: there is no
    # reviewable output to offer, and pushing a failing tree would be noise.
    def publish? = @publish

    def worktree_path = repository.path.to_s

    # HOW to publish, never WHICH repository. A Platform that sends no policy at all did not ask
    # for publication; that is a policy outcome, not a failure (see #skipped).
    def policy = payload["repository_policy"].to_h
    def policy_assigned? = policy.any?
    def create_pull_requests? = policy.fetch("create_pull_requests", false)
    def draft_pull_request? = policy.fetch("pull_request_draft", true)

    # Access is now a property of the RUN's policy rather than of a per-repository assignment
    # entry, because there are no assignment entries. Withdrawing write access still publishes
    # nothing, which is the property that mattered.
    def writable? = policy.fetch("access", READ_ACCESS).to_s == WRITE_ACCESS
    def task_id = payload.dig("run", "task_id").to_s
    def run_id = payload.dig("run", "id").to_s
    def changed_files = Array(repository.changed_files)

    def publish
      # Every repository that reaches publication is one the executor changed and the runner
      # verified, so `changed` is true by construction rather than by measurement here.
      result = Result.new(id: repository.id.to_s, clone_url: repository.clone_url,
                          default_branch: repository.default_branch, changed: true,
                          base_commit: repository.base_commit, head_commit: nil, branch: nil,
                          pull_request_url: nil, publication_error: nil,
                          publication_skipped_reason: nil)
      return result unless publish?
      return skipped(result) unless policy_assigned? && writable?

      branch = repository.branch.to_s
      return blocked(result, "no canonical branch was assigned for this run") if branch.empty?
      return blocked(result, default_branch_refusal(branch)) if default_branch?(branch)

      publish_changed(result, branch)
    end

    # Policy never asked for this repository to be published — read-only access, or a Platform
    # that sends no publication policy at all. That is a POLICY decision, not a failure: it is
    # reported with the observed change state and a descriptive reason, and it must not fail the
    # run (review-001 finding 3).
    def skipped(result)
      result.publication_skipped_reason =
        "repository is configured read-only; SpecRelay reported the change without publishing it"
      log("Did not publish #{result.id}: repository is read-only by policy (not a failure).")
      result
    end

    # spec.md §2 places "MUST NOT push to a default branch such as main" on the RUNNER,
    # not only on Platform's branch policy. This is the runner-side half of that
    # guarantee: a Platform regression, or a hand-crafted or replayed assignment, can
    # still never make the runner push onto the default branch (review-001 finding 4).
    def default_branch?(branch)
      default = repository.default_branch.to_s.strip
      return false if default.empty?

      branch == default
    end

    def default_branch_refusal(branch)
      "refusing to publish onto #{branch}, which is the repository's default branch; " \
        "SpecRelay only pushes a dedicated task branch"
    end

    def blocked(result, reason)
      result.publication_error = reason
      log("Publication blocked for #{result.id}: #{reason}")
      result
    end

    def publish_changed(result, branch)
      commit = ensure_commit(branch)
      return blocked(result, commit.error) if commit.error

      result.head_commit = commit.head_commit
      push = push_branch(branch)
      return blocked(result, push.error) if push.error

      result.branch = branch
      return result unless create_pull_requests?

      pull_request = ensure_pull_request(branch, result)
      return blocked(result, pull_request.error) if pull_request.error

      result.pull_request_url = pull_request.url
      result
    end

    Step = Struct.new(:head_commit, :url, :error, keyword_init: true)

    # Commits the executor's output. `git add -A` then a commit with a stable,
    # task-identifying subject. On retry the tree is already clean, so the existing
    # head is reused rather than creating a second, noisy commit.
    def ensure_commit(branch)
      add = git(%w[add -A])
      return Step.new(error: failure_reason(add, "git add")) unless add.success?

      clean = working_tree_clean
      return Step.new(error: clean.error) if clean.error
      # The clean tree IS the retry path, so it needs the same guard as the post-commit
      # path: returning a raw nil head here let a retry render "…but this run pushed "
      # with a blank (review-004 R4-F3).
      return resolved_head if clean.clean

      commit = git([ "-c", "user.name=#{COMMIT_AUTHOR_NAME}", "-c", "user.email=#{COMMIT_AUTHOR_EMAIL}",
                     "commit", "--no-verify", "-m", commit_message(branch) ])
      return Step.new(error: failure_reason(commit, "git commit")) unless commit.success?

      log("Committed repository output on #{branch}.")
      resolved_head
    end

    # The commit message identifies the SpecRelay run and the Jira/task id, and
    # carries no secrets, prompt text, provider transcript, or model reasoning.
    def commit_message(branch)
      <<~MESSAGE.strip
        #{task_id}: SpecRelay automated execution output

        Published by the SpecRelay standalone runner for run #{run_id}
        on branch #{branch}.
      MESSAGE
    end

    def push_branch(branch)
      # Explicit refspec: push this worktree's HEAD to the Platform-assigned branch.
      # Never a force push, so a diverged remote branch fails closed instead of
      # destroying someone else's work.
      result = git([ "push", REMOTE, "HEAD:refs/heads/#{branch}" ])
      return Step.new if result.success?

      Step.new(error: push_error(result))
    end

    def push_error(result)
      text = combined(result)
      return diverged_refusal if !result.timed_out? && text.match?(/non-fast-forward|fetch first|rejected/i)
      if !result.timed_out? && text.match?(/authentication|permission denied|could not read Username/i)
        return "git push failed: authentication was refused on this runner host; " \
               "check the git credential setup where the runner executes, then release and re-run the task"
      end

      failure_reason(result, "git push")
    end

    # spec.md Outcome 4 requires a precise, secret-safe reason AND a next step. The
    # diverged case is the one an operator is most likely to hit — an earlier attempt
    # pushed the branch and then lost its lease — and it is unrecoverable without
    # touching the remote, so the remedy has to be stated (review-001 finding 5).
    def diverged_refusal
      "git push rejected: the remote branch has diverged and SpecRelay never force-pushes. " \
        "Inspect the remote branch; if it is a stale SpecRelay attempt, delete it " \
        "(`git push origin --delete <branch>`), then release and re-run the task. " \
        "If it holds work you need, merge or rename it first"
    end

    # A single place that turns a failed CommandRunner result into a non-empty,
    # secret-safe reason. A timeout leaves exit_code nil and stdout/stderr empty, which
    # previously produced the bare reason "git push failed: " and a blank operator
    # message (review-001 finding 6).
    def failure_reason(result, label)
      return "#{label} timed out after #{result.duration_seconds.round}s on this runner host" if result.timed_out?

      detail = first_line(result)
      return "#{label} failed with exit status #{result.exit_code.inspect} and no output" if detail.empty?

      "#{label} failed: #{detail}"
    end

    # Reuse before create, so a retry can never open a second pull request for the
    # same branch. The lookup FAILS CLOSED: if we cannot establish whether a pull
    # request already exists, we report that and stop, because guessing "none" and
    # creating is how a retry produced a duplicate (review-001 finding 1).
    def ensure_pull_request(branch, result)
      # The identity was normalized once, by the verifier that read it from this repository's own
      # `origin` ({GithubRemote}). There is no second parse here, so `gh` can never be asked about
      # a different repository than the one whose pull-request URL is validated.
      slug = repository.id.to_s
      return Step.new(error: "cannot resolve the GitHub repository for #{result.id}") if slug.empty?
      return Step.new(error: gh_unavailable_reason) unless gh_available?

      # result.head_commit is the commit this run actually committed and pushed, which is
      # what the pull request has to contain. Passing anything else here is what made
      # CR-001's guard refuse a pull request whose head WAS our commit (review-003).
      lookup = find_open_pull_request(slug, branch, result.head_commit)
      return Step.new(error: lookup.error) if lookup.error
      return Step.new(url: lookup.url) if lookup.url

      create_pull_request(slug, branch, result)
    end

    # The outcome of asking GitHub whether a reusable pull request exists. `url` set
    # means reuse it; `error` set means we could not tell; both nil means there is
    # definitively none and creating is safe.
    Lookup = Struct.new(:url, :error, keyword_init: true)

    # Only an OPEN pull request on this exact branch may be reused.
    #
    # `--state open` (not `all`) is the fix for review-001 finding 2: a closed or
    # merged pull request from an earlier round on the same deterministic
    # `specrelay/<KEY>` branch no longer tracks the branch, so reporting it would
    # link a pull request that does not contain this round's commit. Excluding it
    # here means such a round opens a fresh pull request instead — the recorded
    # choice CR-001 asks for.
    def find_open_pull_request(slug, branch, pushed_head)
      result = gh([ "pr", "list", "--repo", slug, "--head", branch, "--state", "open",
                    "--limit", "10", "--json", "url,state,headRefName,headRefOid" ])
      return Lookup.new(error: lookup_failure(result)) unless result.success?

      entries = parse_pull_requests(result.stdout)
      return Lookup.new(error: "could not read the pull-request list for #{branch}") if entries.nil?

      reusable(entries, branch, pushed_head)
    end

    def lookup_failure(result)
      "could not determine whether a pull request already exists for this branch " \
        "(#{failure_reason(result, 'gh pr list')}); SpecRelay will not create one " \
        "without knowing, so release and re-run the task"
    end

    # The only decisions that permit reuse, in preference order: an exact match is
    # preferred over a lagging GitHub snapshot. This constant is the SINGLE source of
    # truth — `reusable` derives its behaviour from it and the table-driven test pins
    # it, so a decision cannot join the reusable set in one place only (review-005
    # R5-F2, which found the set duplicated as a hardcoded expression here).
    #
    # MVP-0027 moved the set and the predicate it belongs to into {PullRequestReuse} so the
    # specification lane holds the same copy rather than a second implementation. This alias
    # keeps the constant readable at its original name; the authority is the module.
    REUSABLE_DECISIONS = PullRequestReuse::REUSABLE_DECISIONS

    # Belt and braces on top of `--state open`: the pull request must name this branch,
    # and its head must be shown to contain the commit THIS RUN PUSHED — `pushed`, taken
    # from result.head_commit, never the pre-commit worktree head.
    def reusable(entries, branch, pushed)
      candidates = entries.select { |pr| pr["headRefName"].to_s == branch && pr["url"].to_s.start_with?("https://") }
      return Lookup.new if candidates.empty?

      pushed = pushed.to_s
      decisions = candidates.to_h { |pr| [ pr, reuse_decision(pr["headRefOid"].to_s, pushed) ] }
      match = REUSABLE_DECISIONS.lazy.filter_map { |decision| decisions.key(decision) }.first
      if match.nil?
        first, decision = decisions.first
        return Lookup.new(error: refusal_for(decision, first, branch, pushed))
      end

      log("Reusing the existing open pull request for #{branch}: #{match['url']}")
      Lookup.new(url: match["url"])
    end

    # THE reuse decision. One enumerated predicate over the whole input space, replacing
    # the incremental guards that produced a fail-open in four consecutive rounds
    # (review-001 finding 2, review-002/CR-002, the round-003 self-audit, review-004
    # R4-F1). Every row below is asserted by a table-driven test against a REAL commit
    # chain. A newly discovered input class becomes a new row here — never a new branch
    # somewhere else.
    #
    #   reported vs pushed                     decision                 outcome
    #   -------------------------------------  -----------------------  -------
    #   pushed empty (ours unknown)            :pushed_head_unknown     refuse
    #   both empty                             :pushed_head_unknown     refuse
    #   reported empty or absent               :reported_head_unknown   refuse
    #   equal                                  :head_matches            REUSE
    #   reported is an ancestor of pushed      :reported_is_ancestor    REUSE
    #   pushed is an ancestor of reported      :reported_head_ahead     refuse
    #   divergent sibling                      :heads_diverged          refuse
    #   reported is an unknown object          :heads_diverged          refuse
    #
    # Why `reported_head_ahead` is its own row rather than `:heads_diverged` (review-005
    # R5-F1). The two are opposite factual situations and must not share an operator
    # message: when the pushed commit is an ancestor of the reported head, the pull request
    # verifiably DOES contain this run's commit, so the diverged wording ("may not contain
    # this run's commit") asserted the opposite of what git had just proven. The decision to
    # refuse is unchanged and deliberate — the pull request carries commits this run never
    # validated, so it is not this run's reviewable output — but the reason now says that.
    #
    # Why `reported empty` REFUSES. It used to reuse, justified as "gh's omission, not our
    # uncertainty". That does not hold: `parse_pull_requests` already fails closed on an
    # unparseable list, which is equally gh's problem. We asked for `headRefOid` in
    # `--json`; a requested field that comes back missing means we could not determine the
    # head, and whose fault that is has no bearing on whether linking an unverified pull
    # request as this run's output is safe.
    #
    # MVP-0027 moved the table itself into {PullRequestReuse} so the specification lane's
    # publication path decides reuse by the same rows rather than by a second implementation of
    # them. The comment above stays here because this is where the four rounds happened; the
    # module carries it too, and the module is the authority. `ancestor?` — the one part that
    # touches a repository — remains this class's, which is exactly the boundary that made the
    # rest shareable.
    def reuse_decision(reported, pushed)
      PullRequestReuse.decide(reported: reported, pushed: pushed,
                              ancestor: ->(candidate, descendant) { ancestor?(candidate, descendant) })
    end

    def refusal_for(decision, pull_request, branch, pushed)
      case decision
      when :pushed_head_unknown
        "could not establish which commit this run pushed, so the open pull request for " \
          "#{branch} cannot be confirmed to contain it; release and re-run the task"
      when :reported_head_unknown
        "GitHub reported no head commit for the open pull request for #{branch} " \
          "(#{pull_request['url']}), so SpecRelay cannot confirm it contains this run's " \
          "commit #{pushed}; release and re-run the task"
      when :reported_head_ahead
        ahead_head_refusal(pull_request, branch, pushed)
      else
        stale_head_refusal(pull_request, branch, pushed)
      end
    end

    def ancestor?(candidate, descendant)
      git([ "merge-base", "--is-ancestor", candidate, descendant ]).success?
    end

    # The pull request contains this run's commit AND more. Say exactly that, name the
    # extra commits so the operator can look at them, and give the same next step the
    # other refusals give (review-005 R5-F1: the diverged wording claimed the opposite
    # and offered no way forward).
    def ahead_head_refusal(pull_request, branch, pushed)
      reported = pull_request["headRefOid"].to_s
      "the open pull request for #{branch} (#{pull_request['url']}) reports head #{reported}, " \
        "which contains this run's commit #{pushed} plus #{extra_commit_phrase(pushed, reported)} " \
        "SpecRelay did not execute or validate; refusing to report it as this run's output. " \
        "Review those commits (`git log #{pushed}..#{reported}`), then release and re-run the task"
    end

    def extra_commit_phrase(pushed, reported)
      count = commits_between(pushed, reported)
      return "later commits" if count.nil?

      "#{count} later #{count == 1 ? 'commit' : 'commits'}"
    end

    # Best-effort detail for the message only: a failure here must never change the
    # decision, so an unparseable count degrades to unquantified wording.
    def commits_between(pushed, reported)
      result = git([ "rev-list", "--count", "#{pushed}..#{reported}" ])
      return nil unless result.success?

      count = result.stdout.to_s.strip
      count.match?(/\A\d+\z/) ? count.to_i : nil
    end

    def stale_head_refusal(pull_request, branch, pushed)
      "the open pull request for #{branch} reports head #{pull_request['headRefOid']} but this run " \
        "pushed #{pushed}; refusing to report a pull request that may not contain this run's commit"
    end

    def create_pull_request(slug, branch, result)
      argv = [ "pr", "create", "--repo", slug, "--head", branch,
               "--base", repository.default_branch.to_s, "--title", pull_request_title,
               "--body", pull_request_body(branch) ]
      argv << "--draft" if draft_pull_request?
      created = gh(argv)
      return Step.new(error: failure_reason(created, "gh pr create")) unless created.success?

      # Fall back to a lookup only when the CLI printed no URL. A failed fallback
      # lookup is reported rather than silently swallowed.
      url = first_url(created.stdout)
      if url.nil?
        lookup = find_open_pull_request(slug, branch, result.head_commit)
        return Step.new(error: lookup.error) if lookup.error

        url = lookup.url
      end
      return Step.new(error: "gh pr create reported no pull-request URL") if url.nil?

      log("Opened #{draft_pull_request? ? 'draft ' : ''}pull request for #{result.id}: #{url}")
      Step.new(url: url)
    end

    def pull_request_title = "#{task_id}: SpecRelay automated execution output"

    # Stable, secret-safe body. It links the Platform run and the work item using the
    # URLs Platform supplied (never runner-invented), and summarizes the diff and the
    # validation result. It deliberately contains no prompt text, provider transcript,
    # model reasoning, or credential material.
    def pull_request_body(branch)
      files = changed_files
      lines = [
        "SpecRelay executed this change automatically from an approved specification.",
        "", "- Task: #{task_id}", "- Run: #{run_id}", "- Branch: #{branch}"
      ]
      lines << "- Platform run: #{links['run_url']}" unless links["run_url"].to_s.empty?
      lines << "- Work item: #{links['work_item_url']}" unless links["work_item_url"].to_s.empty?
      lines << "- Validation: `#{test[:command]}` exited #{test[:exit_code]}"
      lines.concat([ "", "## Changed files (#{files.length})", "" ])
      lines.concat(files.first(MAX_BODY_FILES).map { |file| "- `#{file}`" })
      lines << "- …and #{files.length - MAX_BODY_FILES} more" if files.length > MAX_BODY_FILES
      lines.concat([ "", "Review the Platform run for the full execution report and evidence." ])
      Redaction.redact(lines.join("\n"))
    end

    def links = payload["links"].to_h

    # `gh` is optional infrastructure on the runner host. When it is missing or
    # unauthenticated the branch is still published and the failure is reported as a
    # publication_error with the exact operator remedy — Platform then treats the
    # publication as incomplete rather than pretending it succeeded.
    def gh_available?
      return @gh_available if defined?(@gh_available)

      @gh_available = gh(%w[auth status]).success?
    end

    def gh_unavailable_reason
      "the GitHub CLI (gh) is unavailable or unauthenticated on this runner host; " \
        "run `gh auth login` where the runner executes, then release and re-run the task"
    end

    Cleanliness = Struct.new(:clean, :error, keyword_init: true)

    # A failed `git status` must not read as "clean": that would skip the commit and
    # publish whatever the previous head was.
    def working_tree_clean
      result = git(%w[status --porcelain])
      return Cleanliness.new(error: failure_reason(result, "git status")) unless result.success?

      Cleanliness.new(clean: result.stdout.to_s.strip.empty?)
    end

    # The head is not optional: it is the commit we push AND the value the reuse decision
    # compares against. It must also be shaped like a commit — the equality row of
    # reuse_decision short-circuits before any git call, so a non-SHA value that `git
    # rev-parse` happened to print (a wrapper's warning, a shell alias) would otherwise
    # satisfy the comparison against itself (review-004 R4-F4).
    def resolved_head
      head = head_commit.to_s
      return Step.new(error: "could not resolve the worktree head") if head.empty?
      return Step.new(error: "the worktree head is not a commit sha") unless head.match?(COMMIT_PATTERN)

      Step.new(head_commit: head)
    end

    def head_commit
      result = git(%w[rev-parse HEAD])
      result.success? ? result.stdout.to_s.strip : nil
    end

    def git(args) = run([ "git", "-C", worktree_path, *args ], GIT_TIMEOUT_SECONDS)
    def gh(args) = run([ "gh", *args ], GH_TIMEOUT_SECONDS)

    # Publication needs more of the operator's environment than the executor does:
    # HOME for git/gh config, SSH_AUTH_SOCK for an agent key, and the GH_*/GIT_*
    # variables a credential setup may rely on. Only these names are forwarded, and
    # none of their values is ever logged.
    def run(argv, timeout_seconds)
      CommandRunner.run(argv, chdir: worktree_path, env: publication_env, timeout_seconds: timeout_seconds)
    rescue SystemCallError => e
      # A missing or non-executable binary (`gh` not installed on this host) must
      # degrade into a reported publication_error, never crash the attempt. Process
      # spawn failures surface as Errno subclasses, so SystemCallError is the
      # narrowest boundary that covers them.
      CommandRunner::Result.new(exit_code: 127, stdout: "", stderr: e.message.to_s,
                                duration_seconds: 0.0, timed_out: false)
    end

    FORWARDED_ENV = %w[PATH HOME SSH_AUTH_SOCK SSH_AGENT_PID GH_TOKEN GH_CONFIG_DIR
                       GIT_SSH_COMMAND GIT_CONFIG_GLOBAL XDG_CONFIG_HOME].freeze

    def publication_env
      @publication_env ||= FORWARDED_ENV.each_with_object({}) do |name, acc|
        value = env[name]
        acc[name] = value.to_s unless value.nil?
      end
    end

    # Returns the parsed entries, or nil when the payload could not be read at all —
    # nil is "could not tell", which the caller turns into a fail-closed error rather
    # than into "no pull request exists".
    def parse_pull_requests(json)
      parsed = JSON.parse(json.to_s)
      return nil unless parsed.is_a?(Array)

      parsed.select { |entry| entry.is_a?(Hash) }
    rescue JSON::ParserError
      nil
    end

    def first_url(text) = text.to_s[%r{https://github\.com/\S+/pull/\d+}]

    def combined(result) = [ result.stderr, result.stdout ].join("\n")

    def first_line(result)
      Redaction.redact(combined(result).strip).each_line.map(&:strip).find { |line| !line.empty? }.to_s
    end

    def log(message) = io.puts(Redaction.redact(message.to_s))
  end
end
