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
      Result = Struct.new(:outcome, :message, keyword_init: true) do
        def success? = outcome == :submitted
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
        return failure("no reviewer provider is configured on this machine") unless settings.configured?

        workspace_root = config.workspace_root(assignment.workspace_key, env: env)
        checkout = Checkout.verify(assignment: assignment, workspace_root: workspace_root)
        return failure(checkout.reason) unless checkout.ok?

        review(workspace_root)
      rescue Config::Error => e
        failure(Redaction.redact(e.message))
      end

      private

      attr_reader :assignment, :config, :client, :settings, :env, :io, :runner

      def review(workspace_root)
        log "Reviewing #{assignment.ticket_id} at the pinned head (attempt #{assignment.attempt_ordinal})"
        heartbeater = start_heartbeater
        parsed = parse(launch(workspace_root))
        return failure(parsed.error) unless parsed.ok?

        submit(parsed.review)
      ensure
        heartbeater&.stop
      end

      # A timeout and a non-zero exit are provider FAILURES, not results: whatever the process
      # printed before dying is not a verdict, so it is never parsed for one.
      def parse(result)
        return Review::Result::Parsed.new(error: "the reviewer timed out") if result.timed_out?
        return Review::Result::Parsed.new(error: "the reviewer exited #{result.exit_code}") unless result.exit_code.to_i.zero?

        Review::Result.parse(result.stdout)
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
        client.submit_review_result(claim: assignment.claim_token, review: review)
        log "Submitted #{review['outcome']} for #{assignment.ticket_id}"
        Result.new(outcome: :submitted, message: "Review submitted: #{review['outcome']}.")
      rescue PlatformClient::Error => e
        failure("Platform refused the review result: #{Redaction.redact(e.message)}")
      end

      # A refusal is reported, never merely printed: Platform must record the failed attempt so
      # the run page explains why no verdict exists and a new attempt can be offered.
      def failure(reason)
        safe = Redaction.redact(reason.to_s)
        report_failure(safe)
        log "Review failed: #{safe}"
        Result.new(outcome: :failed, message: "Review failed: #{safe}")
      end

      # Reported through the SAME submission endpoint, as an outcome-less body. Platform's
      # strict validation rejects it, which is exactly the intent: the attempt is recorded
      # FAILED with this reason and no verdict is created.
      def report_failure(reason)
        client.submit_review_result(claim: assignment.claim_token,
                                    review: { "summary" => reason, "findings" => [], "evidence" => {} })
      rescue PlatformClient::Error
        # The attempt's lease will expire and Platform will record it. Nothing further is
        # possible from here, and raising would replace a clear local message with a stack.
        nil
      end

      def log(message) = io.respond_to?(:line) ? io.line(message) : io.puts(message)
    end
  end
end
