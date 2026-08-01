# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # The structure a real Jira ticket already carries, read out of the reporter's own words
    # (MVP-0026 scope 3, CR-002 must-fix 1).
    #
    # This class exists because of a defect that only a real ticket could expose. Six of the
    # generated specification's nine sections were fixed literal strings with the issue key
    # interpolated, so a ticket stating six acceptance criteria, four out-of-scope items and
    # three edge cases produced a document containing none of them — and asserting, instead,
    # an idempotency criterion for a stateless read-only endpoint. Two packages for two
    # different tickets were byte-identical in those sections. Against the synthetic fixtures
    # the suite used, that was invisible; against `MAPIAI-47` it was the first thing a reader
    # saw.
    #
    # The rule this encodes: **where the ticket says it, the specification quotes it.** Prose
    # the runner composes is scaffolding around the reporter's material, never a replacement
    # for it. Where the ticket says nothing, the document says *that*, and labels what it
    # derived as derived — because a fabricated acceptance criterion is worse than a missing
    # one, and a reviewer cannot tell them apart after the fact.
    #
    # ## What a Jira description actually looks like here
    #
    # Not Markdown. Jira stores ADF and SpecRelay's integration flattens it to text, which
    # loses heading markup entirely: a heading arrives as a bare short line surrounded by
    # blank lines. Lists survive as markers, but not the ones a Markdown author would expect —
    # an ADF ordered list becomes `#` per item and a bulleted list becomes `*`:
    #
    #     Acceptance criteria
    #
    #     # GET /healthz returns HTTP 200.
    #     # The response content-type is application/json; charset=utf-8 …
    #
    # A bare `#` line is a level-1 heading in Markdown. Reproducing those verbatim would blow
    # the generated document's outline apart, so ordered markers are renumbered on the way
    # out. That is the one transformation applied to the reporter's text; everything else is
    # copied.
    #
    # Both real shapes are handled because both were met: `MAPIAI-47` numbers its criteria and
    # writes "Out of scope" as one paragraph of four sentences; `MAPIAI-48` bullets its
    # criteria and writes "Non-goals" as four paragraphs. A section's body is reproduced
    # whatever its shape, which is why neither needs a special case.
    class TicketSections
      # A heading loses its markup in the ADF→text conversion, so it has to be recognised by
      # SHAPE: a short line, alone between blank lines, that reads like a title rather than a
      # sentence. Explicit Markdown (`## Problem`) and bold-only (`**Problem**`) forms are
      # accepted too, because some reporters type them by hand.
      MAX_HEADING_CHARS = 60
      SENTENCE_ENDING = /[.!?;,:]\z/
      LIST_MARKER = /\A\s*([*+-]|#|\d+[.)])\s+/

      # `##` and deeper only. A SINGLE `#` is an ADF ordered-list marker here, not a level-1
      # heading — that is what the conversion emits for `1.`, and it is far more common in a
      # Jira description than a hand-typed H1. Accepting `#` as a heading was a real bug found
      # against `MAPIAI-47`: every one of its six numbered acceptance criteria was read as a
      # section heading, which left the "Acceptance criteria" section empty and dropped.
      MARKDOWN_HEADING = /\A\s{0,3}\#{2,6}\s+(.+?)\s*\z/
      BOLD_HEADING = /\A\s*\*\*(.+?)\*\*\s*\z/

      # The four things a ticket reliably carries and a specification must not paraphrase.
      #
      # `definition of done` is deliberately in ACCEPTANCE rather than OUTCOME: on the real Bug
      # `MAPIAI-49` it introduces six lettered testable criteria, which is what it usually
      # means. OUTCOME is for a ticket's statement of the *goal* — "What we want" on
      # `MAPIAI-47` and `MAPIAI-48` — and a ticket may legitimately have none, in which case
      # the generated Outcome section says one short honest thing instead of pretending.
      PROBLEM = /\A(problem|context|background|why)\b/i
      ACCEPTANCE = /\A(acceptance criteria|acceptance|criteria|definition of done)\b/i
      NON_GOALS = /\A(out of scope|out-of-scope|non-?goals?|not in scope|exclusions)\b/i
      OUTCOME = /\A(outcome|desired outcome|what we want|goal|goals|expected behaviou?r|expected result)\b/i

      Section = Struct.new(:heading, :body, keyword_init: true) do
        def empty? = body.to_s.strip.empty?
      end

      def self.parse(text) = new(text).parse

      def initialize(text)
        @text = text.to_s
      end

      def parse
        @sections = build_sections
        self
      end

      attr_reader :sections

      def problem = find(PROBLEM)
      def acceptance_criteria = find(ACCEPTANCE)
      def non_goals = find(NON_GOALS)
      def outcome = find(OUTCOME)

      def problem? = !problem.nil?
      def acceptance_criteria? = !acceptance_criteria.nil?
      def non_goals? = !non_goals.nil?
      def outcome? = !outcome.nil?

      # Everything the ticket says about what it WANTS, excluding what it says it does not want.
      #
      # The distinction is not academic. A `user_facing?`-style keyword heuristic run over the
      # whole description reads an exclusion as an inclusion: on `MAPIAI-49` the only
      # occurrence of "page" is in "This is about surviving a failed read, not about the page
      # content" — inside `Out of scope` — and the generated analysis reported `UI | Likely`
      # for a process that dies on a failed file read. Word boundaries did not help, because
      # the matching mode was never the problem.
      def inclusive_material
        sections.reject { |section| NON_GOALS.match?(section.heading) }
                .map { |section| "#{section.heading}\n#{section.body}" }.join("\n\n")
      end

      # The heading the reporter actually wrote, so the generated document can attribute the
      # quote to it ("the ticket's own \"Out of scope\" section") rather than to a label this
      # runner chose.
      def heading_for(matcher) = find_section(matcher)&.heading

      # Any section, by its heading, for the sections this class does not name — "Edge cases
      # that matter" is a real heading on both real tickets and belongs in the specification
      # even though nothing here looks for it by name.
      def other_sections
        named = [ PROBLEM, ACCEPTANCE, NON_GOALS, OUTCOME ]
        sections.reject { |section| named.any? { |matcher| matcher.match?(section.heading) } }
      end

      private

      attr_reader :text

      def find(matcher) = find_section(matcher)&.body
      def find_section(matcher) = sections.find { |section| matcher.match?(section.heading) }

      # One pass, line by line. A heading closes the previous section and opens the next; text
      # before the first heading belongs to no section (it is the preamble, which is exactly
      # the material the old "first paragraph" rule mistook for the problem statement).
      def build_sections
        found = []
        current = nil
        lines = text.lines
        lines.each_with_index do |line, index|
          heading = heading_at(lines, index)
          if heading
            found << current if current && !current.empty?
            current = Section.new(heading: heading, body: +"")
          elsif current
            current.body << line
          end
        end
        found << current if current && !current.empty?
        found.each { |section| section.body = normalize(section.body) }
        found
      end

      def heading_at(lines, index)
        line = lines[index].to_s.chomp
        explicit = line[MARKDOWN_HEADING, 1] || line[BOLD_HEADING, 1]
        return explicit.strip if explicit

        return nil unless bare_heading?(line)
        return nil unless blank?(lines[index - 1]) || index.zero?
        return nil unless blank?(lines[index + 1])

        line.strip
      end

      def bare_heading?(line)
        stripped = line.strip
        return false if stripped.empty? || stripped.length > MAX_HEADING_CHARS
        return false if LIST_MARKER.match?(line)
        return false if SENTENCE_ENDING.match?(stripped)

        # A title has at least one letter and is not a bare URL or path fragment.
        /[[:alpha:]]/.match?(stripped) && !stripped.include?("://")
      end

      def blank?(line) = line.nil? || line.to_s.strip.empty?

      # The one transformation applied to the reporter's words: ADF ordered-list markers (`#`)
      # become real Markdown numbers. Left alone they render as level-1 headings and destroy
      # the generated document's outline — which makes this a correctness fix, not a
      # cosmetic one. Bulleted markers are already valid Markdown and are copied as they are.
      def normalize(body)
        counter = 0
        body.lines.map do |line|
          if /\A\s*#\s+\S/.match?(line)
            counter += 1
            line.sub(/\A(\s*)#\s+/, "\\1#{counter}. ")
          else
            counter = 0 unless line.strip.empty?
            line
          end
        end.join.strip
      end
    end
  end
end
