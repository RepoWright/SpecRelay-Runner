# SpecRelay Runner

The SpecRelay **execution plane**: a thin, developer-installed runner that claims
approved work from the SpecRelay Platform control plane **only over the runner
HTTP API** (`/api/runner/*`), executes it on a machine you control, and uploads
events, heartbeats, and the final execution report back through that API.

Platform decides. This runner executes and reports facts.

## The trust boundary

This program shares **no code and no process** with the Platform Rails
application:

- no `require "rails"`, no Bundler boot, no ActiveRecord, no Platform constant
  anywhere in this repository (asserted by
  [`test/repository_boundary_test.rb`](test/repository_boundary_test.rb) and
  [`test/protocol_flow_test.rb`](test/protocol_flow_test.rb));
- it uses only the Ruby standard library (`net/http`, `json`, `yaml`, `open3`,
  `base64`, …);
- the **only** way it reaches Platform is
  [`lib/specrelay_runner/platform_client.rb`](lib/specrelay_runner/platform_client.rb)
  over HTTP.

Claim eligibility, claim policy, approved-spec authority, lease and cancellation
authority, event ordering, terminal-result validation, report import, and Jira
finalization are all **Platform's** decisions. This client never makes them.

### Closed-source posture

The runner may later ship as a proprietary binary. Anything on a customer machine
is inspectable and reverse-engineerable, so the runner stays **thin** and carries
no strategic product logic. Even fully reverse-engineered, it can only ask
Platform to claim work it is already authorized for.

## Install

Requirements: **Ruby 3.4+** (standard library only — no gems, no Bundler),
**git**, and **`gh`** if your Platform policy asks for pull requests.

```bash
git clone git@github.com:SpecRelay/SpecRelay-Runner.git
cd SpecRelay-Runner
bin/specrelay-runner version
```

## Configure

Copy [`config/runner.example.yml`](config/runner.example.yml) to a real path (for
example `~/.specrelay/runner.yml`) and edit it. This is the **only** supported
operator-facing runner config example.

```bash
cp config/runner.example.yml ~/.specrelay/runner.yml
```

The config carries **no secret**. The registration token, the runner credential,
and the development token are all read from environment variables the config
*names*; none is ever written to the file. Point the runner at it with
`--config <path>` or `SPECRELAY_RUNNER_CONFIG`.

## Usage

### 1. Register the runner (primary path)

An operator issues a **one-time registration token** on Platform:

```bash
bin/platform runners issue-registration-token   # on the Platform host; printed once
```

Then this runner enrolls with it and receives its **own credential exactly once**:

```bash
export SPECRELAY_RUNNER_REGISTRATION_TOKEN=<the one-time token>

bin/specrelay-runner register --config ~/.specrelay/runner.yml
# -> prints the per-runner credential once; store it:
export SPECRELAY_RUNNER_CREDENTIAL=<the credential from the output>
```

`register` exits `0` on success, `1` on a rejected/expired/used token, `2` on a
config/usage error.

### 2. Claim and execute work

```bash
bin/specrelay-runner claim-once --config ~/.specrelay/runner.yml
```

`claim-once` claims at most one eligible run (**Platform** decides which),
executes it, and uploads the report. Exit `0` on completion or no eligible work,
`1` on a failed execution, `2` on a config/usage error.

**Auth mode is chosen automatically and printed on start.** If the credential env
var (`runner.credential_env`, default `SPECRELAY_RUNNER_CREDENTIAL`) is set, the
runner authenticates as its **registered runner**; otherwise it falls back to the
shared **development token** (`platform.token_env`, default
`SPECRELAY_RUNNER_API_TOKEN`) — a local/demo path only.

The physical local workspace root is resolved, in order, from
`SPECRELAY_RUNNER_WORKSPACE_ROOT_<WORKSPACE_KEY>`,
`SPECRELAY_RUNNER_WORKSPACE_ROOT`, then the config's `workspace_roots` map. This
is the one thing the runner needs from you and never guesses.

### There is no Platform-side execution command

`bin/platform runner once|loop` was removed in MVP-0015 and now refuses with a
pointer here. Platform keeps only the commands that operate on **its own state**:

```bash
bin/platform runner release <run-id|task-id>   # free a stuck/stale claim
bin/platform runner cancel  <run-id|task-id>   # terminally stop a run
bin/platform runner sweep-leases               # reclaim lapsed leases
bin/platform runners issue-registration-token|list|revoke|rotate-credential
```

