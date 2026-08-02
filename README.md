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

## Usage — the normal path (MVP-0017, extended by MVP-0018)

Two commands to get going, no files to author, no credential to export: one to
connect the machine, one to leave running.

### 1. Connect this machine to one workspace

An authenticated operator issues a one-time enrollment code from Platform's
**Project setup -> Connect a Runner** screen and copies the single command it
displays. Run it here:

```bash
bin/specrelay-runner connect <one-time-enrollment-code>
```

It asks you for exactly **one** thing — the local checkout directory for the
assigned repository — and derives everything else from the code exchange: the
Platform endpoint (carried inside the code, so no `--platform` flag), the
project/workspace assignment, the repository identity to validate against, and
the executor profile to check.

Order of operations. Steps 1 to 4 change **nothing** — no code is consumed, no
credential is issued, and no binding is touched — so a purely local failure costs
the operator nothing and the same code still works:

1. confirm this platform supports guided secret storage (**macOS only** in this
   release — see below);
2. **preview** the code's assignment without consuming it
   (`POST /api/runner/enrollment_preview`);
3. validate the checkout: it must be a Git repository whose configured remote and
   default branch match the assigned workspace. Remote comparison is identity-only
   (`host/owner/repo`), so an `https` URL and an scp-like SSH remote for the same
   repository match, while a different repository, owner, or host does not;
4. run the bounded provider readiness checks **only** when the assigned executor
   is the real Claude profile;
5. prove the **Keychain accepts a write**, using a throwaway non-secret item — only when this
   machine holds no credential yet, because that is when a write is certain to be needed;
6. **exchange** the code, presenting the credential this machine already holds for this
   Platform (if any) in the `X-SpecRelay-Runner-Credential` header, so Platform can recognise a
   reconnect;
7. store the durable credential in the **macOS Keychain** — skipped entirely when
   Platform replied `credential_unchanged`, because there is nothing new to store;
8. write non-secret connection facts to `~/.specrelay/runner/connections.json`
   (mode `0600`, and you never need to edit it);
9. report a bounded readiness result and print the state **Platform** decided.

Exit `0` when Platform records this machine ready, `1` otherwise, `2` on a
usage/platform error.

**Secret posture.** The durable credential is never printed, never written to
YAML, a shell profile, Git, or a log, and never appears in an error message. It is
also never an argv element: it is handed to the `security` tool on **stdin**, via that tool's
interactive mode (`security -i`), because `security` documents `-w` as insecure and an argv
element is visible in the process table to any process running as the same user.

Interactive mode is used rather than a valueless `-w`: that form makes `security` *prompt*, and
it reads the prompt with `readpassphrase(3)`, which opens **`/dev/tty`** and falls back to stdin
only when no controlling terminal exists. In a real terminal the tool therefore never read the
pipe and the connection hung until it timed out. Interactive mode involves no terminal at all.
Because that mode splits its command line on whitespace, a value containing whitespace, a quote,
or a backslash is refused rather than stored truncated, and **every write is read back and
compared** before it is reported as saved. The local checkout path is
stored **locally only** and is never sent to Platform, along with the Keychain
service name, the credential, the provider account identity, and raw probe output.

**Supported storage.** macOS only in this release. On any other system `connect`
stops **before** registering with a clear message rather than saving a plaintext
credential — there is no file-based fallback in the code at all
([`lib/specrelay_runner/secret_store.rb`](lib/specrelay_runner/secret_store.rb)).

**Retry is safe and idempotent.** A failure in steps 1 to 5 does not consume the
code, so the operator simply runs the same command again. When a code *is*
consumed, presenting the same machine-derived runner id updates that machine
instead of creating a second one, and the single (runner, workspace) binding is
reused.

Step 5 exists because storage failing *after* the exchange is not merely inconvenient: Platform
has already issued a credential this machine then fails to keep, which both spends the code and
leaves any previously-ready connection unable to authenticate.

**A reconnect does not replace a working credential.** Step 6 sends the credential this machine
already holds; when Platform recognises it, nothing is rotated and step 7 is skipped. That is
what stops a reconnect that fails later from taking a working machine offline.

The credential is stored under ONE **runner-scoped** Keychain account
(`runner:<runner-public-id>`), because that is its actual scope —
`registered_runners.credential_digest` is per runner, not per workspace. Connecting a second
workspace on the same machine therefore presents the credential it already has and leaves the
first workspace authenticating. Pre-round-003 per-workspace accounts are still READ as a
fallback — for **every** workspace this machine has connected at that Platform, not only the one
being connected, so a machine whose credential still sits under another workspace's account is
not rotated out from under itself.

It travels in a **header**, never the request body, so it cannot reach Rails' parameter log.

### 2. Execute work

Two commands. `loop` is the normal mode for a connected machine; `claim-once` is
the controlled single shot.

```bash
bin/specrelay-runner loop                          # poll, claim one at a time, repeat
bin/specrelay-runner loop --workspace <key>        # when several are connected here
bin/specrelay-runner loop --poll-interval 300      # 5-3600s (default 60s)
bin/specrelay-runner loop --on-failure stop        # end the session after a failed run

bin/specrelay-runner claim-once                    # exactly one claim, then exit
bin/specrelay-runner claim-once --workspace <key>
```

