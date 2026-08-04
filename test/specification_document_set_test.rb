# frozen_string_literal: true

require_relative "test_helper"

# MVP-0028 remediation, defect 3 — direct unit coverage for `DocumentSet#open_questions`'s new
# parsing of `analysis/open-questions.md`, and for the structural validation that document now
# gets. `specification_provider_test.rb` proves the CLI-level accept/reject behavior; this file
# proves the PARSED CONTENT is correct — specifically the exact bug caught while writing this
# slice: the parser's first draft returned each question's generic "why it blocks" boilerplate
# (identical across every entry) instead of its distinguishing "decision required" text.
#
# Review 006 finding F1 adds the per-question FIELD validation below: a question used to be
# certified by its heading alone, and a body missing "Decision required" made `#open_questions`
# silently substitute the first bullet it found — so Platform could display unrelated text as
# though it were the decision the Product Owner must answer. That fallback is gone; a malformed
# body is now rejected before the package is ever written.
class SpecificationDocumentSetTest < Minitest::Test
  DocumentSet = SpecrelayRunner::Specification::DocumentSet
  PackagePath = SpecrelayRunner::Specification::PackagePath

  ISSUE = "SR-700"

  # Every generated document opens with its own H1 (MVP-0028 remediation, defect 10), so the
  # baseline every example below starts from carries one.
  def sectioned_document(title, sections)
    "# #{title}\n\n" + sections.map { |section| "## #{section}\n\n#{'x' * 50}\n" }.join
  end

  def base_files
    {
      PackagePath::SPEC_MD => sectioned_document("#{ISSUE} — add an export button",
                                                 DocumentSet::REQUIRED_SECTIONS.fetch(PackagePath::SPEC_MD)),
      PackagePath::INPUT_EVIDENCE_MD => "# Input evidence — #{ISSUE}\n\nNo supporting input was recorded.\n",
      PackagePath::BUSINESS_MD => sectioned_document("Business analysis — #{ISSUE}",
                                                     DocumentSet::REQUIRED_SECTIONS.fetch(PackagePath::BUSINESS_MD)),
      PackagePath::TECHNICAL_MD => sectioned_document("Technical analysis — #{ISSUE}",
                                                      DocumentSet::REQUIRED_SECTIONS.fetch(PackagePath::TECHNICAL_MD))
    }
  end

  # ------------------------------------------------------------------ open_questions parsing

  def test_open_questions_is_empty_when_the_file_is_absent
    documents = DocumentSet.new(base_files)

    assert_empty documents.open_questions
  end

  # THE regression this slice caught interactively: the id must pair with the DISTINGUISHING
  # "decision required" text, not the "why it blocks" boilerplate that reads identically for
  # every question in the file.
  def test_open_questions_returns_the_decision_required_text_not_the_why_it_blocks_boilerplate
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - Why it blocks: the recorded inputs do not decide this, and guessing would put an
        unreviewed product decision into the implementation.
      - Decision required: should a repeat request return the cached result or re-run the operation?
      - Consequence: without an answer, an implementer must choose arbitrarily.
    MD
    documents = DocumentSet.new(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))

    assert_equal [ "OQ-001: should a repeat request return the cached result or re-run the operation?" ],
                documents.open_questions
  end

  # Two questions, each with its OWN decision text, correctly paired by id rather than both
  # collapsing to the same (identical) "why it blocks" sentence.
  def test_open_questions_pairs_each_id_with_its_own_distinct_decision
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - Why it blocks: the recorded inputs do not decide this.
      - Decision required: what happens on a second identical request?
      - Consequence: an implementer must guess.

      ## OQ-002

      - Why it blocks: the recorded inputs do not decide this.
      - Decision required: what does the user see on failure?
      - Consequence: an implementer must guess.
    MD
    documents = DocumentSet.new(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))

    assert_equal [ "OQ-001: what happens on a second identical request?",
                  "OQ-002: what does the user see on failure?" ], documents.open_questions
  end

  # A "Decision required" bullet whose value soft-wraps onto a continuation line still joins
  # into one value rather than being cut at the wrap point or read as a second, unlabelled bullet.
  def test_open_questions_joins_a_wrapped_decision_required_value
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - Why it blocks: a
      - Decision required: should a repeat request return the cached result
        or re-run the operation end to end?
      - Consequence: an implementer must guess.
    MD
    documents = DocumentSet.new(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))

    assert_equal [ "OQ-001: should a repeat request return the cached result or re-run the " \
                  "operation end to end?" ], documents.open_questions
  end

  # ------------------------------------------------------------------ validate! on the new files

  def test_validate_accepts_input_evidence_with_no_supporting_inputs
    assert DocumentSet.validate!(base_files, issue_key: ISSUE)
  end

  def test_validate_rejects_an_open_questions_file_with_a_duplicate_id
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - Why it blocks: a
      - Decision required: b
      - Consequence: c

      ## OQ-001

      - Why it blocks: d
      - Decision required: e
      - Consequence: f
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md), issue_key: ISSUE)
    end

    assert_includes error.message, "reuses question id"
    assert_includes error.message, "OQ-001"
  end

  def test_validate_rejects_input_evidence_below_the_supplementary_floor
    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::INPUT_EVIDENCE_MD => "short"), issue_key: ISSUE)
    end

    assert_includes error.message, "too short"
  end

  # ------------------------------------------------------ review 006, finding F1: field shapes

  # THE exact shape the fallback used to paper over: no recognized label at all. Removing the
  # fallback means this is now rejected rather than silently surfaced as though it were the
  # decision required.
  def test_validate_rejects_a_question_with_no_labelled_fields_at_all
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - What should happen on a repeat request? This generation found no stated decision for it.
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md), issue_key: ISSUE)
    end

    assert_includes error.message, "OQ-001"
    assert_includes error.message, "missing required field(s)"
  end

  def test_validate_rejects_a_question_missing_decision_required
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - Why it blocks: a
      - Consequence: c
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md), issue_key: ISSUE)
    end

    assert_includes error.message, "OQ-001"
    assert_includes error.message, "missing required field(s): decision required"
  end

  def test_validate_rejects_a_question_with_a_duplicated_field
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - Why it blocks: a
      - Why it blocks: a again
      - Decision required: b
      - Consequence: c
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md), issue_key: ISSUE)
    end

    assert_includes error.message, "OQ-001"
    assert_includes error.message, "duplicate field(s): why it blocks"
  end

  def test_validate_rejects_a_question_with_a_blank_field
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - Why it blocks: a
      - Decision required:
      - Consequence: c
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md), issue_key: ISSUE)
    end

    assert_includes error.message, "OQ-001"
    assert_includes error.message, "blank field: decision required"
  end

  def test_validate_rejects_a_question_with_an_unexpected_field
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - Why it blocks: a
      - Decision required: b
      - Consequence: c
      - Priority: high
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md), issue_key: ISSUE)
    end

    assert_includes error.message, "OQ-001"
    assert_includes error.message, "unexpected field: priority"
  end

  # ------------------------------------------------------ MVP-0028 decision D6: resolved shape

  def test_a_resolved_question_validates_with_its_own_three_field_shape
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - Status: resolved
      - Decision: cache the result and return it unchanged on a repeat request.
      - Source: Jira comment from the reporter, 2026-08-02.
    MD

    assert DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md), issue_key: ISSUE)
  end

  def test_open_questions_omits_a_resolved_entry_from_the_run_summary
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - Status: resolved
      - Decision: cache the result.
      - Source: Jira comment.

      ## OQ-002

      - Why it blocks: the recorded inputs do not decide this.
      - Decision required: what does the user see on failure?
      - Consequence: an implementer must guess.
    MD
    documents = DocumentSet.new(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))

    assert_equal [ "OQ-002: what does the user see on failure?" ], documents.open_questions
  end

  def test_a_resolved_question_missing_its_own_required_field_is_rejected
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - Status: resolved
      - Decision: cache the result.
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md), issue_key: ISSUE)
    end

    assert_includes error.message, "OQ-001"
    assert_includes error.message, "missing required field(s): source"
  end

  # The open shape is unaffected: no "status" bullet at all still means "open", exactly as every
  # package generated before this decision already relied on.
  def test_a_resolved_question_reusing_an_open_field_is_rejected_as_unexpected
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - Status: resolved
      - Decision: cache the result.
      - Source: Jira comment.
      - Why it blocks: this used to block.
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md), issue_key: ISSUE)
    end

    assert_includes error.message, "unexpected field: why it blocks"
  end

  def test_an_unrecognized_status_value_is_rejected
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - Status: closed
      - Decision: cache the result.
      - Source: Jira comment.
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md), issue_key: ISSUE)
    end

    assert_includes error.message, "OQ-001"
    assert_includes error.message, "unrecognized status"
  end

  def test_a_mix_of_open_and_resolved_questions_both_validate_in_one_file
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - Status: resolved
      - Decision: cache the result.
      - Source: Jira comment.

      ## OQ-002

      - Why it blocks: the recorded inputs do not decide this.
      - Decision required: what happens on a timeout?
      - Consequence: an implementer must guess.
    MD

    assert DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md), issue_key: ISSUE)
  end

  # ------------------------------------------------- MVP-0028 remediation, defect 10: titles
  #
  # The live MAPIAI-53 revision published a `technical.md` whose title was gone: the provider
  # emitted its FIRST required section name as the H1, repeated it immediately as the H2, and
  # narrated its own instructions in between. Every `##` section was present, so every check
  # this class had passed it.
  #
  # The gate is the document's ROLE, not the presence of a heading. A section name is not a
  # title, however well-formed the `#` in front of it is.

  # The exact bytes the live run produced, reduced to the shape that matters.
  def malformed_technical_md
    "# Source entry points inspected\n\n(placeholder-free content follows)\n\n" +
      DocumentSet::REQUIRED_SECTIONS.fetch(PackagePath::TECHNICAL_MD)
        .map { |section| "## #{section}\n\n#{'x' * 50}\n" }.join
  end

  def test_validate_rejects_the_live_malformed_technical_analysis_document
    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::TECHNICAL_MD => malformed_technical_md),
                            issue_key: ISSUE)
    end

    assert_includes error.message, PackagePath::TECHNICAL_MD
    assert_includes error.message, "technical analysis"
  end

  # Named separately from the title check because they fail for different reasons and an
  # operator fixes them differently: one is a wrong title, this is text that is not content.
  def test_validate_rejects_provider_scaffolding_on_a_line_of_its_own
    document = base_files.fetch(PackagePath::BUSINESS_MD)
                         .sub("\n\n##", "\n\n(placeholder-free content follows)\n\n##")

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::BUSINESS_MD => document), issue_key: ISSUE)
    end

    assert_includes error.message, "scaffolding"
    assert_includes error.message, "placeholder-free content follows"
  end

  def test_validate_rejects_a_document_with_no_title_at_all
    document = base_files.fetch(PackagePath::BUSINESS_MD).sub(/\A# .*\n\n/, "")

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::BUSINESS_MD => document), issue_key: ISSUE)
    end

    assert_includes error.message, "level-1 title"
  end

  # Role, not merely "a title exists": the right shape naming the wrong document is still wrong,
  # and this is the case a "does it start with #" check would wave through.
  def test_validate_rejects_a_title_that_names_a_different_document
    document = base_files.fetch(PackagePath::TECHNICAL_MD)
                         .sub("# Technical analysis — #{ISSUE}", "# Business analysis — #{ISSUE}")

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::TECHNICAL_MD => document), issue_key: ISSUE)
    end

    assert_includes error.message, "technical analysis"
  end

  def test_validate_rejects_a_specification_whose_title_does_not_name_its_ticket
    document = base_files.fetch(PackagePath::SPEC_MD).sub(/\A# .*$/, "# Specification")

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::SPEC_MD => document), issue_key: ISSUE)
    end

    assert_includes error.message, ISSUE
  end

  # The optional file is held to the same rule WHEN PRESENT, and to nothing when absent.
  def test_validate_rejects_an_open_questions_file_with_the_wrong_title
    open_questions_md = <<~MD
      # OQ-001

      ## OQ-001

      - Why it blocks: the recorded inputs do not decide this.
      - Decision required: what happens on a timeout?
      - Consequence: an implementer must guess.
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md), issue_key: ISSUE)
    end

    assert_includes error.message, "open questions"
  end

  # The titles real providers write differ in wording and separator; the contract is the ROLE the
  # title names, so every one of these must pass. Anchoring on exact strings would reject honest
  # output and teach an operator to fight the gate.
  def test_validate_accepts_the_title_wordings_real_providers_produce
    [
      [ PackagePath::INPUT_EVIDENCE_MD, "# Supporting input evidence — #{ISSUE}" ],
      [ PackagePath::INPUT_EVIDENCE_MD, "# Input evidence for #{ISSUE}" ],
      [ PackagePath::TECHNICAL_MD, "# Technical Analysis: #{ISSUE}" ],
      [ PackagePath::SPEC_MD, "# #{ISSUE}: add an export button" ]
    ].each do |name, title|
      document = base_files.fetch(name).sub(/\A# .*$/, title)

      assert DocumentSet.validate!(base_files.merge(name => document), issue_key: ISSUE),
             "expected #{title.inspect} to be accepted for #{name}"
    end
  end

  # A title inside a fenced block is not a title, for the same reason a heading inside one is not
  # a heading — the reader never sees it.
  def test_validate_rejects_a_title_that_only_exists_inside_a_code_block
    document = "```\n# Technical analysis — #{ISSUE}\n```\n\n" +
               base_files.fetch(PackagePath::TECHNICAL_MD).sub(/\A# .*\n\n/, "")

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::TECHNICAL_MD => document), issue_key: ISSUE)
    end

    assert_includes error.message, "level-1 title"
  end
end
