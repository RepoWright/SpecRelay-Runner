# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "shellwords"

module SpecrelayRunner
  # Orchestrates ONE claimed run end to end on the developer machine (MVP-0010),
  # talking to Platform only over the API client. It performs the same Tiny Demo
  # execution flow proven in MVP-0009 — worktree create, executor launch, test
  # command, diff/log capture — but as a separate process, and streams ORDERED v1
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

    Result = Struct.new(:outcome, :message, keyword_init: true) do
      def success? = outcome == :completed

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
    end

    STOP_HEARTBEAT_ENV = "SPECRELAY_RUNNER_STOP_HEARTBEAT_AFTER_SECONDS"
    DEFAULT_RENEWAL_SECONDS = 30

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
      @lease_stop_reason = nil
      @package = nil
      # MVP-0035 — nil for an ordinary first execution, which is every claim that does not
      # follow a CHANGES_REQUESTED review.
      @rework = Rework.for(payload)
      # MVP-0036 Stage 2b — nil unless this claim is a REPLACEMENT run continuing the pull
      # request an abandoned run had already published. A run is never both this and a rework:
      # a replacement is new, so nothing has reviewed it.
      @restart = ContinuedTarget.for(payload, "restart")
      # MVP-0036 Stage 2a — nil unless this claim continues an answered offline question on the
      # machine that still holds its uncommitted work.
      @resume = Resume.for(payload)
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

    # Stage 2a — the recorded checkpoint is not what this machine holds. The question, its
    # answers and its checkpoint all stay durable on Platform, and the uncommitted work stays
    # here, so the owner can correct the worktree and claim again.
    def resume_refused(reason)
      refuse_before_provider(reason, "Refusing to resume #{run['task_id']}")
    end

    def refuse_before_provider(reason, headline)
      safe = Redaction.redact(reason.to_s)
      log("#{headline}: #{safe}")
      log("Nothing ran: no provider received this task, nothing was pushed, and Jira was not touched.")
      release_claim(safe)
      Result.new(outcome: :preflight_failed,
                 message: "Runner outcome: preflight_failed (#{safe}); nothing executed.")
    end

    # Give the machine's capacity back and leave the run claimable. ONLY a refused change-request
    # target does this. The other pre-provider refusals keep their manual recovery step: each is
    # a misconfiguration of this machine that the operator has to correct anyway, and releasing
    # under the default `continue` loop policy would let the same runner reclaim and re-refuse
    # the same run in a loop instead of holding one actionable failure (CR-001 F3).
    #
    # Best effort by design: a Platform that cannot be reached will expire the lease on its own,
    # and raising here would replace a precise local reason with a transport error.
    def release_claim(reason)
      client.release_claim(claim: claim, reason: reason)
      log("Released this claim on Platform; the run is claimable again.")
    rescue PlatformClient::Error => e
      log("Could not release the claim (#{Redaction.redact(e.message)}); its lease will expire on Platform.")
    end

    # Fail closed before anything happens: no worktree, no executor launch, no
    # report, no publication, no Jira transition. Only checked when this runner
    # selected a real provider profile — the fake-executor regression path is
    # unaffected.
    def guard_selected_executor!
      profile = config.selected_claude_profile
      return if profile.nil?

      # Same env the executor will launch with, so the comparison resolves the very
      # file that would run (review-001 finding F1).
      reason = profile.mismatch_reason(payload.fetch("executor"), env: env)
      raise ExecutorMismatch, reason if reason
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

    def run_flow(root, staging)
      emit("attempt.started", "Runner #{runner_name} started an attempt for #{run['task_id']}", phase: "attempt")

      emit("workspace.preparing", "Preparing worktree for #{run['task_id']}", phase: "workspace")
      # MVP-0036 Stage 2a — a resume continues the DIRTY worktree its question was asked from, so
      # it reads and proves that worktree where an ordinary claim creates a clean one. A refusal
      # here stops before the provider, before the package, and before any external write.
      if @resume
        prepared = @resume.prepare(workspace: measuring_workspace(root))
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

        worktree = Workspace::Info.new(path: worktree.path, base_commit: continuation.head_commit || worktree.base_commit)
      end

      # MVP-0034 contract 4 — the pinned package is verified and written read-only BEFORE the
      # provider starts. A document whose bytes do not reproduce the digest Platform pinned ends
      # the attempt here, with a failed report and no executor (S23).
      @package = SpecificationPackage.call(payload: payload, staging_dir: staging)
      unless @package.ok?
        return package_refused(root, worktree, @package.failure)
      end

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
        return failed_report(root, worktree, executor_result, executor_failure(executor_result),
                             classification: executor_classification(executor_result))
      end

      changes = measuring_workspace(root).capture_changes(worktree.path)
      # An unmeasurable worktree is NOT an unchanged one. Reporting `changed: false`
      # here would advance Jira announcing "no code changes" while the executor's diff
      # sits on disk, so this fails closed instead (review-002 finding N1).
      return unmeasured_report(worktree, executor_result, changes) unless changes.measured?

      emit("verification.started", "Running project tests for #{run['task_id']}", phase: "verification")
      test = run_tests(worktree, root)
      emit("verification.completed", "Project tests exited #{test[:exit_code]} for #{run['task_id']}",
           phase: "verification", test_command: test[:command], test_exit_code: test[:exit_code])

      # Final gate before finalizing: never upload a success report for a claim
      # Platform no longer considers live.
      check_stop!
      demonstrate_protocol_controls
      status = terminal_status(test)
      publication = publish(worktree, changes, test, status)
      # An incomplete publication is a FAILED attempt, not a success with a warning:
      # the tests passed but the output never became reviewable. Reporting it as
      # failed is what makes Platform record a durable, operator-visible reason and
      # leave Jira where it is (MVP-0014).
      failure = publication_failure(publication)
      status = ReportBundle::STATUS_FAILED if failure
      submit(worktree, executor_result, test, changes, status, publication, failure)
    end

    # The first publication error across the assigned repositories, or nil.
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
      test = { command: workspace.fetch("test_command"), exit_code: nil, output: "" }
      emit("attempt.completed", "Uploading failed execution report for #{run['task_id']}", phase: "completed")
      bundle = ReportBundle.build(payload: payload, status: ReportBundle::STATUS_FAILED, executor: executor_result,
                                  test: test, changes: changes, base_commit: worktree.base_commit,
                                  worktree_path: worktree.path, failure_details: reason,
                                  live_log: live_log_evidence)
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
    def publish(worktree, changes, test, status)
      publishing = status == ReportBundle::STATUS_SUCCEEDED
      publication = Publication.new(payload: payload, worktree_path: worktree.path, changes: changes,
                                    base_commit: worktree.base_commit, test: test, env: env, io: io,
                                    publish: publishing)
      return publication.call unless publishing && publication.expected?

      emit("publication.started", "Publishing repository output for #{run['task_id']}", phase: "publication")
      results = publication.call
      emit("publication.completed", publication_summary(results), phase: "publication",
           published_branch: results.map(&:branch).compact.first,
           pull_request_url: results.map(&:pull_request_url).compact.first)
      results
    end

    # The report's failure narrative names the real cause: a publication failure is
    # reported as such rather than blamed on the tests, which passed.
    def failure_details(status, test, publication_failure)
      return nil unless status == ReportBundle::STATUS_FAILED
      return "repository publication failed: #{publication_failure}" if publication_failure

      "project test command exited #{test[:exit_code]}"
    end

    def publication_summary(results)
      failed = results.select(&:publication_error)
      return "Publication failed for #{run['task_id']}: #{failed.map(&:publication_error).first}" if failed.any?

      published = results.select(&:branch)
      "Published #{published.length} repository branch(es) for #{run['task_id']}"
    end

    def create_worktree(root)
      Workspace.new(root: root, canonical_branch: run["canonical_branch"],
                    create_command: workspace.fetch("worktree_create_command")).create
    end

    # The same workspace, for READING only: the change capture, the Stage 2a checkpoint and the
    # resume's worktree lookup all ask about a worktree rather than create one, so none of them
    # carries a create command.
    def measuring_workspace(root)
      Workspace.new(root: root, canonical_branch: run["canonical_branch"], create_command: "")
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
      # can never appear in the diff the executor is measured on.
      @bridge = QuestionBridge.new(client: client, claim: claim, staging_dir: staging, io: io,
                                   measure: -> { measure_checkpoint(root, worktree) },
                                   resume_question_id: @resume&.question_id).start
      Executor.new(config: payload.fetch("executor"), worktree_path: worktree.path, staging_dir: staging, env: env)
              .run(prompt_text(worktree.path, @bridge.path), on_output: @log_stream.sink,
                   on_start: -> { @bridge.confirm_resume },
                   stop_check: -> { @bridge.stop_provider? })
    ensure
      @log_stream&.finish
      @bridge&.stop
    end

    # MVP-0036 Stage 2a — what this machine looked like at the instant the provider paused.
    def measure_checkpoint(root, worktree)
      Checkpoint.measure(repository_key: workspace.fetch("workspace_key"),
                         branch: run["canonical_branch"].to_s, worktree_path: worktree.path,
                         workspace: measuring_workspace(root))
    end

    # MVP-0036 — the two honest endings for a provider that paused on a question. Neither runs
    # tests, uploads a report, publishes, or touches Jira: there is no result to report, only a
    # decision a human has not made yet. The dirty worktree stays exactly where it is.
    def question_outcome
      return input_capture_failure if @bridge.failed?

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
    def input_capture_failure
      reason = @bridge.failure_reason.to_s
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

    # The bounded live-log text for the report, or nil when nothing streamed. Kept
    # separate from the full stdout/stderr capture on purpose (see ReportBundle).
    def live_log_evidence = @log_stream&.evidence_text

    # The report-relative artifacts named in the terminal-result envelope. The live
    # executor log joins the list only when it exists, so a run with no streamed
    # output never claims an artifact it did not upload.
    def terminal_artifacts
      base = %w[README.md manifest.yml evidence/stdout.log evidence/tests.log evidence/diff.txt]
      live_log_evidence ? base + [ ReportBundle::LIVE_LOG_PATH ] : base
    end

    def run_tests(worktree, root)
      command = workspace.fetch("test_command")
      result = CommandRunner.run(Shellwords.split(command), chdir: worktree.path,
                                 env: { "PATH" => env["PATH"].to_s }, timeout_seconds: 900)
      { command: command, exit_code: result.exit_code, output: [ result.stdout, result.stderr ].join("\n") }
    end

    # Forced terminal failure (deterministic control) records a failed outcome even
    # when the tests passed, so the terminal-failure/non-review scenario can be
    # proven without an artificial broken test.
    def terminal_status(test)
      return ReportBundle::STATUS_FAILED if controls.force_terminal_failure?

      test[:exit_code].to_i.zero? ? ReportBundle::STATUS_SUCCEEDED : ReportBundle::STATUS_FAILED
    end

    def submit(worktree, executor_result, test, changes, status, publication, publication_failure = nil)
      emit("attempt.completed", "Uploading execution report for #{run['task_id']} (#{status})",
           phase: "completed", exit_code: test[:exit_code])
      bundle = ReportBundle.build(payload: payload, status: status, executor: executor_result, test: test,
                                  changes: changes, base_commit: worktree.base_commit, worktree_path: worktree.path,
                                  failure_details: failure_details(status, test, publication_failure),
                                  live_log: live_log_evidence)
      terminal = terminal_result(status: status, final_sequence: emitter.sequence, exit_code: test[:exit_code],
                                 base_commit: worktree.base_commit, changes: changes, publication: publication,
                                 error_classification: publication_failure ? "publication_failed" : nil)
      response = client.submit_report(claim: claim, bundle: bundle, terminal_result: terminal)
      outcome = response["outcome"].to_s
      log("Report stored: #{response.dig('report', 'url')} (run #{response['run_state']})")
      Result.new(outcome: outcome.to_sym, message: "Runner outcome: #{outcome}.")
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
    def failed_report(root, worktree, executor_result, message, classification: ClaudeProfile::EXECUTOR_FAILED)
      log(message)
      changes = measuring_workspace(root).capture_changes(worktree.path)
      test = { command: workspace.fetch("test_command"), exit_code: nil, output: "" }
      emit("attempt.completed", "Uploading failed execution report for #{run['task_id']}", phase: "completed")
      bundle = ReportBundle.build(payload: payload, status: ReportBundle::STATUS_FAILED, executor: executor_result,
                                  test: test, changes: changes, base_commit: worktree.base_commit,
                                  worktree_path: worktree.path, failure_details: message,
                                  live_log: live_log_evidence)
      terminal = terminal_result(status: ReportBundle::STATUS_FAILED, final_sequence: emitter.sequence,
                                 exit_code: executor_result.exit_code, base_commit: worktree.base_commit,
                                 changes: changes, error_classification: classification)
      client.submit_report(claim: claim, bundle: bundle, terminal_result: terminal)
      Result.new(outcome: :executor_failed, message: message)
    end

    # Which local condition actually failed. Timeout and "could not launch it at
    # all" are provider-agnostic facts; the real profile refines the remaining
    # non-zero exit into an authentication problem when its own captured output
    # says so, so an expired login is not reported as a task failure.
    def executor_classification(result)
      profile = config.selected_claude_profile
      return profile.classify_failure(result) if profile

      return ClaudeProfile::EXECUTOR_UNAVAILABLE if result.launch_error
      return ClaudeProfile::EXECUTOR_TIMEOUT if result.timed_out

      ClaudeProfile::EXECUTOR_FAILED
    end

    def terminal_result(status:, final_sequence:, exit_code:, base_commit:, changes:,
                        publication: nil, error_classification: nil)
      succeeded = status == ReportBundle::STATUS_SUCCEEDED
      TerminalResult.build(
        run_id: run.fetch("id"), attempt_id: claim,
        outcome: succeeded ? TerminalResult::SUCCEEDED : TerminalResult::FAILED,
        final_sequence: final_sequence, exit_code: exit_code,
        error_classification: succeeded ? nil : (error_classification || "tests_failed"),
        repositories: publication || unpublished_repositories(base_commit, changes),
        artifacts: terminal_artifacts
      )
    end

    # Repository results for a path that never reached publication (an executor
    # failure). They report the observed change state truthfully with nothing
    # published, so Platform records the repository without a false publication.
    def unpublished_repositories(base_commit, changes)
      ids = Array(payload["repositories"]).map { |repository| repository["id"].to_s }
      ids = [ workspace.fetch("workspace_key") ] if ids.empty?
      # When measurement failed, `changed: false` is not a fact — it is the absence of one
      # (review-003 finding 2). Reporting it as unknown requires a nullable `changed`,
      # which Platform's envelope validator rejects and CR-002 puts out of scope; see
      # TerminalResult#repository_result. The reason therefore travels with the repository
      # so no reader can mistake this for a clean "nothing changed".
      changed = Array(changes.changed_files).any?
      error = changes.measurement_error && "change detection failed: #{changes.measurement_error}"
      ids.map do |id|
        Publication::Result.new(id: id, changed: changed, base_commit: base_commit,
                                head_commit: changed ? changes.head_commit : nil,
                                branch: nil, pull_request_url: nil, publication_error: error,
                                publication_skipped_reason: nil)
      end
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

    def prompt_text(worktree_path, bridge_path)
      preamble = <<~MD.strip
        # Automated execution task — #{run['task_id']}

        You are an automated, non-interactive executor. Implement the approved
        specification in the dedicated worktree below, then stop.

        - Worktree (your working directory): `#{worktree_path}`
        - Task id: `#{run['task_id']}`
        - Canonical branch: `#{run['canonical_branch']}`
        #{package_lines.join("\n")}

        Rules:
        - Change ONLY files inside the worktree above, per the approved specification.
        - Do NOT edit any `spec.md`/`spec_persian.md`, push, open a PR, or write to Platform.
        - Make the change idempotently.

        #{question_lines(bridge_path)}
      MD
      "#{preamble}\n\n---\n\n#{payload.dig('specification_package', 'handoff_prompt')}#{rework_prompt}#{resume_prompt}"
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