Neither needs a config file, an exported credential, or a workspace-root
environment variable: the credential is read from the Keychain and the workspace
root is the checkout you validated.

Which connection an argument-free invocation uses, and why, is resolved in this
order (MVP-0021): `--workspace`, then this machine's **explicit default**, then the
sole stored connection. Anything else asks. The chosen source is printed, so the
decision is visible rather than inferred:

```text
Source:   connected workspace tiny-demo-workspace (your explicit default workspace)
```

`claim-once` claims at most one eligible run (**Platform** decides which), executes
it, and uploads the report. Exit `0` on completion, no eligible work, or a generated
specification package (below), `1` on a failed execution or a refused generation,
`2` on a config/usage error.

### Two lanes, and one of them writes files (MVP-0026, MVP-0027)

Platform can hand this runner work from either lane, and the runner branches on the
assignment's own `run.type` — never on which fields are missing:

| `run.type` | What this runner does |
|---|---|
| `implementation` | The full flow: worktree, executor, tests, report, publication. |
| `spec_creation` | Two phases, each its own claim: **generate** a specification package locally, then — when Platform offers the same run again — **publish** it as a draft pull request. |

Within the specification lane the runner branches a second time, on
`assignment_boundary.expected_runner_action` rather than on the run's state:

| `expected_runner_action` | Phase |
|---|---|
| `generate_specification_package` | Write the package into the operator's specification checkout. Nothing is committed. |
| `publish_specification_package` | Verify the recorded digests, commit, push, and open or reuse one draft pull request. |
| anything else | **Stop.** A build that meets an action it does not implement refuses rather than guessing, and prints the release command. |

Neither phase writes a Jira field, transitions an issue, or adds a comment — that is
MVP-0028, and the assignment says so as data
(`assignment_boundary.publication = "publish_draft_pull_request_only"`).

#### What it writes

```text
<specification-root>/<ISSUE-KEY>-<sanitized-summary-slug>/
  spec.md
  analysis/business.md
  analysis/technical.md
  generation-manifest.json
```

The folder name is deterministic — the same issue always produces the same
directory, so a re-run replaces its own package instead of accumulating
near-duplicates. The issue key is validated against a closed shape and the
configured specification root is REFUSED (not sanitized) if it is absolute,
traverses, carries URL userinfo, or contains a shell metacharacter or control
character: a silently rewritten destination is one the operator cannot predict.

Every path in the generated Markdown is repository-relative. Absolute host paths
never reach a generated file — including in quoted `bin/graph-check` and
`bin/graph-query` output, which the runner relativizes before quoting. The input
bundle is identified by its **trace id**, never by a Platform URL: that address is
machine-local, and this package is destined for a shared repository.

#### Publishing the package (MVP-0027)

When Platform offers the run again with `expected_runner_action:
publish_specification_package`, the assignment adds two blocks: `generated_package`, the
SHA-256 of every file Platform recorded, and `publication`, Platform's branch decision. The
runner executes that decision; it never invents a branch name, a base, or a pull-request
kind.

The order is the contract, and everything before the first git command is reversible by
doing nothing:

```text
parse -> resolve the checkout -> VERIFY EVERY DIGEST -> check `gh auth` -> commit+push -> draft PR -> report
```

- **Digest verification first.** A file that differs, is missing, or cannot be read is a
  refusal with no git command run at all. The package was written by an earlier run into a
  checkout the operator owns and can edit; publishing whatever is there now would mean
  Platform's evidence described a different document set from the one a developer reviews.
- **`gh auth` before the commit, not after the push.** A host that cannot open a pull
  request must not first push a branch nobody will be asked to review.
- **The commit never touches the working tree or HEAD.** It is built with plumbing into a
  TEMPORARY index — `read-tree` the base, `hash-object` each verified file,
  `update-index`, `write-tree`, `commit-tree` — and the commit object is pushed directly.
  Run this against a checkout you are working in; that is the intent. It also makes
  "the commit contains only the package files" structural: nothing else was ever added.
- **A retry reuses.** The base is the existing remote branch tip, so a republish writes the
  same tree; an unchanged tree means no commit is created and the existing tip is reused,
  and the push is a no-op. The pull request is looked up before it is created, and a lookup
  that cannot answer FAILS CLOSED rather than guessing "none". The reuse decision itself is
  `SpecrelayRunner::PullRequestReuse`, shared with the implementation lane.
- **Never a force push, never a delete.** A diverged publication branch is refused with the
  branch named and the remedy stated.

A pushed branch without the required draft pull request is a **failure**, not a partial
success: the run does not reach approval, and the branch is reported as evidence of how far
the attempt got. Failure classes are a closed set — `publication_assignment_malformed`,
`specification_repository_unresolved`, `specification_checkout_mismatch`,
`generated_package_missing`, `generated_package_digest_mismatch`, `github_cli_unavailable`,
`git_push_failed`, `pull_request_creation_failed`, `publication_verification_failed` — and
Platform enforces the same list.

