# Specification-creation input bundle — MAPIAI-48

## Input completeness

Every expected input was readable.

## Issue

- Issue: [MAPIAI-48](https://finlink.atlassian.net/browse/MAPIAI-48) — Show the running app version on the Tiny Demo homepage and at /version
- Jira status at capture: Ready for Spec Creation
- Reporter: Reza Mohseni
- Labels: (none)
- Components: (none)
- Captured at: 2026-08-01T09:23:55Z
- Bundle trace id: `bundle_f4136909f67d7dc5`

## Classified inputs

| Kind | Name | Read status | Media type | Size | Reference | Reason |
| --- | --- | --- | --- | --- | --- | --- |
| description | Jira description | available | — | — | — | read from the Jira issue |
| comments | Jira comments | available | — | — | — | 0 readable |
| linked_issues | Linked Jira issues | available | — | — | — | 0 readable |

## Specification repository target

- Host: github.com
- Owner: SpecRelay
- Repository: tiny-demo-workspace
- Repository URL: https://github.com/SpecRelay/tiny-demo-workspace
- Default branch: `main`
- Specification root: `specs`

## Jira description

```text
Real change request for the Tiny Demo app in SpecRelay/tiny-demo-workspace, raised while verifying SpecRelay MVP-0026 (runner specification generation), round 003. Safe for the Product Owner to close or delete once the round is filed.

Problem

A SpecRelay demo run changes demo-app/index.html and then somebody opens http://127.0.0.1:5173 to see the result. Nothing on the page or in the response says which build is being served, so a stale browser cache, a server process that was never restarted, and a change that never landed all look exactly the same. That has already cost review time twice: the change was there, the process was old, and there was no way to tell from the page.

What we want

Serve a version string in two places — visibly on the homepage, for a person, and as JSON at /version, for a script. The version comes from the "version" field of demo-app/package.json. That file has no "version" field today, so add one starting at 0.1.0.

Acceptance criteria

* GET /version returns 200 with content-type application/json; charset=utf-8, and a body that parses to an object whose "version" key is the string from demo-app/package.json.
* The homepage response contains that same version string inside an element with id "app-version", rendered after the existing h1.
* The existing h1 text is unchanged, and demo-app/test/homepage.test.mjs passes untouched.
* The version is read once when the process starts, not on every request.
* If demo-app/package.json is missing or carries no "version", the server still starts, /version returns 200 with "version": "unknown", and the homepage shows "unknown".
* A new test under demo-app/test/ asserts the /version body and that the homepage contains the version string. It runs under the existing "node --test" setup with no new dependency.

Edge cases that matter

/version with a trailing slash, and /version?probe=1 with a query string. The router compares request.url with exact string equality today, so both fall through to the 404 branch. Say which of them the endpoint must accept.

Non-GET requests to /version. Decide whether they 404 like every other unmatched path today or return 405, and state the choice rather than leaving it to whichever branch happens to catch it.

The homepage is served by reading index.html verbatim. Injecting a version means deciding where the substitution happens and what the server does when the anchor element is not present in the file.

Non-goals

No build-time or git-derived version string. The package.json field is the single source of truth.

No version history, no changelog, and no /versions listing.

No new npm dependency. demo-app/package.json must stay dependency-free.

No change to the 404 behaviour for unknown paths, and no change to demo-app/index.html beyond the new anchor element.
```
