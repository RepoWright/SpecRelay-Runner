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

    Result = Struct.new(:outcome, :message, keyword_init: true) do
      def success? = outcome == :completed
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
      @lease_stop_reason = nil
      @controls = ProtocolControls.new(env: env)
      @emitter = EventEmitter.new(client: client, run_id: @run.fetch("id"), attempt_id: @claim)
    end

    def call
      root = @config.workspace_root(@workspace.fetch("workspace_key"), env: @env)
      Dir.mktmpdir("specrelay-runner-") do |staging|
        start_heartbeater
        run_flow(root, staging)
      end
    rescue Aborted => e
      aborted_result(e)
    rescue Config::Error, Workspace::Error => e
      # A pre-execution local failure AFTER the claim already succeeded: the
      # workspace root is not mapped, or the worktree could not be created. Left
      # unhandled this crashed the runner and left the run CLAIMED/stuck forever
      # (the exact QUALITY-0002 manual-test failure). Instead, surface precise,
      # secret-safe recovery guidance and exit non-zero cleanly.
      preflight_failure(e)
    ensure
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
      reason = @heartbeater&.stop_reason || @lease_stop_reason
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

    def run_flow(root, staging)
      emit("attempt.started", "Runner #{runner_name} started an attempt for #{run['task_id']}", phase: "attempt")

      emit("workspace.preparing", "Preparing worktree for #{run['task_id']}", phase: "workspace")
      worktree = create_worktree(root)

      emit("core.started", "Running #{provider} executor for #{run['task_id']}", phase: "core")
      executor_result = run_executor(worktree, staging)
      # If Platform expired or cancelled the claim while the executor held it, stop
      # BEFORE running tests or uploading anything (MVP-0012).
      check_stop!
      unless executor_result.success?
        return failed_report(root, worktree, executor_result, executor_failure(executor_result))
      end

      changes = Workspace.new(root: root, canonical_branch: run["canonical_branch"], create_command: "").capture_changes(worktree.path)
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

    def run_executor(worktree, staging)
      Executor.new(config: payload.fetch("executor"), worktree_path: worktree.path, staging_dir: staging)
              .run(prompt_text(worktree.path))
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
                                  failure_details: failure_details(status, test, publication_failure))
      terminal = terminal_result(status: status, final_sequence: emitter.sequence, exit_code: test[:exit_code],
                                 base_commit: worktree.base_commit, changes: changes, publication: publication,
                                 error_classification: publication_failure ? "publication_failed" : nil)
      response = client.submit_report(claim: claim, bundle: bundle, terminal_result: terminal)
      outcome = response["outcome"].to_s
      log("Report stored: #{response.dig('report', 'url')} (run #{response['run_state']})")
      Result.new(outcome: outcome.to_sym, message: "Runner outcome: #{outcome}.")
    end

    # A failed executor: emit the terminal event and upload a failed report + a
    # failed terminal envelope so Platform records the attempt (run marked FAILED;
    # Jira is not advanced).
    def failed_report(root, worktree, executor_result, message)
      log(message)
      changes = Workspace.new(root: root, canonical_branch: run["canonical_branch"], create_command: "").capture_changes(worktree.path)
      test = { command: workspace.fetch("test_command"), exit_code: nil, output: "" }
      emit("attempt.completed", "Uploading failed execution report for #{run['task_id']}", phase: "completed")
      bundle = ReportBundle.build(payload: payload, status: ReportBundle::STATUS_FAILED, executor: executor_result,
                                  test: test, changes: changes, base_commit: worktree.base_commit,
                                  worktree_path: worktree.path, failure_details: message)
      terminal = terminal_result(status: ReportBundle::STATUS_FAILED, final_sequence: emitter.sequence,
                                 exit_code: executor_result.exit_code, base_commit: worktree.base_commit,
                                 changes: changes, error_classification: "executor_failed")
      client.submit_report(claim: claim, bundle: bundle, terminal_result: terminal)
      Result.new(outcome: :executor_failed, message: message)
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
        artifacts: %w[README.md manifest.yml evidence/stdout.log evidence/tests.log evidence/diff.txt]
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

    def prompt_text(worktree_path)
      preamble = <<~MD.strip
        # Automated execution task — #{run['task_id']}

        You are an automated, non-interactive executor. Implement the approved
        specification in the dedicated worktree below, then stop.

        - Worktree (your working directory): `#{worktree_path}`
        - Task id: `#{run['task_id']}`
        - Canonical branch: `#{run['canonical_branch']}`

        Rules:
        - Change ONLY files inside the worktree above, per the approved specification.
        - Do NOT edit any `spec.md`/`spec_persian.md`, push, open a PR, or write to Platform.
        - Make the change idempotently.
      MD
      "#{preamble}\n\n---\n\n#{payload.dig('approved_specification', 'handoff_prompt')}"
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

    def log(message) = io.puts(Redaction.redact(message.to_s))

    def executor_failure(result)
      reason = result.timed_out ? "executor timed out" : "executor exited #{result.exit_code}"
      Redaction.redact([ reason, first_line(result.stderr, result.stdout) ].reject { |s| s.to_s.empty? }.join(": "))
    end

    def first_line(*candidates)
      candidates.map { |c| c.to_s.strip }.find { |s| !s.empty? }.to_s.each_line.first.to_s.strip
    end
  end
end