**A publication is `published` only once Platform has accepted the result.** If Platform
answers `4xx`, it has read the payload and REFUSED it — the run will not reach approval and no
retry of the same body will change that, so the runner reports a failure, names what Platform
refused, still prints the branch and pull request (they exist, and Platform holds no record of
where), and exits non-zero. A `5xx` or an unreachable Platform is different: the outcome on
GitHub still stands, the runner says so, and the claim is left to expire so a later attempt can
reuse the same branch and pull request.

The checkout is checked against the assigned repository, but only when its `origin`
resolves to a GitHub `owner/repo`. A remote that does not resolve (an ssh alias, an internal
mirror, a local path) is not evidence of a mismatch, and refusing every one would refuse
legitimate setups on a guess; the wrong-clone case those could hide still fails closed at
the pull-request step, which addresses GitHub by the ASSIGNED slug.

#### What happens when the source checkout yields nothing

The runner samples any file in the source checkout that is not binary, not oversized,
and not a known non-source format — an exclusion rule, not a list of blessed
extensions, so a language this runner has never met is still inspected.

If it still finds **nothing readable**, the runner **generates anyway and warns**. It
does not refuse. A resolved-but-empty checkout is not scope 8's *unresolvable* workspace,
and a specification written from a complete Jira ticket is still worth having — provided
it admits what it is missing, which it does: the header, the Problem section, the
dependencies, and the technical risks all state that no source was inspected, and the
run carries a warning that Platform stores and the run page shows.

If you would rather it refused, the fix is on your side: point the workspace root at a
checkout that has source in it. A refusal here would make the lane unusable for any
repository this runner cannot classify, which is how an extension allowlist silently
produced an empty inspection of a real Node app in the first place.

#### Preflight, and why a refusal is the good outcome

Every capability is checked **before any output file is opened**. If one is
missing, the runner refuses, reports a stable failure class to Platform, and leaves
zero output files. There is no code path from a refusal to a file handle, so that is
a property of the control flow rather than of a cleanup routine that might fail.

| Failure class | What to fix |
|---|---|
| `assignment_malformed` | Platform sent an assignment without required generation data, or with an incomplete bundle. |
| `specification_repository_unresolved` | Point this machine at its checkout of the specification repository (below). |
| `specification_folder_unsafe` / `specification_folder_unwritable` | The configured specification root is not a safe, writable repository-relative folder. |
| `existing_package_present` | Only with `on_existing_package: refuse`. Move the existing package, or switch back to `replace`. |
| `source_workspace_unresolved` | Map the workspace to its local source checkout (`SPECRELAY_RUNNER_WORKSPACE_ROOT_<KEY>`). |
| `input_content_unreadable` | The bundle offers an input Platform classified as unusable. Re-read the ticket. |
| `external_reference_analysis_unavailable` | A Confluence page or screenshot was deferred to this runner. Enable the capability or record a substitute. |
| `graphify_unavailable` | Graphify is present but incomplete, not executable, stale, or unhealthy. Repair it with `bin/graph-build`, or record a substitute. A repository with neither wrapper installed continues with direct source inspection and records that Graphify contributed nothing. |
| `context_plus_unavailable` | Legacy result from older runners. Current runners continue with an explicit warning when Context+ is unavailable. |
| `generation_provider_unavailable` | The configured provider command is missing or not executable. |
| `redaction_validation_unavailable` | The redaction guard failed its own self-check; generated output cannot be proven safe. |

After preflight passes, three more classes can occur, and they are distinguished
because the operator's next move differs: `generation_provider_failed`,
`generated_output_invalid`, and `package_write_failed`. Almost always they leave the
destination unchanged — the runner stages the whole package and moves it into place
with a single rename.

**Almost always is not always, so the runner reports which.** Every failure result
carries `zero_output_files_written`, and it is computed from whether that rename
completed rather than asserted. If a rare failure lands *after* the move — the
package is already in place and something in the bookkeeping went wrong — the result
says `false`, the message names the package path, and the run page tells you to go
and look at the checkout. Deleting the package a lease or an I/O error interrupted
would be a worse surprise than leaving it, so it is left.

Recovery from any of these is on the **Platform** host, and it is not `release`
(the refusing attempt already closed its own claim):

```bash
bin/platform runner requeue-specification <run-id|ticket-key>
```

#### Configuration

Under `runner.specification:` in the config file, or from the environment. No secret
belongs here — the provider is a local executable path.

```yaml
runner:
  specification:
    provider:
      kind: composed        # composed (built-in deterministic composer) | command
      command: /abs/path/to/spec-writer   # required for kind: command
      timeout_seconds: 900
    repository_roots:
      "SpecRelay/SpecRelay-Specs": /abs/path/to/your/specs-checkout
    on_existing_package: replace          # replace (default) | refuse
    context_plus:
      available: true       # optional declaration; never treated as proof of use
      # Optional semantic evidence YOU gathered — the runner cannot query Context+.
      queries:
        - "where is the weekly report rendered"
      evidence: "ReportsController#weekly and ExportReport are the material hits"
    graphify:
      substitute: "why, when the wrappers are absent"
    external_references:
      substitute: "why, when the bundle defers a reference to this runner"
```

