# frozen_string_literal: true

require "base64"

module SpecrelayRunner
  module PackagePreflight
    # One claimed package preflight, end to end (MVP-0034 CR-001 Runner responsibilities).
    #
    # The order is the contract, and every step exists to keep one promise: **no provider starts
    # on a specification nobody has verified.**
    #
    #   1. validate the assignment's own shape — a pull request, a repository, a 40-character
    #      commit, a folder, and a file set to reproduce;
    #   2. read the pull request's state, base and current head with the operator's `gh`;
    #   3. require that head to equal the commit Platform recorded for the publication;
    #   4. read every package file BY that commit;
    #   5. read the remote head once more, immediately before submitting;
    #   6. submit, and let Platform decide.
    #
    # Step 5 is not redundant with step 3. Steps 3 and 4 take time, and a pull request that moved
    # while its package was being read would produce bytes that were individually correct and
    # collectively from two heads. Re-reading the head last is what makes "these bytes are that
    # commit" true at the moment of submission (S18).
    #
    # The runner never decides authority. It submits what it read and obeys the answer: only an
    # `authorized` response — meaning Platform recomputed every digest, pinned the package and
    # completed the Jira transition — lets the caller launch an executor. A refusal, a failure, a
    # timeout or a moved head all end here with nothing launched and Jira untouched.
    class Execution
      Result = Struct.new(:outcome, :message, :assignment_payload, keyword_init: true) do
        # The ONLY true answer that authorizes a provider. Written as an equality against
        # `:authorized` rather than as "not a failure" so a future outcome cannot become a launch
        # by default.
        def authorized? = outcome == :authorized
        def refused? = outcome == :refused
      end

      def self.call(**kwargs) = new(**kwargs).call

      def initialize(config:, client:, payload:, env: ENV, io: $stdout)
        @config = config
        @client = client
        @assignment = Assignment.new(payload)
        @env = env
        @io = io
      end

      def call
        assignment.validate!
        Dir.mktmpdir("specrelay-preflight-") do |workdir|
          @commands = Specification::GitCommands.new(checkout_root: workdir, env: env)
          verify_and_submit
        end
      rescue Assignment::Error => e
        local_failure("this assignment could not be read: #{e.message}")
      end

      private

      attr_reader :config, :client, :assignment, :env, :io, :commands

      def verify_and_submit
        pull_request = read_pull_request
        return pull_request if pull_request.is_a?(Result)

        reader = Reader.new(commands: commands, assignment: assignment)
        documents = reader.read
        return refuse(documents.classification, documents.message) if documents.is_a?(Reader::Failure)

        # Step 5 — the last thing before the wire.
        return refuse(Reader::UNREADABLE, moved_message) if reader.head_moved?

        submit(documents)
      end

      # Steps 2 and 3. {Specification::ExistingPullRequest} already owns "is this pull request
      # usable?" for the specification lane, and the question is the same one here — open, on this
      # repository, against the configured base — so it is reused rather than restated.
      def read_pull_request
        result = Specification::ExistingPullRequest.call(
          commands: commands, slug: assignment.repository_slug,
          base_branch: assignment.base_branch, url: assignment.pull_request_url, io: io
        )
        return refuse(Reader::UNREADABLE, result.message) unless result.ok?
        return refuse("package_stale", moved_message) unless
          result.head_sha.to_s.casecmp?(assignment.head_sha)

        nil
      end

      def submit(documents)
        response = client.submit_specification_package(claim: assignment.claim_token, package: body(documents))
        authorized?(response) ? authorized(response) : platform_refusal(response)
      rescue PlatformClient::Error => e
        # A refusal Platform stated, or a transport failure. Either way nothing was pinned that
        # this runner may act on, so it launches nothing and leaves the claim for release.
        local_failure("Platform did not accept the specification package: #{Redaction.redact(e.message)}")
      end

      # Paths and bytes only. No digest this runner computed is sent: Platform recomputes every
      # one from the bytes, so a digest here could only be a value that looks authoritative and is
      # not.
      def body(documents)
        {
          contract_version: Assignment::KIND, run_id: assignment.run_id,
          runner_execution_id: assignment.claim_token,
          spec_pull_request_url: assignment.pull_request_url,
          repository_slug: assignment.repository_slug,
          pull_request_number: assignment.pull_request_number,
          base_branch: assignment.base_branch, head_sha: assignment.head_sha,
          documents: documents.values.map do |document|
            { path: document.path, content_base64: Base64.strict_encode64(document.bytes) }
          end
        }
      end

      def authorized?(response) = response.to_h["authorized"] == true

      def authorized(response)
        log("Platform pinned the specification package for #{assignment.ticket_key} " \
            "(#{response.to_h['manifest_digest'].to_s[0, 12]}) and authorized execution.")
        Result.new(outcome: :authorized, assignment_payload: response.to_h["assignment"],
                   message: "Runner outcome: package_pinned (Platform authorized execution).")
      end

      # Platform accepted the submission as well-formed but did not authorize: either it refused
      # the package, or it pinned it and could not finish the Jira transition. Neither launches a
      # provider, and the distinction is Platform's to report.
      def platform_refusal(response)
        fields = response.to_h
        blocker = fields["blocker"].to_h
        log("Platform did not authorize #{assignment.ticket_key}: " \
            "#{blocker['detail'] || fields['outcome']}")
        Result.new(outcome: :refused,
                   message: "Runner outcome: preflight_refused (#{blocker['classification'] || fields['outcome']}); " \
                            "nothing was executed and Jira was not advanced.")
      end

      # A refusal this runner reached itself, reported to Platform so the ticket shows an operator
      # WHY rather than sitting silently claimable. The submission carries no documents.
      def refuse(classification, message)
        log("Refusing #{assignment.ticket_key}: #{Redaction.redact(message.to_s)}")
        client.submit_specification_package(
          claim: assignment.claim_token,
          package: { contract_version: Assignment::KIND, run_id: assignment.run_id,
                     runner_execution_id: assignment.claim_token, refusal: classification,
                     message: Redaction.redact(message.to_s) }
        )
        Result.new(outcome: :refused,
                   message: "Runner outcome: preflight_refused (#{classification}); " \
                            "nothing was executed and Jira was not advanced.")
      rescue PlatformClient::Error => e
        local_failure("could not report the refusal to Platform: #{Redaction.redact(e.message)}")
      end

      def local_failure(message)
        log("Preflight failed for #{assignment.ticket_key}: #{message}")
        log("Nothing was executed and Jira was not advanced. The run is still CLAIMED on Platform;")
        log("release it there so another attempt can take it.")
        Result.new(outcome: :failed,
                   message: "Runner outcome: preflight_failed (#{message}); nothing was executed.")
      end

      def moved_message
        "the Spec PR head no longer matches the commit this ticket's specification was published " \
          "at (#{assignment.head_sha[0, 12]}); publish the specification revision again"
      end

      def log(message) = io.puts(Redaction.redact(message.to_s))
    end
  end
end
