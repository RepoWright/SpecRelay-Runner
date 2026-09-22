# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module SpecrelayRunner
  # Orchestrates ONE claimed run end to end on the developer machine (MVP-0010),
  # talking to Platform only over the API client. It performs the same Tiny Demo
  # execution flow proven in MVP-0009 — worktree create, executor launch,
  # verification, diff/log capture — but as a separate process, and streams ORDERED v1
  # protocol events (MVP-0013) + heartbeats and uploads the final report bundle
  # together with a terminal-result envelope through the API.
  #
  # It contains NO strategic product logic: it never decides claim eligibility,
  # spec authority, event classification, terminal validation, or Jira
  # finalization (Platform owns those). It only executes what the run payload
  # describes, assigns its own attempt-scoped event sequence, and reports the
  # result back. Platform classifies, dedupes, orders, and validates everything.
  class Execution
    # Raised when Platform signals (via the lease/cancellation liveness signal)
    # that this claim is no longer live — the lease expired and the run was
    # reclaimed, or an operator cancelled it (MVP-0012). The runner stops and
    # uploads NO success report.
    Aborted = Class.new(StandardError)

    # Raised when the executor Platform actually resolved is not the real provider
    # profile this runner selected locally (MVP-0016). The runner refuses to launch
    # it: executing an unexpected command — or silently falling back to the fake
    # executor — would produce evidence that lies about what ran.
    ExecutorMismatch = Class.new(StandardError)

    # The one Platform execution state this runner reads back rather than assumes: the answer
    # window closed and the attempt paused (MVP-0036 CR-002 F2).
    PLATFORM_AWAITING_INPUT = "AWAITING_INPUT"

    Result = Struct.new(:outcome, :message, :reported_status, :release_attempted, keyword_init: true) do
      def success? = outcome == :completed

      # MAPIAI-107 — the attempt refused deterministically BEFORE any provider, and ATTEMPTED to
      # hand the claim back.
      #
      # It is the one failure a `loop` session must not poll past. Every other one has already
      # travelled the terminal-result contract, which makes the run terminal and the next poll
      # about different work; this one leaves the run exactly as this machine found it, so a
      # session that claimed again would reach the identical refusal — the observed twelve-times
      # spin. That is true whether or not Platform accepted the release: a rejected release leaves
      # the run claimed here until its lease expires, and a retry from this session is no more
      # useful then than it is after a successful one.
      #
      # Attempted, deliberately, and not "released" (CR-001 F2). Whether Platform actually
      # released the claim is observable only inside {#release_claim}, which is the one place that
      # reports it. A flag set beside a best-effort call cannot mean more than "we tried", and
      # naming it as though it did let the loop contradict the line printed just above it.
      def refused_after_release_attempt? = !!release_attempted

      # An attempt that ended WELL, whether or not it finished the work (MVP-0036 CR-001 F4).
      #
      # A released answer window is an approved pause, not a failure: the question is durable,
      # the machine is free, and the operator has simply not decided yet. Reported as a failed
      # run it would make a `--on-failure stop` loop shut the machine down every time the AI
      # asked something — the opposite of the outcome this MVP exists to deliver.
      #
      # `:input_capture_failed` is deliberately NOT here. That one is a real failure and must
      # still stop such a loop.
      def handled? = success? || outcome == :awaiting_input

      # MAPIAI-97 — the attempt SUCCEEDED, both halves of it: the implementation reported success
      # and Platform accepted that report.
      #
      # `success?` alone is not that. It reads Platform's answer to the upload, so a run whose
      # verification or publication failed — and which said so in its own terminal result — is
      # still `completed` here, because the report was received and stored. Releasing on it would
      # delete the worktree holding the failure someone has to look at, and the retry that has to
      # reuse it.
      def completed_successfully? = success? && reported_status == ReportBundle::STATUS_SUCCEEDED
    end

    STOP_HEARTBEAT_ENV = "SPECRELAY_RUNNER_STOP_HEARTBEAT_AFTER_SECONDS"
    DEFAULT_RENEWAL_SECONDS = 30

    # The lane discriminator Platform states on every assignment (MVP-0025).
    RUN_TYPE = "implementation"

    # The two fields an assignment uses to declare a SPECIALISED lane — a review, a package
    # preflight, a live preview. An executable implementation assignment declares neither: its
    # lane is the run's own, named by `run.type`.
    LANE_FIELDS = %w[assignment_kind assignment_type].freeze

    # MAPIAI-97 CR-005 — is this assignment the EXECUTABLE implementation lane, the one lane that
    # builds a task environment and therefore owns releasing it?
    #
    # It reads the DECLARED discriminators, never the presence of an ordinary field. Both halves
    # are load-bearing, and each was a real defect: deciding from `run.task_id` made a successful
    # package preflight release an environment it had never created, and `run.type` alone is not
    # enough either, because a REVIEW and a PREFLIGHT are both assignments about an implementation
    # run and carry `implementation` too. An assignment that names a specialised kind is that
    # kind — including one this build has never heard of, which is the safe way to be wrong.
    def self.implementation?(payload)
      return false unless payload.is_a?(Hash)
      return false if LANE_FIELDS.any? { |field| payload[field].to_s.strip != "" }

      payload["run"].to_h["type"].to_s == RUN_TYPE
    end

    def initialize(config:, client:, payload:, env: ENV, io: $stdout)
      @config = config
      @client = client
      @payload = payload
      @env = env
      @io = io
      @run = payload.fetch("run")
      @workspace = payload.fetch("workspace")
      @claim = payload.fetch("claim").fetch("runner_execution_id")
      @heartbeater = nil
      @log_stream = nil
      @provider_stream = nil
      @lease_stop_reason = nil
      @package = nil
      # MVP-0035 — nil for an ordinary first execution, which is every claim that does not
      # follow a CHANGES_REQUESTED review.
      @rework = Rework.for(payload)
      # MVP-0036 Stage 2b — nil unless this claim is a REPLACEMENT run continuing the pull
      # request an abandoned run had already published. A run is never both this and a rework:
      # a replacement is new, so nothing has reviewed it.
      @restart = ContinuedTarget.for(payload, "restart")
      # Nil unless this claim continues an answered offline question — on the machine that asked,
      # or on any other eligible one, which restores the recorded work first.
      @resume = Resume.for(payload)
      # MAPIAI-87 — what the claim says about the ticket's previous accepted implementation. The
      # field is required and nullable, so this reads it rather than guessing at it: a malformed
      # or absent one is refused at the top of {#run_flow}, and a valid package is read-only
      # CONTEXT materialized only into a task workspace this attempt had to create.
      @continuation = PreviousAcceptedPackage.read(payload, env: env)
      @bridge = nil
      @controls = ProtocolControls.new(env: env)
      @emitter = EventEmitter.new(client: client, run_id: @run.fetch("id"), attempt_id: @claim)
    end

    def call
      guard_selected_executor!
      root = @config.workspace_root(@workspace.fetch("workspace_key"), env: @env)
      Dir.mktmpdir("specrelay-runner-") do |staging|
        start_heartbeater
        run_flow(root, staging)
      end
    rescue Aborted => e
      aborted_result(e)
    rescue ExecutorMismatch => e
      executor_mismatch_failure(e)
    rescue Config::Error, Workspace::Error => e
      # A pre-execution local failure AFTER the claim already succeeded: the
      # workspace root is not mapped, or the worktree could not be created. Left
      # unhandled this crashed the runner and left the run CLAIMED/stuck forever
      # (the exact QUALITY-0002 manual-test failure). Instead, surface precise,
      # secret-safe recovery guidance and exit non-zero cleanly.
      preflight_failure(e)
    ensure
      # The log stream owns a timer thread, so it is stopped on EVERY exit path —
      # including the aborted/mismatch/preflight ones — before the heartbeater.
      @log_stream&.finish
      @heartbeater&.stop
    end

    private

    attr_reader :config, :client, :payload, :env, :io, :run, :workspace, :claim, :controls, :emitter

    def start_heartbeater
      @heartbeater = Heartbeater.new(
        client: client, claim: claim, interval_seconds: renewal_seconds,
        io: io, stop_after_seconds: stop_heartbeat_after
      ).start
    end

    def renewal_seconds
      payload.dig("execution_policy", "lease_renewal_seconds").to_i.then { |n| n.positive? ? n : DEFAULT_RENEWAL_SECONDS }
    end

    def stop_heartbeat_after
      value = env[STOP_HEARTBEAT_ENV].to_i
      value.positive? ? value : nil
    end

    def check_stop!
      reason = @heartbeater&.stop_reason || @log_stream&.stop_reason || @lease_stop_reason
      raise Aborted, reason if reason
    end

    def aborted_result(error)
      reason = error.message.to_s.empty? ? "the lease is no longer live" : error.message
      log("Stopping #{run['task_id']}: Platform reports #{reason}. No report was uploaded.")
      log("Platform owns the outcome — an expired lease is reclaimed for another runner; " \
          "a cancelled run is terminal. Nothing to recover locally.")
      Result.new(outcome: :aborted,
                 message: "Runner outcome: aborted (#{reason}); claim released to Platform, no report uploaded.")
    end

    def preflight_failure(error)
      key = workspace.fetch("workspace_key")
      env_var = "SPECRELAY_RUNNER_WORKSPACE_ROOT_#{key.to_s.upcase.gsub(/[^A-Z0-9]+/, '_')}"
      log("Pre-execution failure for #{run['task_id']}: #{Redaction.redact(error.message)}")
      log("The run is still CLAIMED on Platform. To recover:")
      log("  1) Map this workspace to its local checkout, e.g.:")
      log("       export #{env_var}=/absolute/path/to/#{key}")
      log("  2) Release the stuck claim on the Platform host so the run is claimable again:")
      log("       bin/platform runner release #{run['task_id']}")
      log("  3) Re-run: specrelay-runner claim-once --config <path>")
      Result.new(outcome: :preflight_failed,
                 message: "Runner outcome: preflight_failed (local workspace not ready; claim not executed).")
    end

    # The two refusals that happen BEFORE a provider and hand the claim straight back. Neither
    # knows anything about the outcome of the work, so neither may report one: a failed report
    # would mark the run terminal when the correct answer is "another attempt can still run this
    # once the input is readable" (MVP-0035) or "the owner can retry once the machine is right"
    # (MVP-0036 Stage 2a design 9).
    def continuation_refused(reason)
      refuse_before_provider(reason, "Refusing to continue the recorded work for #{run['task_id']}")
    end

    # The recorded work is not what this machine could prove. The question, its answers and its
    # recorded package all stay durable on Platform, and every local file stays exactly as it is,
    # so this machine — or another eligible one — can try again.
    def resume_refused(reason)
      refuse_before_provider(reason, "Refusing to resume #{run['task_id']}")
    end

    def refuse_before_provider(reason, headline)
      safe = Redaction.redact(reason.to_s)
      log("#{headline}: #{safe}")
      log("Nothing ran: no provider received this task, nothing was pushed, and Jira was not touched.")
      release_claim(safe)
      Result.new(outcome: :preflight_failed, release_attempted: true,
                 message: "Runner outcome: preflight_failed (#{safe}); nothing executed.")
    end

    # Give the machine's capacity back and leave the run claimable. ONLY a refused continuation or
    # resume target does this. The other pre-provider refusals keep their manual recovery step:
    # each is a misconfiguration of this machine that the operator has to correct anyway.
    #
    # Releasing does make the same run immediately eligible again, which under the default
    # `continue` loop policy let one session reclaim and re-refuse it without end (CR-001 F3, and
    # the live MAPIAI-106 spin). That is now answered where it belongs — the result reports
    # `refused_after_release_attempt?` and {LoopRunner} ends the session — rather than by
    # withholding capacity another machine could use.
    #
    # Best effort by design: a Platform that cannot be reached will expire the lease on its own,
    # and raising here would replace a precise local reason with a transport error.
    #
    # THIS is the only place that may say what actually happened to the claim, which is why the
    # two outcomes are logged here and nowhere else. A caller holding the result knows a release
    # was attempted and nothing more.
    def release_claim(reason)
      client.release_claim(claim: claim, reason: reason)
      log("Released this claim on Platform; the run is claimable again.")
    rescue PlatformClient::Error => e
      log("Could not release the claim (#{Redaction.redact(e.message)}); its lease will expire on Platform.")
    end

    # Fail closed before anything happens: no worktree, no executor launch, no report, no
    # publication, no Jira transition.
    #
    # TWO refusals, in the order they can be decided. The CLAIMED executor is resolved through the
    # one closed choice first, because that is the configuration that would actually be launched:
    # an unsupported provider or an argv this runner will not run is refused here even when this
    # machine selected nothing locally, which a guided connection never does. Only then, when this
    # runner DID select a profile of its own, is the claim compared against it.
    def guard_selected_executor!
      # Resolving the CLAIM is the first refusal: it raises for an unsupported provider, and for a
      # supported one whose argv this runner will not launch. Its return value is deliberately
      # unused — what matters is that an unusable claim never reaches the second check.
      ImplementationProfile.for(payload.fetch("executor"))
      selected = config.selected_implementation_profile
      return if selected.nil?

      # Same env the executor will launch with, so the comparison resolves the very
      # file that would run (review-001 finding F1).
      reason = selected.mismatch_reason(payload.fetch("executor"), env: env)
      raise ExecutorMismatch, reason if reason
    rescue ImplementationProfile::Error, ClaudeProfile::Error, CodexProfile::Error => e
      raise ExecutorMismatch, "claimed executor is not one this runner will launch: #{Redaction.redact(e.message)}"
    end

    def executor_mismatch_failure(error)
      log("Refusing to execute #{run['task_id']}: #{Redaction.redact(error.message)}")
      log("Nothing ran: no worktree was created, no report was uploaded, and Jira was not advanced.")
      log("The run is still CLAIMED on Platform. To recover:")
      log("  1) Align the executor policy — this runner's `executor:` override, or the")
      log("     workspace definition's executor_config on the Platform host.")
      log("  2) Release the claim on the Platform host so the run is claimable again:")
      log("       bin/platform runner release #{run['task_id']}")
      log("  3) Re-run: specrelay-runner claim-once --config <path>")
      Result.new(outcome: :preflight_failed,
                 message: "Runner outcome: preflight_failed (claimed executor is not the selected profile; nothing executed).")
    end

    # The pre-provider tree, named the way an operator can check it: one line per contained
    # repository with its own path inside the environment and the exact commit it is on, then the
    # approved package's location and the commit it was pinned to and verified against.
    def report_effective_inputs(worktree)
      state = Specification::Preflight.repository_state(task_root: worktree.path, env: env)
      anchor = @package.anchor
      if state.nil?
        emit("workspace.prepared", "Prepared #{run['task_id']}; its repositories could not be " \
             "inspected to report their heads", phase: "workspace")
        return
      end

      heads = state.map do |prefix, facts|
        # The task root's own prefix is empty; naming it "." keeps every entry readable as a path.
        "#{prefix.to_s.empty? ? '.' : prefix}@#{facts[:head].to_s[0, 12]}"
      end.sort.join(" ")
      pinned = anchor ? ", approved specification #{anchor[:package_path]} pinned at " \
                        "#{anchor[:head].to_s[0, 12]} in #{anchor[:repository]}" : ""
      emit("workspace.prepared", "Prepared #{run['task_id']} at #{heads}#{pinned}",
           phase: "workspace")
    end

    def run_flow(root, staging)
      # MAPIAI-87 CR-001 F1 — the continuation field is authority, so an absent or malformed one
      # is refused HERE: before a worktree is created or reused, before any git or GitHub read,
      # before the provider, and before any external write. Reading it as "no previous accepted
      # implementation" would start a continued run from the default branch and silently discard
      # accepted work.
      return continuation_refused(@continuation.reason) unless @continuation.ok?

      emit("attempt.started", "Runner #{runner_name} started an attempt for #{run['task_id']}", phase: "attempt")

      emit("workspace.preparing", "Preparing worktree for #{run['task_id']}", phase: "workspace")
      # MVP-0036 Stage 2a — a resume continues the DIRTY worktree its question was asked from, so
      # it reads and proves that worktree where an ordinary claim creates a clean one. A refusal
      # here stops before the provider, before the package, and before any external write.
      if @resume
        prepared = @resume.prepare(measuring: measuring_workspace(root), creating: creating_workspace(root),
                                   download: -> { download_checkpoint })
        return resume_refused(prepared.reason) unless prepared.ok?
      end
      worktree = prepared&.worktree || create_worktree(root)

      # MVP-0035 rework and MVP-0036 Stage 2b restart both continue an exact recorded head, so the
      # worktree must hold that commit before anything else looks at it. One branch, because it is
      # one proof ({ContinuedTarget}) and a claim is never both. A refusal here stops before the
      # provider, before the package, and before any external write.
      continued = @rework || @restart
      if continued
        continuation = continued.materialize(worktree_path: worktree.path)
        return continuation_refused(continuation.reason) unless continuation.ok?

        worktree = Workspace::Info.new(path: worktree.path, created: worktree.created?,
                                       base_commit: continuation.head_commit || worktree.base_commit)
      end

      # The pinned package is verified and ANCHORED
      # to the contained repository and commit it belongs to. It sits here, after any recorded
      # target has been placed and before any fresh input is, for two reasons: a rework or restart
      # target is this run's own recorded authority and keeps its precedence, including its own
      # refusals; and the owner that chooses a head for the fresh inputs below has to know what the
      # specification requires in order to pick a commit that satisfies both. The check reads the
      # pinned COMMIT rather than the working tree, so it is answerable at this point.
      @package = SpecificationPackage.call(payload: payload, staging_dir: staging,
                                           task_root: worktree.path)
      return package_refused(root, worktree, @package.failure) unless @package.ok?

      if !continued && (@continuation.package || @package.anchor) && worktree.created?
        # MAPIAI-87 — the ticket's PREVIOUS accepted implementation, and only into a workspace
        # this attempt just built. Same-run authority wins: a rework or restart target is handled
        # above and never reaches here, and a resume reuses the worktree its question was asked
        # from, so `created?` is false for it.
        #
        # The verified specification anchor travels with the accepted code, so one authority
        # chooses a commit that satisfies BOTH inputs — or refuses before placing any of them. A
        # first run has no accepted code and still needs its approved specification placed, so the
        # same owner is used with no accepted targets rather than a second placement path here.
        placer = @continuation.package ||
                 PreviousAcceptedPackage.for_specification(run["canonical_branch"], env: env)
        reconstructed = placer.materialize(task_root: worktree.path,
                                           specification: @package.anchor)
        return continuation_refused(reconstructed.reason) unless reconstructed.ok?
      end

      # What the provider is ABOUT to see, measured after every input has been placed. The seeds an
      # environment was allocated from are not this: inputs are placed in stages, and reporting the
      # starting point as the effective one would describe a tree that no longer exists. Identities
      # are repository-relative and the values are commit ids, so nothing here carries a host path.
      report_effective_inputs(worktree)

      emit("core.started", "Running #{provider} executor for #{run['task_id']}", phase: "core")
      executor_result = run_executor(root, worktree, staging)
      # MVP-0036 — the provider stopped on a QUESTION, not on work. Checked before the lease
      # and before the exit code, because both would misreport it: a released session ends the
      # attempt on Platform (so the lease reads "terminal"), and a terminated provider exits
      # non-zero. Neither is a failure of the task, and neither may upload a report.
      return question_outcome if @bridge&.outcome
      # MVP-0036 CR-005 F2 — no provider ever received the answers, so there is nothing to
      # report. A failed report would mark the run TERMINAL and take the offline batch with it;
      # handing the claim back leaves the answers, the checkpoint and the changed files exactly
      # as they were, for the owner to try again.
      return resume_refused(executor_result.launch_error) if @resume && executor_result.launch_error
      # If Platform expired or cancelled the claim while the executor held it, stop
      # BEFORE running tests or uploading anything (MVP-0012).
      check_stop!
      unless executor_result.success?
        return unfinished_provider(root, worktree, executor_result, executor_failure(executor_result),
                                   classification: executor_classification(executor_result))
      end
      # MAPIAI-60 — the provider exited cleanly but its structured output could not be read, so
      # there is no result this runner can prove. Fails closed as a failed attempt rather than
      # reporting an empty success: an unreadable stream is not an unchanged repository.
      if (unreadable = @provider_stream&.close&.failure)
        return unfinished_provider(root, worktree, executor_result,
                                   "the #{provider} executor produced unusable output: #{unreadable}")
      end

      changes = measuring_workspace(root).capture_changes(worktree.path)
      # An unmeasurable worktree is NOT an unchanged one. Reporting `changed: false`
      # here would advance Jira announcing "no code changes" while the executor's diff
      # sits on disk, so this fails closed instead (review-002 finding N1).
      return unmeasured_report(worktree, executor_result, changes) unless changes.measured?

      # MAPIAI-84 — the executor's semantic repository selection, read back and then VERIFIED
      # against the repositories on disk. It happens here, before verification and before any
      # external write, for the same reason change measurement does: an unsafe or incoherent
      # selection means there is nothing this attempt can honestly publish, so running its
      # commands would only add noise to a refusal.
      reported = RepositorySelection.read(staging)
      return selection_refused(root, worktree, executor_result, reported.error) unless reported.ok?

      selection = measuring_workspace(root).select(worktree.path, reported.entries.map(&:path))
      return selection_refused(root, worktree, executor_result, selection.error) unless selection.ok?

      repositories = selection.repositories
      changes = combined_changes(repositories, changes)

      emit("verification.started", "Verifying #{repositories.length} changed repository(ies) for #{run['task_id']}",
           phase: "verification")
      verifications = verify_repositories(repositories, reported)
      emit("verification.completed", verification_summary(verifications), phase: "verification")

      # Final gate before finalizing: never upload a success report for a claim
      # Platform no longer considers live.
      check_stop!
      demonstrate_protocol_controls
      status = terminal_status(verifications)
      # MAPIAI-93 CR-001 F1 — the last gate before anything external. Asked only on the path that
      # would otherwise publish: every other ending already blocks publication and already names a
      # more specific cause, and replacing that cause with a drift reason would hide it.
      if status == ReportBundle::STATUS_SUCCEEDED && (drift = verification_drift(root, worktree, reported, repositories))
        return drift_refused(root, worktree, executor_result, verifications, drift)
      end

      publication = publish(repositories, status)
      # An incomplete publication is a FAILED attempt, not a success with a warning:
      # verification passed but the output never became reviewable. Reporting it as
      # failed is what makes Platform record a durable, operator-visible reason and
      # leave Jira where it is (MVP-0014).
      failure = publication_failure(publication)
      status = ReportBundle::STATUS_FAILED if failure
      submit(worktree, executor_result, verifications, changes, status, publication, failure)
    end

    # MAPIAI-93 — the runner's own replay of what the executor selected, one verified repository
    # at a time. {RepositoryVerification} owns the commands and the outcome; the lease check
    # between repositories stays here, with every other stop check in this class, so a cancelled
    # claim ends through the one owner rather than through a second rule inside verification.
    def verify_repositories(repositories, reported)
      commands = reported.entries.to_h { |entry| [ entry.path, entry.commands ] }
      repositories.map do |repository|
        check_stop!
        RepositoryVerification.call(repository: repository,
                                    commands: commands.fetch(repository.relative_path, []), env: env)
      end
    end

    # MAPIAI-93 CR-001 F1 — the reason this attempt must not publish, or nil when the tree that
    # was verified is still the tree that would be published.
    #
    # It RE-ASKS the existing verifier rather than introducing a second measurement model: the
    # same containment, git-root, branch, remote, uniqueness and change-measurement rules that
    # produced the selection produce the comparison, so there is one definition of publishable
    # state and one definition of a publishable repository. A repository that verification left
    # clean, unbranched or ambiguous fails HERE through that verifier's own refusal.
    #
    # Ignored files are absent from the comparison because they are absent from the measurement
    # (`git status --porcelain`), so a command that writes only scratch output is harmless.
    #
    # Nothing is adopted, remeasured into the package, or retried. The whole answer is whether the
    # attempt may proceed.
    def verification_drift(root, worktree, reported, verified)
      current = measuring_workspace(root).select(worktree.path, reported.entries.map(&:path))
      unless current.ok?
        return "the selected repositories could not be re-verified after verification ran: #{current.error}"
      end

      drifted = drifted_paths(verified, current.repositories)
      return nil if drifted.empty?

      "verification changed the publishable state of #{drifted.join(', ')} after it was measured; " \
        "nothing was published because the report would describe a different tree than the commit"
    end

    # The repositories whose publishable state moved, by relative path only. A drift reason travels
    # into a report, a Platform event and an operator's terminal, so it names WHICH repository
    # changed and never what changed in it.
    def drifted_paths(verified, current)
      before = verified.to_h { |repository| [ repository.relative_path, repository.publishable_state ] }
      after = current.to_h { |repository| [ repository.relative_path, repository.publishable_state ] }
      (before.keys | after.keys).reject { |path| before[path] == after[path] }
    end

    # Reported as a FAILED attempt with its own classification, carrying the verification results
    # that really were observed: the commands ran, and what they returned is a fact worth keeping
    # even though their side effect is what ended the attempt.
    def drift_refused(root, worktree, executor_result, verifications, reason)
      failed_report(root, worktree, executor_result,
                    "Refusing to publish #{run['task_id']}: #{Redaction.redact(reason)}",
                    classification: "verification_changed_publishable_state",
                    verifications: verifications)
    end

    def verification_summary(verifications)
      return "No repository changed for #{run['task_id']}; there was nothing to verify" if verifications.empty?

      counts = verifications.group_by(&:status).transform_values(&:length)
      "Verification for #{run['task_id']}: #{counts.map { |status, count| "#{count} #{status}" }.join(', ')}"
    end

    # The executor answered, but with something the runner will not act on: a path outside the task
    # workspace, a directory that is not a repository root, a repository on the wrong branch or with
    # no supported remote, two entries naming one repository, or a repository with nothing to
    # publish. Reported as a FAILED attempt with its own classification and NO repository rows —
    # a refused selection must not leave a partial authoritative repository set anywhere.
    def selection_refused(root, worktree, executor_result, reason)
      failed_report(root, worktree, executor_result,
                    "Refusing to publish #{run['task_id']}: #{Redaction.redact(reason.to_s)}",
                    classification: "repository_selection_refused")
    end

    # The report bundle's single diff view over every selected repository. Each repository measures
    # its own change set, so paths are prefixed with the repository they belong to: a bare
    # `app/x.rb` from two repositories would read as one file changed twice.
    #
    # `measured` is the task workspace's own measurement. Its `head_commit` is kept, because the
    # report's worktree identity is about the task workspace rather than about any one repository
    # inside it, and it is the whole answer for an empty selection — a clean run still reports a
    # measured (and empty) change set rather than an absent one.
    def combined_changes(repositories, measured)
      return measured if repositories.empty?

      Workspace::Changes.new(
        changed_files: repositories.flat_map { |repository| prefixed_files(repository) }.first(500),
        diff: repositories.map(&:diff).join("\n"),
        head_commit: measured.head_commit, measurement_error: nil
      )
    end

    def prefixed_files(repository)
      Array(repository.changed_files).map do |file|
        repository.relative_path == "." ? file : File.join(repository.relative_path, file)
      end
    end

    # The first publication error across the published repositories, or nil.
    #
    # Only `publication_error` — publication that was ATTEMPTED and FAILED — may fail
    # the attempt. `publication_skipped_reason` (a read-only repository Platform never
    # asked us to publish) is a policy outcome, not a failure, and used to fail the
    # whole run with core.exit_code 0 (review-001 finding 3).
    def publication_failure(publication)
      Array(publication).map(&:publication_error).compact.first
    end

    # The change set could not be established. The tests are not run and nothing is
    # published: with no trustworthy diff there is nothing to validate or review, and
    # any repository claim would be a guess. Reported as a FAILED attempt with its own
    # classification so the operator sees the real cause.
    def unmeasured_report(worktree, executor_result, changes)
      reason = "could not determine what the executor changed: #{changes.measurement_error}"
      log("Publication aborted for #{run['task_id']}: #{Redaction.redact(reason)}")
      emit("attempt.completed", "Uploading failed execution report for #{run['task_id']}", phase: "completed")
      bundle = ReportBundle.build(payload: payload, status: ReportBundle::STATUS_FAILED, executor: executor_result,
                                  verifications: [], changes: changes, base_commit: worktree.base_commit,
                                  worktree_path: worktree.path, failure_details: reason)
      terminal = terminal_result(status: ReportBundle::STATUS_FAILED, final_sequence: emitter.sequence,
                                 exit_code: executor_result.exit_code, base_commit: worktree.base_commit,
                                 changes: changes, error_classification: "worktree_unmeasurable")
      client.submit_report(claim: claim, bundle: bundle, terminal_result: terminal)
      Result.new(outcome: :publication_failed, message: "Runner outcome: publication_failed (#{reason}).")
    end

    # MVP-0014 — publish the changed repository output to GitHub, between verification
    # and finalization. Only a successful attempt publishes: a failed run has nothing
    # reviewable to offer, and its repositories are still reported truthfully.
    #
    # Publication never raises. A push or pull-request failure comes back as a
    # publication_error on the repository result, which Platform validates and refuses
    # to treat as success — so an incomplete publication blocks the run instead of
    # silently passing.
    def publish(repositories, status)
      publishing = status == ReportBundle::STATUS_SUCCEEDED
      publications = repositories.map do |repository|
        Publication.new(payload: payload, repository: repository, env: env, io: io, publish: publishing)
      end
      return publications.map(&:call) unless publishing && expected?(repositories)

      emit("publication.started", "Publishing repository output for #{run['task_id']}", phase: "publication")
      results = publications.map(&:call)
      emit("publication.completed", publication_summary(results), phase: "publication",
           published_branch: results.map(&:branch).compact.first,
           pull_request_url: results.map(&:pull_request_url).compact.first)
      results
    end

    # Publication is expected to do real work — and so deserves its events — when the executor
    # selected at least one repository and policy grants write access. Access is the run's policy
    # rather than a per-repository entry, so it is one question for the whole selection.
    def expected?(repositories)
      repositories.any? && payload["repository_policy"].to_h.fetch("access", "read").to_s == "write"
    end

    # The report's failure narrative names the real cause: a publication failure is reported as
    # such rather than blamed on the verification, which passed.
    def failure_details(status, verifications, publication_failure)
      return nil unless status == ReportBundle::STATUS_FAILED
      return "repository publication failed: #{publication_failure}" if publication_failure

      failed = verifications.select(&:failed?).map(&:repository_path)
      return "verification failed in #{failed.join(', ')}" if failed.any?

      "the attempt was recorded as failed"
    end

    def publication_summary(results)
      failed = results.select(&:publication_error)
      return "Publication failed for #{run['task_id']}: #{failed.map(&:publication_error).first}" if failed.any?

      published = results.select(&:branch)
      "Published #{published.length} repository branch(es) for #{run['task_id']}"
    end

    def create_worktree(root) = creating_workspace(root).create

    # The workspace that may BUILD the task environment, through the project's own command. One
    # owner, because a resume onto a machine that never saw the work builds it the same way an
    # ordinary first execution does.
    def creating_workspace(root)
      Workspace.new(root: root, canonical_branch: run["canonical_branch"], task_id: run["task_id"],
                    run_id: run_identity,
                    create_command: workspace.fetch("worktree_create_command"))
    end

    # The Platform Run this attempt acts for, and the only identity that may own its environment.
    # Not the claim, the attempt or the execution: those change between attempts of the SAME run,
    # and an environment whose owner changed under a retry could not be continued or released.
    def run_identity = run["id"].to_s

    # The recorded package, from the one claim-bound path Platform put in the assignment.
    def download_checkpoint
      client.executor_question_checkpoint(claim: claim, path: @resume.download_path)
            .to_h["payload"]
    end

    # The same workspace, for READING only: the change capture, the checkpoint and the resume's
    # worktree lookup all ask about a worktree rather than create one, so none of them carries a
    # create command.
    #
    # It carries the run identity all the same, because one of those reads is a CONTINUATION: an
    # answered resume picks up the dirty worktree its question was asked from, and that worktree
    # has to be this run's. The measurement calls are unaffected — they are handed a path.
    def measuring_workspace(root)
      Workspace.new(root: root, canonical_branch: run["canonical_branch"], task_id: run["task_id"],
                    run_id: run_identity, create_command: "")
    end

    # MVP-0018 — the executor runs with a live output sink attached, so safe,
    # redacted, bounded progress reaches the terminal and Platform BETWEEN
    # `core.started` and `verification.started` instead of only at process exit.
    #
    # The stream is stopped here rather than only in the outer `ensure`, so its
    # final flush and truncation notice land before `verification.started` — the
    # live executor log is a record of the CORE phase, not of everything after it.
    def run_executor(root, worktree, staging)
      @log_stream = start_log_stream
      # The bridge lives in the STAGING directory, outside the worktree, so a question request
      # can never appear in the diff the executor is measured on. It is built before the decoder,
      # which reads its refusal count.
      @bridge = QuestionBridge.new(client: client, claim: claim, staging_dir: staging, io: io,
                                   capture: -> { capture_checkpoint(root, worktree, staging) },
                                   resume_question_id: @resume&.question_id).start
      @provider_stream = provider_stream(worktree)
      result = Executor.new(config: payload.fetch("executor"), worktree_path: worktree.path,
                            staging_dir: staging, env: env)
                       .run(prompt_text(worktree.path, @bridge.path, RepositorySelection.path(staging)),
                            on_output: (@provider_stream || @log_stream).sink,
                            on_start: -> { @bridge.confirm_resume },
                            stop_check: -> { @bridge.stop_provider? })
      decoded(result)
    ensure
      @log_stream&.finish
      @bridge&.stop
    end

    # Both real profiles are structured-output-only, so their stdout is a JSONL
    # transport rather than operator text and is decoded before anything sees it. Each provider
    # gets its OWN decoder because the two turn contracts differ; the deterministic fixture keeps
    # the line-oriented contract it has always had, and nothing pretends it emits either shape.
    def provider_stream(worktree)
      case ImplementationProfile.provider_of(payload["executor"])
      when ClaudeProfile::PROVIDER
        # The Claude decoder's one exception to its one-result rule is authorized by the bridge's
        # refusal count and by nothing else it knows about questions.
        ClaudeStream.new(sink: @log_stream.sink, repository_path: worktree.path, refusals: -> { @bridge.refusals })
      when CodexProfile::PROVIDER
        CodexStream.new(sink: @log_stream.sink, repository_path: worktree.path)
      end
    end

    # The report is built from the DECODED terminal result, never from the raw frames: raw JSONL
    # is transport, so it may not become this attempt's stdout evidence.
    def decoded(result)
      return result unless @provider_stream

      Executor::Result.new(**result.to_h, stdout: @provider_stream.final_text)
    end

    # The portable checkpoint of everything the provider has changed, taken at the instant it
    # pauses. It reads the executor's OWN repository selection — the same document publication
    # reads — and verifies it through the same rules, so a question is never stored describing
    # repositories this runner could not prove.
    #
    # A refusal here reaches the provider, which may correct its selection and ask again while
    # its session is alive.
    def capture_checkpoint(root, worktree, staging)
      reported = RepositorySelection.read(staging)
      return Checkpoint.refuse_capture(reported.error) unless reported.ok?

      measuring = measuring_workspace(root)
      selection = measuring.select(worktree.path, reported.entries.map(&:path), require_change: false)
      return Checkpoint.refuse_capture(selection.error) unless selection.ok?

      Checkpoint.capture(repositories: selection.repositories, workspace: measuring)
    end

    # MVP-0036 — the two honest endings for a provider that paused on a question. Neither runs
    # tests, uploads a report, publishes, or touches Jira: there is no result to report, only a
    # decision a human has not made yet. The dirty worktree stays exactly where it is.
    def question_outcome
      return input_capture_failure(@bridge.failure_reason.to_s) if @bridge.failed?

      released_session
    end

    def released_session
      log("The provider session for #{run['task_id']} was released; the question and its context " \
          "are durable on Platform and this machine's changes were left in place.")
      Result.new(outcome: :awaiting_input,
                 message: "Runner outcome: awaiting_input (question durable; no report uploaded).")
    end

    # Reported to Platform rather than left to a lapsing lease, so the attempt ends as a
    # distinct recoverable failure and the machine is freed now.
    #
    # PLATFORM classifies the ending, not this runner (CR-002 F2). There is a real interval in
    # which the Product Owner's release has already won and the provider exits before the next
    # poll can observe it: what this runner saw is a lost question, but what happened is an
    # ordinary pause, and calling it a failure would stop a `--on-failure stop` session over a
    # normal decision. Anything else — a transport fault, a refusal, a state this runner does
    # not recognise — stays a failure, because an ending it cannot confirm must not be reported
    # as handled. A failure to REPORT the failure is still an honest non-zero exit: Platform
    # reclaims the lapsed lease.
    def input_capture_failure(reason)
      response = client.report_input_capture_failure(claim: claim, reason: reason)
      return released_session if response.to_h.dig("execution", "state") == PLATFORM_AWAITING_INPUT

      capture_failed(reason)
    rescue PlatformClient::Error => e
      capture_failed(e.message)
    end

    def capture_failed(reason)
      log("Could not capture the provider's question for #{run['task_id']}: #{Redaction.redact(reason)}")
      log("Nothing was tested, reported, published, or written to Jira. Your changes are still in the worktree.")
      Result.new(outcome: :input_capture_failed,
                 message: "Runner outcome: input_capture_failed (#{Redaction.redact(reason)}).")
    end

    def start_log_stream
      ExecutorLogStream.start(emitter: emitter, io: io, provider: provider, task_id: run["task_id"])
    end

    # The report-relative artifacts named in the terminal-result envelope.
    def terminal_artifacts
      %w[README.md manifest.yml evidence/stdout.log evidence/verification.log evidence/diff.txt]
    end

    # MAPIAI-93 — publication is allowed only when EVERY changed repository is `passed` or
    # `not_found`. A repository with no applicable verification is a valid, non-blocking outcome;
    # one that failed makes the whole attempt fail, because a partially verified run must not
    # leave a half-published output for review.
    #
    # Forced terminal failure (deterministic control) still records a failed outcome even when
    # every repository passed, so the terminal-failure/non-review scenario can be proven without
    # an artificial broken command.
    def terminal_status(verifications)
      return ReportBundle::STATUS_FAILED if controls.force_terminal_failure?

      verifications.any?(&:failed?) ? ReportBundle::STATUS_FAILED : ReportBundle::STATUS_SUCCEEDED
    end

    def submit(worktree, executor_result, verifications, changes, status, publication, publication_failure = nil)
      emit("attempt.completed", "Uploading execution report for #{run['task_id']} (#{status})",
           phase: "completed", exit_code: executor_result.exit_code)
      bundle = ReportBundle.build(payload: payload, status: status, executor: executor_result,
                                  verifications: verifications,
                                  changes: changes, base_commit: worktree.base_commit, worktree_path: worktree.path,
                                  failure_details: failure_details(status, verifications, publication_failure))
      terminal = terminal_result(status: status, final_sequence: emitter.sequence, exit_code: executor_result.exit_code,
                                 base_commit: worktree.base_commit, changes: changes, publication: publication,
                                 error_classification: publication_failure ? "publication_failed" : nil)
      response = client.submit_report(claim: claim, bundle: bundle, terminal_result: terminal)
      outcome = response["outcome"].to_s
      log("Report stored: #{response.dig('report', 'url')} (run #{response['run_state']})")
      Result.new(outcome: outcome.to_sym, message: "Runner outcome: #{outcome}.", reported_status: status)
    end

    # MVP-0034 S23 — the assignment's package did not reproduce what Platform pinned. Reported as
    # a failed attempt with NO executor: `launch_error` is what the report bundle already uses to
    # say "the provider was never started", so the evidence reads truthfully rather than blaming a
    # task nobody ran.
    def package_refused(root, worktree, reason)
      message = "Refusing to implement #{run['task_id']}: #{reason}. The executor was not started."
      never_launched = Executor::Result.new(exit_code: nil, stdout: "", stderr: "", duration_seconds: 0,
                                            timed_out: false, argv: [], launch_error: reason)
      failed_report(root, worktree, never_launched, message,
                    classification: SpecificationPackage::REFUSED)
    end

    # A failed executor: emit the terminal event and upload a failed report + a
    # failed terminal envelope so Platform records the attempt (run marked FAILED;
    # Jira is not advanced).
    def failed_report(root, worktree, executor_result, message, classification: ClaudeProfile::EXECUTOR_FAILED,
                      verifications: [])
      log(message)
      changes = measuring_workspace(root).capture_changes(worktree.path)
      emit("attempt.completed", "Uploading failed execution report for #{run['task_id']}", phase: "completed")
      bundle = ReportBundle.build(payload: payload, status: ReportBundle::STATUS_FAILED, executor: executor_result,
                                  verifications: verifications, changes: changes, base_commit: worktree.base_commit,
                                  worktree_path: worktree.path, failure_details: message)
      terminal = terminal_result(status: ReportBundle::STATUS_FAILED, final_sequence: emitter.sequence,
                                 exit_code: executor_result.exit_code, base_commit: worktree.base_commit,
                                 changes: changes, error_classification: classification)
      client.submit_report(claim: claim, bundle: bundle, terminal_result: terminal)
      Result.new(outcome: :executor_failed, message: message)
    end

    # The provider ended without one provable result: a non-zero exit, a timeout, or a stream this
    # runner cannot decode. Ordinarily that is a failed report. After a question turn this attempt
    # REFUSED back to the provider it is the rejected-question continuation failing to finish, and
    # the ending belongs to the question lifecycle: a failed report about a changed worktree would
    # carry no verification rows, which Platform's report contract refuses, and the operator would
    # see that refusal instead of the cause. The bridge's own faults never reach here — they end the
    # attempt above, before any report is considered.
    def unfinished_provider(root, worktree, executor_result, reason, classification: ClaudeProfile::EXECUTOR_FAILED)
      return failed_report(root, worktree, executor_result, reason, classification: classification) unless @bridge.refusals.positive?

      input_capture_failure("the provider's question was refused and its session did not finish: #{reason}")
    end

    # Which local condition actually failed. Timeout and "could not launch it at
    # all" are provider-agnostic facts; the real profile refines the remaining
    # non-zero exit into an authentication problem when its own captured output
    # says so, so an expired login is not reported as a task failure.
    def executor_classification(result)
      profile = ImplementationProfile.for(payload["executor"])
      return profile.classify_failure(result) if profile

      return ClaudeProfile::EXECUTOR_UNAVAILABLE if result.launch_error
      return ClaudeProfile::EXECUTOR_TIMEOUT if result.timed_out

      ClaudeProfile::EXECUTOR_FAILED
    rescue ImplementationProfile::Error, ClaudeProfile::Error, CodexProfile::Error
      # Unreachable through a claim {#guard_selected_executor!} admitted, and stated rather than
      # assumed: a classification is the last thing a failed attempt reports, and it must not
      # raise over a configuration the attempt already refused to be launched with.
      ClaudeProfile::EXECUTOR_FAILED
    end

    def terminal_result(status:, final_sequence:, exit_code:, base_commit:, changes:,
                        publication: nil, error_classification: nil)
      succeeded = status == ReportBundle::STATUS_SUCCEEDED
      TerminalResult.build(
        run_id: run.fetch("id"), attempt_id: claim,
        outcome: succeeded ? TerminalResult::SUCCEEDED : TerminalResult::FAILED,
        final_sequence: final_sequence, exit_code: exit_code,
        error_classification: succeeded ? nil : (error_classification || "verification_failed"),
        # MAPIAI-84 — an attempt that never reached publication reports NO repositories. It has
        # no verified selection, so it has no repository identity, remote or base commit it can
        # honestly assert; inventing a row from the workspace key is what let a run whose change
        # detection failed announce a repository state nobody had measured (review-003 finding 2).
        # The cause travels in the error classification and the report's failure narrative instead.
        repositories: publication || [],
        artifacts: terminal_artifacts
      )
    end

    # Deterministic, default-off protocol controls (MVP-0013) that reproduce the
    # anomalies the spec requires real evidence for. They run AFTER the ordered
    # lifecycle stream and BEFORE the terminal event, so they never create a
    # success-blocking gap. Each is a no-op unless its env flag is set.
    def demonstrate_protocol_controls
      return unless controls.any?

      if controls.out_of_order?
        log("[control] emitting an out-of-order event pair (reversed sequence)")
        emit_pair("core.progress", "Out-of-order lower-sequence progress for #{run['task_id']}",
                  "Out-of-order higher-sequence progress for #{run['task_id']}", phase: "core")
      end
      if controls.duplicate?
        log("[control] re-sending an event verbatim to prove idempotent duplicate handling")
        observe_lease(emitter.resend_duplicate(2))
      end
      if controls.conflict?
        log("[control] re-sending a used sequence with a different payload to prove conflict handling")
        observe_lease(emitter.resend_conflict(2, "Conflicting payload for sequence 2 (#{run['task_id']})"))
      end
      check_stop!
    end

    def prompt_text(worktree_path, bridge_path, selection_path)
      preamble = <<~MD.strip
        # Automated execution task — #{run['task_id']}

        You are an automated, non-interactive executor. Implement the approved
        specification in the task workspace below, then stop.

        - Task workspace (your working directory): `#{worktree_path}`
        - Task id: `#{run['task_id']}`
        - Canonical branch: `#{run['canonical_branch']}`
        #{package_lines.join("\n")}

        Rules:
        - Change ONLY files inside the task workspace above, per the approved specification.
        - Do NOT edit any `spec.md`/`spec_persian.md`, push, open a PR, or write to Platform.
        - Make the change idempotently.

        #{selection_lines(selection_path)}

        #{question_lines(bridge_path)}
      MD
      "#{preamble}\n\n---\n\n#{payload.dig('specification_package', 'handoff_prompt')}#{rework_prompt}#{resume_prompt}"
    end

    # MAPIAI-84/MAPIAI-93 — the ONE way the executor's repository choice AND its verification
    # choice reach the runner.
    #
    # The task workspace may contain several independent git repositories; WHICH of them an
    # approved specification needs, and which verification is relevant to what changed in each, are
    # decisions only the executor can make. Nothing else is read: the runner never infers a
    # repository or a command from prose, terminal output or provider reasoning, so an unreported
    # repository is simply not published. The document is required even when nothing changed,
    # because silence and "nothing changed" are different facts — and so is an empty command list,
    # which says "I found no verification here" rather than "I did not look".
    def selection_lines(selection_path)
      <<~MD.strip
        Before you exit successfully, report which repositories you changed and how each one is
        verified:

        - Write `#{selection_path}` as one JSON object with `repositories`, an array of
          `{ "path": "<repository path relative to the task workspace>", "commands": [ ["<argv>", "..."] ] }`.
          Use `"."` for the task workspace repository itself. Write `{ "repositories": [] }` if you
          changed nothing.
        - List a repository ONLY if you changed it, and give each one once. Paths only: no absolute
          paths, no pull-request URLs, no credentials, no explanation of your reasoning, and no
          claimed exit code or result.
        - For each repository, select the SMALLEST verification relevant to what you changed there:
          read that repository's own instructions, scripts, manifests and CI configuration. Each
          command is an argv array, run from that repository's root — never a shell string.
        - Run what you select, diagnose any failure, fix it, and rerun it before you exit. If you
          cannot fix it, still report the final commands so SpecRelay records the real failure.
        - Write `"commands": []` when a repository has no applicable verification. That is a valid
          answer; do not invent a command or a passing result.
        - SpecRelay verifies every entry, re-runs every command you report against your final files,
          and publishes one draft pull request per repository. Its own result decides the outcome:
          an entry it cannot verify or a repository whose verification fails is not published.
      MD
    end

    # MVP-0036 Stage 2a — the answered batch, appended once after the unchanged approved package.
    # It is the ONLY thing a fresh session receives from the one that asked: the questions, the
    # decisions, and the bounded public continuation context. No transcript, no earlier reasoning
    # and no local path, because none of those was ever stored.
    def resume_prompt = @resume&.prompt_section.to_s

    # MVP-0035 — the change request, appended ONCE after the unchanged approved package. The
    # package leads because it is still the authority; the findings follow because they are what
    # this round is for.
    def rework_prompt
      return "" if @rework.nil?

      @rework.prompt_section(payload.dig("report_contract", "round_label").to_s)
    end

    # MVP-0036 — the ONE way to reach the Product Owner. Named explicitly because a provider's
    # own question UI is private: SpecRelay never reads it, never interprets stdout as a
    # question, and cannot answer either.
    #
    # The required context fields and the size bound come from the assignment's
    # `question_contract`, which Platform builds from the very validator that enforces them, so
    # these instructions cannot describe a document Platform would refuse.
    def question_lines(bridge_path)
      contract = payload["question_contract"].to_h
      fields = contract["continuation_context_fields"].to_h
      <<~MD.strip
        If you need a Product Owner decision, do not guess and do not ask on stdout:

        - Write `#{File.join(bridge_path, QuestionBridge::REQUEST)}` as one JSON object with
          `questions` (each `prompt`, and optional `options` of `key`/`label`/`trade_off`/`recommended`)
          and `continuation_context`. `#{contract['reserved_option_key']}` is always offered for you
          and is a reserved key. The whole document must fit within #{contract['max_document_bytes']} bytes.
        - `continuation_context` requires: #{fields.map { |name, description| "`#{name}` (#{description})" }.join(', ')}.
          It is PUBLIC: no local paths, credentials, or your own reasoning.
        - Write the repository selection above FIRST and keep it current: SpecRelay checkpoints
          exactly the repositories it names so another machine can continue this work, and a
          question whose selection is missing, stale or unverifiable is refused rather than stored.
        - Then wait for `#{File.join(bridge_path, QuestionBridge::ANSWER)}` and continue with its
          `answers`, or for `#{File.join(bridge_path, QuestionBridge::ERROR)}`, which you may correct
          and re-submit. If neither appears, your session was released; stop.
      MD
    end

    # Where the verified package actually IS on this machine. The handoff prompt tells the
    # executor every document was "delivered read-only with your assignment"; without these lines
    # that sentence names nothing it can open.
    def package_lines
      return [] if @package.nil? || !@package.ok?

      [ "- Specification package (read-only, read ALL of it before implementing): `#{@package.root}`" ] +
        @package.paths.map { |path| "  - `#{File.join(@package.root, path)}`" }
    end

    # Emit ONE ordered v1 protocol event, then heartbeat. Both responses carry the
    # lease/cancellation liveness signal (MVP-0012); observe it so a
    # cancellation/expiry that lands at a phase boundary is noticed immediately.
    # Console output is redacted defensively.
    def emit(event_type, summary, **attributes)
      log("[#{event_type}] #{summary}")
      observe_lease(emitter.emit(event_type, summary, **attributes))
      observe_lease(client.heartbeat(claim: claim))
      check_stop!
    end

    def emit_pair(event_type, summary_lower, summary_higher, **attributes)
      lower, higher = emitter.emit_out_of_order_pair(event_type, summary_lower, summary_higher, **attributes)
      observe_lease(higher)
      observe_lease(lower)
    end

    def observe_lease(response)
      lease = response.is_a?(Hash) ? response["lease"].to_h : {}
      state = lease["state"].to_s
      return if state.empty? || (state == "active" && !lease["cancel_requested"])

      @lease_stop_reason ||= lease["cancel_requested"] ? "cancelled" : state
    end

    def runner_name = payload.dig("claim", "runner_display_name").to_s
    def provider = payload.dig("executor", "provider").to_s

    # Flushed for the same reason the live log stream is (MVP-0018): a redirected
    # stdout is block-buffered, so an unflushed phase line only appears at exit and
    # the operator cannot tell a working run from a stuck one.
    def log(message)
      io.puts(Redaction.redact(message.to_s))
      io.flush if io.respond_to?(:flush)
    end

    def executor_failure(result)
      return Redaction.redact("the #{provider} executor could not be started: #{result.launch_error}") if result.launch_error

      reason = result.timed_out ? "executor timed out" : "executor exited #{result.exit_code}"
      Redaction.redact([ reason, first_line(result.stderr, result.stdout) ].reject { |s| s.to_s.empty? }.join(": "))
    end

    def first_line(*candidates)
      candidates.map { |c| c.to_s.strip }.find { |s| !s.empty? }.to_s.each_line.first.to_s.strip
    end
  end
end
