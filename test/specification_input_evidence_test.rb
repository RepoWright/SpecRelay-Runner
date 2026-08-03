# frozen_string_literal: true

require_relative "test_helper"

# Review 006, finding F2 — direct unit coverage for how `Composer` reports linked Jira issues in
# `analysis/input-evidence.md`.
#
# Before this correction, `Composer::CORE_INPUT_KINDS` categorically excluded `linked_issues`
# from this file on the same footing as the ticket's own description and comments. The controlled
# MAPIAI-52 package showed the failure that produced: `spec.md` said a linked issue was present
# and readable, while `analysis/input-evidence.md` said no supporting input beyond the core Jira
# fields existed at all — a linked issue disappeared from the one file whose whole job is to
# account for supporting evidence.
#
# Platform classifies the ENTIRE linked-issues collection as one entry (never one row per linked
# issue, see `Jira::SpecCreation::ClassifyInputs#collection_entry`), and its "available" verdict
# means only that Jira exposed the collection — never that this runner received any issue's own
# title, description, or acceptance criteria. So the honest report is never "analyzed"; it is
# either "nothing is linked" (silence, same as any other absent supporting input) or "something is
# linked, and here is the operational limitation on what this runner can say about it".
class SpecificationInputEvidenceTest < Minitest::Test
  Composer = SpecrelayRunner::Specification::Composer

  def test_a_present_linked_issues_collection_gets_an_honest_not_analyzed_entry
    package = compose(linked_issues_input(reason: "1 readable", used: true))

    entry = package.fetch("analysis/input-evidence.md")
    assert_includes entry, "## linked_issues"
    assert_includes entry, "- Status: not analyzed"
    assert_includes entry, "Jira reports 1 linked issue for SR-800"
    assert_includes entry, "- Limitation:"
    refute_includes entry, "Requirement implication"
  end

  def test_an_empty_linked_issues_collection_produces_no_entry_and_no_noise
    package = compose(linked_issues_input(reason: "0 readable", used: true))

    entry = package.fetch("analysis/input-evidence.md")
    refute_includes entry, "linked_issues"
    assert_includes entry, "No supporting input beyond the Jira ticket's own description and " \
                            "comments was recorded"
  end

  def test_an_unreadable_linked_issues_collection_gets_the_generic_operational_limitation
    package = compose(linked_issues_input(
                        reason: "Jira did not expose this field to the configured credential",
                        used: false,
                        note: "Platform classified this input as \"unavailable\", which is not usable evidence"
                      ))

    entry = package.fetch("analysis/input-evidence.md")
    assert_includes entry, "## linked_issues"
    assert_includes entry, "- Status: not analyzed"
    assert_includes entry, "- Limitation: this runner could not analyse it"
  end

  def test_the_generated_package_still_passes_document_set_validation_with_a_linked_issue_present
    package = compose(linked_issues_input(reason: "3 readable", used: true))

    assert SpecrelayRunner::Specification::DocumentSet.validate!(package)
  end

  # ------------------------------------------------------------------------ helpers

  def linked_issues_input(reason:, used:, note: "read from the rendered input bundle")
    { "kind" => "linked_issues", "name" => "Linked Jira issues", "read_status" => used ? "available" : "unavailable",
      "used" => used, "note" => note, "reason" => reason }
  end

  def compose(*extra_inputs)
    Composer.call(packet(extra_inputs))
  end

  def packet(extra_inputs)
    {
      "issue" => { "key" => "SR-800", "url" => "https://example.atlassian.net/browse/SR-800",
                   "title" => "Add an export button" },
      "input_bundle" => {
        "content_markdown" => "## Jira description\n\n```text\nAdd an export button to the report " \
                               "list so operators can download a CSV without asking engineering.\n```\n",
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
