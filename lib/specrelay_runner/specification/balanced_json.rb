# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # Extracts the first genuinely BALANCED `{...}` object from text a model produced (MVP-0028
    # remediation, defect 1 correction / review-004 non-blocking note).
    #
    # Extracted from {Provider::Claude} because a SECOND caller now needs the identical judgment
    # call: {ReferenceAnalyzer::Claude} (defect 2, review-005 finding F2) asks the same real Claude
    # profile a different question and must extract its answer the same way. Two independent
    # re-implementations of "which text is the model's JSON object" would be two places that could
    # silently disagree about where one ends — exactly the class of bug review-004 found here the
    # first time, when "first `{` to last `}`" let a trailing aside with its own braces swallow the
    # real object's end.
    #
    # Brace depth is tracked character by character, and a brace inside a quoted string does not
    # count, so text a model adds despite instruction — a trailing sentence, a fence, an unrelated
    # aside that itself contains braces — cannot extend or shorten the match. Only genuine object
    # nesting inside the JSON can.
    module BalancedJson
      NotFound = Class.new(StandardError)

      def self.extract_object(text)
        source = text.to_s
        start = source.index("{")
        raise NotFound if start.nil?

        finish = matching_brace(source, start)
        raise NotFound if finish.nil?

        source[start..finish]
      end

      def self.matching_brace(text, start)
        depth = 0
        in_string = false
        escaped = false
        (start...text.length).each do |index|
          char = text[index]
          if escaped
            escaped = false
          elsif in_string
            escaped = true if char == "\\"
            in_string = false if char == '"'
          elsif char == '"'
            in_string = true
          elsif char == "{"
            depth += 1
          elsif char == "}"
            depth -= 1
            return index if depth.zero?
          end
        end
        nil
      end
      private_class_method :matching_brace
    end
  end
end