## The deterministic demo executor

[`bin/specrelay-fake-executor`](bin/specrelay-fake-executor) applies scripted
find-and-replace edits from its environment so the whole pipeline can be tested
and demonstrated without a real AI provider.

**It is not the real product executor.** It does not read a specification, reason,
or write code. A real run configures a real provider CLI as the executor command
(for example `claude`), which authenticates from your own environment on this
machine — never from a value in the config or from Platform.

Platform's seeded Tiny Demo workspace names it by the **bare** command
`specrelay-fake-executor`; the runner resolves a bundled bare name against this
repository's own `bin/`, so the demo needs no absolute-path override from you.
Platform cannot know where you checked this repository out.

## Run leasing

While a claim is held, the runner keeps a background **heartbeater** that beats on
the cadence Platform advertises (`execution_policy.lease_renewal_seconds`), so a
long executor/test run keeps its lease alive. The runner carries **no** lease or
cancellation authority: it reports liveness and **obeys the signal** Platform
returns on each heartbeat/event. If Platform reports the claim is no longer live
(`cancelled` / `expired` / `terminal`), the runner stops at the next safe
boundary, uploads **no** report, prints guidance, and exits non-zero.

Deterministic, non-secret controls for reproducing the leasing states locally
(timing only — the ticket/run/claim/report stay real):

- `SPECRELAY_RUNNER_STOP_HEARTBEAT_AFTER_SECONDS=1` — stop heartbeating
  (simulated crash/network loss) so the lease lapses and Platform reclaims the
  run; recover with `bin/platform runner sweep-leases`.
- `FAKE_EXECUTOR_SLEEP_SECONDS=<n>` (on the executor config env) — hold the claim
  so heartbeat renewal is visible and a cancellation can land mid-execution.
- `SPECRELAY_RUNNER_LEASE_SECONDS` / `_RENEWAL_SECONDS` (on Platform) — a short
  lease so expiry is observable in seconds; `renewal < duration` is enforced.

## Ordered protocol events and terminal results

The runner streams **ordered v1 protocol events** and submits a **terminal-result
envelope**, so the Platform boundary is a validated protocol, not an optimistic
log pipe:

- it keeps a per-attempt monotonic `sequence` and emits lifecycle events
  (`attempt.started` → `workspace.preparing` → `core.started` →
  `verification.started`/`.completed` → `attempt.completed`) as v1 envelopes
  (`contract_version: "1"`, `run_id`, `attempt_id`, `sequence`, `occurred_at`,
  redacted `public_summary`, allowlisted `attributes`);
- event submission retries a transient transport error with the **same payload**
  and never reuses a sequence for a different payload; Platform dedupes on
  `(attempt_id, sequence)` and returns the classification plus lease signal;
- at completion it submits the terminal-result envelope with the report bundle;
  if Platform rejects it, the runner **fails closed** and never claims success
  locally.

Sequencing, retry, and envelope construction are the runner's only
responsibilities here; classification, ordering, validation, and finalization
stay in Platform.