`provider.kind: fake` is still accepted as an alias for `composed` and normalizes on
the way in, so an existing config keeps working. The value was renamed because the
built-in composer is not a fake: it composes from the real bundle and the real source
evidence, and an operator reading `provider: fake` in a run page's diagnostics was
being told the intended default was a stub.

Environment overrides: `SPECRELAY_RUNNER_SPEC_REPOSITORY_ROOT_<OWNER>_<REPO>` (or the
unsuffixed `SPECRELAY_RUNNER_SPEC_REPOSITORY_ROOT`), `SPECRELAY_RUNNER_SPEC_PROVIDER`,
`SPECRELAY_RUNNER_SPEC_PROVIDER_COMMAND`, `SPECRELAY_RUNNER_SPEC_ON_EXISTING_PACKAGE`.

**The `substitute:` keys are not off switches.** Each is a sentence you write, and
the runner copies it verbatim into `analysis/technical.md` and into the evidence
Platform stores. Recording the gap is what makes proceeding honest; omitting the key
can make preflight refuse for capabilities that must handle deferred input. A substituted
tool is reported as having contributed **nothing** — "we were allowed to continue without
Graphify" and "Graphify produced evidence" are different facts and are never collapsed.

**Context+ is always reported as having contributed nothing.** The runner is a
separate OS process with no MCP client, so it can neither run a semantic query nor
verify that one ran. Its absence does not refuse generation: the runner records a warning
and grounds the package in direct source inspection without semantic Context+ evidence.
`context_plus.available: true` changes nothing about what the runner may claim. If you
have gathered semantic evidence yourself, put it in `context_plus.queries` and
`context_plus.evidence` — the runner reproduces both verbatim under
`## Context+ evidence` and attributes them to you. It still does not mark the tool as
having contributed, because the contributor was a person, not this process.

#### The generation provider boundary

Everything that turns evidence into prose goes through one interface with two
methods — `describe` and `generate(packet)` — and the entire input a provider
receives is one reviewable, redacted packet. Two implementations ship:

- **`composed`** (the default) is the built-in deterministic composer: same packet,
  same bytes, no model, no network. It is both the test double and a genuinely usable
  default, because it composes from the real bundle and the real source evidence.
- **`command`** runs an operator-configured local executable with the packet as JSON
  on stdin, expecting the file map as JSON on stdout. No shell, no inherited
  environment beyond `PATH`, and a throwaway working directory — the provider is
  never handed either checkout, because writing is not its job.

#### What the built-in composer takes from the ticket

Where the Jira ticket states something, the generated specification **quotes it** rather
than paraphrasing it. These sections are read out of the reporter's own description:

| Ticket heading (case-insensitive) | Where it lands |
|---|---|
| `Problem`, `Context`, `Background`, `Why` | `## Problem`, as a blockquote |
| `Outcome`, `What we want`, `Goal`, `Expected behaviour` | `## Outcome`, verbatim and attributed |
| `Acceptance criteria`, `Acceptance`, `Criteria`, `Definition of done` | `## Acceptance criteria`, verbatim and attributed |
| `Out of scope`, `Non-goals`, `Not in scope`, `Exclusions` | `## Non-goals`, verbatim and attributed |

Every other heading the ticket carries — `Edge cases that matter`, say — is reproduced
under `## Proposed behavior`, because it is material an implementer needs and dropping
it for want of a name for it would be the same mistake in a smaller form.

Headings are recognised by shape, not by markup: Jira stores ADF and the conversion to
text loses heading formatting, so a heading arrives as a short line alone between blank
lines. Ordered list items arrive as `#`, which is renumbered to `1.` on the way out —
left alone, a bare `#` is a level-1 heading and would destroy the document's outline.

**Where the ticket says nothing, the document says so** — and where it says something, the
composer does not add to it.

- A ticket that states its own acceptance criteria gets **no derived numbered criteria and no
  derived numbered behaviour list**. The reproduced material plus the standing conditions is the
  section. A ticket that has written six testable criteria does not need a machine to add four
  more.
- **No requirement is derived from a keyword.** An earlier version treated the word "again"
  as a request for idempotency, and on a real bug about a file becoming "readable again" it
  produced four statements telling an implementer to build and test idempotency for a stateless
  read handler. No generated sentence claims the ticket asked for something it did not.
  One keyword heuristic survives: `user_facing?` matches a list of UI words over the title and
  the ticket's included sections, and it decides one row of `analysis/technical.md`. It states
  what the recorded inputs do or do not imply, never what the ticket requires.
- Where a specification needs a decision the ticket never made, the output is an **open
  question**, never a requirement. **A ticket that supplies its own acceptance criteria raises
  neither standing question** — not the repeat one, not the failure-path one. Where it supplies
  none, both are raised, worded as what this generation found rather than as a finding about the
  ticket. Nothing reads the criteria text for keywords to decide this; a generator cannot tell
  whether a reporter made a decision, and both directions of that guess have now shipped a
  defect — a false requirement in round 003, a false absence in round 004.
