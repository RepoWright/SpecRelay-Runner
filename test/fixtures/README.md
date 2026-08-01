# Captured fixtures

Files here are **verbatim output of real SpecRelay code**, not hand-written approximations of
it. Each one exists because a hand-written stand-in was tidier than the thing it stood in for
and hid a defect the unit suite therefore could not see.

Do not edit them by hand. Re-capture them.

## `input_bundle_rendered.md`, `input_bundle_rendered_backticked.md`

Platform's `Jira::SpecCreation::Markdown.render` output for a complete specification-creation
input bundle. The runner is Rails-free and cannot call that renderer, so the capture is
committed and the composer is tested against it.

The `_backticked` variant is the same bundle with a Jira description that contains its own
fenced code block. The renderer lengthens the description fence to four backticks for it —
which is the case that broke every generated `spec.md` in round 001, and the reason a second
capture exists rather than a hand-edited copy of the first.

To re-capture, from a running task environment with the Platform container up:

```ruby
# bin/rails runner - < this-script, inside the Platform container
configuration = SpecLaneConfiguration.first
jira = SpecRelay::Integrations::Jira
issue = jira::Issue.new(
  issue_key: "SR-700", issue_url: "https://example.atlassian.net/browse/SR-700",
  title: "Add an export button", status: "Ready for Spec", description: DESCRIPTION,
  reporter: "Dana Reporter", labels: %w[spec-lane], components: %w[platform],
  created_at: "2026-07-19T09:00:00.000+0000", updated_at: "2026-07-19T09:30:00.000+0000"
)
detail = jira::IssueDetail.new(
  issue: issue, attachments: [], comments: [], linked_issues: [], custom_fields: {},
  references: [], comments_retrieval_status: jira::IssueDetail::READABLE,
  links_retrieval_status: jira::IssueDetail::READABLE
)
bundle = Jira::SpecCreation::InputBundle.build(
  detail: detail, configuration: configuration, captured_at: Time.utc(2026, 7, 31, 12, 0, 0)
)
puts Jira::SpecCreation::Markdown.render(bundle)
```

`DESCRIPTION` is the plain reporter text for the first fixture; for the second it is the same
text with a ```` ```ruby ```` block in the middle.

## `jira_ticket_healthz.md`, `jira_ticket_version.md`

The rendered input bundles for two **real Jira tickets**, captured from the real Platform
after a real intake pass:

| Fixture | Ticket | Shape |
|---|---|---|
| `jira_ticket_healthz.md` | [`MAPIAI-47`](https://finlink.atlassian.net/browse/MAPIAI-47) | numbered acceptance criteria (ADF `#` markers), `Out of scope` as one paragraph |
| `jira_ticket_version.md` | [`MAPIAI-48`](https://finlink.atlassian.net/browse/MAPIAI-48) | bulleted acceptance criteria (ADF `*` markers), `Non-goals` as four paragraphs |

Two rather than one, deliberately. The property that matters most for the composer — that two
different tickets produce two different documents — cannot be asserted with a single fixture,
and its absence is why a round shipped in which six of nine sections were fixed strings.

They are real Jira text because the two defects CR-002 raised were both invisible against
synthetic tickets: an invented description has the shape you imagined, and both real ones
turned out to open with an administrative preamble, mark lists in ways Markdown does not, and
name their exclusions under two different headings.

To re-capture, after a real intake pass:

```ruby
run = Run.joins(:work_item).find_by(work_items: { external_id: "MAPIAI-48" })
print run.spec_creation_input_bundle.content
```
