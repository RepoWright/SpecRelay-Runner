# Specification-creation input bundle — MAPIAI-47

## Input completeness

Every expected input was readable.

## Issue

- Issue: [MAPIAI-47](https://finlink.atlassian.net/browse/MAPIAI-47) — [MVP-0026 REVIEW] Add a /healthz endpoint to the Tiny Demo app
- Jira status at capture: Ready for Spec Creation
- Reporter: Reza Mohseni
- Labels: (none)
- Components: (none)
- Captured at: 2026-08-01T08:42:14Z
- Bundle trace id: `bundle_ed2b20962554a010`

## Classified inputs

| Kind | Name | Read status | Media type | Size | Reference | Reason |
| --- | --- | --- | --- | --- | --- | --- |
| description | Jira description | available | — | — | — | read from the Jira issue |
| comments | Jira comments | available | — | — | — | 0 readable |
| linked_issues | Linked Jira issues | available | — | — | — | 0 readable |

## Specification repository target

- Host: github.com
- Owner: SpecRelay
- Repository: tiny-demo-runs
- Repository URL: https://github.com/SpecRelay/tiny-demo-runs
- Default branch: `main`
- Specification root: `specs`

## Jira description

```text
Reviewer-created verification fixture for SpecRelay MVP-0026 (runner specification generation), review round 002. Safe for the Product Owner to close or delete once the review is filed. It describes a real, implementable change to the Tiny Demo app in SpecRelay/tiny-demo-runs.

Problem

The Tiny Demo app (demo-app/server.mjs) answers only two paths. Anything that is not "/" or "/index.html" gets a 404 with the plain-text body "Not found". There is no way for an operator, a container orchestrator, or a smoke check to ask the process "are you up and serving?" without fetching the whole homepage and parsing HTML out of it. When a SpecRelay demo run starts the app we currently look at the log line it prints on boot, which tells us the listener bound but nothing about whether it can still answer a request.

What we want

Add a liveness endpoint at /healthz. A GET to /healthz responds 200 with content-type application/json; charset=utf-8 and the body {"status":"ok"}. It must not read demo-app/index.html — the point of the endpoint is to answer even if the homepage asset is missing or unreadable, so a failure to serve the homepage and a dead process stay distinguishable.

Edge cases that matter

Only GET is meaningful. A non-GET request to /healthz should not report "ok"; decide and state whether it 404s like every other unmatched path today or returns 405, and make that explicit rather than leaving it to whichever branch happens to catch it.

/healthz/ with a trailing slash, and /healthz?probe=1 with a query string, are the shapes a real probe sends. The current router compares request.url by exact string equality, so both would fall through to the 404 branch. Say which of these the endpoint must accept.

The 404 behaviour for every other unknown path must not change. Existing behaviour for "/" and "/index.html" must not change, and demo-app/test/homepage.test.mjs must keep passing untouched.

Acceptance criteria

# GET /healthz returns HTTP 200.
# The response content-type is application/json; charset=utf-8 and the body parses as JSON equal to {"status":"ok"}.
# The handler does not read index.html; the endpoint still answers 200 when demo-app/index.html is absent.
# GET / and GET /index.html still return 200 with the existing HTML, and the existing homepage test passes unchanged.
# An unknown path such as /nope still returns 404 with the plain-text body "Not found".
# A new test under demo-app/test/ starts the server on an ephemeral port, requests /healthz, and asserts the status code, the content-type, and the parsed body. It runs under the existing "node --test" setup with no new dependency.

Out of scope

No readiness or dependency checks (the app has no database and no downstream service). No metrics endpoint. No change to demo-app/index.html. No new npm dependency — demo-app/package.json must stay dependency-free.
```