- A ticket with no criteria at all produces a section that opens "The ticket states no
  acceptance criteria" and labels what follows as derived and needing confirmation.

A fabricated acceptance criterion is worse than a missing one, because a reviewer cannot tell it
from a real one.

Whatever a provider returns is validated before anything is written, so a
plausible-looking document that silently omits acceptance criteria is rejected rather
than committed. **The document contract a provider must satisfy:**

- every required section present as a `##` heading with a substantive body;
- that heading **outside** every fenced code block — a heading that exists only
  inside a fence is not a heading, and counts as absent;
- **balanced fences**: a code block opened and never closed fails validation, because
  everything after it renders as code.

The last two are not pedantry. Round 001 shipped a `spec.md` in which six of the nine
required sections rendered inside an unterminated code block, and a validator that
matched headings on raw lines certified it. If your provider embeds text it did not
author — a ticket body, tool output — choose the fence length from that text, longer
than the longest backtick run inside it.

Exit status is `0` only for a generated package. A refusal or a post-preflight
failure exits `1`: the correct behaviour is now a package, so a `loop` session that
treated a refusal as success would poll forever against a misconfigured runner while
reporting health.

`loop` (MVP-0018) does the same repeatedly, at a bounded poll interval. Exit `0`
when every run it executed succeeded, `1` if any failed or the credential was
rejected, `2` on a config/usage error. It shares `claim-once`'s connection
resolution, credential read, readiness gate, claim request, and reporting — it adds
repetition and nothing else, so `claim-once` remains byte-for-byte the command it
was.

`--poll-interval` is bounded at `5-3600s`. A value outside the range is **clamped
and the clamp is printed**; a non-numeric value is **refused**, because silently
substituting a default would hide that the operator's intent was lost.

Only **one run at a time**, structurally: the loop body is synchronous, so
`Execution#call` must return before the next poll is even attempted. There is no
code path that starts a second executor.

`SIGINT`/`SIGTERM` stop it cleanly and name the situation it stopped in:

```text
[loop] stopped by signal while IDLE — no execution was in progress and nothing was claimed
[loop] stopped by signal DURING an execution — the run finished and reported its result first
```

Foreground only, deliberately: no LaunchAgent, no daemonization, no supervisor.

When nothing was claimed either command prints the reason **Platform** returned, so
a machine that is not connected (or not ready) is told to run `connect` rather than
reading a refusal as a healthy idle.

### Live executor output (MVP-0018)

While the executor runs, safe output is streamed to the terminal between
`[core.started]` and `[verification.started]` and submitted to Platform as ordered
live log events, so a working run never looks like a hung one:

```text
[core.started] Running claude executor for MAPIAI-40
  [claude:status] claude executor running for 15s on MAPIAI-40 (no new output yet)
  [claude:stdout] MAPIAI-40 is implemented per approved spec `specs/DEMO-0012-…/spec.md`
[verification.started] Running project tests for MAPIAI-40
```

The supported Claude profile runs with `--print` and emits nothing until it
finishes (`--output-format` is a forbidden flag), so a `core.progress` **heartbeat**
is emitted every 15s of silence naming the elapsed time. It is a fallback, never a
substitute: real output, when available, is what you see.

Every line is redacted before the terminal write **and** before upload, clipped at
2000 bytes, and counted against a 131072-byte per-run budget whose exhaustion emits
one `log.truncated` event rather than dropping output silently. Output is flushed,
because Ruby block-buffers a non-terminal stdout and an unflushed live log is just
a delayed one.

It cannot break the run: a consumer that raises is swallowed, an upload failure is
counted and reported once, and the buffered capture plus the child's exit status are
observed independently of any of it.

The report carries the bounded stream as its own artifact,
`evidence/live-executor-log.txt`, deliberately separate from the full
`evidence/stdout.log` / `evidence/stderr.log` capture — a reviewer needs to tell
what the operator saw live from what was collected for review.

Platform authorizes a claim only for a workspace this machine has explicitly
connected to and been recorded `ready` for — and only while its reported
repository identity still matches that workspace. A historical `all_eligible`
claim policy grants nothing on its own.

### 3. Manage this machine's connections (MVP-0021)

```bash
bin/specrelay-runner            # in a terminal: opens the local control center
bin/specrelay-runner            # with no terminal: prints usage, exits 2
bin/specrelay-runner help       # always prints help, exits 0
```

The dashboard lists every workspace this machine is connected to and, for a
selected one, offers: `Start loop`, `Claim once`, `Test connection/readiness`,
`Show details`, `Set as default` / `Clear default`, `Disconnect locally`,
`Disconnect from Platform`, `Back`.

Keys match `./bin/worktree`: single-key shortcuts act immediately, arrows move a
highlight that Enter runs, `Esc`/`Ctrl-C` backs out. The terminal is restored on
every exit path — quit, `Ctrl-C`, an error, and after a nested command — which is
asserted under a real pty in [`test/dashboard_tty_test.rb`](test/dashboard_tty_test.rb),
by reading the terminal's own attributes after the process exits.

