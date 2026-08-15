# frozen_string_literal: true

require "json"

module SpecrelayRunner
  module Review
    # Strict parsing of the reviewer process's stdout (MVP-0033 contract 6).
    #
    # A language model's stdout is not a protocol. This turns it into one, or refuses:
    #
    #   - the output must be ONE JSON object; anything else fails;
    #   - it is size-bounded before it is parsed, so a runaway provider cannot exhaust memory
    #     or produce an unreviewable wall of text (S26);
    #   - only the named fields survive, so nothing the schema does not know about is
    #     forwarded to Platform (S25);
    #   - every string is redacted with the runner's existing Redaction boundary before it
    #     leaves this machine (S27).
    #
    # Platform validates all of this again. That is deliberate, not redundant: the runner is
    # not the trust boundary, and this pass exists so a malformed provider result fails HERE
    # with a local, actionable message instead of as a rejected submission.
    module Result
      module_function

      Parsed = Struct.new(:review, :error, keyword_init: true) do
        def ok? = error.nil?
      end

      # Raised while parsing a document that states one member twice.
      DuplicateMember = Class.new(StandardError)

      # The object the reviewer's JSON is built into: a Hash that refuses to be written twice
      # under one name (MAPIAI-78 review-001 F1).
      #
      # A duplicate member is an ambiguous document — `{"outcome":"ACCEPT","outcome":
      # "CHANGES_REQUESTED"}` states two verdicts — and whichever one survives is a choice this
      # runner is not entitled to make. The standard library makes that choice silently, and
      # differently across the versions the runner supports, so the refusal is expressed to the
      # parser BOTH ways it will listen: this object class, which sees every member the pure-Ruby
      # parser assigns (json 2.9, Ruby 3.4), and `allow_duplicate_key: false`, which the native
      # parser honours (json 2.10+, Ruby 3.5+). One rule, stated once per parser generation,
      # because neither statement alone is deterministic over the supported range.
      class StrictDocument < Hash
        def []=(name, value)
          raise DuplicateMember, name if key?(name)

          super
        end
      end

      MAX_OUTPUT_BYTES = 200_000
      SEVERITIES = %w[blocking major minor].freeze
      EVIDENCE_KEYS = %w[structural_review verification_run browser_review].freeze

      # `outcomes` is Platform's own result contract, threaded in from the packet. This module
      # keeps no copy of the supported set: a second list here would be free to drift from the
      # one Platform actually validates against (MAPIAI-78 design 1).
      def parse(output, outcomes:)
        text = output.to_s
        return Parsed.new(error: "the reviewer produced no output") if text.strip.empty?
        return Parsed.new(error: "the reviewer produced more than #{MAX_OUTPUT_BYTES} bytes") if text.bytesize > MAX_OUTPUT_BYTES

        document = extract_object(text)
        return Parsed.new(error: "the reviewer did not return one JSON object") if document.nil?

        build(document, outcomes)
      rescue DuplicateMember
        # Named without its value: the point is that the document says two things, not which
        # two. Repeating them would put a verdict this runner refused into the reason it gives
        # Platform for refusing it.
        Parsed.new(error: "the reviewer's result states one field twice, so it means two things at once")
      end

      # A model reliably wraps JSON in a fence or a sentence, so the OUTERMOST balanced object
      # is taken rather than requiring byte-exact output. It is still one object: the braces
      # must balance, and anything that does not parse is refused.
      def extract_object(text)
        start = text.index("{")
        finish = text.rindex("}")
        return nil if start.nil? || finish.nil? || finish < start

        JSON.parse(text[start..finish], object_class: StrictDocument, allow_duplicate_key: false)
      rescue JSON::ParserError
        nil
      end

      def build(document, outcomes)
        return Parsed.new(error: "the reviewer's result was not a JSON object") unless document.is_a?(Hash)

        # A scalar, or nothing. An array or an object carrying several outcomes is refused whole
        # rather than reduced to one of its candidates.
        raw = document["outcome"]
        outcome = raw.is_a?(String) ? raw.strip.upcase : nil
        return Parsed.new(error: "outcome must be one of #{outcomes.join(', ')}") unless outcomes.include?(outcome)

        review = { "outcome" => outcome, "summary" => clean(document["summary"]),
                   "findings" => findings(document["findings"]),
                   "evidence" => evidence(document["evidence"]) }
        review["question"] = question(document["question"]) if outcome == "NEEDS_INPUT"
        Parsed.new(review: review.compact)
      end

      def findings(raw)
        Array(raw).filter_map do |entry|
          next unless entry.is_a?(Hash)

          severity = entry["severity"].to_s.strip.downcase
          { "severity" => SEVERITIES.include?(severity) ? severity : "minor",
            "summary" => clean(entry["summary"]), "reason" => clean(entry["reason"]),
            "location" => clean(entry["location"]) }
        end
      end

      def evidence(raw)
        fields = raw.is_a?(Hash) ? raw : {}
        EVIDENCE_KEYS.to_h { |key| [ key, fields[key] == true ] }
      end

      def question(raw)
        return nil unless raw.is_a?(Hash)

        { "prompt" => clean(raw["prompt"]), "reason" => clean(raw["reason"]),
          "options" => Array(raw["options"]).filter_map { |option| question_option(option) } }
      end

      def question_option(option)
        return nil unless option.is_a?(Hash)

        { "key" => option["key"].to_s.strip.downcase, "label" => clean(option["label"]),
          "trade_off" => clean(option["trade_off"]), "recommended" => option["recommended"] == true }
      end

      # Every string leaving this machine goes through the runner's own redaction boundary,
      # which strips credential shapes and URL userinfo. Platform redacts again; both must,
      # because neither trusts the other's diligence.
      def clean(value) = Redaction.redact(value.to_s.strip)
    end
  end
end
