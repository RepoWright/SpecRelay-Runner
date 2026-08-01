# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # The one place in this namespace that understands Markdown fenced code blocks.
    #
    # It exists because of a defect this round shipped: the composer wrapped the rendered
    # input bundle in a hardcoded three-backtick fence, the bundle always carries its own
    # three-backtick fence, and so every generated `spec.md` closed the outer block early and
    # then opened one it never closed. Six required sections rendered as literal code. The
    # digests were right, the sections were "present", and the document was unusable.
    #
    # Two lessons are encoded here, and both are why this is a module rather than two
    # one-line fixes at the call sites:
    #
    #   - A fence around text this process did not author must be CHOSEN from that text.
    #     `fenced` is the only sanctioned way to embed untrusted content — bundle Markdown,
    #     Graphify stdout, anything a provider or a tool produced. Platform's own bundle
    #     renderer (Jira::SpecCreation::Markdown) reached the same rule independently; this is
    #     deliberately the same rule for the same reason, in the repository that consumes its
    #     output.
    #   - Structure must be read the way a renderer reads it. A `##` line inside a code block
    #     is not a heading, and a validator that cannot tell the difference will certify a
    #     broken document — which is exactly what happened. {each_line} yields that
    #     distinction so DocumentSet can scan headings the way CommonMark defines them.
    #
    # The subset implemented: backtick and tilde fences, up to three leading spaces of
    # indentation, a closing fence at least as long as its opening one and carrying no info
    # string, and the rule that a backtick fence's info string may not itself contain a
    # backtick (CommonMark §4.5). Indented (four-space) code blocks are deliberately NOT
    # modelled — no document this runner produces or validates uses them, and pretending to
    # handle a construct we never exercise would be a worse kind of wrong than declaring the
    # boundary.
    module Markdown
      # A line that could open or close a fence: optional indent, then a run of at least three
      # backticks or tildes, then the info string.
      FENCE_LINE = /\A {0,3}(`{3,}|~{3,})[ \t]*(.*?)[ \t]*\z/

      MIN_FENCE = 3

      # The longest unbroken run of backticks anywhere in the text. The measure that decides
      # how long a fence has to be to survive containing it.
      def self.longest_backtick_run(text) = text.to_s.scan(/`+/).map(&:length).max.to_i

      # A fence guaranteed to survive `body`: longer than anything inside it.
      def self.fence_for(body) = "`" * [ MIN_FENCE, longest_backtick_run(body) + 1 ].max

      # `body`, fenced so that it renders as one code block whatever it contains.
      #
      # The info string is this process's own literal (`text`, `markdown`), never
      # caller-supplied content, so it cannot smuggle a backtick into the opening line.
      def self.fenced(body, info: "")
        text = body.to_s.strip
        fence = fence_for(text)
        "#{fence}#{info}\n#{text}\n#{fence}"
      end

      # Yields `[line, inside_fence]` for every line of `content`, where `inside_fence` is
      # true for the opening fence, the closing fence, and everything between them. Returns
      # the 1-based line number of an opening fence that was never closed, or nil.
      #
      # Both the yielded flag and the return value matter to different callers, which is why
      # they are one traversal: a second pass could disagree with the first.
      def self.each_line(content)
        open = nil
        open_at = nil
        content.to_s.lines.each_with_index do |line, index|
          marker, info = fence_parts(line)
          if open
            closing = marker && marker[0] == open[0] && marker.length >= open.length && info.empty?
            open = open_at = nil if closing
            yield(line, true) if block_given?
          elsif opening?(marker, info)
            open = marker
            open_at = index + 1
            yield(line, true) if block_given?
          else
            yield(line, false) if block_given?
          end
        end
        open_at
      end

      # The 1-based line number of an unterminated fenced block, or nil when the document is
      # balanced. This is the check that would have caught the shipped defect before a byte
      # reached disk.
      def self.unterminated_fence(content) = each_line(content) { |_line, _inside| }

      def self.balanced?(content) = unterminated_fence(content).nil?

      # Every line that a renderer would treat as document structure rather than as code,
      # paired with its 1-based line number. Headings are scanned over this, never over the
      # raw lines.
      def self.structural_lines(content)
        lines = []
        number = 0
        each_line(content) do |line, inside|
          number += 1
          lines << [ line, number ] unless inside
        end
        lines
      end

      def self.fence_parts(line)
        match = FENCE_LINE.match(line.chomp)
        match ? [ match[1], match[2].to_s ] : [ nil, "" ]
      end

      # CommonMark §4.5: a backtick fence's info string may not contain a backtick, because
      # that would be ambiguous with inline code. A tilde fence has no such restriction.
      def self.opening?(marker, info)
        return false if marker.nil?

        !(marker.start_with?("`") && info.include?("`"))
      end

      private_class_method :fence_parts, :opening?
    end
  end
end
