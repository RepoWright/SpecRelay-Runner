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
