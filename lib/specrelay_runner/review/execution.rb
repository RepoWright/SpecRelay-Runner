# frozen_string_literal: true

module SpecrelayRunner
  module Review
    # Executes ONE claimed review attempt (MVP-0033 contract 6).
    #
    # The order is the contract, and each step fails closed:
    #
    #   1. verify the local checkout really is the pinned remote and head — otherwise refuse
    #      before a reviewer sees anything (S23);
    #   2. launch ONE FRESH provider process with the fixed Reviewer instructions and nothing
    #      from this runner's implementation work — no resumed session, no shared context
    #      (S24);
    #   3. parse its stdout strictly and redact it;
    #   4. submit exactly one structured outcome.
    #
    # A failure at any step is reported to Platform as a failed attempt with a safe reason
    # rather than swallowed, so the operator sees why review did not happen and Platform can
    # offer a new attempt (S30). The implementation result is never touched.
    class Execution
      # The two ways a review attempt can end with no verdict, reported explicitly (MAPIAI-78
      # design 2). They are different facts with different remedies: a provider that never
      # produced a usable result is a machine or configuration problem, while an unusable result
      # is a reviewer problem — and neither is a verdict about the implementation.
      PROVIDER_EXECUTION_FAILURE = "provider_execution_failure"
      INVALID_REVIEWER_RESULT = "invalid_reviewer_result"
      NO_CONTRACT = "Platform sent no supported review outcomes, so no result could be checked"
      NO_REVIEWER = "no reviewer provider is configured on this machine"
      # The ONE remedy for a guided connection made before its reviewer selection was stored
      # (MAPIAI-91). Reconnecting is the only supported way to record that selection; nothing here
      # may infer it from the executor, PATH, the Platform profile, or a default.
      RECONNECT_REMEDY = "reconnect this workspace with `specrelay-runner connect <enrollment-code>` " \
                         "to store its reviewer selection"

      Result = Struct.new(:outcome, :message, keyword_init: true) do
        def success? = outcome == :submitted
        # A moved target is not a machine fault: the reviewer correctly refused to judge code
        # that is no longer there. Distinct from `success?` because no verdict exists, and
        # distinct from a failure because there is nothing on this machine to fix.
        def stale? = outcome == :stale
      end

      def self.call(**kwargs) = new(**kwargs).call

      def initialize(config:, client:, payload:, settings: nil, env: ENV, io: $stdout, runner: CommandRunner)
        @assignment = Assignment.new(payload)
        @config = config
        @client = client
        @settings = settings || Settings.from(config, env: env)
        @env = env
        @io = io
        @runner = runner
      end

      def call
        return failure(PROVIDER_EXECUTION_FAILURE, no_reviewer_reason) unless settings.configured?
        return failure(PROVIDER_EXECUTION_FAILURE, NO_CONTRACT) if assignment.supported_outcomes.empty?

        workspace_root = config.workspace_root(assignment.workspace_key, env: env)
        checkout = Checkout.verify(assignment: assignment, workspace_root: workspace_root)
        return stale(checkout.reason) if checkout.stale?
        return failure(PROVIDER_EXECUTION_FAILURE, checkout.reason) unless checkout.ok?

        review(workspace_root)
      rescue Config::Error, Settings::Error => e
        # Both mean the reviewer could not be launched at all: an unusable workspace root, or a
        # local configuration that would put the provider in an output mode whose result is not
        # a review.
        failure(PROVIDER_EXECUTION_FAILURE, Redaction.redact(e.message))
      end

      private

      attr_reader :assignment, :config, :client, :settings, :env, :io, :runner

      # A YAML-configured machine is left to its own `runner.reviewer:` block; a machine connected
      # through guided setup is told to reconnect, because that is where its reviewer selection
      # lives. Either way the attempt is reported as a retryable failure, never as a verdict, and
      # neither message claims the setup is complete.
      def no_reviewer_reason
        config.connection.nil? ? NO_REVIEWER : "#{NO_REVIEWER}; #{RECONNECT_REMEDY}"
      end

      def review(workspace_root)
        log "Reviewing #{assignment.ticket_id} at the pinned head (attempt #{assignment.attempt_ordinal})"
        heartbeater = start_heartbeater
        launched = launch(workspace_root)
        # A timeout and a non-zero exit are provider FAILURES, not results: whatever the process
        # printed before dying is not a verdict, so it is never parsed for one.
        return failure(PROVIDER_EXECUTION_FAILURE, "the reviewer timed out") if launched.timed_out?
        return failure(PROVIDER_EXECUTION_FAILURE, "the reviewer exited #{launched.exit_code}") unless launched.exit_code.to_i.zero?

        parsed = Review::Result.parse(launched.stdout, outcomes: assignment.supported_outcomes)
        return failure(INVALID_REVIEWER_RESULT, parsed.error) unless parsed.ok?

        verdict(parsed.review, workspace_root)
      ensure
        heartbeater&.stop
      end

      # The head can move WHILE the reviewer works — a review takes minutes and a push takes
      # seconds. Re-verified here, immediately before the only call that can record a verdict,
      # so a move during the review can never produce acceptance (CR-001 F3).
      def verdict(review, workspace_root)
        recheck = Checkout.verify(assignment: assignment, workspace_root: workspace_root)
        return stale(recheck.reason) if recheck.stale?
        return failure(PROVIDER_EXECUTION_FAILURE, recheck.reason) unless recheck.ok?

        submit(review)
      end

      # ONE fresh process. The child environment is the operator's own PATH and HOME only —
      # this runner passes no session id, no resume flag and no context of its own, which is
      # what makes the reviewer independent of any executor work this same machine did (S24).
      def launch(workspace_root)
        runner.run(settings.argv(Packet.new(assignment).prompt),
                   chdir: workspace_root, env: child_env,
                   timeout_seconds: settings.timeout_seconds)
      end

      def child_env
        { "PATH" => env["PATH"].to_s, "HOME" => env["HOME"].to_s }
      end

      def start_heartbeater
        renewal = assignment.lease_renewal_seconds
        return nil unless renewal.positive?

        Heartbeater.new(client: client, claim: assignment.claim_token,
                        interval_seconds: renewal, io: io).start
      end

      def submit(review)
        client.submit_review_result(claim: assignment.claim_token, attempt_id: assignment.attempt_id,
                                    review: review)
        log "Submitted #{review['outcome']} for #{assignment.ticket_id}"
        Result.new(outcome: :submitted, message: "Review submitted: #{review['outcome']}.")
      rescue PlatformClient::Error => e
        # A 4xx is Platform having READ this result and refused it, so the attempt already
        # carries Platform's own reason and a failure report on top of it would be a second,
        # conflicting ending for one attempt.
        unrecorded("Platform refused the review result", e)
      end

      # Reported through the dedicated stale body rather than as an outcome-less result:
      # Platform must be able to tell "this reviewer failed, offer another attempt" from "this
      # target is gone, close the assignment", and an outcome-less body cannot say which.
      def stale(reason)
        safe = Redaction.redact(reason.to_s)
        client.report_stale_target(claim: assignment.claim_token, attempt_id: assignment.attempt_id,
                                   reason: safe)
        log "Review stopped: #{safe}"
        Result.new(outcome: :stale, message: "Review stopped: #{safe}")
      rescue PlatformClient::Error => e
        unrecorded("Platform refused the stale-target report", e)
      end

      # A refusal is reported AS a failure, never as an outcome-less review body (MAPIAI-78
      # design 2). The old shape made Platform's generic outcome-validation message replace the
      # local reason that actually explained what happened, which is how the live MAPIAI-73
      # review came to say that a rule nobody had broken was broken.
      def failure(kind, reason)
        safe = Redaction.redact(reason.to_s)
        client.report_review_failure(claim: assignment.claim_token, attempt_id: assignment.attempt_id,
                                     kind: kind, reason: safe)
        log "Review failed: #{safe}"
        Result.new(outcome: :failed, message: "Review failed: #{safe}")
      rescue PlatformClient::Error => e
        unrecorded("Review failed (#{safe}), and Platform refused the failure report", e)
      end

      # Platform's answer, or its silence, about a delivery this machine cannot resolve.
      #
      # Nothing further is delivered on either path: a refusal means Platform already recorded
      # its own ending, and a transport failure means the outcome of this attempt is Platform's
      # durable state and its lease-expiry path to decide — not something to guess at from here.
      # Both exit non-zero, because this claim did not produce what it was made for.
      def unrecorded(context, error)
        message = error.refused? ? "#{context}: #{Redaction.redact(error.message)}"
                                 : "#{context}: Platform did not confirm it (#{Redaction.redact(error.message)})"
        log message
        Result.new(outcome: :failed, message: message)
      end

      def log(message) = io.respond_to?(:line) ? io.line(message) : io.puts(message)
    end
  end
end
