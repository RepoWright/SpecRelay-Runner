# frozen_string_literal: true

require_relative "test_helper"

# MVP-0026 CR-002 must-fix 1 — the generated specification must be ABOUT THE TICKET.
#
# Round 002 shipped six of the nine required sections as fixed literal strings with the issue
# key interpolated. Two packages for two different tickets were byte-identical in those
# sections, a ticket stating six acceptance criteria produced a document containing none of
# them, and the document asserted an idempotency requirement for a stateless read-only probe.
#
# Every fixture here is the text of a REAL Jira ticket, captured from the real bundle renderer:
#
#   MAPIAI-47  numbered criteria (ADF `#` markers), "Out of scope" as one paragraph
#   MAPIAI-48  bulleted criteria (ADF `*` markers), "Non-goals" as four paragraphs
#
# Two real tickets rather than one, because the property that matters most — that two tickets
# produce two different documents — cannot be asserted with a single fixture, and that is
# exactly why the old suite could not fail.
class SpecificationTicketMaterialTest < Minitest::Test
  ENTRY_POINTS = %w[demo-app/server.mjs demo-app/index.html demo-app/package.json
                    demo-app/test/homepage.test.mjs].freeze

  # ------------------------------------------------------- the ticket's own criteria

  def test_the_tickets_own_numbered_acceptance_criteria_are_reproduced_verbatim
    spec = compose(:healthz)["spec.md"]
    criteria = section(spec, "Acceptance criteria")

    [ "GET /healthz returns HTTP 200.",
      "The response content-type is application/json; charset=utf-8",
      "The handler does not read index.html",
      "GET / and GET /index.html still return 200",
      "An unknown path such as /nope still returns 404",
      "starts the server on an ephemeral port" ].each do |stated|
      assert_includes criteria, stated
    end
    # The fabricated one, named by the CR, must be gone.
    refute_includes spec, "Repeating the same request produces no second effect"
  end

  def test_the_tickets_own_bulleted_acceptance_criteria_are_reproduced_verbatim
    criteria = section(compose(:version)["spec.md"], "Acceptance criteria")

    [ "GET /version returns 200 with content-type application/json",
      "inside an element with id \"app-version\"",
      "The version is read once when the process starts",
      "the server still starts, /version returns 200 with \"version\": \"unknown\"" ].each do |stated|
      assert_includes criteria, stated
    end
  end

  # An ADF ordered list arrives as `#` per item, which is a level-1 heading in Markdown.
  # Reproducing those verbatim would destroy the generated document's outline.
  def test_adf_ordered_markers_become_real_markdown_numbers
    criteria = section(compose(:healthz)["spec.md"], "Acceptance criteria")

    assert_includes criteria, "1. GET /healthz returns HTTP 200."
    assert_includes criteria, "6. A new test under demo-app/test/"
    refute_match(/^# GET \/healthz/, criteria)
  end

  # --------------------------------------------------------------- non-goals and problem

  def test_the_tickets_own_out_of_scope_items_are_reproduced
    non_goals = section(compose(:healthz)["spec.md"], "Non-goals")

    [ "No readiness or dependency checks", "No metrics endpoint",
      "No change to demo-app/index.html", "No new npm dependency" ].each do |stated|
      assert_includes non_goals, stated
    end
  end

  def test_a_tickets_non_goals_heading_is_found_under_either_name
    non_goals = section(compose(:version)["spec.md"], "Non-goals")

    assert_includes non_goals, "No build-time or git-derived version string"
    assert_includes non_goals, "No version history, no changelog"
    assert_includes non_goals, "demo-app/package.json must stay dependency-free"
  end

  # The Problem section must be the ticket's Problem, not its first paragraph. Both real
  # tickets open with an administrative preamble, which is what the old rule quoted.
  def test_the_problem_quotes_the_problem_section_not_the_first_paragraph
    problem = section(compose(:healthz)["spec.md"], "Problem")

    assert_includes problem, "> The Tiny Demo app (demo-app/server.mjs) answers only two paths."
    refute_includes problem, "Reviewer-created verification fixture"
  end

  # ------------------------------------------------- CR-003 must-fix 1: no derived requirements

  # THE regression. On the real Bug MAPIAI-49 the only match for any repeat keyword in the whole
  # description is the word "again", in "a following request to / succeeds once the file is
  # readable again" — a sentence about a file becoming readable. Round 003 turned that into four
  # statements across two documents instructing an implementer to build and test idempotency for
  # a stateless GET handler, attributed to the reporter.
  def test_the_word_again_in_readable_again_does_not_produce_an_idempotency_requirement
    package = compose(:failed_read)
    spec = package["spec.md"]
    technical = package["analysis/technical.md"]

    assert_includes spec, "readable again", "the fixture must still contain the phrase that misfired"
    refute_includes spec, "the ticket calls for idempotent behaviour"
    refute_includes spec, "Evidence that the idempotency criterion holds"
    refute_includes spec, "idempotency"
    refute_includes technical, "Make the operation idempotent"
    refute_includes technical, "An idempotency test"
    refute_includes technical, "idempotent"
  end

  # ------------------------------- CR-004 must-fix 1: an open question stops characterising the ticket
  #
  # These three replace the round-003 pair that pinned the keyword predicates. That pair could
  # not fail on the defect that shipped, because both of its "positive branch" assertions were
  # `assert_includes` over text the predicates produced either way.
  #
  # The chosen correction, of the two CR-004 offered: a ticket that supplies its own acceptance
  # criteria raises NEITHER standing question, and the predicates are deleted rather than
  # reworded. So the property under test is no longer "does the word list fire" — it is "does
  # the document ever tell the reader what the reporter's criteria do not cover".

  # CR-004 must-fix 1 criterion 1. The exact string round 004 shipped, over every document of
  # every real fixture — not just the section it appeared in, because it appeared in two.
  def test_no_document_asserts_that_the_tickets_criteria_omit_something
    %i[healthz version failed_read silent].each do |ticket|
      package = compose(ticket)
      %w[spec.md analysis/technical.md analysis/business.md].each do |name|
        refute_includes package[name], "No stated criterion covers", "#{ticket} #{name}"
      end
    end
  end

  # CR-004 must-fix 1 criterion 2 — the regression that shipped it. `MAPIAI-49` criterion c)
  # states repeat behaviour outright ("a following request to /nope still returns 404"), and it
  # does so without using any of the nine words the deleted predicate matched: not "repeat", not
  # "twice", not "idempotent". Round 004 therefore asserted on the same page as the reproduced
  # criterion that no criterion covered it.
  #
  # The assertion is `refute`, deliberately. The old test asserted the question was PRESENT for
  # this fixture, which is why the word list could have been empty without any test noticing.
  def test_a_ticket_whose_criteria_state_repeat_behaviour_in_their_own_words_raises_no_repeat_question
    package = compose(:failed_read)

    assert_includes package["spec.md"], "a following request to /nope still returns 404",
                    "fixture drift: this test is meaningless unless the criterion is reproduced"
    refute package.key?("analysis/open-questions.md"),
          "a ticket whose criteria decide repeat behaviour must raise no open question at all"
  end

  # CR-004 must-fix 1 criterion 3. `MAPIAI-48`'s criterion decides the failure path in full —
  # missing file, missing key, 200, `"version": "unknown"`, the homepage — using none of the
  # twelve words the deleted failure predicate matched. Round 004 called it unspecified twice.
  def test_a_ticket_whose_criteria_decide_the_failure_path_is_not_told_the_failure_path_is_unspecified
    package = compose(:version)

    assert_includes package["spec.md"], "still starts",
                    "fixture drift: the failure-path criterion must be reproduced"
    # A ticket whose criteria decide everything raises no standing question at all — MVP-0028
    # remediation, defect 3 moved open questions into their own file, omitted entirely when empty.
    refute package.key?("analysis/open-questions.md")
  end

  # The other half of the choice: where the ticket really is silent, both questions stand. Without
  # this, deleting `standing_decision_questions` altogether would pass everything above.
  def test_a_ticket_with_no_criteria_still_raises_both_standing_questions
    questions = compose(:silent)["analysis/open-questions.md"]

    assert_includes questions, "attempted a second time"
    assert_includes questions, "cannot complete"
    assert_includes questions, "This generation found no stated decision for it"
  end

  # The empty state (no file at all) must be reached only by a ticket that decided its own
  # criteria — not by a generation that simply declined to look for what is undecided.
  def test_the_empty_open_questions_state_points_at_the_tickets_own_criteria
    package = compose(:failed_read)

    refute package.key?("analysis/open-questions.md"),
          "a ticket with its own stated criteria must not get standing open questions"
    assert_includes section(package["spec.md"], "Acceptance criteria"), "are authoritative",
                    "the fixture must actually state its own criteria for the omission to mean anything"
  end

  # …and it must be ONE bullet. `DocumentSet#open_questions` parses this section back out for
  # Platform and treats each bullet as a question, skipping only a leading "none" — so the first
  # draft of the fix above put a second, perfectly true bullet on the run page under the heading
  # "Open questions raised by the specification". Caught in the live browser pass, not by a test,
  # which is why this one exists: it asserts through the same reader Platform uses.
  def test_an_empty_open_questions_section_reports_no_questions_to_platform
    %i[healthz version failed_read].each do |ticket|
      documents = SpecrelayRunner::Specification::DocumentSet.new(compose(ticket))

      assert_empty documents.open_questions,
                   "#{ticket}: the empty state must not reach Platform as a question"
    end
  end

  # CR-004 should-fix 5 criterion 1. `standing_criteria` appends a third bullet whenever an open
  # question survives, so the hardcoded "Two conditions" in the preamble was wrong in both
  # committed packages — three bullets under a sentence promising two. Asserted for every
  # fixture, in both the stated-criteria and derived-criteria shapes, so neither branch can
  # reintroduce a count.
  NUMBER_WORDS = %w[One Two Three Four Five one two three four five].freeze

  def test_the_acceptance_criteria_preamble_never_promises_a_count_the_bullets_contradict
    %i[healthz version failed_read silent].each do |ticket|
      criteria = section(compose(ticket)["spec.md"], "Acceptance criteria")
      preamble = criteria.split(/^- /).first.to_s
      bullets = criteria.scan(/^- /).length

      NUMBER_WORDS.each do |word|
        refute_match(/\b#{word} conditions?\b/, preamble,
                     "#{ticket}: preamble promises \"#{word}\" above #{bullets} bullets")
      end
    end
  end

  # CR-003 must-fix 1 criterion 5: refute over the WHOLE document, not one section.
  def test_no_real_ticket_produces_a_fabricated_repeat_requirement_anywhere
    %i[healthz version failed_read].each do |ticket|
      package = compose(ticket)
      %w[spec.md analysis/technical.md analysis/business.md].each do |name|
        refute_includes package[name], "Repeating the same request produces no second effect",
                        "#{ticket} #{name}"
        refute_includes package[name], "the ticket calls for", "#{ticket} #{name}"
        refute_includes package[name], "which the ticket asks for", "#{ticket} #{name}"
      end
    end
  end

  # ------------------------------------- CR-003 must-fix 1 part 2: three sections stop being literal

  def test_outcome_differs_between_two_real_tickets
    a = section(compose(:version)["spec.md"], "Outcome").gsub("MAPIAI-48", "KEY")
    b = section(compose(:failed_read)["spec.md"], "Outcome").gsub("MAPIAI-49", "KEY")

    refute_equal a, b, "## Outcome is identical for two differently-shaped real tickets"
  end

  # The ticket's own goal material where it has some — MAPIAI-48's "What we want".
  def test_outcome_reproduces_the_tickets_own_goal_section_when_it_has_one
    outcome = section(compose(:version)["spec.md"], "Outcome")

    assert_includes outcome, "From the ticket's own \"What we want\" section, verbatim"
    assert_includes outcome, "> Serve a version string in two places"
  end

  # And says so, briefly and without inventing bullets, where it has none — MAPIAI-49.
  def test_outcome_says_the_ticket_states_none_rather_than_inventing_one
    outcome = section(compose(:failed_read)["spec.md"], "Outcome")

    assert_includes outcome, "states no outcome section of its own"
    refute_includes outcome, "Concretely:"
    refute_includes outcome, "partially approximated"
  end

  # The choice CR-003 must-fix 1 part 2 criterion 2 asks to be stated: this section's bullets are
  # UNIVERSALLY TRUE of validating any change, rather than ticket-specific. Naming the choice in
  # the test is the requirement.
  def test_validation_expectations_are_universally_true_rather_than_ticket_specific
    %i[healthz version failed_read].each do |ticket|
      expectations = section(compose(ticket)["spec.md"], "Validation expectations")

      refute_includes expectations, "idempotency", ticket.to_s
      assert_includes expectations, "existing full validation", ticket.to_s
      assert_includes expectations, "Evidence for each criterion the ticket itself states", ticket.to_s
    end
  end

  def test_a_ticket_with_its_own_criteria_gets_no_derived_numbered_lists
    spec = compose(:failed_read)["spec.md"]

    refute_includes section(spec, "Acceptance criteria"), "DERIVED by this generation"
    refute_includes section(spec, "Proposed behavior"), "DERIVED by this generation, and to be confirmed"
    assert_includes section(spec, "Acceptance criteria"), "adds no numbered criteria of its own"
  end

  # ------------------------------------------- CR-003 should-fix 2: cross-references must resolve

  # BOTH analyses, not just the technical one. The review found the dangling references in
  # `analysis/technical.md`; `analysis/business.md` had six of its own, one of them justifying
  # the very fabrication must-fix 1 removes ("Criterion 2 (idempotency) is not in the ticket. It
  # is included because…"). Fixing only the file the review named would have left that standing.
  def test_neither_analysis_cites_a_criterion_number_the_specification_lacks
    %i[healthz version failed_read].each do |ticket|
      package = compose(ticket)
      present = package["spec.md"].scan(/^\s*(\d+)\.\s/).flatten.uniq

      %w[analysis/technical.md analysis/business.md].each do |name|
        cited = package[name].scan(/criterion (\d+)/i).flatten.uniq
        dangling = cited - present

        assert_empty dangling, "#{ticket}: #{name} cites criterion #{dangling.join(', ')}, " \
                               "which spec.md does not number"
      end
    end
  end

  def test_the_business_analysis_does_not_justify_an_invented_idempotency_criterion
    business = compose(:failed_read)["analysis/business.md"]

    refute_includes business, "idempotency"
    assert_includes business, "The criteria are the reporter's own"
  end

  # ------------------------------------------------ CR-003 should-fix 3: exclusions are not inclusions

  # MAPIAI-49's only `\bpage\b` is inside its own "Out of scope": "not about the page content".
  # Word boundaries did not fix this, because the matching mode was never the problem.
  def test_a_ui_keyword_inside_out_of_scope_does_not_make_a_ticket_user_facing
    surface = section(compose(:failed_read)["analysis/technical.md"], "Implementation surface")

    assert_includes compose(:failed_read)["spec.md"], "not about the page content",
                    "the fixture must still contain the excluded keyword"
    refute_includes surface, "| UI | Likely"
  end

  # ------------------------------------------------------------------ no fabrication

  # The CR's criterion 5: a ticket silent on repeat behaviour must get the open QUESTION and
  # not the criterion. The two used to be driven by different predicates, so one document
  # could require idempotency and then ask who would decide it.
  def test_a_silent_ticket_gets_the_open_question_and_no_invented_criterion
    package = compose(:silent)

    assert_includes package["analysis/open-questions.md"],
                    "What should happen when the operation is attempted a second time?"
    assert_includes package["analysis/open-questions.md"],
                    "What should the user see when the operation cannot complete?"
    refute_includes section(package["spec.md"], "Acceptance criteria"), "idempotency"
    refute_includes section(package["spec.md"], "Proposed behavior"), "idempotent"
  end

  def test_a_ticket_with_no_criteria_says_its_criteria_are_derived
    criteria = section(compose(:silent)["spec.md"], "Acceptance criteria")

    assert_includes criteria, "The ticket states no acceptance criteria"
    assert_includes criteria, "DERIVED"
    assert_includes criteria, "must be confirmed by the product owner"
  end

  # The CR's criterion 6, and the assertion the old suite could not fail.
  def test_two_real_tickets_produce_materially_different_sections
    healthz = compose(:healthz)["spec.md"]
    version = compose(:version)["spec.md"]

    %w[Acceptance\ criteria Non-goals].each do |name|
      a = section(healthz, name).gsub("MAPIAI-47", "KEY").gsub("tiny-demo-workspace", "REPO")
      b = section(version, name).gsub("MAPIAI-48", "KEY").gsub("tiny-demo-workspace", "REPO")

      refute_equal a, b, "## #{name} is identical for two different tickets"
    end
  end

  # ----------------------------------------------------------------- must-fix 2, document half

  def test_a_generation_that_read_no_source_does_not_claim_it_did
    spec = compose(:version, entry_points: [])["spec.md"]

    refute_includes spec, "read-only inspection of the source checkout"
    refute_includes spec, "which this specification was written against"
    assert_includes spec, "No source was inspected"
    assert_includes spec, "no source file in the `tiny-demo-workspace` checkout could be read"
  end

  def test_a_generation_that_read_source_still_says_so
    spec = compose(:version)["spec.md"]

    assert_includes spec, "read-only inspection of the source checkout"
    assert_includes spec, "which this specification was written against"
    refute_includes spec, "No source was inspected"
  end

  # ------------------------------------------------------------------- should-fix 6

  # `include?` matched `page` inside "homepage", `ui` inside "distinguishable" and `view`
  # inside "REVIEW" — three coincidences in one real ticket, producing `UI | Likely` for a
  # JSON endpoint with no user interface.
  def test_the_user_facing_heuristic_uses_word_boundaries
    technical = compose(:healthz)["analysis/technical.md"]
    surface = section(technical, "Implementation surface")

    assert_includes surface, "| UI | Not implied by the recorded inputs. |"
  end

  def test_the_user_facing_heuristic_still_fires_on_a_real_ui_ticket
    surface = section(compose(:version)["analysis/technical.md"], "Implementation surface")

    assert_includes surface, "| UI | Likely"
  end

  # ------------------- CR-005 must-fix 1: a heading is not a decision either
  #
  # Round 005 stopped the document asserting what the reporter's criteria FAIL to cover. It then
  # asserted that whatever they do cover is sufficient — gated on `acceptance_criteria?`, which is
  # true for any non-empty body under the heading. Review-004's Finding 1 with the sign reversed,
  # and the same mechanism one level out: a keyword no longer decides whether the reporter made a
  # decision, but the presence of a heading did.

  # Criterion 1. Scoped to the CLAIM, not the bare word: "The authoritative bundle record is
  # trace …" is a different and correct use of it, about the Platform record rather than about
  # the reporter's criteria. `are authoritative` is the criteria claim, and criterion 5 below
  # asserts the same string is still present for a real ticket.
  def test_a_placeholder_criteria_section_is_never_called_authoritative
    PLACEHOLDER_CRITERIA.each do |body, shape|
      package = placeholder_package(body)
      %w[spec.md analysis/technical.md analysis/business.md].each do |name|
        refute_includes package[name], "are authoritative", "#{shape}: #{name}"
        refute_includes package[name], "the reporter's criteria and", "#{shape}: #{name}"
      end
    end
  end

  # Criterion 2 — refute over all three documents, not one section, because round 005's claim
  # appeared in two places.
  def test_a_placeholder_criteria_section_is_never_said_to_decide_the_rest
    PLACEHOLDER_CRITERIA.each do |body, shape|
      package = placeholder_package(body)
      %w[spec.md analysis/technical.md analysis/business.md].each do |name|
        refute_includes package[name], "is decided by the ticket's own", "#{shape}: #{name}"
        refute_includes package[name], "anything this specification does not decide", "#{shape}: #{name}"
      end
    end
  end

  # Criterion 3. The fix must not start hiding the reporter's text — that half of round 005 was
  # right, and losing it would be a worse defect than the one being fixed.
  def test_a_placeholder_criteria_section_is_still_reproduced_verbatim
    PLACEHOLDER_CRITERIA.each_key do |body|
      criteria = section(placeholder_package(body)["spec.md"], "Acceptance criteria")

      assert_includes criteria, body.sub(/\A\* /, ""), "the reporter's own words must survive"
      assert_includes criteria, "From the ticket's own", "and must still be attributed"
    end
  end

  # Criterion 4, through the reader Platform actually uses. This is the one that decides whether
  # the run page shows an operator that something is undecided.
  def test_a_placeholder_criteria_section_reports_open_questions_to_platform
    PLACEHOLDER_CRITERIA.each do |body, shape|
      documents = SpecrelayRunner::Specification::DocumentSet.new(placeholder_package(body))

      refute_empty documents.open_questions, "#{shape}: Platform must be told something is undecided"
    end
  end

  # Criterion 5 — the counterweight, and the one that matters. Round 005's behaviour on the two
  # REAL tickets must be exactly unchanged. If this fails, the predicate is too strict and the
  # fix has re-broken what rounds 004 and 005 established.
  def test_real_criteria_are_unaffected_by_the_placeholder_gate
    %i[healthz version failed_read].each do |ticket|
      package = compose(ticket)
      documents = SpecrelayRunner::Specification::DocumentSet.new(package)

      assert_empty documents.open_questions, "#{ticket}: a real ticket raises no standing question"
      assert_includes package["spec.md"], "are authoritative", "#{ticket}: real criteria stay authoritative"
      refute package.key?("analysis/open-questions.md"), "#{ticket}: no standing question means no file at all"
      %w[spec.md analysis/technical.md analysis/business.md].each do |name|
        refute_includes package[name], "No stated criterion covers", "#{ticket} #{name}"
      end
    end
  end

  # Criterion 6 — the negative direction. Without this, a predicate returning false for
  # everything passes criteria 1-4, and a real ticket that writes one prose criterion instead of
  # a list would be told its own criteria are not criteria.
  def test_a_real_criterion_written_as_one_sentence_still_counts_as_stated
    package = placeholder_package(UNUSUAL_REAL_CRITERION)
    documents = SpecrelayRunner::Specification::DocumentSet.new(package)

    assert_includes package["spec.md"], "are authoritative"
    assert_empty documents.open_questions
  end

  # -------------------------------- CR-005 should-fix 9: the same miscount, a fifth time
  #
  # Four instances in two rounds, all the same defect — prose stating a count of something a list
  # or a conditional generates:
  #
  #   review-004 F6   "Two conditions" above three bullets            (generated document)
  #   review-004 F7   "Three sections" above a four-row table         (README)
  #   CR-004 SF5      the same "Two conditions", at the root          (generated document)
  #   review-005 F9   "nine UI words" above a list of ten             (README)
  #
  # Round 005 pinned the generated-document half with
  # `test_the_acceptance_criteria_preamble_never_promises_a_count_the_bullets_contradict`. The
  # README had no equivalent guard, so the fourth instance arrived in the very edit that closed
  # the third. CR-005 asks how a fifth gets caught; this is the answer, and it is a test rather
  # than a convention because "we were careful" is what produced instances two and four.
  #
  # The rule enforced is the conclusion CR-004 should-fix 5 already reached for generated prose:
  # do not write a count that something else generates. Applied to the README's own sentences.
  COUNTABLE_NOUNS = %w[sections conditions words criteria bullets rows items keywords predicates
                       questions documents fixtures].freeze

  def test_the_runner_readme_states_no_count_of_a_generated_list
    readme = File.read(File.expand_path("../README.md", __dir__))
    offenders = readme.lines.each_with_index.filter_map do |line, index|
      next if line.start_with?("|")  # tables enumerate their own rows; the reader can count them

      match = line.match(/\b(#{NUMBER_WORDS.join('|')})\s+(#{COUNTABLE_NOUNS.join('|')})\b/i)
      "README.md:#{index + 1}: \"#{match[0]}\"" if match
    end

    assert_empty offenders,
                 "a count in prose drifts the moment the thing it counts changes — say " \
                 "\"a list of\" instead:\n#{offenders.join("\n")}"
  end

  # ------------------------------------------------------------------------ helpers

  # A packet carrying the REAL rendered bundle for one of the two real tickets.
  def compose(ticket, entry_points: ENTRY_POINTS)
    SpecrelayRunner::Specification::Composer.call(packet(ticket, entry_points))
  end

  def packet(ticket, entry_points)
    {
      "issue" => { "key" => TICKETS.fetch(ticket)[:key], "url" => TICKETS.fetch(ticket)[:url],
                   "title" => TICKETS.fetch(ticket)[:title] },
      "input_bundle" => {
        "content_markdown" => bundle_markdown(ticket), "trace_id" => "bundle_test", "url" => "",
        "inputs" => [ { "kind" => "description", "name" => "Jira description",
                        "read_status" => "available", "used" => true, "note" => "read from the ticket" } ],
        "warnings" => []
      },
      "source" => { "repository" => "tiny-demo-workspace", "entry_points" => entry_points },
      "package" => { "relative_path" => "specs/x" },
      "tool_evidence" => [ { "name" => "graphify", "usable" => true, "contributed" => true,
                             "summary" => "graph FRESH" },
                           { "name" => "context_plus", "usable" => true, "contributed" => false,
                             "summary" => "not queried by this process" } ]
    }
  end

  TICKETS = {
    healthz: { key: "MAPIAI-47", url: "https://finlink.atlassian.net/browse/MAPIAI-47",
               title: "Add a /healthz endpoint to the Tiny Demo app", fixture: "jira_ticket_healthz.md" },
    version: { key: "MAPIAI-48", url: "https://finlink.atlassian.net/browse/MAPIAI-48",
               title: "Show the running app version on the Tiny Demo homepage and at /version",
               fixture: "jira_ticket_version.md" },
    # The real Bug from review round 003. Lettered `a)`–`f)` criteria under a
    # "Definition of done" heading, four paragraph-shaped exclusions, a "Notes" section, no
    # outcome section — and the word "again" appearing exactly once, in "readable again".
    failed_read: { key: "MAPIAI-49", url: "https://finlink.atlassian.net/browse/MAPIAI-49",
                   title: "Tiny Demo app dies when index.html cannot be read",
                   fixture: "jira_ticket_failed_read.md" },
    # A ticket with no headings and no lists at all — the shape the derived path exists for.
    silent: { key: "MAPIAI-49", url: "https://finlink.atlassian.net/browse/MAPIAI-49",
              title: "Sort the run list newest first", fixture: nil }
  }.freeze

  SILENT_DESCRIPTION = "The run list is ordered oldest first, which puts the run somebody just " \
                       "started at the bottom of a long list. Order it newest first."

  def bundle_markdown(ticket)
    fixture = TICKETS.fetch(ticket)[:fixture]
    return rendered_bundle(TICKETS.fetch(ticket)[:key], SILENT_DESCRIPTION) if fixture.nil?

    File.read(File.expand_path("fixtures/#{fixture}", __dir__))
  end

  # CR-005 must-fix 1, and the test-double gap the CR named: every fixture here was either a
  # ticket with well-formed criteria or a ticket with no criteria section at all. The third
  # shape — a section that EXISTS and says nothing checkable — was never exercised, which is why
  # round 005's heading-presence gate shipped.
  #
  # The four bodies are the ones CR-005 executed against the round-005 build, where 4 of 4
  # asserted the criteria were authoritative and 4 of 4 raised zero open questions.
  PLACEHOLDER_CRITERIA = {
    "TBD." => "a bare marker",
    "See the linked Confluence page." => "a pointer somewhere else",
    "To be agreed with the product owner." => "an explicit deferral",
    "* It works." => "a list item carrying no checkable statement"
  }.freeze

  # A real single criterion, written as one prose sentence rather than a list — CR-005 must-fix 1
  # criterion 6. The predicate must not simply return false for everything that is not a
  # six-item list, or criteria 1-4 pass for the wrong reason.
  UNUSUAL_REAL_CRITERION =
    "A GET of /version returns 200 with the JSON body {\"version\": \"0.1.0\"} and the homepage " \
    "shows that same string inside the element with id app-version."

  def placeholder_package(body)
    packet = packet(:silent, ENTRY_POINTS)
    packet["input_bundle"]["content_markdown"] =
      rendered_bundle("MAPIAI-50", "#{SILENT_DESCRIPTION}\n\nAcceptance criteria\n\n#{body}")
    SpecrelayRunner::Specification::Composer.call(packet)
  end

  # The bundle wrapper around a description, in the shape the real renderer produces.
  def rendered_bundle(key, description)
    <<~MD
      # Specification-creation input bundle — #{key}

      ## Input completeness

      Every expected input was readable.

      ## Jira description

      ```text
      #{description}
      ```
    MD
  end

  def section(document, name)
    document[/^## #{Regexp.escape(name)}$\n(.*?)(?=^## |\z)/m, 1].to_s
  end
end