The no-argument split matters in both directions. Opening a menu with no terminal
would render escape sequences into a log and then block on a keypress that can
never arrive; exiting `0` with only help text would let a mis-scripted invocation
pass as a successful run that executed nothing.

**The dashboard is a presentation layer and nothing else.** Every action calls one
`ConnectionOperations` method — the same one the equivalent direct command calls —
and `Start loop` / `Claim once` hand `["loop", "--workspace", <key>]` to the CLI's
own dispatcher. They cannot drift from the direct commands, because they *are*
them; the command line is echoed before it runs so it can be copied.

Every action is also scriptable, needs no terminal, and never prompts:

```bash
bin/specrelay-runner connections list
bin/specrelay-runner connections show <workspace-key>
bin/specrelay-runner connections test <workspace-key>
bin/specrelay-runner connections default <workspace-key>
bin/specrelay-runner connections clear-default
bin/specrelay-runner connections disconnect-local <workspace-key> [--remove-credential]
bin/specrelay-runner connections disconnect-platform <workspace-key>
bin/specrelay-runner connections forget-legacy-credential <workspace-key>
```

Exit codes: `0` success, `1` an expected operation failure (Platform rejected it, a
readiness check failed), `2` usage or unusable local state. `1` means "the answer
is no"; `2` means "the question was wrong".

#### Test connection and readiness

Walks the same preconditions a claim depends on, in the order a claim hits them,
and stops at the first failure so the remedy names the thing worth fixing:
`local_state_invalid`, `credential_missing`, `platform_unreachable`,
`credential_rejected`, `workspace_grant_missing`, `workspace_grant_not_ready`,
`repository_mismatch`, `executor_unavailable`, `executor_not_authenticated`, or
`ok`.

It **claims nothing** — no run requested, no lease taken, no readiness report
submitted, and Platform's half is a pure `GET`. It can be run repeatedly without
risking the connection it is testing, which is what makes it usable as a first move
when something looks wrong.

#### The explicit default workspace

Stored in the runner's own non-secret local state as `default_workspace_key`. With
it set, `loop` and `claim-once` run with no `--workspace` even when several
workspaces are connected, and they print that the default was used.

There is no implicit default by recency, alphabet, project, or last menu row, and a
default that no longer resolves **fails closed** — it is checked before the
sole-connection shortcut, so it cannot fall through even on a machine with exactly
one remaining connection.

A `connections.json` written by an earlier runner has no such key, loads unchanged,
and simply has no default; the document is written as version 2 the next time it
changes.

#### Two disconnects

| | Effect |
|---|---|
| `disconnect-local` | Removes THIS machine's stored connection. Platform **still** authorizes this runner for that workspace — local deletion revokes nothing. |
| `disconnect-platform` | Asks Platform to remove THIS runner's grant for THIS workspace. Never revokes the runner identity, never touches another workspace, and deletes no project, workspace, run, report, or branch. |

The runner credential is scoped to the **runner identity**, so a local disconnect
keeps it while any other local connection still uses it. When nothing depends on it
any more you are asked separately (dashboard) or must pass `--remove-credential`
(script). The pre-round-003 per-workspace Keychain item is removed only by
`forget-legacy-credential`, which names the exact account it removes — nothing else
in the runner ever deletes a legacy item, because a machine that connected under the
old scheme still authenticates from it.

Platform disconnect goes first; local removal is offered only after Platform
confirms, and a **failed** Platform disconnect changes no local state.

A `200` alone is **not** a confirmation: the runner accepts the disconnect only when
Platform states an `outcome` of `revoked` or `already_absent`, and any other answer
on that status (an HTML page from a proxy, a missing block, an unrecognised value)
exits `1` with *"Platform answered, but did not confirm the disconnect"* and writes
nothing locally. Similarly, if the Keychain **refuses** the credential deletion, the
local entry is still removed but the command exits `1` and says the credential could
not be removed and is still stored — it never claims a removal the OS refused.

**You never need to edit `~/.specrelay/runner/connections.json`.** These commands
write it atomically and preserve mode `0600`.

## ADVANCED / LEGACY: the hand-written config path

Supported for an operator who already runs this setup. It is **not** the way to
set a new machine up, and `register` alone authorizes no work.

Copy [`config/runner.example.yml`](config/runner.example.yml) to a real path (for
example `~/.specrelay/runner.yml`) and edit it. The config carries **no secret**:
the registration token, the runner credential, and the development token are all
read from environment variables the config only *names*. Point the runner at it
with `--config <path>` or `SPECRELAY_RUNNER_CONFIG`; an explicit `--config` always
wins over a stored connection.

```bash
# On Platform: issue a one-time registration token (printed once).
bin/platform runners issue-registration-token

# Here: enroll with it and capture the credential (printed exactly once).
export SPECRELAY_RUNNER_REGISTRATION_TOKEN=<the one-time token>
bin/specrelay-runner register --config ~/.specrelay/runner.yml
export SPECRELAY_RUNNER_CREDENTIAL=<the credential from the output>

# Claim with that config and credential.
bin/specrelay-runner claim-once --config ~/.specrelay/runner.yml
```

