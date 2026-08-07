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

      MAX_OUTPUT_BYTES = 200_000
      OUTCOMES = %w[ACCEPT CHANGES_REQUESTED NEEDS_INPUT].freeze
      SEVERITIES = %w[blocking major minor].freeze
      EVIDENCE_KEYS = %w[structural_review verification_run browser_review].freeze

      def parse(output)
        text = output.to_s
        return Parsed.new(error: "the reviewer produced no output") if text.strip.empty?
        return Parsed.new(error: "the reviewer produced more than #{MAX_OUTPUT_BYTES} bytes") if text.bytesize > MAX_OUTPUT_BYTES

        document = extract_object(text)
        return Parsed.new(error: "the reviewer did not return one JSON object") if document.nil?

        build(document)
      end

      # A model reliably wraps JSON in a fence or a sentence, so the OUTERMOST balanced object
      # is taken rather than requiring byte-exact output. It is still one object: the braces
      # must balance, and anything that does not parse is refused.
      def extract_object(text)
        start = text.index("{")
        finish = text.rindex("}")
        return nil if start.nil? || finish.nil? || finish < start

        JSON.parse(text[start..finish])
      rescue JSON::ParserError
        nil
      end

      def build(document)
        return Parsed.new(error: "the reviewer's result was not a JSON object") unless document.is_a?(Hash)

        outcome = document["outcome"].to_s.strip.upcase
        return Parsed.new(error: "outcome must be one of #{OUTCOMES.join(', ')}") unless OUTCOMES.include?(outcome)

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
