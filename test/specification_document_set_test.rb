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

    assert_equal [ "OQ-001\n" \
                  "Why it blocks: the recorded inputs do not decide this, and guessing would put an " \
                  "unreviewed product decision into the implementation.\n" \
                  "Decision required: should a repeat request return the cached result or re-run the operation?\n" \
                  "Consequence: without an answer, an implementer must choose arbitrarily." ],
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

    assert_equal [ "OQ-001\nWhy it blocks: the recorded inputs do not decide this.\n" \
                  "Decision required: what happens on a second identical request?\n" \
                  "Consequence: an implementer must guess.",
                  "OQ-002\nWhy it blocks: the recorded inputs do not decide this.\n" \
                  "Decision required: what does the user see on failure?\n" \
                  "Consequence: an implementer must guess." ], documents.open_questions
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

    assert_equal [ "OQ-001\nWhy it blocks: a\n" \
                  "Decision required: should a repeat request return the cached result or re-run the " \
                  "operation end to end?\nConsequence: an implementer must guess." ], documents.open_questions
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

    assert_equal [ "OQ-002\nWhy it blocks: the recorded inputs do not decide this.\n" \
                  "Decision required: what does the user see on failure?\n" \
                  "Consequence: an implementer must guess." ], documents.open_questions
    assert_includes documents.files[PackagePath::OPEN_QUESTIONS_MD], "- Status: resolved"
  end

  # A long decision listing its answer options keeps every option: the entry is the question as
  # written, not a summary cut at a display length.
  def test_open_questions_keeps_every_answer_option_of_a_long_decision
    options = (1..8).map { |n| "(#{n}) keep the export behaviour described in option #{n} with its own column order" }
    decision = "which export behaviour should ship? Options: #{options.join('; ')}; or (9) the final option."
    assert_operator decision.length, :>=, 688
    open_questions_md = <<~MD
      # Open questions — SR-700

      ## OQ-001

      - Why it blocks: the recorded inputs do not decide this.
      - Decision required: #{decision}
      - Consequence: an implementer must guess.
    MD
    documents = DocumentSet.new(base_files.merge(PackagePath::OPEN_QUESTIONS_MD => open_questions_md))

    assert_includes documents.open_questions.first, "Decision required: #{decision}\n"
    assert documents.open_questions.first.end_with?("Consequence: an implementer must guess.")
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

  # ------------------------------------------------------------ the single leading-space alias

  # A valid open-questions document, for the tests that alias the OPTIONAL file.
  def open_questions_document
    <<~MD
      # Open questions — #{ISSUE}

      ## OQ-001

      - Why it blocks: the recorded inputs do not decide this.
      - Decision required: what happens on a second identical request?
      - Consequence: an implementer must guess.
    MD
  end

  # A valid map in which the business analysis arrives a SECOND time, with equal content, under a
  # name carrying one leading space.
  #
  # Asserted on the resolved file set rather than only on acceptance — a key that were merely
  # tolerated would pass `validate!` and then never be written, because `#each_file` yields the
  # canonical names and nothing else.
  def test_validate_resolves_a_leading_space_alias_that_duplicates_a_canonical_document
    files = base_files.merge(" #{PackagePath::BUSINESS_MD}" => base_files.fetch(PackagePath::BUSINESS_MD))

    documents = DocumentSet.validate!(files, issue_key: ISSUE)

    assert_equal PackagePath::REQUIRED_FILES.sort, documents.files.keys.sort
    assert_equal PackagePath::REQUIRED_FILES, documents.each_file.to_a
    assert_equal base_files.fetch(PackagePath::BUSINESS_MD), documents.files.fetch(PackagePath::BUSINESS_MD)
  end

  # The same map built the other way round. Order independence is the specific guard against the
  # natural implementation — rewriting the key inside a `to_h` — which keeps whichever entry was
  # written last and makes the surviving document a matter of provider ordering.
  def test_validate_resolves_a_duplicate_alias_written_before_its_canonical_name
    business = base_files.fetch(PackagePath::BUSINESS_MD)
    files = { " #{PackagePath::BUSINESS_MD}" => business }.merge(base_files)

    documents = DocumentSet.validate!(files, issue_key: ISSUE)

    assert_equal PackagePath::REQUIRED_FILES.sort, documents.files.keys.sort
    assert_equal business, documents.files.fetch(PackagePath::BUSINESS_MD)
  end

  # Two different documents under one name have no honest resolution, so neither is published and
  # neither is dropped. Checked in BOTH orders, because the failure mode is that one order happens
  # to overwrite the other quietly.
  def test_validate_rejects_an_alias_whose_content_differs_from_its_canonical_document
    business = base_files.fetch(PackagePath::BUSINESS_MD)
    conflicting = business.sub("Business analysis", "Business analysis (second)")

    [ base_files.merge(" #{PackagePath::BUSINESS_MD}" => conflicting),
      { " #{PackagePath::BUSINESS_MD}" => conflicting }.merge(base_files) ].each do |files|
      error = assert_raises(DocumentSet::Invalid) { DocumentSet.validate!(files, issue_key: ISSUE) }

      assert_includes error.message, PackagePath::BUSINESS_MD
      assert_includes error.message, "leading space"
      refute_includes error.message, "second"
    end
  end

  # The diagnostic names the document and the problem. Quoting either body would put generated
  # content into the run page and the operator's log.
  def test_the_collision_diagnostic_carries_neither_document_body
    conflicting = base_files.fetch(PackagePath::TECHNICAL_MD).sub("Technical analysis", "Technical analysis of")
    files = base_files.merge(" #{PackagePath::TECHNICAL_MD}" => conflicting)

    error = assert_raises(DocumentSet::Invalid) { DocumentSet.validate!(files, issue_key: ISSUE) }

    refute_includes error.message, "## Source entry points inspected"
    refute_includes error.message, "x" * 50
  end

  # Each required name in turn arrives ONLY as an alias. The content assertion is the point: the
  # document must survive under its canonical name, not merely be counted as present.
  def test_validate_accepts_an_alias_standing_in_for_each_required_document
    PackagePath::REQUIRED_FILES.each do |name|
      content = base_files.fetch(name)
      files = base_files.except(name).merge(" #{name}" => content)

      documents = DocumentSet.validate!(files, issue_key: ISSUE)

      assert_equal content, documents.files.fetch(name), "expected the alias of #{name} to keep its content"
      assert_equal PackagePath::REQUIRED_FILES.sort, documents.files.keys.sort
    end
  end

  # The OPTIONAL document resolves the same way, and is then held to its own existing rules —
  # read back through `#open_questions`, which only ever looks at the canonical name.
  def test_validate_resolves_an_open_questions_alias_and_still_parses_it
    files = base_files.merge(" #{PackagePath::OPEN_QUESTIONS_MD}" => open_questions_document)

    documents = DocumentSet.validate!(files, issue_key: ISSUE)

    assert_equal [ "OQ-001\nWhy it blocks: the recorded inputs do not decide this.\n" \
                  "Decision required: what happens on a second identical request?\n" \
                  "Consequence: an implementer must guess." ], documents.open_questions
  end

  # Resolution changes which keys are recognized, never what a valid document must contain.
  def test_validate_rejects_an_aliased_open_questions_document_with_a_malformed_question
    malformed = open_questions_document.sub("- Decision required: what happens on a second identical request?\n", "")
    files = base_files.merge(" #{PackagePath::OPEN_QUESTIONS_MD}" => malformed)

    error = assert_raises(DocumentSet::Invalid) { DocumentSet.validate!(files, issue_key: ISSUE) }

    assert_includes error.message, PackagePath::OPEN_QUESTIONS_MD
    assert_includes error.message, "missing required field(s): decision required"
  end

  # Content validation runs on the resolved document, and reports it under the CANONICAL name —
  # which is also how this proves the key was rewritten rather than tolerated.
  def test_validate_rejects_an_alias_whose_content_is_an_invalid_document
    files = base_files.except(PackagePath::TECHNICAL_MD).merge(" #{PackagePath::TECHNICAL_MD}" => "# too short")

    error = assert_raises(DocumentSet::Invalid) { DocumentSet.validate!(files, issue_key: ISSUE) }

    assert_includes error.message, PackagePath::TECHNICAL_MD
    assert_includes error.message, "too short"
  end

  # An alias is not a substitute for a document that is simply absent.
  def test_validate_still_rejects_a_missing_required_document
    error = assert_raises(DocumentSet::Invalid) do
      DocumentSet.validate!(base_files.except(PackagePath::BUSINESS_MD), issue_key: ISSUE)
    end

    assert_includes error.message, "returned no #{PackagePath::BUSINESS_MD}"
  end

  # The containment. Every one of these is one character away from a recognized alias and none of
  # them is recognized — which is what keeps this a fixed exception rather than a whitespace policy.
  def test_validate_rejects_every_spelling_that_is_not_the_single_leading_space
    [
      "  #{PackagePath::BUSINESS_MD}",
      "#{PackagePath::BUSINESS_MD} ",
      "\t#{PackagePath::BUSINESS_MD}",
      " #{PackagePath::BUSINESS_MD}",
      " Analysis/Business.md",
      " analysis/notes.md",
      " #{PackagePath::MANIFEST_JSON}"
    ].each do |name|
      error = assert_raises(DocumentSet::Invalid) do
        DocumentSet.validate!(base_files.merge(name => "x" * 500), issue_key: ISSUE)
      end

      assert_includes error.message, "unexpected files", "expected #{name.inspect} to stay rejected"
    end
  end

  # Unsafe shapes are rejected exactly as before, aliased or not: nothing here rewrites a path.
  def test_validate_rejects_absolute_traversing_and_backslash_names
    [ "/#{PackagePath::SPEC_MD}", " /#{PackagePath::SPEC_MD}", "../#{PackagePath::SPEC_MD}",
      " ../#{PackagePath::SPEC_MD}", "analysis\\business.md", " analysis\\business.md" ].each do |name|
      error = assert_raises(DocumentSet::Invalid) do
        DocumentSet.validate!(base_files.merge(name => "x" * 500), issue_key: ISSUE)
      end

      assert_includes error.message, "unexpected files", "expected #{name.inspect} to stay rejected"
    end
  end

  # A package with no alias in it behaves exactly as it always did.
  def test_a_canonical_package_is_unaffected
    documents = DocumentSet.validate!(base_files, issue_key: ISSUE)

    assert_equal PackagePath::REQUIRED_FILES, documents.each_file.to_a
    assert_empty documents.open_questions
  end
end
