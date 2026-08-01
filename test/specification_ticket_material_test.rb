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

  # ------------------------------------------------------------------ no fabrication

  # The CR's criterion 5: a ticket silent on repeat behaviour must get the open QUESTION and
  # not the criterion. The two used to be driven by different predicates, so one document
  # could require idempotency and then ask who would decide it.
  def test_a_silent_ticket_gets_the_open_question_and_no_invented_criterion
    spec = compose(:silent)["spec.md"]

    assert_includes spec, "What should happen when the operation is attempted a second time?"
    assert_includes spec, "What should the user see when the operation cannot complete?"
    refute_includes section(spec, "Acceptance criteria"), "idempotency"
    refute_includes section(spec, "Proposed behavior"), "idempotent"
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
