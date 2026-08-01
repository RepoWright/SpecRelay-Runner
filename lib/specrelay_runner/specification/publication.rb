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
    #   parse -> resolve checkout -> VERIFY DIGESTS -> check `gh` -> commit+push -> draft PR -> report
    #
    # Digest verification runs before any git command, so criterion 2's "refuses before Git
    # mutation on mismatch" is a property of this sequence rather than of a rollback. The `gh`
    # check runs before the commit for the same kind of reason: a host that cannot open a pull
    # request must not first push a branch nobody will be asked to review.
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
      REPOSITORY_UNRESOLVED = "specification_repository_unresolved"
      # Local outcome only. Platform refused the result, so by definition Platform stored no
      # failure class of its own; this one names the condition in the runner's exit and log.
      REPORT_REFUSED = "publication_report_refused"

      Result = Struct.new(:outcome, :message, :pull_request_url, :branch, :head_commit, keyword_init: true) do
        def success? = outcome == PUBLISHED
      end

      def self.call(**kwargs) = new(**kwargs).call

      def initialize(config:, client:, payload:, env: ENV, io: $stdout, clock: Time, settings: nil)
        @config = config
        @client = client
        @payload = payload.to_h
        @env = env
        @io = io
        @clock = clock
        @injected_settings = settings
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

      attr_reader :config, :client, :payload, :env, :io, :clock, :assignment

      def settings = @settings ||= @injected_settings || Settings.from(config, env: env)

      def announce(assignment)
        log("Claimed a SPECIFICATION PUBLICATION assignment for #{assignment.issue_key} " \
            "(run #{assignment.run_id}).")
        log("  Repository: #{assignment.publication_repository_url}")
        log("  Branch:     #{assignment.publication_branch} (base #{assignment.publication_base_branch})")
        log("  Package:    #{assignment.generated_package_path}")
      end

      # The whole sequence, guarded by the lease. A heartbeater runs for the duration and the
      # liveness signal is checked before the first git mutation and again before reporting, so a
      # run Platform has cancelled or reclaimed is never reported as published.
      def publish(assignment)
        start_heartbeater(assignment)
        checkout = resolve_checkout(assignment)
        return checkout if checkout.is_a?(Result)

        verified = verify_package(assignment, checkout)
        return verified if verified.is_a?(Result)

        checkpoint!
        push_and_open(assignment, checkout, verified)
      rescue Aborted => e
        aborted(e)
      ensure
        @heartbeater&.stop
      end

      # `gh` is checked BEFORE the commit, not after the push. A host without an authenticated
      # GitHub CLI can still push, so checking later would leave a branch on a shared repository
      # for a publication that was never going to be reviewable.
      def push_and_open(assignment, checkout, verified)
        commands = GitCommands.new(checkout_root: checkout, env: env)
        return fail_closed(PullRequestPublisher::GH_UNAVAILABLE, PullRequestPublisher.unavailable_message) unless
          PullRequestPublisher.available?(commands: commands)

        pushed = GitPublisher.call(commands: commands, assignment: assignment, files: verified, io: io)
        return fail_closed(pushed.failure_class, pushed.message) unless pushed.ok?

        opened = PullRequestPublisher.call(commands: commands, assignment: assignment, files: verified,
                                           head_commit: pushed.head_commit, io: io)
        return fail_closed(opened.failure_class, opened.message, pushed: pushed) unless opened.ok?

        checkpoint!
        succeed(verified, pushed, opened)
      end

      # This machine's clone of the specification repository, resolved through the same operator
      # configuration generation used — so the two phases can never disagree about where the
      # package lives.
      def resolve_checkout(assignment)
        slug = assignment.publication_slug
        slug = assignment.publication_repository_url if slug.empty?
        root = settings.repository_root(slug, repository_url: assignment.publication_repository_url)
        return fail_closed(REPOSITORY_UNRESOLVED, missing_checkout_message(slug)) if root.nil?

        expanded = File.expand_path(root)
        return fail_closed(REPOSITORY_UNRESOLVED,
                           "the configured specification repository checkout does not exist on this " \
                           "runner: #{expanded}") unless File.directory?(expanded)

        expanded
      end

      def missing_checkout_message(slug)
        "no local checkout is configured for the specification repository " \
          "#{assignment.publication_repository_url}. Set #{settings.repository_root_env(slug)} to its " \
          "absolute path, or add it under runner.specification.repository_roots, then retry publication."
      end

      def verify_package(assignment, checkout)
        result = PackageVerification.call(checkout_root: checkout, package_path: assignment.generated_package_path,
                                          files: assignment.generated_files)
        return result.files if result.ok?

        log("Refusing to publish: #{result.message}")
        log("Nothing was committed, pushed, or opened as a pull request.")
        fail_closed(result.failure_class, result.message)
      end

      # ------------------------------------------------------------------ outcomes

      # `published` is claimed only once Platform has ACCEPTED the result. The pull request
      # existing is not the same fact as the run having advanced, and only Platform can say the
      # second one happened.
      def succeed(verified, pushed, opened)
        refusal = submit(success_payload(verified, pushed, opened))
        return report_refused(refusal, pushed, opened) if refusal

        log("")
        log("Published #{verified.length} files on #{assignment.publication_branch} as a draft pull request:")
        log("  #{opened.url}")
        log("No Jira field was written, no status was transitioned, and no comment was added.")
        Result.new(outcome: PUBLISHED, pull_request_url: opened.url, branch: assignment.publication_branch,
                   head_commit: pushed.head_commit,
                   message: "Runner outcome: published (draft pull request #{opened.url}).")
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
        log("  Branch:       #{assignment.publication_branch}")
        log("  Pull request: #{opened.url}")
        log("Fix what Platform refused; the next attempt on this run reuses both.")
        Result.new(outcome: FAILED, pull_request_url: opened.url, branch: assignment.publication_branch,
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
        refusal = submit(failure_payload(failure_class, text, pushed))
        # Already a failure, so the outcome does not change — but the operator must not be left
        # believing Platform recorded a failure it in fact refused.
        log("Platform REFUSED this failure report: #{refusal}") if refusal
        Result.new(outcome: FAILED, branch: pushed ? assignment.publication_branch : nil,
                   head_commit: pushed&.head_commit,
                   message: "Runner outcome: publication_failed (#{failure_class}).")
      end

      # Platform cancelled the claim or the lease lapsed. NOTHING is reported: Platform already
      # owns the outcome, and a late success from a superseded attempt is what the liveness
      # signal exists to prevent. Anything already pushed stays on the remote — deleting a branch
      # because a lease expired would be a worse surprise than an unreferenced one.
      def aborted(error)
        reason = error.message.to_s.empty? ? "the lease is no longer live" : error.message
        log("")
        log("Stopping: Platform reports #{reason}. No publication result was submitted.")
        log("Anything already pushed is left in place and is NOT recorded as this run's result.")
        Result.new(outcome: ABORTED,
                   message: "Runner outcome: aborted (#{reason}); no publication result was reported.")
      end

      # ------------------------------------------------------------------- payloads

      def success_payload(verified, pushed, opened)
        base_payload(OUTCOME_PUBLISHED).merge(
          "repository_url" => assignment.publication_repository_url,
          "branch" => assignment.publication_branch,
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
          "branch" => pushed ? assignment.publication_branch : "",
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

      # Returns nil when Platform recorded the result, and the redacted refusal message when
      # Platform read it and REFUSED it. The two are not interchangeable: one leaves the local
      # outcome standing, the other invalidates it as something to report.
      def submit(publication)
        claim = publication["runner_execution_id"].to_s
        if claim.empty?
          log("(no claim identity in the assignment — nothing was reported to Platform)")
          return nil
        end

        response = client.submit_specification_publication(claim: claim, publication: publication)
        log("Platform recorded the result: run #{response['run_state']} (#{response['outcome']}).")
        nil
      rescue PlatformClient::Error => e
        text = Redaction.redact(e.message)
        return text if e.refused?

        # A TRANSPORT failure only. The remote outcome is already true — the branch and the pull
        # request exist or they do not. Failing to REACH Platform is a separate problem with its
        # own remedy, and it must not be reported as a publication failure, which would send the
        # operator to look at GitHub for something that is not wrong there.
        log("Could not report the result to Platform: #{text}")
        log("The outcome above still stands. Platform will reclaim this run when the lease expires.")
        nil
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
