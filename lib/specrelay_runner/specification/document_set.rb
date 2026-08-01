# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # The three generated documents, and the gate every provider's output must pass before
    # any of it reaches disk (MVP-0026 scope 9, criteria 2-4).
    #
    # A generation provider is the one component here whose output this runner cannot
    # predict — a configured external command may be a language model, and a language model
    # may return a plausible-looking document that silently omits acceptance criteria. So
    # the boundary is not "call the provider and write what comes back"; it is "call the
    # provider, prove the result is structurally complete, then write it".
    #
    # The checks are deliberately structural rather than semantic. This class can prove that
    # a document HAS an acceptance-criteria section with content under it; it cannot prove
    # the criteria are good. Claiming otherwise would be the more dangerous failure, so the
    # validation states exactly what it establishes and the review step remains human.
    #
    # Section titles are matched as `##` headings, OUTSIDE any fenced code block, and every
    # document must have balanced fences. That is a contract with the composer and with any
    # operator writing an external provider, and it is documented in the runner README rather
    # than left to be reverse-engineered from a rejection message.
    #
    # The fence rules are here because their absence was a shipped defect rather than a
    # theoretical gap: a raw-line heading scan certified a `spec.md` whose last six required
    # sections rendered inside an unterminated code block. Structural completeness that a
    # renderer disagrees with is not completeness.
    class DocumentSet
      Invalid = Class.new(StandardError)

      # Required `##` sections per document, in the order a reader meets them. Criterion 2
      # for the specification, 3 for the business analysis, 4 for the technical analysis —
      # each line here traces to one required element in the spec.
      REQUIRED_SECTIONS = {
        PackagePath::SPEC_MD => [
          "Problem", "Outcome", "Input summary", "Proposed behavior", "Non-goals",
          "Acceptance criteria", "Validation expectations",
          "Dependencies, assumptions, and open questions", "Analysis"
        ].freeze,
        PackagePath::BUSINESS_MD => [
          "User problem and affected workflow", "Stakeholder impact",
          "Risks, edge cases, and missing product decisions", "Acceptance-criteria rationale",
          "Input conflicts and gaps", "Recommendation"
        ].freeze,
        PackagePath::TECHNICAL_MD => [
          "Source entry points inspected", "Graphify evidence", "Context+ evidence",
          "Dependency and blast-radius assessment", "Likely implementation approach",
          "Implementation surface", "Tests a future implementation ticket needs",
          "Technical risks, unknowns, and blocked evidence"
        ].freeze
      }.freeze

      # A section heading with nothing under it satisfies a naive "does it contain the
      # words" check while telling a reader nothing. This is the floor below which a
      # section counts as absent.
      MIN_SECTION_BODY_CHARS = 40

      # A whole document below this is not a specification, whatever headings it carries.
      MIN_DOCUMENT_CHARS = 400

      attr_reader :files

      def self.validate!(files) = new(files).validate!

      def initialize(files)
        @files = files.to_h { |name, content| [ name.to_s, content.to_s ] }
      end

      # Raises Invalid on the FIRST structural problem, naming the document and the section.
      # A provider whose output is rejected must be able to see what to fix from the message
      # alone; "invalid output" would send the operator to read this class.
      def validate!
        missing = PackagePath::REQUIRED_FILES - files.keys
        raise Invalid, "the provider returned no #{missing.join(', ')}" if missing.any?

        extra = files.keys - PackagePath::ALL_FILES
        raise Invalid, "the provider returned unexpected files: #{extra.sort.join(', ')}" if extra.any?

        PackagePath::REQUIRED_FILES.each { |name| validate_document(name) }
        self
      end

      # Every generated file, keyed by its package-relative path. Ordered so the manifest
      # and the digest list are stable across runs.
      def each_file(&block) = PackagePath::ALL_FILES.select { |name| files.key?(name) }.each(&block)

      # The open questions the generated specification raises, read back out of the document
      # rather than passed alongside it.
      #
      # Reading them from the file is what makes this work for EVERY provider. A configured
      # external command returns Markdown and nothing else, so a structured side-channel
      # would be populated only by the built-in composer — and Platform's run page would then
      # show open questions for one provider and none for the other, which is worse than
      # showing none at all. The `### Open questions` subheading is part of the documented
      # document contract, so parsing it is reading the contract, not guessing at prose.
      OPEN_QUESTIONS_HEADING = "### Open questions"

      def open_questions
        body = subsection_body(files.fetch(PackagePath::SPEC_MD, ""), OPEN_QUESTIONS_HEADING)
        body.to_s.lines.filter_map do |line|
          text = line.strip
          next unless text.start_with?("- ")

          question = text.delete_prefix("- ").strip
          question unless question.downcase.start_with?("none")
        end
      end

      private

      # The lines under one `###` subheading, up to the next heading of any level. Separate
      # from #section_body because that one deliberately treats `###` as part of the body.
      def subsection_body(content, heading)
        bounded_body(content, /\A#{Regexp.escape(heading)}\z/, /\A\#{1,3}[ \t]+\S/)
      end

      def validate_document(name)
        content = files.fetch(name)
        raise Invalid, "#{name} is too short to be a generated document (#{content.length} characters)" if
          content.strip.length < MIN_DOCUMENT_CHARS

        validate_fences!(name, content)
        REQUIRED_SECTIONS.fetch(name).each { |section| validate_section(name, content, section) }
      end

      # A document with an unterminated fenced code block is not a valid document, whatever
      # its text contains: everything after the stray fence renders as code, including the
      # acceptance criteria.
      #
      # This check exists because its absence let a broken package through. The section scan
      # below matched `##` on raw lines, so it could not tell a heading from a line of
      # code-block content, and it certified a `spec.md` in which six of the nine required
      # sections were inside an unterminated block. Both halves are fixed together on
      # purpose — a renderability gate without a fence-aware section scan would still accept
      # a document whose headings exist only inside a code block.
      def validate_fences!(name, content)
        line = Markdown.unterminated_fence(content)
        return if line.nil?

        raise Invalid, "#{name} has a fenced code block opened at line #{line} that is never closed; " \
                       "everything after it would render as code"
      end

      def validate_section(name, content, section)
        body = section_body(content, section)
        raise Invalid, "#{name} is missing the required section \"## #{section}\"" if body.nil?
        raise Invalid, "#{name} has an empty \"## #{section}\" section" if body.strip.length < MIN_SECTION_BODY_CHARS
      end

      # The text between one `##` heading and the next heading of the same or higher level.
      #
      # Matched line by line rather than with one regular expression over the whole
      # document, for two reasons: a mention of the section title in prose must not be
      # mistaken for the section itself (so the heading must be a whole line), and a `###`
      # SUBheading belongs to the section rather than ending it (so only `#` and `##`
      # terminate the body). Returns nil when the heading is absent, which is a different
      # answer from an empty body and is reported differently.
      def section_body(content, section)
        bounded_body(content, /\A##[ \t]+#{Regexp.escape(section)}[ \t]*\z/, /\A\#{1,2}[ \t]+\S/)
      end

      # The body between a heading and its terminator, where BOTH are looked for only among
      # lines a renderer would treat as document structure.
      #
      # Scanning raw lines is the bug that let a broken `spec.md` through: the generated
      # document embeds the input bundle in a fenced block, the bundle carries `##` headings
      # of its own, and a raw scan happily reported those as this document's sections. A
      # heading that exists only inside a code block is not a heading, and this returns nil
      # for it — which is the same answer as "absent", because to a reader it is.
      #
      # The BODY is still taken from the raw lines: everything between the two structural
      # headings belongs to the section, fenced content included.
      def bounded_body(content, heading, terminator)
        structural = Markdown.structural_lines(content)
        start = structural.find { |line, _number| heading.match?(line.chomp) }
        return nil if start.nil?

        finish = structural.find { |line, number| number > start.last && terminator.match?(line) }
        lines = content.lines
        lines[start.last..(finish ? finish.last - 2 : lines.length - 1)].to_a.join
      end
    end
  end
end
