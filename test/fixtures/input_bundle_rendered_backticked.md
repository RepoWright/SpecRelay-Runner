# Specification-creation input bundle — SR-700

## Input completeness

Every expected input was readable.

## Issue

- Issue: [SR-700](https://example.atlassian.net/browse/SR-700) — Add an export button
- Jira status at capture: Ready for Spec
- Reporter: Dana Reporter
- Labels: spec-lane
- Components: platform
- Captured at: 2026-07-31T12:00:00Z
- Bundle trace id: `bundle_3b4b76c63f3ca617`

## Classified inputs

| Kind | Name | Read status | Media type | Size | Reference | Reason |
| --- | --- | --- | --- | --- | --- | --- |
| description | Jira description | available | — | — | — | read from the Jira issue |
| comments | Jira comments | available | — | — | — | 0 readable |
| linked_issues | Linked Jira issues | available | — | — | — | 0 readable |

## Specification repository target

- Host: github.com
- Owner: SpecRelay
- Repository: SpecRelay-Specs
- Repository URL: https://github.com/SpecRelay/SpecRelay-Specs
- Default branch: `main`
- Specification root: `specs`

## Jira description

````text
Reporting analysts need to take the weekly report out of the app and into a
spreadsheet. Today they retype it by hand.

The current export helper looks like this:

```ruby
def export(rows)
  rows.map { |row| row.join(",") }
end
```

Add a way to export the report the analysts already look at.
````
