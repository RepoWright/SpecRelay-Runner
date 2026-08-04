# frozen_string_literal: true

require_relative "test_helper"

# Review 006, finding F2 — direct unit coverage for how `Composer` reports linked Jira issues in
# `analysis/input-evidence.md`.
#
# The FIRST correction (round two) disclosed only that a linked issue's content had not been
# captured, while generation still succeeded — the second-pass review found that not fail-closed.
# The real fix is upstream, in Platform (`Jira::SpecCreation::EnrichLinkedIssues`/`ClassifyInputs`):
# an unreadable linked issue now blocks intake before a specification is ever generated, so by the
# time a bundle reaches this runner, every `linked_issue` entry it carries is one Platform actually
# read. This file proves what `Composer` does with that real content: genuine analysis, not a
# boilerplate limitation — plus a defensive fallback for the shape that should not reach
# generation at all.
class SpecificationInputEvidenceTest < Minitest::Test
  Composer = SpecrelayRunner::Specification::Composer

  def test_a_readable_linked_issue_gets_a_genuinely_analyzed_entry
    linked_markdown = linked_issue_section(key: "SR-750", title: "Style title in center", link_type: "blocks",
                                           status: "Open", body: "The reporter wants the heading centered on the page.")
    package = compose(linked_issue_input(key: "SR-750", title: "Style title in center"), linked_markdown)

    entry = package.fetch("analysis/input-evidence.md")
    assert_includes entry, "## linked_issue (SR-750 — Style title in center)"
    assert_includes entry, "- Status: analyzed"
    assert_includes entry, "The reporter wants the heading centered on the page."
    assert_includes entry, "- Requirement implication:"
    refute_includes entry, "Limitation"
  end

  def test_the_excerpt_is_the_first_paragraph_only_not_the_whole_linked_ticket
    long_body = "The first paragraph is the request.\n\n#{'Filler detail. ' * 60}"
    linked_markdown = linked_issue_section(key: "SR-750", title: "Style title in center", link_type: "blocks",
                                           status: "Open", body: long_body)
    package = compose(linked_issue_input(key: "SR-750", title: "Style title in center"), linked_markdown)

    entry = package.fetch("analysis/input-evidence.md")
    assert_includes entry, "The first paragraph is the request."
    refute_includes entry, "Filler detail."
  end

  def test_two_linked_issues_are_reported_independently
    linked_markdown = "## Linked Jira issues\n\n" \
                       "#{linked_issue_section(key: 'SR-750', title: 'Style title in center', link_type: 'blocks', status: 'Open', body: 'Center the heading.', wrap: false)}\n\n" \
                       "#{linked_issue_section(key: 'SR-751', title: 'Unrelated cleanup', link_type: 'relates to', status: 'Done', body: 'Tidy up the footer.', wrap: false)}\n"
    package = compose([ linked_issue_input(key: "SR-750", title: "Style title in center"),
                       linked_issue_input(key: "SR-751", title: "Unrelated cleanup") ], linked_markdown)

    entry = package.fetch("analysis/input-evidence.md")
    assert_includes entry, "Center the heading."
    assert_includes entry, "Tidy up the footer."
  end

  # Defensive only: Platform blocks intake before generation when a linked issue's content could
  # not be read (see the class comment above), so this shape should not reach a real run. The
  # composer still must not crash or fabricate content if it ever does.
  def test_a_linked_issue_with_no_captured_content_falls_back_to_the_operational_limitation
    package = compose(linked_issue_input(key: "SR-750", title: "Style title in center", used: false,
                                        note: "Jira did not expose this linked issue's content to " \
                                              "the configured credential"))

    entry = package.fetch("analysis/input-evidence.md")
    assert_includes entry, "## linked_issue (SR-750 — Style title in center)"
    assert_includes entry, "- Status: not analyzed"
    assert_includes entry, "- Limitation:"
    refute_includes entry, "Requirement implication"
  end

  def test_an_empty_linked_issues_collection_produces_no_entry_and_no_noise
    package = compose({ "kind" => "linked_issues", "name" => "Linked Jira issues", "read_status" => "available",
                        "used" => true, "note" => "read from the rendered input bundle",
                        "reason" => "0 readable" })

    entry = package.fetch("analysis/input-evidence.md")
    refute_includes entry, "linked_issue"
    assert_includes entry, "No supporting input beyond the Jira ticket's own description and " \
                            "comments was recorded"
  end

  def test_the_generated_package_still_passes_document_set_validation_with_a_linked_issue_present
    linked_markdown = linked_issue_section(key: "SR-750", title: "Style title in center", link_type: "blocks",
                                           status: "Open", body: "Center it.")
    package = compose(linked_issue_input(key: "SR-750", title: "Style title in center"), linked_markdown)

    assert SpecrelayRunner::Specification::DocumentSet.validate!(package, issue_key: "SR-800")
  end

  # ------------------------------------------------------------------------ helpers

  def linked_issue_input(key:, title:, used: true, note: "linked issue content read from Jira")
    { "kind" => "linked_issue", "name" => "#{key} — #{title}", "read_status" => used ? "available" : "unavailable",
      "used" => used, "note" => note, "reason" => note, "reference" => "https://example.atlassian.net/browse/#{key}" }
  end

  # `wrap: true` (the default) returns a complete "## Linked Jira issues" section for a single
  # issue; `wrap: false` returns just the "### KEY — TITLE" sub-block, for a caller assembling
  # several under one section heading itself.
  def linked_issue_section(key:, title:, link_type:, status:, body:, wrap: true)
    block = <<~MD.strip
      ### #{key} — #{title} (#{link_type}, #{status})

      ```text
      #{body}
      ```
    MD
    wrap ? "## Linked Jira issues\n\n#{block}\n" : block
  end

  # `extra_inputs` may be one input Hash or an Array of them — `Array()` on a Hash would
  # (wrongly) flatten it into key/value pairs, so the shapes are told apart explicitly.
  def compose(extra_inputs, linked_markdown = nil)
    inputs = extra_inputs.is_a?(Hash) ? [ extra_inputs ] : extra_inputs
    Composer.call(packet(inputs, linked_markdown))
  end

  def packet(extra_inputs, linked_markdown)
    description = "## Jira description\n\n```text\nAdd an export button to the report list so " \
                  "operators can download a CSV without asking engineering.\n```\n"
    {
      "issue" => { "key" => "SR-800", "url" => "https://example.atlassian.net/browse/SR-800",
                   "title" => "Add an export button" },
      "input_bundle" => {
        "content_markdown" => linked_markdown ? "#{description}\n#{linked_markdown}" : description,
        "trace_id" => "bundle_test", "url" => "",
        "inputs" => [ { "kind" => "description", "name" => "Jira description", "read_status" => "available",
                        "used" => true, "note" => "read from the rendered input bundle",
                        "reason" => "read from the Jira issue" } ] + extra_inputs,
        "warnings" => []
      },
      "source" => { "repository" => "tiny-demo-workspace", "entry_points" => [ "app/services/export_report.rb" ] },
      "package" => { "relative_path" => "specs/x" },
      "tool_evidence" => [ { "name" => "graphify", "usable" => true, "contributed" => true, "summary" => "graph FRESH" },
                           { "name" => "context_plus", "usable" => true, "contributed" => false,
                             "summary" => "not queried by this process" } ]
    }
  end
end
