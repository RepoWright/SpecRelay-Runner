# Specification-creation input bundle — MAPIAI-49

## Input completeness

Every expected input was readable.

## Issue

- Issue: [MAPIAI-49](https://finlink.atlassian.net/browse/MAPIAI-49) — [MVP-0026 REVIEW] Tiny Demo server dies for good when index.html cannot be read
- Jira status at capture: Ready for Spec Creation
- Reporter: Reza Mohseni
- Labels: (none)
- Components: (none)
- Captured at: 2026-08-01T10:20:06Z
- Bundle trace id: `bundle_c4930f07b30a21fd`

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
Reviewer-created verification fixture for SpecRelay MVP-0026, review round 003. Safe for the Product Owner to close or delete once the review is filed.

Problem

demo-app/server.mjs awaits readFile(join(__dirname, "index.html")) inside its request handler and never guards it. If that read rejects for any reason — the file was deleted, a permission changed, the checkout is mid-rebase — the rejection escapes the async handler as an unhandled promise rejection. On Node 24 that is fatal by default, so the process exits.

Reproduced on Node v24.4.1 against a copy of the real demo-app: with index.html removed, the first request to / returns nothing at all (curl reports an empty reply from server, exit 52) and every request after it is refused outright (curl exit 7). The listener is gone. The log shows the ENOENT stack and then "Node.js v24.4.1", which is the process dying.

Two separate faults are hiding in one line here. The caller gets no response, so a probe cannot tell a broken asset from a hung network. And the process does not survive, so one missing file takes the whole app down until somebody restarts it by hand. A demo app that dies silently is worse than one that returns an error, because the operator has nothing to read.

Definition of done

a) A request to / or /index.html whose underlying read fails gets an actual HTTP response rather than a dropped connection. Choose 500 and state the choice; do not leave it to whichever branch happens to catch it.

b) The response body for that case is plain text and names the condition in a way an operator can act on. It must not include the filesystem path, the stack trace, or the errno object, because this body is what ends up in a screenshot.

c) The process stays alive and keeps serving. After a failed read, a following request to /nope still returns 404 with the body "Not found", and a following request to / succeeds once the file is readable again.

d) The failure is written to the server log once per occurrence, with enough detail to diagnose, and that logging is the only place the path appears.

e) The existing behaviour is untouched: / and /index.html still return 200 with the HTML and the existing content-type, /nope still returns 404, and demo-app/test/homepage.test.mjs keeps passing without being edited.

f) A new test under demo-app/test/ covers the failing read. It must exercise the real handler rather than asserting on a mock, and it must assert both that a response arrived and that the process was still answering afterwards. It runs under the existing node --test setup and adds no dependency.

Out of scope

Any change to demo-app/index.html or to what the homepage displays. This is about surviving a failed read, not about the page content.

A general-purpose error-handling middleware or framework. The app is one createServer call and should stay that way.

Caching the HTML in memory at boot. That would hide the bug rather than fix it, and it changes when the file is read, which is a separate decision nobody has asked for.

Any change to the 404 branch, which is already correct.

Notes

The two failure modes need to stay distinguishable afterwards: a read that fails and a process that is not listening must not look the same to a caller. That is the whole point of the ticket.
```
