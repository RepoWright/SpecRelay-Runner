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

  def sectioned_document(sections)
    sections.map { |section| "## #{section}\n\n#{'x' * 50}\n" }.join
  end

  def base_files
    {
      PackagePath::SPEC_MD => sectioned_document(DocumentSet::REQUIRED_SECTIONS.fetch(PackagePath::SPEC_MD)),
      PackagePath::INPUT_EVIDENCE_MD => "# Input evidence\n\nNo supporting input was recorded.\n",
      PackagePath::BUSINESS_MD => sectioned_document(DocumentSet::REQUIRED_SECTIONS.fetch(PackagePath::BUSINESS_MD)),
      PackagePath::TECHNICAL_MD => sectioned_document(DocumentSet::REQUIRED_SECTIONS.fetch(PackagePath::TECHNICAL_MD))
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
    assert DocumentSet.validate!(base_files)
  end

  def test_validate_rejects_an_open_questions_file_with_a_duplicate_id
    open_questions_md = <<~MD
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
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))
    end

    assert_includes error.message, "reuses question id"
    assert_includes error.message, "OQ-001"
  end

  def test_validate_rejects_input_evidence_below_the_supplementary_floor
    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::INPUT_EVIDENCE_MD => "short"))
    end

    assert_includes error.message, "too short"
  end

  # ------------------------------------------------------ review 006, finding F1: field shapes

  # THE exact shape the fallback used to paper over: no recognized label at all. Removing the
  # fallback means this is now rejected rather than silently surfaced as though it were the
  # decision required.
  def test_validate_rejects_a_question_with_no_labelled_fields_at_all
    open_questions_md = <<~MD
      ## OQ-001

      - What should happen on a repeat request? This generation found no stated decision for it.
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))
    end

    assert_includes error.message, "OQ-001"
    assert_includes error.message, "missing required field(s)"
  end

  def test_validate_rejects_a_question_missing_decision_required
    open_questions_md = <<~MD
      ## OQ-001

      - Why it blocks: a
      - Consequence: c
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))
    end

    assert_includes error.message, "OQ-001"
    assert_includes error.message, "missing required field(s): decision required"
  end

  def test_validate_rejects_a_question_with_a_duplicated_field
    open_questions_md = <<~MD
      ## OQ-001

      - Why it blocks: a
      - Why it blocks: a again
      - Decision required: b
      - Consequence: c
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))
    end

    assert_includes error.message, "OQ-001"
    assert_includes error.message, "duplicate field(s): why it blocks"
  end

  def test_validate_rejects_a_question_with_a_blank_field
    open_questions_md = <<~MD
      ## OQ-001

      - Why it blocks: a
      - Decision required:
      - Consequence: c
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))
    end

    assert_includes error.message, "OQ-001"
    assert_includes error.message, "blank field: decision required"
  end

  def test_validate_rejects_a_question_with_an_unexpected_field
    open_questions_md = <<~MD
      ## OQ-001

      - Why it blocks: a
      - Decision required: b
      - Consequence: c
      - Priority: high
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))
    end

    assert_includes error.message, "OQ-001"
    assert_includes error.message, "unexpected field: priority"
  end

  # ------------------------------------------------------ MVP-0028 decision D6: resolved shape

  def test_a_resolved_question_validates_with_its_own_three_field_shape
    open_questions_md = <<~MD
      ## OQ-001

      - Status: resolved
      - Decision: cache the result and return it unchanged on a repeat request.
      - Source: Jira comment from the reporter, 2026-08-02.
    MD

    assert DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))
  end

  def test_open_questions_omits_a_resolved_entry_from_the_run_summary
    open_questions_md = <<~MD
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
      ## OQ-001

      - Status: resolved
      - Decision: cache the result.
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))
    end

    assert_includes error.message, "OQ-001"
    assert_includes error.message, "missing required field(s): source"
  end

  # The open shape is unaffected: no "status" bullet at all still means "open", exactly as every
  # package generated before this decision already relied on.
  def test_a_resolved_question_reusing_an_open_field_is_rejected_as_unexpected
    open_questions_md = <<~MD
      ## OQ-001

      - Status: resolved
      - Decision: cache the result.
      - Source: Jira comment.
      - Why it blocks: this used to block.
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))
    end

    assert_includes error.message, "unexpected field: why it blocks"
  end

  def test_an_unrecognized_status_value_is_rejected
    open_questions_md = <<~MD
      ## OQ-001

      - Status: closed
      - Decision: cache the result.
      - Source: Jira comment.
    MD

    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))
    end

    assert_includes error.message, "OQ-001"
    assert_includes error.message, "unrecognized status"
  end

  def test_a_mix_of_open_and_resolved_questions_both_validate_in_one_file
    open_questions_md = <<~MD
      ## OQ-001

      - Status: resolved
      - Decision: cache the result.
      - Source: Jira comment.

      ## OQ-002

      - Why it blocks: the recorded inputs do not decide this.
      - Decision required: what happens on a timeout?
      - Consequence: an implementer must guess.
    MD

    assert DocumentSet.validate!(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))
  end
end