`register` exits `0` on success, `1` on a rejected/expired/used token, `2` on a
config/usage error. A machine enrolled this way displays as `legacy setup` in
Platform and can claim **nothing** until it also completes
`connect` for a workspace.

On this path the physical local workspace root is resolved, in order, from
`SPECRELAY_RUNNER_WORKSPACE_ROOT_<WORKSPACE_KEY>`,
`SPECRELAY_RUNNER_WORKSPACE_ROOT`, then the config's `workspace_roots` map. The
shared **development token** (`platform.token_env`, default
`SPECRELAY_RUNNER_API_TOKEN`) still authenticates API calls but, since MVP-0017,
**cannot claim work**: it authenticates no machine identity, so it holds no
workspace grant.

### There is no Platform-side execution command

`bin/platform runner once|loop` was removed in MVP-0015 and now refuses with a
pointer here. Platform keeps only the commands that operate on **its own state**:

```bash
bin/platform runner release <run-id|task-id|ticket-key>   # free a stuck/stale claim
bin/platform runner cancel  <run-id|task-id|ticket-key>   # terminally stop a run
bin/platform runner sweep-leases               # reclaim lapsed leases
bin/platform runners issue-registration-token|list|revoke|rotate-credential
```

## The real provider: one Claude Code profile

The runner supports exactly **one** real provider profile — Claude Code — and it
is a *validated* profile, not an arbitrary command string that happens to work on
your laptop. Supporting a second provider requires its own approved
specification; there is no plugin registry and no auto-detection here on purpose.

Select it in your own runner config:

```yaml
runner:
  executor:
    provider: claude
    command: claude                  # or an absolute path whose basename is `claude`
    args: [--print, --dangerously-skip-permissions]
    prompt_delivery: argument
    timeout_seconds: 900
    env: {}
```

`SpecrelayRunner::ClaudeProfile` ([lib](lib/specrelay_runner/claude_profile.rb)) is
the only place that knows anything Claude-specific. `Executor` and `CommandRunner`
stay provider-agnostic — they launch an argv array and nothing more.

### It refuses a profile that breaks the bounded contract

These are enforced, with a test per flag, not documented hopes:

- `--print`/`-p` is **required** (non-interactive), and `prompt_delivery` must be
  `argument` so the prompt stays one distinct argv element — no shell, no
  interpolation, no `eval`.
- `command`'s basename must be `claude`. Another CLI is refused rather than
  silently executed.
- Refused flags: `--output-format`, `--input-format`, `--mcp-config`,
  `--strict-mcp-config`, `--bg`/`--background`, `--chrome`, `--remote-control`,
  `--tmux`, `-c`/`--continue`/`-r`/`--resume`/`--fork-session`/`--session-id`.
- `env:` must carry **no credential** — that block travels to Platform in the
  claim request, so the runner fails closed instead of redacting afterwards.

### Readiness is checked before any claim

With this profile selected, `claim-once` runs a local, no-edit readiness check
and **exits non-zero having sent no claim request at all** if it fails. It runs
exactly two bounded metadata commands, `claude --version` and
`claude auth status`, and nothing else — no prompt, no inference, no repository
access, no claim consumed.

```text
Executor: claude claude --print --dangerously-skip-permissions (prompt via argument)
Readiness: claude=available, auth=authenticated
```

Only a classification is recorded: `available`, `unavailable`, `authenticated`,
`not_authenticated`, or `check_failed`. `claude auth status` returns your account
email, org id, and org name — the runner reads a single boolean out of it and
**discards the rest**. It never reaches a console, log, report, event, or Platform.

Not ready gives you the classification and a remedy (`install Claude Code so
`claude` resolves on this runner's PATH`, or `run `claude auth login` as this
runner's operator on this host`).

Both the readiness probe and the executor launch resolve `claude` through the
**same** effective `PATH`, so readiness can never pass against one CLI while
execution runs another.

### It fails closed on an unexpected claim payload

Platform is authoritative for the effective executor policy (it merges your
`executor:` override over the workspace definition). If the claimed payload is not
the profile you selected — say the workspace still resolves to the fake executor —
the runner refuses to launch it and reports `preflight_failed`. No worktree, no
executor launch, no report, no branch or pull request, no Jira transition. It
prints the exact `bin/platform runner release <task>` recovery command.

### Failures after the claim are classified honestly

| Classification | Meaning |
| --- | --- |
| `executor_unavailable` | the CLI could not be started on this host at all |
| `executor_not_authenticated` | the CLI's own output shows an auth failure |
| `executor_timeout` | `timeout_seconds` elapsed; the child process group was killed |
| `executor_failed` | any other non-zero exit |

Each uploads a failed terminal result and report: the run stays out of review,
Jira does not advance, and nothing reviewable is published. A real model that
produces no usable change is a **valid failed run**, not a reason to fall back to
the fake executor.

Reports keep redacted command metadata (the prompt appears only as `<PROMPT>`),
exit status, duration, a bounded redacted transcript, diff, test output, terminal
result, and publication facts. They never carry provider credentials, raw auth
output, account identity, hidden reasoning, tool-call streams, or session ids.

