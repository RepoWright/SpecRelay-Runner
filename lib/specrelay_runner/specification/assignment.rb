# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # A parsed, validated READ of the specification-creation assignment payload Platform
    # builds in Runner::Api::SpecCreationPayload (MVP-0025 scope 3).
    #
    # It exists so that every later stage — preflight, evidence gathering, the generation
    # packet, the writer, the result — reads ONE checked object rather than digging into a
    # nested Hash with `dig` and discovering a missing field halfway through a write. That
    # ordering is the whole point of MVP-0026 criterion 5: a malformed assignment must be a
    # refusal BEFORE any output file exists, and it can only be that if the validation
    # happens here, at parse time, rather than at the first place a field is needed.
    #
    # It is a pure value object. It performs no I/O, makes no Platform call, and reads
    # nothing outside the payload it was handed.
    class Assignment
      # Raised when the payload is not a usable specification assignment. Carries the
      # operator-facing reason; Preflight turns it into the `assignment_malformed`
      # refusal class rather than letting it escape as a crash.
      Malformed = Class.new(StandardError)

      RUN_TYPE = "spec_creation"

      # The fields an assignment MUST carry for generation to be possible at all. Each is
      # a path into the payload plus the operator-facing name used in the refusal message.
      # A table rather than ten guard clauses: the list is the contract, and a reader
      # checking "what does the runner require?" should find one place that answers it.
      REQUIRED = [
        [ %w[run id], "run.id" ],
        [ %w[claim runner_execution_id], "claim.runner_execution_id" ],
        [ %w[work_item issue_key], "work_item.issue_key" ],
        [ %w[input_bundle content_markdown], "input_bundle.content_markdown" ],
        [ %w[specification_target repository_url], "specification_target.repository_url" ],
        [ %w[specification_target specification_root], "specification_target.specification_root" ],
        [ %w[workspace workspace_key], "workspace.workspace_key" ]
      ].freeze

      # True when this payload is a specification assignment. Reads the discriminator
      # defensively, because an OLDER Platform that predates MVP-0025 sends no `run.type`
      # at all and the correct reading of a missing discriminator is "not a specification
      # assignment" — the implementation path, which is all such a Platform can send.
      def self.specification?(payload) = payload.to_h.dig("run", "type") == RUN_TYPE

      # Parse and validate, or raise Malformed. Deliberately raising rather than returning
      # a nullable: there is no partially usable assignment, and a caller that forgot to
      # check a nil would proceed into evidence gathering with no issue key.
      def self.parse(payload) = new(payload).tap(&:validate!)

      def initialize(payload)
        @payload = payload.to_h
      end

      def validate!
        unless self.class.specification?(payload)
          raise Malformed, "assignment is not a specification-creation run (run.type=#{payload.dig('run', 'type').inspect})"
        end

        missing = REQUIRED.reject { |path, _| present?(payload.dig(*path)) }.map(&:last)
        raise Malformed, "assignment is missing required generation data: #{missing.join(', ')}" if missing.any?

        validate_bundle_complete!
        self
      end

      # An INCOMPLETE bundle is refused here rather than generated from with warnings.
      # Platform already refuses to make such a run claimable (Run#spec_creation_bundle_assignable?),
      # so a runner seeing one has been handed an assignment its own Platform says is not
      # assignable — which is a contract violation, not a degraded input. Writing a
      # specification from inputs the product classified as blocking is exactly the
      # "smoothing it over" that scope 4 forbids.
      def validate_bundle_complete!
        return if section("input_bundle")["complete"] == true

        blocking = Array(section("input_bundle")["blocking_inputs"]).length
        raise Malformed, "the input bundle is not complete (#{blocking} blocking " \
                         "#{blocking == 1 ? 'input' : 'inputs'}); a specification must not be written from it"
      end

      def run_id = section("run")["id"].to_s
      def run_state = section("run")["state"].to_s
      def runner_execution_id = section("claim")["runner_execution_id"].to_s
      def runner_display_name = section("claim")["runner_display_name"].to_s
      def issue_key = section("work_item")["issue_key"].to_s
      def issue_url = section("work_item")["issue_url"].to_s
      def issue_title = section("work_item")["title"].to_s
      def workspace_key = section("workspace")["workspace_key"].to_s
      def workspace_display_name = section("workspace")["display_name"].to_s
      def run_url = section("links")["run_url"].to_s
      def bundle_markdown = section("input_bundle")["content_markdown"].to_s
      def bundle_url = section("input_bundle")["url"].to_s
      def bundle_trace_id = section("input_bundle")["trace_id"].to_s
      def repository_url = target["repository_url"].to_s
      def specification_root = target["specification_root"].to_s
      def default_branch = target["default_branch"].to_s
      def target_owner = target["owner"].to_s
      def target_repository = target["repository"].to_s

      # Every input the bundle recorded, as plain hashes with string keys. The runner reads
      # them but never trusts them as file paths or commands — they are evidence metadata.
      def inputs = Array(section("input_bundle")["inputs"]).map { |entry| entry.to_h }

      # `owner/repository` when Platform parsed them, else nil. Used as the lookup key for
      # the operator's local specification-repository checkout, so a runner connected to
      # two specification repositories can map each one.
      def target_slug
        return nil if target_owner.empty? || target_repository.empty?

        "#{target_owner}/#{target_repository}"
      end

      # How long this claim is good for, as Platform stated it. The generation loop checks
      # it so a long provider call cannot report success against a dead lease.
      def lease_expires_at = section("execution_policy")["lease_expires_at"].to_s
      def lease_renewal_seconds = section("execution_policy")["lease_renewal_seconds"].to_i

      # ------------------------------------------------------------------ MVP-0027

      # What this claim authorizes, read from the field Platform writes for exactly that
      # purpose. The runner branches on THIS rather than on `run.state`, so "what am I allowed
      # to do?" has one answer written by the control plane — and a runner build that does not
      # recognise the token stops instead of guessing.
      PUBLISH_ACTION = "publish_specification_package"
      GENERATE_ACTION = "generate_specification_package"

      def expected_runner_action = section("assignment_boundary")["expected_runner_action"].to_s
      def publication? = expected_runner_action == PUBLISH_ACTION

      # Generation is the DEFAULT for an empty action as well as for the explicit token: a
      # Platform old enough not to send the field at all can only be asking for generation, and
      # refusing it would break a runner against a Platform it used to work with. An action that
      # is present but unrecognised is a different case entirely — that is a newer Platform
      # asking for something this build does not implement, and guessing would be worse than
      # stopping.
      def generation? = expected_runner_action.empty? || expected_runner_action == GENERATE_ACTION

      # The publication decisions Platform made. The runner executes them; it never invents a
      # branch name, never chooses a base, and never decides whether a pull request is a draft.
      def publication_branch = publication["branch"].to_s
      def publication_base_branch = publication["base_branch"].to_s
      def publication_repository_url = publication["repository_url"].to_s
      def publication_slug = publication["slug"].to_s
      def create_pull_request? = publication["create_pull_request"] == true
      def draft_pull_request? = publication["pull_request_draft"] == true

      # The package Platform RECORDED at generation, with a digest per file. This is the
      # evidence the runner verifies its local checkout against before it is allowed to touch
      # git — the whole point of publishing from Platform's record rather than from whatever
      # happens to be on the disk now.
      def generated_package_path = generated_package["path"].to_s

      def generated_files
        Array(generated_package["files"]).map do |file|
          entry = file.to_h
          { "path" => entry["path"].to_s, "sha256" => entry["sha256"].to_s }
        end
      end

      # Everything a publication needs, validated as a set BEFORE any git command runs. A
      # publication assignment missing one of these is a contract violation, and discovering it
      # halfway through — after a branch exists on a shared repository — is exactly what this
      # ordering prevents.
      PUBLICATION_REQUIRED = [
        [ %w[publication repository_url], "publication.repository_url" ],
        [ %w[publication branch], "publication.branch" ],
        [ %w[publication base_branch], "publication.base_branch" ],
        [ %w[generated_package path], "generated_package.path" ]
      ].freeze

      SHA256 = /\A[0-9a-f]{64}\z/

      def validate_publication!
        missing = PUBLICATION_REQUIRED.reject { |path, _| present?(payload.dig(*path)) }.map(&:last)
        raise Malformed, "publication assignment is missing required data: #{missing.join(', ')}" if missing.any?

        files = generated_files
        raise Malformed, "publication assignment names no generated file to publish" if files.empty?

        undigested = files.reject { |file| SHA256.match?(file["sha256"]) }.map { |file| file["path"] }
        raise Malformed, "publication assignment carries no usable digest for: #{undigested.join(', ')}" if
          undigested.any?

        self
      end

      # Prefer the command Platform sent, so the runner never invents an identifier — the
      # same rule the implementation lane follows for branch names.
      def release_command
        configured = section("assignment_boundary")["release_command"].to_s
        configured.strip.empty? ? "bin/platform runner release #{run_id}" : configured
      end

      private

      attr_reader :payload

      def target = section("specification_target")
      def publication = section("publication")
      def generated_package = section("generated_package")
      def section(name) = payload[name].to_h
      def present?(value) = !value.to_s.strip.empty?
    end
  end
end
