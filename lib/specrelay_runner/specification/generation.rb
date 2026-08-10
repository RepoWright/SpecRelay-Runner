# frozen_string_literal: true

require "time"

module SpecrelayRunner
  module Specification
    # Orchestrates ONE claimed specification-creation assignment end to end (MVP-0026).
    #
    # The specification lane's counterpart to {Execution}, and deliberately a sibling rather
    # than a mode of it: the two share a claim identity, a lease, and an API client, and
    # nothing else. This one creates no worktree, launches no executor, runs no project test
    # command, uploads no execution report, publishes no branch, and touches no Jira field.
    # Those absences are structural — there is no code here that could do them.
    #
    # The order is the contract:
    #
    #   preflight -> (refuse and stop) | gather -> generate -> validate -> write -> report
    #
    # Preflight runs FIRST and writes nothing, so criterion 6's "proof that zero output files
    # were written" is a property of the control flow rather than of a cleanup routine. Every
    # path after it either produces a complete package or leaves the destination untouched,
    # because PackageWriter stages and then performs a single rename.
    #
    # A claim is real work, so the lease is real too: a heartbeater runs for the duration, and
    # the liveness signal is checked before the write and again before the report. A run
    # Platform has cancelled or reclaimed must never be reported as generated — the files may
    # already be on the operator's disk, but claiming the run produced them would let a
    # superseded attempt overwrite a newer one's result.
    class Generation
      # Raised internally when Platform signals the claim is no longer live. Handled here;
      # never escapes.
      Aborted = Class.new(StandardError)

      CONTRACT_VERSION = "mvp-0026"
      DEFAULT_RENEWAL_SECONDS = 30

      GENERATED = :generated
      REFUSED = :generation_refused
      FAILED = :generation_failed
      ABORTED = :aborted

      Result = Struct.new(:outcome, :message, :package_path, :files, keyword_init: true) do
        def success? = outcome == GENERATED
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
        @lease_stop_reason = nil
      end

      def call
        assignment = Assignment.parse(payload)
        @assignment = assignment
        announce(assignment)
        ready = Preflight.call(assignment: assignment, settings: settings, config: config, env: env)
        return refuse(ready) if ready.refused?

        generate(assignment, ready)
      rescue Assignment::Malformed => e
        # A malformed assignment cannot be reported against a claim identity the runner could
        # not parse, so this is the one refusal that may have nowhere to send itself. It is
        # still reported when the claim token survived parsing, and always printed.
        refuse(Preflight::Refusal.new(failure_class: Preflight::ASSIGNMENT_MALFORMED, message: e.message))
      end

      private

      attr_reader :config, :client, :payload, :env, :io, :clock, :assignment

      def settings = @settings ||= @injected_settings || Settings.from(config, env: env)

      def announce(assignment)
        log("Claimed a SPECIFICATION assignment for #{assignment.issue_key} (run #{assignment.run_id}).")
        log("  Jira issue:       #{assignment.issue_key} — #{assignment.issue_title}")
        log("  Specification to: #{assignment.repository_url} (#{assignment.specification_root})")
        log("  Source workspace: #{assignment.workspace_key}")
        log("  Platform run:     #{assignment.run_url}")
      end

      # The generating half. Everything before `write_package` is reversible by doing nothing;
      # `write_package` writes into the Runner-owned isolated worktree preflight created, and
      # nothing in this method can reach the operator's checkout at all.
      def generate(assignment, ready)
        start_heartbeater(assignment)
        log("Preflight passed. Generating with #{ready.provider.describe}.")
        documents = produce(ready)
        checkpoint!
        written = write_package(assignment, ready, documents)
        checkpoint!
        report_success(assignment, ready, written, documents)
      rescue Aborted => e
        aborted(e)
      rescue Provider::Failed, DocumentSet::Invalid, PackageWriter::Error, PackagePath::Unsafe,
             PackageWorkspace::Error => e
        fail_generation(ready, e)
      ensure
        @heartbeater&.stop
      end

      # Build the packet, call the provider, and validate what comes back — all before any
      # file exists. Validation ahead of the write is what makes "missing required sections
      # are rejected" a guarantee about the destination rather than about a file that has to
      # be deleted afterwards.
      def produce(ready)
        packet = Packet.build(assignment: assignment, source: ready.source, inputs: ready.inputs,
                              package_path: ready.package_path, revision: ready.revision)
        DocumentSet.validate!(ready.provider.generate(packet), issue_key: assignment.issue_key)
      end

      # The write, and the promotion of the workspace to `ready` in the same step. The digests
      # are recorded in the workspace's own metadata as well as reported to Platform, because
      # publication proves the files against BOTH: Platform's copy says what this run is
      # authorized to publish, and the local copy says what this workspace was created to hold.
      def write_package(assignment, ready, documents)
        written = PackageWriter.call(package_path: ready.package_path,
                                     destination_root: ready.workspace.worktree_root,
                                     documents: documents, assignment: assignment,
                                     provider: ready.provider, source: ready.source,
                                     inputs: ready.inputs, clock: clock)
        ready.workspace.finalize!(files: written.files)
        written
      end

      # ------------------------------------------------------------------ outcomes

      def report_success(assignment, ready, written, documents)
        submit(success_payload(assignment, ready, written, documents))
        print_success(written)
        Result.new(outcome: GENERATED, package_path: written.relative_package_path,
                   files: written.file_paths,
                   message: "Runner outcome: generated (#{written.file_paths.length} files at " \
                            "#{written.relative_package_path}; nothing was committed, pushed, or sent to Jira).")
      end

      def print_success(written)
        log("")
        log("Generated #{written.file_paths.length} files at #{written.relative_package_path}:")
        written.files.each { |file| log("  #{file.path}  sha256:#{file.sha256[0, 16]}…  #{file.bytes} bytes") }
        written.warnings.each { |warning| log("  warning: #{warning}") }
        log("")
        log("The package is held in this runner's own isolated worktree, not in your specification")
        log("checkout, which is unchanged. Nothing was published: no branch, no commit, no push, no")
        log("pull request, no Jira field write, and no approval transition.")
      end

      # A preflight refusal. Reported to Platform so the run leaves the claimable state and
      # an operator sees WHY on the run page, then printed with the remedy. The zero-write
      # claim is asserted here because it is true by construction — nothing between the claim
      # and this line opens a file for writing.
      def refuse(refusal)
        log("")
        log("Refusing to generate a specification: #{refusal.message}")
        log("No output file was created, no local workspace was made, and Jira was not touched.")
        log("Fix the cause above and re-run, or release the claim so another runner can take it:")
        log("  #{release_command}")
        submit(refusal_payload(refusal, outcome: "refused", zero_files: true))
        Result.new(outcome: REFUSED,
                   message: "Runner outcome: generation_refused (#{refusal.failure_class}); " \
                            "no output file was written.")
      end

      # A failure AFTER preflight passed. The distinction from a refusal is real and is
      # carried through to Platform: a refusal means a precondition was missing, a failure
      # means generation was attempted and did not produce a usable package.
      #
      # Whether the package landed is ASKED, not asserted: only PackageWriter knows which side
      # of its single rename a failure fell on, and an operator deciding whether the retained
      # workspace is worth inspecting needs the answer.
      #
      # The workspace is RETAINED either way (design 4). A partial or absent package in a
      # Runner-owned directory is inspectable state with a seven-day life, not litter in
      # someone's checkout, so there is nothing here to clean up and no reason to.
      def fail_generation(ready, error)
        message = Redaction.redact(error.message.to_s)
        wrote = wrote_package?(error)
        log("")
        log("Specification generation failed: #{message}")
        log(wrote ? "A complete package for #{error.package_path} IS held in this runner's isolated " \
                    "worktree and was not removed." :
                    "No package was completed. Your specification checkout is unchanged either way.")
        log("The workspace is retained for #{PackageWorkspaceStore::RETENTION_DAYS} days so it can be inspected.")
        log("Re-run after fixing the cause, or release the claim:")
        log("  #{assignment.release_command}")
        refusal = Preflight::Refusal.new(failure_class: failure_class_for(error),
                                         message: failure_message(error, message, wrote))
        submit(refusal_payload(refusal, outcome: "failed", zero_files: !wrote, workspace: ready&.workspace))
        Result.new(outcome: FAILED, message: "Runner outcome: generation_failed (#{failure_class_for(error)}).")
      end

      def wrote_package?(error) = error.is_a?(PackageWriter::Error) && error.wrote_package?

      # When a package IS on disk, the message names its repository-relative path — never the
      # local one. The failure class sends an operator to the runner's configuration; the path
      # tells them what the retained workspace holds.
      def failure_message(error, message, wrote)
        return message unless wrote

        "#{message}. A complete package for #{error.package_path} is retained in this runner's " \
          "isolated worktree and was not removed."
      end

      # Stable failure classes for the post-preflight failures, distinct from the preflight
      # vocabulary so the run page can tell an operator whether to fix configuration or to
      # look at the provider's output.
      PROVIDER_FAILED = "generation_provider_failed"
      OUTPUT_INVALID = "generated_output_invalid"
      WRITE_FAILED = "package_write_failed"

      def failure_class_for(error)
        case error
        when Provider::Failed then PROVIDER_FAILED
        when DocumentSet::Invalid then OUTPUT_INVALID
        else WRITE_FAILED
        end
      end

      # Platform cancelled the claim or the lease lapsed. NOTHING is reported: Platform
      # already owns the outcome, and a late success from a superseded attempt is exactly
      # what the liveness signal exists to prevent. Any package already written stays on
      # disk — deleting an operator's files because a lease expired would be a worse
      # surprise than leaving an unreferenced draft.
      def aborted(error)
        reason = error.message.to_s.empty? ? "the lease is no longer live" : error.message
        log("")
        log("Stopping: Platform reports #{reason}. No generation result was submitted.")
        log("Platform owns the outcome — an expired lease is reclaimed, a cancelled run is terminal.")
        log("Any isolated workspace already created is retained and is NOT recorded as this run's result.")
        Result.new(outcome: ABORTED,
                   message: "Runner outcome: aborted (#{reason}); no generation result was reported.")
      end

      # ------------------------------------------------------------------- payloads

      def success_payload(assignment, ready, written, documents)
        base_payload(assignment, "generated").merge(
          "package" => {
            "path" => written.relative_package_path,
            "files" => written.files.map(&:to_h),
            "manifest" => written.manifest
          },
          "package_workspace" => workspace_block(ready.workspace),
          "tool_evidence" => tool_evidence(ready),
          # Source-inspection warnings travel with the rest. A zero-file inspection is the one
          # this exists for: it is the difference between a specification grounded in code and
          # one grounded in a ticket, and Platform has to be able to show it.
          "warnings" => (ready.inputs.warnings + ready.source.warnings + written.warnings)
            .map { |text| Redaction.redact(text) },
          "open_questions" => documents.open_questions.map { |text| Redaction.redact(text) }
        )
      end

      def refusal_payload(refusal, outcome:, zero_files:, workspace: nil)
        base = base_payload(assignment, outcome).merge(
          "failure_class" => refusal.failure_class,
          "message" => refusal.message,
          "zero_output_files_written" => zero_files,
          "diagnostics" => diagnostics
        )
        workspace ? base.merge("package_workspace" => workspace_block(workspace)) : base
      end

      # The ONLY thing about a local workspace that reaches Platform: an opaque id and when it
      # expires. No path, no machine name, no seed, no directory listing. Platform stores the id
      # beside the registered runner that reported it and hands it back at publication; that
      # pair is the whole ownership contract (design 2).
      #
      # It travels on a FAILURE too, and deliberately. A failed generation still retains a
      # workspace, and the run page has to be able to say which machine holds it and until when
      # — otherwise "inspect the retained package" is advice with no address.
      def workspace_block(workspace)
        { "id" => workspace.id, "expires_at" => workspace.expires_at&.iso8601.to_s,
          "retention_days" => PackageWorkspaceStore::RETENTION_DAYS }
      end

      # Read from the RAW payload, not from the parsed assignment.
      #
      # The claim identity is the one thing a refusal must carry even when validation failed,
      # and an assignment that fails validation has no parsed object to read it from. Taking
      # it from the payload means a malformed assignment is still reported against the claim
      # it was handed — which is what criterion 6 asks for, and what stops such a run from
      # sitting claimed until its lease expires with no recorded reason.
      #
      # These two fields are read defensively for the same reason the discriminator is: they
      # are the only ones the runner needs before it can trust anything else.
      def base_payload(_assignment, outcome)
        {
          "contract_version" => CONTRACT_VERSION,
          "outcome" => outcome,
          "run_id" => payload.dig("run", "id").to_s,
          "runner_execution_id" => claim_token,
          "generated_at" => clock.now.utc.iso8601,
          "runner_version" => VERSION
        }
      end

      def claim_token = payload.dig("claim", "runner_execution_id").to_s

      def tool_evidence(ready)
        [ ready.source.graphify, ready.source.context_plus ].map do |tool|
          { "name" => tool.name, "usable" => tool.usable?, "contributed" => tool.contributed?,
            "summary" => Redaction.redact(tool.summary.to_s) }
        end
      end

      # Sanitized, bounded, and non-secret by construction: the provider KIND (never its
      # command line, which is a local path), and what the operator CONFIGURED. Enough to see
      # which switch to flip, with nothing that describes this machine.
      #
      # Each capability line reports its SUBSTITUTE, not its availability. That is a
      # deliberate correction: the configured availability of Graphify is a default this
      # runner then probes and can override, so printing "graphify: available" next to a
      # `graphify_unavailable` refusal read as a contradiction on the run page. What an
      # operator staring at that refusal actually needs to know is whether a substitute was
      # recorded — because that is the switch that changes the outcome.
      def diagnostics
        [
          "provider: #{settings.provider_kind}",
          "package workspace retention: #{PackageWorkspaceStore::RETENTION_DAYS} days, " \
          "at most #{PackageWorkspaceStore::MAX_RETAINED} retained",
          *capability_diagnostics
        ]
      end

      def capability_diagnostics
        [ settings.graphify, settings.context_plus, settings.external_references ].map do |capability|
          substitute = capability.substitute.to_s
          "#{capability.name} substitute: #{substitute.empty? ? 'none recorded' : substitute}"
        end
      end

      # A refusal for an assignment whose claim token never parsed has nothing to address a
      # report to. It is printed and returned rather than dropped silently; Platform recovers
      # such a claim through the lease sweep, which is the same path a crashed runner takes.
      def submit(generation)
        claim = generation["runner_execution_id"].to_s
        return log("(no claim identity in the assignment — nothing was reported to Platform)") if claim.empty?

        response = client.submit_specification_generation(claim: claim, generation: generation)
        log("Platform recorded the result: run #{response['run_state']} (#{response['outcome']}).")
      rescue PlatformClient::Error => e
        # The local outcome is already true — the package exists or it does not. Failing to
        # REPORT it is a separate problem with its own remedy, and it must not be reported as
        # a generation failure, which would tell the operator to look at the provider.
        log("Could not report the result to Platform: #{Redaction.redact(e.message)}")
        log("The local outcome above still stands. Platform will reclaim this run when the lease expires.")
      end

      # ------------------------------------------------------------------- lifecycle

      def start_heartbeater(assignment)
        @heartbeater = Heartbeater.new(
          client: client, claim: assignment.runner_execution_id, interval_seconds: renewal_seconds(assignment),
          io: io, stop_after_seconds: stop_heartbeat_after
        ).start
      end

      def renewal_seconds(assignment)
        seconds = assignment.lease_renewal_seconds
        seconds.positive? ? seconds : DEFAULT_RENEWAL_SECONDS
      end

      # The same deterministic control the implementation lane uses to prove lease expiry
      # without waiting out a production-shaped lease.
      def stop_heartbeat_after
        value = env[Execution::STOP_HEARTBEAT_ENV].to_i
        value.positive? ? value : nil
      end

      # A phase boundary: renew the lease, READ the liveness signal that comes back, and stop
      # if Platform no longer considers this claim live.
      #
      # The implementation lane gets this for free — it emits an ordered protocol event at
      # every phase and heartbeats alongside each one, so a cancellation lands within a
      # phase. This lane emits no events, so without an explicit beat here the only observer
      # would be the background heartbeater, and a generation that finishes inside one
      # renewal interval (the normal case — composing three documents takes milliseconds)
      # would never look at the signal at all. It would then report success for a run an
      # operator had already cancelled, which is exactly what criterion 10 forbids.
      #
      # A heartbeat that fails in transport is NOT treated as a stop: an unreachable Platform
      # is a reporting problem, and killing a generation over one would turn a network blip
      # into a lost package. The lease expiring is Platform's own remedy for that case.
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

      # Usable even for a payload that failed validation, for the same reason the claim token
      # is: an operator reading a refusal needs the recovery command most when the assignment
      # was the thing that was wrong.
      def release_command
        return assignment.release_command if assignment

        run_id = payload.dig("run", "id").to_s
        run_id.empty? ? "bin/platform runner release <run-id>" : "bin/platform runner release #{run_id}"
      end

      def log(message)
        io.puts(Redaction.redact(message.to_s))
        io.flush if io.respond_to?(:flush)
      end
    end
  end
end
