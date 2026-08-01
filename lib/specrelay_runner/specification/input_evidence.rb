# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # What the assignment's input bundle actually offers, and which of it this runner can
    # genuinely read (MVP-0026 scope 6).
    #
    # Platform classified every input at intake and recorded a read status per entry. This
    # class re-reads that record from the RUNNER's side and answers a different question:
    # not "was it readable when Jira was polled?" but "can this machine, right now, analyse
    # it?". The two differ for exactly the inputs that matter — a Confluence page or a
    # screenshot Platform deliberately deferred to the runner's MCP is `deferred_to_runner_mcp`
    # in the bundle and is available here only if this runner has that capability.
    #
    # The scope 6 rule this implements: "If the bundle claims an input is required and
    # available, but the runner cannot actually read/analyze it, preflight must refuse before
    # writing files." So a deferred reference with no capability and no recorded substitute
    # becomes a BLOCKER, not a warning — and blockers are what Preflight refuses on, before
    # any output file exists.
    #
    # It reads no network and opens no attachment. Platform never downloads attachment bytes
    # and neither does this: the bundle carries references and a rendered Markdown body, and
    # that body is the sanctioned content. Criterion 11 forbids attachment bytes in output,
    # so there is nowhere for them to legitimately go.
    class InputEvidence
      AVAILABLE = "available"
      DEFERRED_TO_RUNNER_MCP = "deferred_to_runner_mcp"
      # Everything Platform can classify. Anything outside this set is treated as blocking,
      # for the same fail-closed reason Jira::SpecCreation::ReadStatus.blocking? is written
      # as "not in the non-blocking set": a status this runner cannot place must never be
      # presented as usable evidence.
      NON_BLOCKING = [ AVAILABLE, DEFERRED_TO_RUNNER_MCP ].freeze

      IMAGE_KINDS = %w[screenshot image].freeze

      # One input, as this runner sees it. `readable?` is the runner's verdict; `read_status`
      # is Platform's, kept alongside it so the generated analysis can state both when they
      # disagree rather than silently preferring one.
      Input = Struct.new(:kind, :name, :read_status, :reason, :reference, :media_type,
                         :readable, :note, keyword_init: true) do
        def readable? = readable ? true : false
        def image? = IMAGE_KINDS.include?(kind.to_s) || media_type.to_s.start_with?("image/")
      end

      Result = Struct.new(:inputs, :blockers, :warnings, :summary_markdown, keyword_init: true) do
        def blocked? = blockers.any?
        def readable_inputs = inputs.select(&:readable?)
      end

      def self.gather(**kwargs) = new(**kwargs).gather

      def initialize(assignment:, settings:)
        @assignment = assignment
        @settings = settings
      end

      def gather
        inputs = assignment.inputs.map { |entry| classify(entry.to_h) }
        Result.new(inputs: inputs, blockers: blockers_for(inputs), warnings: warnings_for(inputs),
                   summary_markdown: summary_markdown(inputs))
      end

      private

      attr_reader :assignment, :settings

      def classify(entry)
        status = entry["read_status"].to_s
        input = Input.new(
          kind: entry["kind"].to_s, name: entry["name"].to_s, read_status: status,
          reason: entry["reason"].to_s, reference: safe_reference(entry["reference"]),
          media_type: entry["media_type"].to_s, readable: false, note: nil
        )
        apply_verdict(input, status)
      end

      # The verdict, in the order the statuses actually differ:
      #
      #   available              — Platform read it, and its content is inside the rendered
      #                            bundle body this runner already holds. Readable, no
      #                            capability required.
      #   deferred_to_runner_mcp — Platform deliberately did NOT read it and expects the
      #                            runner to. Readable only with the external-reference (or,
      #                            for an image, the image-analysis) capability.
      #   anything else          — blocking. Platform would not have made the run claimable
      #                            with one of these present, so encountering one means the
      #                            bundle disagrees with itself.
      def apply_verdict(input, status)
        case status
        when AVAILABLE
          input.readable = true
          input.note = "read from the rendered input bundle"
        when DEFERRED_TO_RUNNER_MCP
          apply_deferred_verdict(input)
        else
          input.readable = false
          input.note = "Platform classified this input as #{status.inspect}, which is not usable evidence"
        end
        input
      end

      # An image and a Confluence page are deferred for different reasons and need different
      # capabilities, but the operator declares one `external_references` capability for
      # both. That is deliberate: they are the same MCP surface in practice, and splitting
      # the switch would let a runner claim it analysed a screenshot because it could reach
      # Confluence.
      def apply_deferred_verdict(input)
        capability = settings.external_references
        analysis = input.image? ? "image analysis" : "external-reference fetching"
        if capability.available?
          input.readable = true
          input.note = "#{analysis} is available on this runner"
        elsif capability.substitute?
          input.readable = false
          input.note = "#{analysis} is unavailable — approved substitute: #{capability.substitute}"
        else
          input.readable = false
          input.note = "#{analysis} is unavailable on this runner and no substitute was recorded"
        end
      end

      # A blocker is an input the bundle offers as usable that this runner cannot actually
      # use, with no recorded substitute. Note what is NOT a blocker: a deferred input the
      # operator explicitly substituted for. That input still does not reach the generated
      # specification, but the gap is recorded rather than hidden, which is the standard the
      # spec sets for every other capability in this lane.
      def blockers_for(inputs)
        inputs.reject(&:readable?).reject { |input| substituted?(input) }.map do |input|
          "#{describe(input)}: #{input.note}"
        end
      end

      def warnings_for(inputs)
        inputs.reject(&:readable?).select { |input| substituted?(input) }.map do |input|
          "#{describe(input)} did not reach this specification. #{input.note}"
        end
      end

      def substituted?(input)
        input.read_status == DEFERRED_TO_RUNNER_MCP && settings.external_references.substitute?
      end

      # The per-input table the generated business analysis embeds. Written here rather than
      # in the document template because the verdict and its presentation must not be able
      # to disagree — this is the one place that decides what each input contributed.
      def summary_markdown(inputs)
        return "_The bundle recorded no individual inputs._" if inputs.empty?

        rows = inputs.map do |input|
          "| #{escape(describe(input))} | `#{input.read_status}` | #{input.readable? ? 'used' : 'not used'} " \
            "| #{escape(input.note.to_s)} |"
        end
        [ "| Input | Platform read status | Used by this runner | Note |",
          "| --- | --- | --- | --- |", *rows ].join("\n")
      end

      def describe(input)
        name = input.name.to_s.strip
        name.empty? ? input.kind.to_s : "#{input.kind} — #{name}"
      end

      # A reference may be an operator-pasted URL. Userinfo is stripped before it can reach
      # a generated file or a Platform payload; the host and path stay, because they are the
      # evidence.
      def safe_reference(value) = Redaction.redact(value.to_s)

      # Pipes would break the Markdown table this text is interpolated into, and a bundle
      # field is not this runner's text to trust.
      def escape(text) = text.to_s.gsub("|", "\\|").gsub(/\s+/, " ").strip
    end
  end
end