## The deterministic demo executor

[`bin/specrelay-fake-executor`](bin/specrelay-fake-executor) applies scripted
find-and-replace edits from its environment so the whole pipeline can be tested
and demonstrated without a real AI provider.

**It is not the real product executor.** It does not read a specification, reason,
or write code. It remains required for offline and regression coverage, and a run
that uses it **never invokes the Claude readiness checks** — you do not need Claude
Code installed or authenticated to run the deterministic demo. Changing your own
runner-local real override cannot alter the Platform-seeded fake Tiny Demo
workspace definition, so the two stay independently runnable.

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
  cli.rb                        # argv -> config/connection -> client -> claim/execute
  loop_runner.rb                # the long-running poll/claim/execute loop (MVP-0018)
  poll_interval.rb              # validated, bounded --poll-interval value object
  connect.rb                    # the guided connection: code -> assignment ->
                                #   checkout validation -> readiness -> Keychain
  secret_store.rb               # macOS Keychain adapter; NO plaintext fallback, credential
                                #   delivered on stdin (never argv), account per RUNNER identity
  repository_check.rb           # local checkout identity validation (git, offline)
  connection_store.rb           # non-secret local connection record (0600), including
                                #   the operator's EXPLICIT default workspace (v2)
  connection_operations.rb      # the ONE implementation of list/test/default/disconnect,
                                #   shared by the dashboard and the direct commands
  connection_diagnosis.rb       # the non-claiming readiness test: local state -> credential
                                #   -> Platform -> grant -> repository -> executor
  connection_view.rb            # the shared non-secret rendering rules (no local path in
                                #   the top-level list; full detail in the detail view)
  connections_command.rb        # `connections …`: argv -> one operation -> exit code
  terminal_menu.rb              # small raw-mode keyboard menu (io/console); pure key decisions
  dashboard.rb                  # the control center's top level (MVP-0021)
  workspace_view.rb             # the per-workspace detail view and its actions
  config.rb                     # local YAML config (secrets from ENV only), or
                                #   built from a stored connection
  platform_client.rb            # the ONLY Platform touchpoint (HTTP/JSON)
  command_runner.rb             # safe argv process launch + timeout
  claude_profile.rb             # the ONE real provider profile: validation,
                                #   readiness, fail-closed match, classification
  workspace.rb                  # worktree create + git diff capture
  executor.rb                   # launch the configured executor with the prompt
  report_bundle.rb              # build manifest + evidence, base64 for upload
  event_emitter.rb              # per-attempt sequence + v1 event envelope (mutex-guarded:
                                #   the log stream allocates sequences concurrently)
  executor_log_stream.rb        # live executor output: redact -> clip -> budget -> batch,
                                #   terminal print + ordered log events + report evidence
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
  support/fake_claude_cli.rb    # an on-disk executable named `claude` (no inference)
  support/fake_secret_store.rb  # the shared in-memory Keychain stand-in
  dashboard_tty_test.rb         # the dashboard under a REAL pty, incl. terminal restoration
  keychain_tty_test.rb          # credential delivery under a REAL controlling terminal
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
ruby -Itest test/claude_profile_test.rb
ruby -Itest test/real_executor_flow_test.rb
ruby -Itest test/live_log_test.rb
ruby -Itest test/loop_mode_test.rb
ruby -Itest test/connect_flow_test.rb
ruby -Itest test/secret_store_test.rb
ruby -Itest test/keychain_tty_test.rb
```

The suite never invokes the operator's real Claude Code, real account, or any
inference: `real_executor_flow_test.rb` strips every directory holding a real
`claude` out of the child `PATH` and prepends its own on-disk double.

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
- **`claude_profile_test.rb`** (MVP-0016) covers the real profile as a unit: the
  accepted argv, a refusal for every forbidden flag and for a credential in `env:`,
  the readiness classifications (ready / unavailable / not authenticated / timed
  out) through an **injected** command seam that mutates no ENV and needs no live
  CLI, proof that the readiness result carries no account detail and runs only the
  two bounded metadata probes, the fail-closed payload comparison, and the four
  failure classifications.
- **`real_executor_flow_test.rb`** (MVP-0016) drives the real profile through the
  whole runner against an on-disk executable named `claude`, so PATH resolution,
  readiness, argv assembly, worktree creation, the real test command, and report
  upload are all the runner's real code. It proves a readiness failure performs
  **zero** Platform requests and creates no worktree; that the fake-executor path
  never invokes the CLI at all; that a claimed payload which is not the selected
  profile is refused without executing it; that the prompt arrives as one distinct
  argv element and is stored only as `<PROMPT>`; that a non-zero exit, an auth
  failure, a real wall-clock timeout, and a CLI that disappears after the claim
  each produce a correctly classified failed report with no pull request; and that
  no account identity, auth output, or leaked token ever reaches the upload.

## Related

- Platform (control plane): `SpecRelay/SpecRelay-Platform`
- Runner API contract and trust model: `docs/runner-api.md` in the development
  workspace
- Operator setup walkthrough: `docs/local-runner.md` in the development workspace
