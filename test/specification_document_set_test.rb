# frozen_string_literal: true

require_relative "test_helper"

# MVP-0028 remediation, defect 3 — direct unit coverage for `DocumentSet#open_questions`'s new
# parsing of `analysis/open-questions.md`, and for the structural validation that document now
# gets. `specification_provider_test.rb` proves the CLI-level accept/reject behavior; this file
# proves the PARSED CONTENT is correct — specifically the exact bug caught while writing this
# slice: the parser's first draft returned each question's generic "why it blocks" boilerplate
# (identical across every entry) instead of its distinguishing "decision required" text.
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

  # A question body with no "Decision required:" label falls back to its first bullet, so a
  # provider that used slightly different wording still surfaces SOMETHING to Platform rather
  # than an empty string.
  def test_open_questions_falls_back_to_the_first_bullet_when_unlabelled
    open_questions_md = <<~MD
      ## OQ-001

      - What should happen on a repeat request? This generation found no stated decision for it.
    MD
    documents = DocumentSet.new(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))

    assert_equal [ "OQ-001: What should happen on a repeat request? This generation found no " \
                  "stated decision for it." ], documents.open_questions
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
end