Deterministic, **default-off**, non-secret controls reproduce the protocol
anomalies for evidence (they only change delivery, never Platform's safety):

```bash
SPECRELAY_RUNNER_EVENT_OUT_OF_ORDER=true      # one adjacent pair delivered reversed
SPECRELAY_RUNNER_EVENT_DUPLICATE=true         # re-send one event verbatim
SPECRELAY_RUNNER_EVENT_CONFLICT=true          # re-send a used sequence with a different payload
SPECRELAY_RUNNER_FORCE_TERMINAL_FAILURE=true  # submit a failed terminal envelope
```

## GitHub publication

After the project tests pass and before the report upload, the runner publishes
the changed repository output to GitHub — commit, push the Platform-assigned
branch, and create or reuse a draft pull request
([`lib/specrelay_runner/publication.rb`](lib/specrelay_runner/publication.rb)).

Ownership stays where it belongs: **Platform decides**, in the assignment's
`repositories` / `repository_policy` / `links` blocks, which repository is
published, on which branch, with which access, and whether a pull request is
required. The runner only runs local git/gh commands and reports facts. It never
invents a branch name — a reported branch that differs from the assigned one is
rejected by Platform.

Commands used, all as argv arrays through `CommandRunner` (never a shell string,
so provider or work-item text can never be interpolated into a command line):

```bash
git -C <worktree> add -A
git -C <worktree> -c user.name=… -c user.email=… commit --no-verify -m "<TASK-ID>: …"
git -C <worktree> push origin HEAD:refs/heads/<assigned-branch>   # never --force
# Reuse first, and only an OPEN pull request on this branch:
gh pr list   --repo <owner/repo> --head <branch> --state open --limit 10 \
             --json url,state,headRefName,headRefOid
gh pr create --repo <owner/repo> --head <branch> --base <default-branch> --draft …
```

### It fails closed

Every decision point reports a blocking reason rather than a success-shaped guess:

- **The pull-request lookup is not allowed to be ambiguous.** A failing or
  unparseable `gh pr list` is *not* "no pull request exists": the runner reports
  that it could not determine the answer and **does not create**. Treating a
  lookup error as "none" is how a retry opened a duplicate pull request.
- **Only an open pull request whose head is the commit just pushed may be
  reused.** `--state open` (never `--state all`) means a closed or merged pull
  request from an earlier round on the same deterministic `specrelay/<KEY>` branch
  is never reported as this round's output — it no longer tracks the branch, so it
  may not contain the change. Such a round opens a **new** pull request instead.
- **The runner refuses to push the repository's `default_branch`**, comparing the
  assigned `branch` against the `default_branch` in the same assignment. Platform's
  branch policy already refuses to render it; this is the runner-side half, so a
  Platform regression or a replayed assignment still cannot push onto `main`.
- **No failure reason is ever empty.** A timeout reports the elapsed seconds and a
  non-zero exit with no output reports the exit status.
- **A failed `git status` is never read as a clean tree**, which would silently
  publish the previous head.

### Requirements and outcomes

- **git** is required. Push uses your host's existing credential setup.
- **`gh`** is required only when `repository_policy.create_pull_requests` is true.
  If it is missing or unauthenticated, the branch is still pushed but the pull
  request is not created; the runner reports `publication_error` with the exact
  remedy (`gh auth login`, then release and re-run) and downgrades the attempt to
  **failed** — a pushed branch without its required pull request is incomplete,
  not success. A missing binary degrades into that reported error, never a crash.
- **Non-fast-forward / diverged remote branch** fails closed and the reason names
  the next step. SpecRelay does not force-push.
- **Read-only** repositories are reported with `publication_skipped_reason` and
  never pushed. This is a **policy outcome, not a failure**.
- **Unchanged** repositories get no commit, no branch, and no pull request.
- **An unmeasurable worktree is not an unchanged one.** If the change set cannot
  be established, the attempt fails with `worktree_unmeasurable` rather than
  announcing "no code changes" to Jira while the executor's diff sits on disk.
- Every step is **idempotent**.

### Secret handling

No credential is read from Platform and none is stored here. Only an allowlist of
environment variables is forwarded to subprocesses (`PATH`, `HOME`,
`SSH_AUTH_SOCK`, `SSH_AGENT_PID`, `GH_TOKEN`, `GH_CONFIG_DIR`, `GIT_SSH_COMMAND`,
`GIT_CONFIG_GLOBAL`, `XDG_CONFIG_HOME`); no value is logged; https remote userinfo
is stripped before a slug is used; and every surfaced command output, pull-request
body, `publication_error`, and `publication_skipped_reason` passes through
[`Redaction.redact`](lib/specrelay_runner/redaction.rb), which covers
`github_pat_*` and `glpat-*` alongside the classic token shapes and strips
`user:secret@` userinfo from any URL a raw git error echoes — the host and path
survive as evidence.

## Recovering a stuck claim

If a claim succeeds but the runner then fails **before** execution (missing
workspace root, worktree create failure), it does not crash: it prints the exact
recovery steps and exits non-zero. The run stays `CLAIMED` on Platform until an
operator releases it:

```bash
bin/platform runner release <TASK-ID>   # on the Platform host; run becomes claimable again
```

`release` is idempotent and always works even if the runner process died without
reporting. Platform's Jira intake page flags runs that currently hold a claim and
prints this command.

## Layout

```text
bin/specrelay-runner            # plain-Ruby executable (no Bundler/Rails)
bin/specrelay-fake-executor     # deterministic demo executor (NOT the real executor)
config/runner.example.yml       # the one operator-facing config example
lib/specrelay_runner.rb         # requires
lib/specrelay_runner/
  cli.rb                        # argv -> config -> client -> claim/execute
  config.rb                     # local YAML config (secrets from ENV only)
  platform_client.rb            # the ONLY Platform touchpoint (HTTP/JSON)
  command_runner.rb             # safe argv process launch + timeout
  workspace.rb                  # worktree create + git diff capture
  executor.rb                   # launch the configured executor with the prompt
  report_bundle.rb              # build manifest + evidence, base64 for upload
  event_emitter.rb              # per-attempt sequence + v1 event envelope
  terminal_result.rb            # terminal-result envelope builder
  protocol_controls.rb          # default-off deterministic protocol test controls
  publication.rb                # commit + push + draft PR create/reuse
  execution.rb                  # orchestrate one claimed run
  redaction.rb                  # client-side secret redaction (defense in depth)
  heartbeater.rb                # background lease renewal
  version.rb
test/                           # minitest: fake Platform HTTP server + real git flow
  support/fake_platform.rb      # a real HTTP server on an ephemeral loopback port
  support/fake_github.rb        # a real bare remote + scriptable fake `gh`
```

## Tests

No gems and no test runner to install — plain minitest on the standard library:

```bash
for t in test/*_test.rb; do ruby -Itest "$t"; done
```

Or individually:

```bash
ruby -Itest test/config_test.rb
ruby -Itest test/repository_boundary_test.rb
ruby -Itest test/runner_flow_test.rb
ruby -Itest test/registration_flow_test.rb
ruby -Itest test/lease_test.rb
ruby -Itest test/protocol_flow_test.rb
ruby -Itest test/publication_flow_test.rb
ruby -Itest test/redaction_test.rb
```

Style: `rubocop` (see [`.rubocop.yml`](.rubocop.yml), which inherits the same
`rubocop-rails-omakase` baseline as Platform and re-enables the maintainability
metrics `docs/rails-engineering-standard.md` mandates).

What each suite proves:

- **`repository_boundary_test.rb`** (MVP-0015) — this repository ships its own
  demo executor and resolves a bundled bare command to it; a real provider command
  and an absolute path are passed through untouched; the config path resolves from
  the canonical env var with the spike-era name still honoured as a deprecated
  alias; and the code carries no Rails/ActiveRecord reference and no path into
  `specrelay-platform`.
- **`runner_flow_test.rb`** starts a real fake Platform HTTP server on loopback and
  a real hermetic git workspace with a deterministic fake executor, then drives the
  full claim → events/heartbeat → worktree + executor + tests → report-upload flow
  over real HTTP — proving the process boundary end to end.
- **`registration_flow_test.rb`** proves the runner `register`s over HTTP with a
  one-time registration token, receives its credential once, and then drives the
  full claim-once flow authenticated by that **registered credential** — never
  storing a secret in the config file.
- **`protocol_flow_test.rb`** proves the ordered v1 event stream (dense monotonic
  sequence, well-formed envelope), the out-of-order/duplicate/conflict controls,
  and the terminal-result envelope submitted with the report.
- **`publication_flow_test.rb`** proves the publication path against a **real bare
  git remote** and a real `gh` argv boundary (a scriptable fake binary on `PATH`),
  so every assertion is an observable fact — a ref that exists in the remote, an
  argv the CLI actually issued. The fake `gh` honours `--head` and `--state` and
  resolves `headRefOid` from the real remote, so the fail-closed reuse semantics
  are genuinely exercised: a failing `gh pr list` never creating a pull request, a
  retry after a transient lookup failure ending with exactly **one** pull request,
  a closed and a merged pull request on the same branch never being reused, an
  open pull request with a foreign head failing closed, an assignment targeting the
  default branch being refused, a read-only repository not failing the run, and an
  injected `Errno::EMFILE` during change detection failing closed instead of
  reporting "no code changes".
- **`redaction_test.rb`** covers the shapes that reach `publication_error` and the
  uploaded transcripts, while commit shas, branch names, and scp-style remotes
  survive as evidence.
- **`lease_test.rb`** proves the heartbeater renews on Platform's advertised
  cadence and that the runner stops and uploads nothing when Platform signals the
  claim is no longer live.

## Related

- Platform (control plane): `SpecRelay/SpecRelay-Platform`
- Runner API contract and trust model: `docs/runner-api.md` in the development
  workspace
- Operator setup walkthrough: `docs/local-runner.md` in the development workspace
