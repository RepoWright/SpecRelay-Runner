# frozen_string_literal: true

module SpecrelayRunner
  # A claimed SPECIFICATION-CREATION assignment, recognized and reported — and
  # deliberately not executed (MVP-0025 scope 5).
  #
  # This is the runner's half of the MVP-0025 boundary. Platform can now hand a
  # specification run to a connected runner; nothing on this side can yet write a
  # specification. The honest behaviour for that gap is to prove the handoff crossed the
  # boundary, say so precisely, and stop — so this class recognizes the assignment, prints
  # what Platform sent, and returns. It is the whole of the runner's specification-lane
  # behaviour in this MVP.
  #
  # What it must never do, because MVP-0026/0027/0028 own them:
  #   - launch an executor, or read the assignment's executor configuration (Platform does
  #     not send one for this lane, and this class never asks for one);
  #   - create a worktree or write a file into any repository;
  #   - upload an execution report, publish a branch, or open a pull request;
  #   - write a Jira field or transition a Jira issue.
  # It performs NO file system write and NO Platform call at all — it only reads the
  # payload it was given and writes to the supplied IO. That is what makes those
  # guarantees structural rather than a promise: there is no client here to call.
  #
  # The claim it leaves behind is real and recoverable. Platform created a leased
  # RunnerExecution at claim time, and both existing recovery paths already work for this
  # lane: `bin/platform runner release <run-id>` abandons the claim immediately, and an
  # unrenewed lease is swept by Runner::ExpireLeases. Neither touches the run's state, so
  # the run returns to AWAITING_SPECIFICATION_CREATION and is claimable again. This class
  # prints the release command rather than assuming the operator knows it — the same
  # convention the pre-execution failure paths in Execution use.
  class SpecificationAssignment
    # The `run.type` value that selects this path. A closed-set comparison against the
    # payload's own discriminator, never an inference from which fields are missing.
    RUN_TYPE = "spec_creation"

    # The documented MVP-0025 outcome. It is NOT `RUN_FAILED`: nothing failed, and an exit
    # code meaning "a claimed execution did not complete successfully" would make a correct
    # assignment-only stop indistinguishable from a broken executor in any script or CI job
    # that reads it.
    OUTCOME = :assignment_received

    Result = Struct.new(:outcome, :message, keyword_init: true) do
      def success? = outcome == OUTCOME
    end

    # True when this payload is a specification assignment. Reads the discriminator
    # defensively (`dig` over `fetch`) because an OLDER Platform that predates MVP-0025
    # sends no `run.type` at all, and the correct reading of a missing discriminator is
    # "not a specification assignment" — the implementation path, which is what such a
    # Platform can only have sent.
    def self.specification?(payload) = payload.to_h.dig("run", "type") == RUN_TYPE

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(payload:, io: $stdout)
      @payload = payload.to_h
      @io = io
    end

    def call
      print_summary
      Result.new(outcome: OUTCOME,
                 message: "Runner outcome: assignment_received (specification run #{run_id}; " \
                          "generation is deferred to MVP-0026, nothing was executed).")
    end

    private

    attr_reader :payload, :io

    def print_summary
      log("Claimed a SPECIFICATION assignment — this runner does not write specifications yet.")
      log("  Run:              #{run_id} (#{section('run')['state']})")
      log("  Jira issue:       #{issue_line}")
      log("  Run type:         #{section('run')['type']}")
      log("  Input bundle:     #{bundle_line}")
      log("  Bundle artifact:  #{section('input_bundle')['url']}")
      log("  Specification to: #{target_line}")
      log("  Workspace:        #{workspace_line}")
      log("  Lease expires:    #{section('execution_policy')['lease_expires_at']}")
      log("  Platform run:     #{section('links')['run_url']}")
      log("")
      log("Stopping here, by design (MVP-0025): specification generation, branch/pull-request")
      log("publication, and Jira write-back are later capabilities. No worktree was created, no")
      log("file was written, no report was uploaded, and Jira was not touched.")
      log("")
      log("Platform still holds this claim. Release it so the run is claimable again:")
      log("  #{release_command}")
      log("An unreleased claim is also swept automatically once its lease expires.")
    end

    def run_id = section("run")["id"]

    def issue_line
      item = section("work_item")
      key = item["issue_key"].to_s
      title = item["title"].to_s
      title.empty? ? key : "#{key} — #{title}"
    end

    # States completeness as a word rather than printing a raw boolean, and counts the
    # blocking inputs when there are any. Platform only offers a complete bundle in this
    # MVP, so a printed "incomplete" here would be a signal worth acting on, not noise.
    def bundle_line
      bundle = section("input_bundle")
      return "complete" if bundle["complete"] == true

      blocking = Array(bundle["blocking_inputs"]).length
      "INCOMPLETE (#{blocking} blocking #{blocking == 1 ? 'input' : 'inputs'})"
    end

    def target_line
      target = section("specification_target")
      url = target["repository_url"].to_s
      return "not specified" if url.empty?

      root = target["specification_root"].to_s
      branch = target["default_branch"].to_s
      line = root.empty? ? url : "#{url} (#{root})"
      branch.empty? ? line : "#{line} on #{branch}"
    end

    def workspace_line
      workspace = section("workspace")
      key = workspace["workspace_key"].to_s
      name = workspace["display_name"].to_s
      name.empty? ? key : "#{name} (#{key})"
    end

    # Prefer the command Platform sent, so the runner never invents an identifier — the
    # same rule the implementation lane follows for branch names. Falls back to composing
    # it from the run id when an older Platform sent no boundary block. Written in plain
    # Ruby: this repository is Rails-free, so there is no `presence` here.
    def release_command
      configured = section("assignment_boundary")["release_command"].to_s
      configured.strip.empty? ? "bin/platform runner release #{run_id}" : configured
    end

    def section(name) = payload[name].to_h

    def log(line) = io.puts(Redaction.redact(line.to_s))
  end
end
