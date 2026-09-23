# frozen_string_literal: true

require "time"

module SpecrelayRunner
  module Specification
    # Orchestrates ONE claimed specification-PUBLICATION assignment end to end (MVP-0027).
    #
    # The specification lane's third phase and a sibling of {Generation}, not a mode of it. The
    # two share a claim identity, a lease, and an API client, and nothing else: this one
    # generates nothing, calls no provider, writes no file into the package, and reads the
    # operator's checkout only to digest it.
    #
    # The ORDER is the contract, and every step before `GitPublisher` is reversible by doing
    # nothing:
    #
    #   parse -> RESUME the isolated workspace -> VERIFY it -> check `gh` -> commit+push
    #   -> draft PR -> report -> clean up only once Platform has accepted
    #
    # Verification runs before any git command, so criterion 2's "refuses before Git mutation on
    # mismatch" is a property of this sequence rather than of a rollback. The `gh` check runs
    # before the commit for the same kind of reason: a host that cannot open a pull request must
    # not first push a branch nobody will be asked to review.
    #
    # MAPIAI-62 replaced the first step outright. It used to RE-RESOLVE the operator's
    # specification checkout from configuration, independently of generation and with no pin
    # between the two, so the two phases could resolve different directories — which is exactly
    # what the live MAPIAI-53 run did. The runner now resumes the one workspace it created, by
    # the opaque id Platform stored and handed back, under the same local lock generation held.
    # There is no checkout resolution here any more and no fallback to one.
    #
    # It fails CLOSED at every step. Nothing here can report `published`, and therefore nothing
    # can move the run to awaiting approval, unless a draft pull request verifiably exists — a
    # pushed branch with a failed pull request is reported as a FAILURE that carries the branch
    # as evidence.
    #
    # It touches no Jira field, transitions no issue, and adds no comment. There is no Jira
    # client here and no code path to one; MVP-0028 owns that.
    class Publication
      Aborted = Class.new(StandardError)

      CONTRACT_VERSION = "mvp-0027"
      DEFAULT_RENEWAL_SECONDS = 30

      # The wire vocabulary for the publication result, kept as constants so the runner and the
      # contract schema cannot drift apart in a string literal.
      OUTCOME_PUBLISHED = "published"
      OUTCOME_FAILED = "failed"

      PUBLISHED = :published
      FAILED = :publication_failed
      ABORTED = :aborted

      ASSIGNMENT_MALFORMED = "publication_assignment_malformed"
      # MAPIAI-62 — another process on this machine holds the workspace lock for this package.
      # A refusal rather than a wait: the lease is finite, and blocking on a lock another
      # publication holds would burn it and then publish the same package twice.
      WORKSPACE_BUSY = "specification_workspace_busy"
      # Local outcome only. Platform refused the result, so by definition Platform stored no
      # failure class of its own; this one names the condition in the runner's exit and log.
      REPORT_REFUSED = "publication_report_refused"

      Result = Struct.new(:outcome, :message, :pull_request_url, :branch, :head_commit, keyword_init: true) do
        def success? = outcome == PUBLISHED
      end

      def self.call(**kwargs) = new(**kwargs).call

      # Discard what a specification Run left on this machine once its ending is definitive —
      # Platform recorded its result, or explicitly cancelled it. The one rule for both phases:
      # {Generation} calls it for its own failures and cancellations.
      #
      # The proved publication snapshot goes first, because it is this runner's own directory;
      # then the project is ASKED to release the ticket's task environment, for the Run that owns
      # it. Published commits, branches and pull requests are never touched. Either step failing
      # is a cleanup failure of its own, raised as {CleanupRequired} so the invocation exits
      # nonzero and a loop claims nothing more; an unremoved snapshot keeps the environment too.
      def self.discard_local_state!(workspace:, assignment:, config:, env:, io:)
        if workspace && !workspace.remove!(commands_for: ->(root) { GitCommands.new(checkout_root: root, env: env) })
          raise CleanupRequired, "the package workspace #{workspace.id} could not be removed, so the " \
                                 "task environment #{assignment.task_id} was not released"
        end
        released = TaskEnvironmentCleanup.call(assignment: assignment, config: config, env: env)
        raise CleanupRequired, released.reason unless released.released?

        io.puts("Released this ticket's task environment.")
      end

      def initialize(config:, client:, payload:, env: ENV, io: $stdout, clock: Time, settings: nil,
                     workspaces: nil)
        @config = config
        @client = client
        @payload = payload.to_h
        @env = env
        @io = io
        @clock = clock
        @injected_settings = settings
        @workspaces = workspaces || PackageWorkspaceStore.for(env: env)
        @heartbeater = nil
      end

      def call
        assignment = Assignment.parse(payload).validate_publication!
        @assignment = assignment
        announce(assignment)
        publish(assignment)
      rescue Assignment::Malformed => e
        fail_closed(ASSIGNMENT_MALFORMED, e.message)
      end

      private

      attr_reader :config, :client, :payload, :env, :io, :clock, :assignment, :workspaces

      def settings = @settings ||= @injected_settings || Settings.from(config, env: env)

      def announce(assignment)
        log("Claimed a SPECIFICATION PUBLICATION assignment for #{assignment.issue_key} " \
            "(run #{assignment.run_id}).")
        log("  Repository: #{assignment.publication_repository_url}")
        log("  Branch:     #{assignment.publication_branch} (base #{assignment.publication_base_branch})")
        log("  Updates:    #{assignment.existing_pull_request_url}") unless assignment.existing_pull_request_url.empty?
        log("  Package:    #{assignment.generated_package_path}")
      end

      # The whole sequence, guarded by the lease AND by the local workspace lock.
      #
      # The lock is taken for the WHOLE publication, not just the verification: it is what makes
      # "two processes with the same registration cannot publish the same package concurrently"
      # true on this machine, and what stops the retention sweep from removing a workspace that
      # is mid-publication. Platform's active-execution index remains the authoritative rule
      # across machines; this is the local half of the same invariant.
      def publish(assignment)
        start_heartbeater(assignment)
        held = workspaces.with_lock(assignment.generated_package_workspace_id, blocking: false) do
          publish_locked(assignment)
        end
        held || fail_closed(WORKSPACE_BUSY, busy_message)
      rescue Aborted => e
        aborted(e)
      ensure
        @heartbeater&.stop
      end

      # `@workspace` is set only once the snapshot is PROVED to be the one Platform recorded; it is
      # the only snapshot a later discard may remove.
      def publish_locked(assignment)
        checked = PackageWorkspaceCheck.call(workspaces: workspaces, assignment: assignment,
                                             config: config, env: env, clock: clock)
        return refuse_workspace(checked) unless checked.ok?

        @workspace = checked.workspace

        checkpoint!
        push_and_open(assignment, checked.workspace, checked.files)
      end

      def busy_message
        "another process on this machine is already working in the isolated workspace for this " \
          "package. Wait for it to finish; this run stays publishable and will be offered again"
      end

      # `gh` is checked BEFORE the commit, not after the push. A host without an authenticated
      # GitHub CLI can still push, so checking later would leave a branch on a shared repository
      # for a publication that was never going to be reviewable.
      #
      # MVP-0028 adds one step in front of the commit and none after it: resolving WHICH BRANCH
      # this publication belongs on. That has to happen before any git mutation, because for a
      # ticket that already has a `Spec PR` the answer comes from GitHub, and every way it can
      # come back unusable (closed, merged, missing, wrong base, from a fork) must refuse the
      # publication rather than fork a second branch off it.
      # Every git and `gh` command runs in the ISOLATED WORKTREE, never in the operator's
      # checkout. It is a linked worktree of the same repository, so it shares the object
      # database, the `origin` remote and the credential helper — everything publication needs —
      # while HEAD, the index and the working tree it can reach belong to this runner alone.
      def push_and_open(assignment, workspace, verified)
        commands = GitCommands.new(checkout_root: workspace.worktree_root, env: env)
        return fail_closed(PullRequestPublisher::GH_UNAVAILABLE, PullRequestPublisher.unavailable_message) unless
          PullRequestPublisher.available?(commands: commands)

        branch = resolve_branch(assignment, commands)
        return branch if branch.is_a?(Result)

        pushed = GitPublisher.call(commands: commands, assignment: assignment, branch: branch,
                                   files: verified, io: io)
        return fail_closed(pushed.failure_class, pushed.message) unless pushed.ok?

        opened = PullRequestPublisher.call(commands: commands, assignment: assignment, branch: branch,
                                           files: verified, head_commit: pushed.head_commit, io: io)
        return fail_closed(opened.failure_class, opened.message, pushed: pushed) unless opened.ok?

        checkpoint!
        succeed(workspace, verified, pushed, opened)
      end

      # A workspace that could not be resumed or proved. Reported with its own failure class so
      # the run page can say WHICH of "gone", "expired" and "not what Platform recorded" it was —
      # the three have the same remedy but not the same cause, and an operator told the wrong one
      # goes looking in the wrong place.
      def refuse_workspace(checked)
        log(checked.message)
        fail_closed(checked.failure_class, checked.message)
      end

      # The branch this publication belongs on: the head of the ticket's existing specification
      # pull request when Jira names one, otherwise the branch Platform derived.
      #
      # Asking GitHub rather than re-deriving is the whole of criterion 3's rename case. The
      # ticket-owned branch name carries a slug of the ticket TITLE, and a ticket can be renamed
      # after its pull request is open; the open pull request remains the source of truth and
      # keeps the branch it was opened on. Re-deriving would open a second pull request for one
      # ticket, which is what this MVP exists to stop.
      #
      # Returns the branch, or a Result when the existing pull request cannot be used — in which
      # case nothing has been committed, pushed, or opened.
      def resolve_branch(assignment, commands)
        url = assignment.existing_pull_request_url
        return assignment.publication_branch if url.empty?

        existing = ExistingPullRequest.call(commands: commands, slug: assignment.publication_slug,
                                           base_branch: assignment.publication_base_branch, url: url, io: io)
        return fail_closed(existing.failure_class, existing.message) unless existing.ok?

        @publication_branch = existing.branch
      end

      # What the runner REPORTS as the branch it published on, which is what Platform validates.
      # Falls back to the assigned branch, so a failure that happens before resolution still names
      # the branch Platform expected rather than nothing.
      def publication_branch = @publication_branch || assignment&.publication_branch

      # ------------------------------------------------------------------ outcomes

      # `published` is claimed only once Platform has ACCEPTED the result. The pull request
      # existing is not the same fact as the run having advanced, and only Platform can say the
      # second one happened.
      def succeed(workspace, verified, pushed, opened)
        submission = submit(success_payload(verified, pushed, opened))
        return report_refused(submission.message, pushed, opened) if submission.refused?

        log("")
        log("Published #{verified.length} files on #{publication_branch} as a draft pull request:")
        log("  #{opened.url}")
        # MVP-0028 remediation, defect 8. This line used to read "No Jira field was written, no
        # status was transitioned, and no comment was added" — true of the RUNNER, and printed
        # microseconds before Platform wrote all three. An operator reading the last line of a
        # successful run was told the ticket was untouched when it was about to be updated.
        #
        # The fix is to state the BOUNDARY rather than a moment: the runner never writes Jira, and
        # Platform finalizes after accepting this result. That stays true whenever it is read.
        log("This runner does not write Jira. Platform finalizes the ticket — Spec PR field, " \
            "comment and status — after accepting this publication.")
        submission.accepted? ? discard(workspace) : retain_for_replay
        Result.new(outcome: PUBLISHED, pull_request_url: opened.url, branch: publication_branch,
                   head_commit: pushed.head_commit,
                   message: "Runner outcome: published (draft pull request #{opened.url}).")
      end

      # Local cleanup, and ONLY after Platform has recorded this Run's ending (design 4): its
      # accepted result, or its explicit cancellation. Removing the package before that would
      # destroy the one copy a refused or unanswered report still needs to retry from.
      #
      # The outcome is already printed when this runs, so a cleanup failure — raised, never a
      # warning — is reported after it rather than instead of it.
      def discard(workspace)
        self.class.discard_local_state!(workspace: workspace, assignment: assignment, config: config,
                                        env: env, io: io)
      end

      # Platform never answered, so it holds no record and will offer this run again. Keeping the
      # workspace is what makes that replay converge: the same files produce the same tree, so
      # {GitPublisher} creates no second commit and {PullRequestPublisher} reuses the pull request.
      def retain_for_replay
        log("This runner is keeping its local package so the next attempt republishes the same " \
            "commit rather than regenerating.")
      end

      # Platform READ the result and refused it. The draft pull request genuinely exists, but
      # Platform holds no record of it, the run did not move to awaiting approval, and no retry
      # of the same body can change that — so this is a FAILURE, not a success with a footnote.
      # Printing "Published" here and exiting 0 is precisely the false success the fail-closed
      # rule exists to prevent (review-001 P2-2).
      #
      # Nothing further is posted. A failure payload would be a SECOND write claiming the
      # publication failed, which is false about GitHub; Platform's record is left untouched and
      # the claim is left to expire, after which a later attempt reuses this branch and PR.
      def report_refused(message, pushed, opened)
        log("")
        log("Platform REFUSED this publication result: #{message}")
        log("The draft pull request exists on GitHub, but Platform holds no record of it and the " \
            "run was NOT moved to awaiting approval.")
        log("  Branch:       #{publication_branch}")
        log("  Pull request: #{opened.url}")
        log("Fix what Platform refused; the next attempt on this run reuses both.")
        Result.new(outcome: FAILED, pull_request_url: opened.url, branch: publication_branch,
                   head_commit: pushed.head_commit,
                   message: "Runner outcome: publication_failed (#{REPORT_REFUSED}).")
      end

      # A failure at ANY step, including one after the branch reached the remote. `pushed` is
      # carried through when there is one, because a branch on a shared repository is the fact
      # that decides whether an operator has something to look at — and hiding it would make the
      # failure look tidier than it is.
      def fail_closed(failure_class, message, pushed: nil)
        text = Redaction.redact(message.to_s)
        log("")
        log("Specification publication failed: #{text}")
        log("The run was NOT moved to awaiting approval and Jira was not touched.")
        submission = submit(failure_payload(failure_class, text, pushed))
        # Already a failure, so the outcome does not change — but the operator must not be left
        # believing Platform recorded a failure it in fact refused.
        log("Platform REFUSED this failure report: #{submission.message}") if submission.refused?
        # A recorded failure ends the Run. Only a proved snapshot is removed; an assignment that
        # never parsed names no environment to release.
        discard(@workspace) if submission.accepted? && assignment
        Result.new(outcome: FAILED, branch: pushed ? publication_branch : nil,
                   head_commit: pushed&.head_commit,
                   message: "Runner outcome: publication_failed (#{failure_class}).")
      end

      # Platform cancelled the claim or the lease lapsed. NOTHING is reported: Platform already
      # owns the outcome, and a late success from a superseded attempt is what the liveness
      # signal exists to prevent. Anything already pushed stays on the remote — deleting a branch
      # because a lease expired would be a worse surprise than an unreferenced one. Only an explicit
      # cancellation is a recorded ending, so only it discards the local state.
      def aborted(error)
        reason = error.message.to_s.empty? ? "the lease is no longer live" : error.message
        log("")
        log("Stopping: Platform reports #{reason}. No publication result was submitted.")
        log("Anything already pushed is left in place and is NOT recorded as this run's result.")
        discard(@workspace) if reason == Execution::CANCELLED
        Result.new(outcome: ABORTED,
                   message: "Runner outcome: aborted (#{reason}); no publication result was reported.")
      end

      # ------------------------------------------------------------------- payloads

      def success_payload(verified, pushed, opened)
        base_payload(OUTCOME_PUBLISHED).merge(
          "repository_url" => assignment.publication_repository_url,
          "branch" => publication_branch,
          "head_commit" => pushed.head_commit,
          "pull_request_url" => opened.url,
          "pull_request_draft" => opened.draft?,
          "reused_branch" => pushed.reused_branch?,
          "reused_pull_request" => opened.reused?,
          "files" => verified.map { |file| { "path" => file.repository_path, "sha256" => file.sha256 } }
        )
      end

      def failure_payload(failure_class, message, pushed)
        base_payload(OUTCOME_FAILED).merge(
          "repository_url" => assignment&.publication_repository_url.to_s,
          "branch" => pushed ? publication_branch : "",
          "head_commit" => pushed&.head_commit.to_s,
          "failure_class" => failure_class,
          "message" => message
        )
      end

      # Read from the RAW payload rather than the parsed assignment, for the same reason the
      # generation path does: the claim identity is the one thing a failure must carry even when
      # the assignment itself was what failed validation.
      def base_payload(outcome)
        {
          "contract_version" => CONTRACT_VERSION,
          "outcome" => outcome,
          "run_id" => payload.dig("run", "id").to_s,
          "runner_execution_id" => claim_token,
          "published_at" => clock.now.utc.iso8601,
          "runner_version" => VERSION
        }
      end

      def claim_token = payload.dig("claim", "runner_execution_id").to_s

      # THREE outcomes, not two, and MAPIAI-62 is why the third had to become distinguishable.
      #
      #   accepted    — Platform read the result and recorded it. The only state in which the
      #                 local package may be deleted (design 4).
      #   refused     — Platform read it and rejected it. The local outcome is invalidated as
      #                 something to report, and the package is kept for the operator's next move.
      #   unreachable — Platform never answered. The pull request exists either way, but Platform
      #                 holds no record, so this run WILL be offered again — and the retained
      #                 workspace is the only thing that lets that replay converge on the same
      #                 commit instead of failing closed (S16).
      #
      # The old implementation returned nil for both `accepted` and `unreachable`, which was
      # harmless while nothing acted on the difference and became a data-loss bug the moment
      # cleanup did.
      Submission = Struct.new(:state, :message, keyword_init: true) do
        def accepted? = state == :accepted
        def refused? = state == :refused
      end

      def submit(publication)
        claim = publication["runner_execution_id"].to_s
        if claim.empty?
          log("(no claim identity in the assignment — nothing was reported to Platform)")
          return Submission.new(state: :unreachable)
        end

        response = client.submit_specification_publication(claim: claim, publication: publication)
        log("Platform recorded the result: run #{response['run_state']} (#{response['outcome']}).")
        Submission.new(state: :accepted)
      rescue PlatformClient::Error => e
        text = Redaction.redact(e.message)
        return Submission.new(state: :refused, message: text) if e.refused?

        # A TRANSPORT failure only. The remote outcome is already true — the branch and the pull
        # request exist or they do not. Failing to REACH Platform is a separate problem with its
        # own remedy, and it must not be reported as a publication failure, which would send the
        # operator to look at GitHub for something that is not wrong there.
        log("Could not report the result to Platform: #{text}")
        log("The outcome above still stands. Platform will reclaim this run when the lease expires.")
        Submission.new(state: :unreachable, message: text)
      end

      # ------------------------------------------------------------------- lifecycle

      def start_heartbeater(assignment)
        @heartbeater = Heartbeater.new(
          client: client, claim: assignment.runner_execution_id,
          interval_seconds: renewal_seconds(assignment), io: io,
          stop_after_seconds: stop_heartbeat_after
        ).start
      end

      def renewal_seconds(assignment)
        seconds = assignment.lease_renewal_seconds
        seconds.positive? ? seconds : DEFAULT_RENEWAL_SECONDS
      end

      def stop_heartbeat_after
        value = env[Execution::STOP_HEARTBEAT_ENV].to_i
        value.positive? ? value : nil
      end

      # A phase boundary: renew the lease, READ the liveness signal that comes back, and stop if
      # Platform no longer considers this claim live. A heartbeat that fails in TRANSPORT is not
      # treated as a stop — an unreachable Platform is a reporting problem, and killing a
      # publication over one would turn a network blip into a half-published run.
      def checkpoint!
        observe_lease(client.heartbeat(claim: assignment.runner_execution_id))
        check_stop!
      rescue PlatformClient::Error
        check_stop!
      end

      def observe_lease(response)
        lease = response.is_a?(Hash) ? response["lease"].to_h : {}
        state = lease["state"].to_s
        return if state.empty? || (state == "active" && !lease["cancel_requested"])

        @lease_stop_reason ||= lease["cancel_requested"] ? "cancelled" : state
      end

      def check_stop!
        reason = @heartbeater&.stop_reason || @lease_stop_reason
        raise Aborted, reason if reason
      end

      def log(message)
        io.puts(Redaction.redact(message.to_s))
        io.flush if io.respond_to?(:flush)
      end
    end
  end
end
