# frozen_string_literal: true

require "json"

module SpecrelayRunner
  module Specification
    # The SANITIZED input packet handed to a generation provider (MVP-0026 scope 9).
    #
    # Every provider — the deterministic built-in one and any external command an operator
    # configures — receives exactly this and nothing else. That is what makes the provider
    # boundary reviewable: there is one place to read to know what leaves this process, and
    # a test can assert its contents without running a model.
    #
    # What it carries: the issue identity, the rendered input bundle, this runner's verdict
    # on each input, the source files it actually inspected, and the structural/semantic
    # tool evidence.
    #
    # What it deliberately does not carry, per criterion 11:
    #   - any credential, and any URL userinfo (every string goes through Redaction);
    #   - absolute host filesystem paths — the source root is reduced to its basename and
    #     every file is repository-relative, so an external provider learns nothing about
    #     the operator's home directory;
    #   - raw Jira provider payloads or attachment bytes, neither of which the assignment
    #     contains in the first place;
    #   - the Platform credential, the runner's environment, or anything from `ENV`.
    #
    # It is a value object with no I/O. Rendering it as JSON is the only thing it does.
    class Packet
      def self.build(**kwargs) = new(**kwargs).build

      # +revision+ is nil for a first specification, or a {PreviousSpecificationPackage::Result}
      # when this generation is a same-ticket REVISION (MVP-0028 decision D6).
      def initialize(assignment:, source:, inputs:, package_path:, revision: nil)
        @assignment = assignment
        @source = source
        @inputs = inputs
        @package_path = package_path
        @revision = revision
      end

      def build
        {
          "contract_version" => Specification::PACKET_CONTRACT_VERSION,
          "issue" => issue_block,
          "package" => package_block,
          "input_bundle" => bundle_block,
          "source" => source_block,
          "tool_evidence" => tool_evidence_block,
          "revision" => revision_block
        }
      end

      private

      attr_reader :assignment, :source, :inputs, :package_path, :revision

      def issue_block
        {
          "key" => assignment.issue_key,
          "title" => clean(assignment.issue_title),
          "url" => clean(assignment.issue_url),
          "run_url" => clean(assignment.run_url),
          "workspace" => clean(assignment.workspace_display_name.empty? ?
                                 assignment.workspace_key : assignment.workspace_display_name)
        }
      end

      # Repository-relative only. The provider is told where the package will go so it can
      # write correct cross-references between the three documents, and it is told nothing
      # about where that is on this disk.
      def package_block
        {
          "relative_path" => package_path.relative_package_path,
          "spec" => PackagePath::SPEC_MD,
          "business_analysis" => PackagePath::BUSINESS_MD,
          "technical_analysis" => PackagePath::TECHNICAL_MD
        }
      end

      def bundle_block
        {
          "url" => clean(assignment.bundle_url),
          "trace_id" => clean(assignment.bundle_trace_id),
          "content_markdown" => clean(assignment.bundle_markdown),
          "inputs" => inputs.inputs.map { |input| input_entry(input) },
          "warnings" => inputs.warnings.map { |warning| clean(warning) }
        }
      end

      def input_entry(input)
        {
          "kind" => clean(input.kind), "name" => clean(input.name),
          "read_status" => clean(input.read_status), "used" => input.readable?,
          "note" => clean(input.note.to_s), "reference" => clean(input.reference.to_s),
          # MVP-0028 remediation, defect 2 (F2 correction): Platform's own classification reason —
          # e.g. "3 readable" for the linked-issues collection — was already read into
          # `input.reason` and already allowlisted for the assignment (SpecCreationPayload::
          # INPUT_FIELDS), but never left this process. Without it, a provider cannot tell "Jira
          # exposed zero linked issues" from "Jira exposed some, but not their content" — the
          # distinction {Composer} needs to report a linked issue honestly instead of either
          # inventing analysis or manufacturing a limitation nobody asked about.
          "reason" => clean(input.reason.to_s)
        }
      end

      # `repository` is the checkout's DIRECTORY NAME, not its path. A provider needs to
      # name the codebase in prose; it does not need to know it lives under /Users/someone.
      def source_block
        {
          "repository" => clean(source.repository_name),
          "entry_points" => source.entry_point_paths.map { |path| clean(path) },
          "fallbacks" => source.fallbacks.map { |note| clean(note) }
        }
      end

      def tool_evidence_block
        [ source.graphify, source.context_plus ].map do |tool|
          { "name" => tool.name, "usable" => tool.usable?, "contributed" => tool.contributed?,
            "summary" => clean(tool.summary), "detail" => clean(tool.detail.to_s) }
        end
      end

      # nil for a first specification. For a same-ticket REVISION (MVP-0028 decision D6), the
      # previous package's own files — read off its pull request's branch, never from provider
      # payloads or Platform's digest record — so the provider can revise from the real prior
      # text instead of writing one with no memory of it.
      def revision_block
        return nil if revision.nil?

        { "previous_files" => revision.files.transform_values { |content| clean(content) } }
      end

      # Every string in the packet passes through here. Applying redaction at the boundary
      # rather than at each call site is what makes "no secret leaves this process" a
      # property of the class instead of a property of remembering.
      def clean(value) = Redaction.redact(value.to_s)
    end
  end
end
