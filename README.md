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
**git**, **`gh`** if your Platform policy asks for pull requests, and
**`cloudflared`** — the loop runs this machine's own preview connector with it;
you install the program and configure nothing for it.

```bash
git clone git@github.com:SpecRelay/SpecRelay-Runner.git
cd SpecRelay-Runner
bin/specrelay-runner version
```

## Usage — the normal path

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
   is one of the real provider profiles;
5. prove the **Keychain accepts a write**, using a throwaway non-secret item — only when this
   machine holds no credential yet, because that is when a write is certain to be needed;
6. **exchange** the code, presenting the credential this machine already holds for this
   Platform (if any) in the `X-SpecRelay-Runner-Credential` header, so Platform can recognise a
   reconnect;
7. store the durable credential in the **macOS Keychain** — skipped entirely when
   Platform replied `credential_unchanged`, because there is nothing new to store —
   and, on every successful exchange, this machine's own **preview connector token**
   beside it under its own runner-scoped account, so a reconnect replaces the
   connector without touching the credential;
8. write non-secret connection facts to `~/.specrelay/runner/connections.json`
   (mode `0600`, and you never need to edit it) — including the **reviewer provider
   identifier** this machine selected, when it advertised a reviewer at all, so review
   later runs with the same provider it reported ready;
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

The credential is stored under ONE **registration-scoped** Keychain account
(`runner:<runner-public-id>`), because that is its actual scope —
`registered_runners.credential_digest` is per registered runner, not per workspace. A machine
holds one registration per project, so connecting another workspace of a project it already
knows presents that registration's credential and leaves it authenticating, while a NEW project
is issued its own.

The credential for a lane is resolved through that lane's registration and nothing else. A
superseded per-workspace account is never read: it cannot say which project it belongs to — two
projects may use the same workspace key — so reading one could authenticate a lane with another
project's secret. A machine still holding one reconnects once, and its missing credential is
reported with that remedy rather than silently substituted.

It travels in a **header**, never the request body, so it cannot reach Rails' parameter log.

### 2. Execute work

Two commands. `loop` is the normal mode for a connected machine; `claim-once` is
the controlled single shot.

```bash
bin/specrelay-runner loop                            # poll, claim one at a time, repeat
bin/specrelay-runner loop --workspace <selector>     # when several are connected here
bin/specrelay-runner loop --poll-interval 300        # 5-3600s (default 10s)
bin/specrelay-runner loop --on-failure stop          # end the session after a failed run

bin/specrelay-runner claim-once                      # exactly one claim, then exit
bin/specrelay-runner claim-once --workspace <selector>
```

**One of these runs at a time per OS user.** Both take one local lock
(`~/.specrelay/runner/session.lock`) for the whole invocation, so a second is refused
at once — before it probes a provider, reports presence, starts a connector or claims
anything — whatever project, working directory, config or state file it names:

```text
another SpecRelay runner session is already running on this machine. Stop it first
(Ctrl-C in its terminal), then start this one.
```

Stopping the first releases it: a clean finish, a startup failure and `Ctrl-C` all do,
with nothing to clean up by hand. It is a same-user, same-machine guard, and every
installation in concurrent use must be updated — an older binary does not take it.
`connect`, the dashboard, listings and the readiness test are not sessions and stay
usable while one runs.

Neither needs a config file, an exported credential, a workspace-root environment
variable, or a reviewer-provider environment variable: the credential is read from
the Keychain, the workspace root is the checkout you validated, and the reviewer
provider is the one recorded when you connected.

**The preview connector.** `loop` starts this machine's own preview connector with
`cloudflared` before its first claim and keeps exactly one running for the session,
from the token stored when you connected — no tunnel name, credential file,
certificate, or environment setting. The token reaches `cloudflared` only through a
private temporary file, removed once the connector is up; it is never an argument
and never printed. A missing program or a missing stored token stops the session
before any claim and names the one remedy: install `cloudflared`, or reconnect. The
connector stops with the loop, including on Ctrl-C. `claim-once` and the `--config`
path manage none. It does not yet carry preview traffic; routing each preview to the
machine that owns it is the next slice.

Which connection an argument-free invocation uses, and why, is resolved in this
order: `--workspace`, then this machine's **explicit default**, then the
sole stored connection. Anything else asks. The chosen source is printed, so the
decision is visible rather than inferred:

```text
Source:   connected workspace https://platform.example.com#tiny-demo/tiny-demo-workspace (your explicit default workspace)
```

**Selectors.** Platform scopes a workspace key to a project, so the same key can
appear in two of them. A connection is named by the whole tuple — origin, project,
workspace key — printed by `connections list` and `connections show`, and accepted by
`--workspace` and every `connections` subcommand. `project/key` and the bare key work
too, but only while they name exactly one connection; when one names several, nothing
is claimed and nothing is read, and the runner lists the full selectors instead of
choosing. The selector is a local label — Platform is still sent the raw workspace
key.

`claim-once` claims at most one eligible run (**Platform** decides which), executes
it, and uploads the report. Exit `0` on completion, no eligible work, or a generated
specification package (below), `1` on a failed execution or a refused generation,
`2` on a config/usage error.

### Claiming an automated review

A claimed **review** runs on the same connected machine through the same commands, with
no per-invocation configuration:

- **The provider comes from the connection.** `connect` resolves the reviewer once, reports
  that identity to Platform, and stores the provider identifier locally. `claim-once` rebuilds
  `runner.reviewer.provider` from that record, so no `SPECRELAY_RUNNER_REVIEWER_PROVIDER` is
  needed. Only the identifier is stored — never a command, argument list, timeout, environment
  map, or account: the supported provider resolves its own executable, which is exactly why the
  identifier is enough. (The deterministic development fixture has no default executable and still
  takes `SPECRELAY_RUNNER_REVIEWER_COMMAND`.)
- **A real Claude review streams.** The reviewer runs in the same supported
  structured mode the executor does, so its safe public activity — narration, tool calls,
  commands, file reads and edits, tests, delegated tasks — appears in this terminal as it
  happens, and the verdict comes from the same decoder's terminal result. That stream is local
  only: nothing of it is sent to Platform or persisted. An `args:` list you write yourself must
  therefore request `--print`, `--output-format stream-json` and `--verbose`; a list that does not
  is refused before the provider is launched, and writing no `args:` at all gets the supported
  default.
- **The reviewed repository is resolved from at most two places:** the connected workspace root
  itself, or one direct child named by the **repository segment** of the pinned key. Platform pins
  `owner/repository`, so `RepoWright/tiny-demo-crm` is looked for at `<root>/tiny-demo-crm` — never
  at a nested `<root>/RepoWright/tiny-demo-crm`. Exactly one of them must be a Git
  repository *at its own top level* whose `origin` matches the assignment's clone URL by identity
  (`host/owner/repo`). Both shapes are normal: a single-repository machine connects the
  repository itself, while a project workspace holds its repositories as direct children.
- **The child must be physically contained.** Its real path must have the real workspace root as
  its parent, checked *before* git is asked anything about it, so a correctly named symlink cannot
  select a repository outside the connected workspace. The configured root itself may still be
  reached through a symlink. A child that resolves to nothing — absent, or a broken link — is
  simply not a location and produces the ordinary refusal.
- **Nothing else is ever inspected** — no parent, sibling, grandchild, registry, or search — and
  a directory's name is never taken as repository identity.
- **It fails closed.** No match, more than one match, a different remote, a missing pinned
  commit, or an unreadable remote head all refuse *before* a reviewer is launched, and are
  reported to Platform as a retryable failed attempt rather than a verdict. A head that moved on
  the remote is reported as a stale target instead, both before the reviewer starts and again
  immediately before any verdict is submitted.
- **A connection made before reviewer selection existed holds none.** It stays fully usable for
  implementation and specification work; a review claim fails with one remedy — run `connect`
  again for that workspace — and is never satisfied by guessing from the executor, `PATH`, the
  Platform profile, or a default.

### Two lanes, and one of them writes files

Platform can hand this runner work from either lane, and the runner branches on the
assignment's own `run.type` — never on which fields are missing:

| `run.type` | What this runner does |
|---|---|
| `implementation` | The full flow: owned task environment, executor, tests, report, publication. |
| `spec_creation` | Two phases, each its own claim: **generate** a specification package locally, then — when Platform offers the same run again — **publish** it as a draft pull request. |

#### The task environment belongs to a Run

Both automatic lanes work in an environment your project allocated **for the Platform Run
they were claimed for**, and in no other.

```bash
bin/worktree create  <TASK-ID> --run-id <RUN-ID>          # allocate, recording the owner
bin/worktree status  <TASK-ID> --json                     # who owns it, if anyone
bin/worktree release <TASK-ID> --run-id <RUN-ID> --json   # hand it back
bin/worktree list --json                                  # every environment, with its owner
```

`list --json` prints `{"environments": [{"task_id": …, "owner_run_id": …}]}`: a Run's id for an
environment a run allocated, `null` for one made by hand. A connected `loop` reads it before
every claim, and a row it cannot classify stops the loop, so a project whose `bin/worktree` does
not answer it that way cannot be watched by a connected `loop`.

Allocation names the run and is then PROVED: the runner reads the owner back before it hands
the environment to a provider, so a command that accepted `--run-id` and recorded nothing
refuses the run instead of leaving it an environment it could never release. Continuing an
environment that is already there asks the same question first, before the working tree is
read and before any reset, materialization or publication. Manual, other-run and unprovable
environments are refused untouched — clean or dirty, because clean is not the same as yours.

A project whose `bin/worktree` cannot record an owner refuses the run. The assignment's plain
git creation command is not used as a fallback: it builds a worktree with no owner, which the
run could neither prove on a retry nor hand back at the end.

A run hands its environment back once Platform has RECORDED how it ended, and not before: an
implementation report (success or failure), a specification publication or publication
failure, or a generation failure or refusal. An explicit cancellation this runner observes
while the run is active is an ending too: it ends the run's process group, sends no late
result and hands the environment back. A question pause ends the provider session, so a
cancellation after it reaches no process: before each claim, a connected `loop` offers the
Run-owned environments its project lists and releases the one Platform names as cancelled
after this machine's pause, then claims. It does the same after a restart. An unreadable list,
an unconfirmed answer or an incomplete release stops the loop before it claims. `claim-once`
and a `--config` loop do not ask, and any other late cancellation releases nothing yet.
Everything unpublished in it is that run's own by then and goes with it,
including edits you made there by hand; the runner removes none of it itself. Only an explicit
`released` naming that run, or your project's own proof that there is nothing left, is
completion. A timeout, a non-zero exit, an unreadable answer or a partial teardown is reported
as still allocated — without guessing which files survived, because your project is what
knows — and this machine stops: a single run exits non-zero and a `loop` session ends before
another claim, until you release it by hand.

Two endings keep something back. After a recorded publication failure the runner keeps its
package snapshot, so a publication retry republishes the same files. After a recorded
generation refusal, an environment your project records as manual or another run's is kept
without a cleanup error; any other answer goes to the release above, including an unmapped
workspace root.

Waiting on a question, an expired lease, a result Platform refused, did not record or could
not be reached for, and a report that could not be built all keep the environment and ask for
no release. The terminal result an implementation run submits therefore always says cleanup
has not yet succeeded.

#### What a fresh environment contains

A new environment starts from the project's current heads, never from a leftover task branch.
Before the provider or final analysis runs, the runner places the run's approved inputs into it:

- **The approved specification, at its pinned commit.** The assignment's repository, commit
  and package path must resolve to one contained repository; that exact commit is fetched if
  needed (a newer branch tip never stands in) and its package files must reproduce the
  approved bytes. The provider sees the package at its normal path, identical to its read-only
  delivered copy.
- **Accepted code from earlier rounds**, each head verified as before. Where one repository
  holds both, the runner keeps whichever existing commit carries both inputs unchanged, and
  otherwise refuses with an incompatible-inputs reason. It never merges or overlays files.
- **A specification revision's previously published package**, placed before source is
  gathered, together with any accepted code.

Every repository is checked before the first one is placed. A missing, ambiguous or unsafe
repository or package, an unavailable commit, a byte mismatch or a failed placement refuses
before the provider and before anything is published.

Final preparation, after placement and before any evidence is gathered or the provider starts,
runs the project's own `bin/graph-check`. Allocation may already have built a graph for the
seed; once inputs have been placed that graph is usually stale, so it is rebuilt with
`bin/graph-build` and verified. A graph that is already fresh is not rebuilt. If the rebuild
fails the run stops rather than reusing the old graph. A project without the wrappers continues on
direct source inspection, and a specification lane's recorded Graphify substitute keeps its
existing meaning. The runner then prints the final heads, relative paths only, for example:

```text
Prepared <TASK-ID> at .@<full-sha> repositories/component-a@<full-sha>, approved specification specs/<TASK-ID> pinned at <full-sha> in <owner>/<repository>
```

The specification lane records the same heads in its source evidence and manifest.

A continued run — the same Run's retry, an answered question or a restored checkpoint — keeps
its environment as it is. Its rework or restart target still wins over older accepted code, and
it is never reset to a fresh seed to make validation pass. An incompatible visible package
refuses instead.

Within the specification lane the runner branches a second time, on
`assignment_boundary.expected_runner_action` rather than on the run's state:

| `expected_runner_action` | Phase |
|---|---|
| `generate_specification_package` | Write the package into the operator's specification checkout. Nothing is committed. |
| `publish_specification_package` | Verify the recorded digests, commit, push, and open or reuse one draft pull request. |
| anything else | **Stop.** A build that meets an action it does not implement refuses rather than guessing, and prints the release command. |

Neither phase writes a Jira field, transitions an issue, or adds a comment — that is
the Jira handoff's job, and the assignment says so as data
(`assignment_boundary.publication = "publish_draft_pull_request_only"`).

#### What it writes

```text
<specification-root>/<ISSUE-KEY>-<sanitized-summary-slug>/
  spec.md
  analysis/input-evidence.md
  analysis/business.md
  analysis/technical.md
  analysis/open-questions.md    # only when synthesis found a material product decision
  generation-manifest.json
```

`analysis/open-questions.md` is the one CONDITIONAL file: present
only when generation found at least one material Product Owner decision, using stable ids
(`## OQ-001`, `## OQ-002`, ...) so a later run can reference the same question. Its filename never
encodes count or status — a run with zero open questions omits the file entirely rather than
writing an empty one, and a resolved question's history is retained by keeping the file rather than
deleting entries from it. Each question is validated as EXACTLY three nonblank fields — "Why it
blocks", "Decision required", "Consequence" — with no field missing, duplicated, blank, or
unexpected (review 006 finding F1): a body that does not have one is rejected before anything is
written, rather than a parser guessing which bullet was meant as the decision.

`analysis/input-evidence.md` is always present. It carries one compact, independently reviewable
entry per SUPPORTING input a bundle recorded — a Jam recording, screenshot, Confluence page, log,
attachment, or linked Jira issue — never the ticket's own description or comments, already
reflected in `spec.md`'s own "Input summary" table. Each entry states whether the input was
actually analysed (not merely referenced), what was observed, what that implies for the
requirement, and any limitation — never the raw transcript or tool output behind it.

A linked Jira issue is analysed from its OWN content, not disclosed as a gap (review 006 finding
F2, second pass): Platform now reads each linked issue's key, title, and description one level
deep (`Jira::SpecCreation::EnrichLinkedIssues`) before classifying the bundle, and an issue whose
content could not be read BLOCKS intake through the same terminally-blocked, marked-comment path
as any other unreadable required input — it never reaches generation looking complete. A linked
issue that does reach generation therefore always carries real content, which the selected real
provider is asked to genuinely analyse, including its own stated acceptance criteria. A ticket with no linked issues produces no entry at
all, the same as any other absent supporting input.

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

#### Publishing the package

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
| `specification_folder_unsafe` | The configured specification root is not a safe repository-relative folder. |
| `package_workspace_unavailable` | This machine cannot hold a package workspace: `~/.specrelay/runner/specification-packages` is not writable or sits inside one of your checkouts, or the seed checkout has no resolvable commit. |
| `source_workspace_unresolved` | Map the workspace to its local source checkout (`SPECRELAY_RUNNER_WORKSPACE_ROOT_<KEY>`). |
| `input_content_unreadable` | The bundle offers an input Platform classified as unusable. Re-read the ticket. |
| `external_reference_analysis_unavailable` | A Confluence page or screenshot was deferred to this runner. Enable the capability or record a substitute. |
| `graphify_unavailable` | Graphify is present but incomplete, not executable, stale, or unhealthy. Repair it with `bin/graph-build`, or record a substitute. A repository with neither wrapper installed continues with direct source inspection and records that Graphify contributed nothing. |
| `context_plus_unavailable` | Legacy result from older runners. Current runners continue with an explicit warning when Context+ is unavailable. |
| `generation_provider_unavailable` | No approved real profile could be used: none was selected, or the selection is the fixture, unknown, or altered from the approved profile. Select `claude` or `codex` (Project Setup, or `runner.executor:` here) and make sure that CLI is installed and authenticated on this machine. |
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
belongs here — the external-reference command is a local executable path.

This section does **not** choose a generation provider. That is one closed selection of an
approved profile, made once for the whole machine under `runner.executor:` or in Platform's
Project Setup — see [the two approved profiles](#the-real-providers-two-approved-profiles).

```yaml
runner:
  specification:
    repository_roots:
      # A SEED, not a destination: the runner reads git objects, `origin` and your
      # credential helper from here and writes the package into its own worktree.
      "SpecRelay/SpecRelay-Specs": /abs/path/to/your/specs-checkout
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

Environment overrides: `SPECRELAY_RUNNER_SPEC_REPOSITORY_ROOT_<OWNER>_<REPO>` (or the
unsuffixed `SPECRELAY_RUNNER_SPEC_REPOSITORY_ROOT`).

### Where a generated package lives

The runner creates one detached, `--no-checkout` git worktree per generation under
`~/.specrelay/runner/specification-packages/<opaque-id>/` and writes the package
there. The location is not configurable, and generation refuses outright if that
directory would sit inside your source or specification checkout. Your specification
checkout is never written to.

Publication resumes that exact workspace by its opaque id and verifies the metadata,
the worktree, the base commit, the exact file set and every digest before it runs a
git command. Platform stores the id and the machine that owns it, and offers the
publication to no other machine.

Retention is fixed and not configurable: an unpublished workspace is kept for **seven
days**, at most **twenty** per machine, oldest removed first. A successful publication
removes its own workspace once Platform has accepted the result — never before, so a
lost response can be replayed onto the same commit. If a package expires or its
machine is gone, use **Generate again** on the run page; any connected runner can then
produce a fresh one.

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
receives is one reviewable, redacted packet. Exactly **two** implementations ship, and they are
the two approved real profiles: `claude` and `codex`. There is no built-in deterministic writer,
no operator-configured executable, no registry and no discovery — a lane that could reach a
plausible substitute by configuration is a lane whose output an operator cannot attribute.

Both are the operator's own already-validated profile writing the specification directly,
requiring no separate configuration. They share one prompt and one file-map parser (reviewable in
full in `provider.rb`), which state the document contract below and the required synthesis
discipline: describe the requested product behaviour rather than Jira labels, resolve a vague
ticket reference (e.g. "the text") from the title and the evidence, avoid raw input-bundle or
transcript dumps, and never claim a current publication or Jira state a later reader could find
false. They differ only in what genuinely differs: Claude takes its prompt as one argv element and
is decoded by `ClaudeStream`; Codex takes it on stdin and is decoded by `CodexStream`.

The selection is the machine's one AI provider, read through `ImplementationProfile`: an explicit
local `runner.executor:` selection wins, otherwise the profile Platform's Project Setup sent with
the assignment. A fixture, unknown or altered profile refuses before any process starts and before
any package byte is written — generation never falls back to a substitute writer.

Whatever a provider returns is validated before anything is written, so a
plausible-looking document that silently omits acceptance criteria is rejected rather
than committed. **The document contract a provider must satisfy:**

- exactly the required keys — `spec.md`, `analysis/input-evidence.md`,
  `analysis/business.md`, `analysis/technical.md` — plus `analysis/open-questions.md`
  ONLY when at least one material open question exists; any other key is rejected;
- every document opening with a `#` TITLE that names its role, matched
  case-insensitively as a substring so your own wording and separator are yours to
  choose: `spec.md` names its ticket's key, `input-evidence.md` names "input evidence",
  `business.md` "business analysis", `technical.md` "technical analysis", and
  `open-questions.md` "open questions". Promoting a `##` section name to the title does
  not satisfy this;
- no line that is entirely a parenthesised aside about the document's own construction
  ("placeholder", "content follows", "as instructed", "per the instructions", "omitted
  for brevity") — these documents carry specification content and nothing else;
- every SECTIONED document's required section present as a `##` heading with a
  substantive body (`spec.md`, the two analyses — `input-evidence.md` and
  `open-questions.md` have no fixed heading list, since each is a variable number of
  per-input or per-question entries);
- a present `open-questions.md` names at least one `## OQ-nnn` heading, each with a
  unique id — its own presence asserts that a question exists;
- each question heading's body has exactly one nonblank "Why it blocks", "Decision
  required", and "Consequence" bullet — missing, duplicated, blank, or any other bullet
  is rejected (review 006 finding F1);
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

`loop` does the same repeatedly, at a bounded poll interval. Exit `0`
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

An interrupt DURING an execution is acknowledged while the run is still finishing,
so a Ctrl-C in the middle of a long provider run does not look ignored:

```text
[loop] stop requested — nothing further will be claimed; the run in progress finishes its report first
```

Foreground only, deliberately: no LaunchAgent, no daemonization, no supervisor.

#### Two kinds of terminal output

| | |
|---|---|
| **Transient** | True only *now*, worthless as history: polling, the countdown, a quiet executor. ONE reusable row, redrawn in place, erased when it stops being true. |
| **Durable** | The record: the start block, a claimed task, real executor stdout/stderr, phase transitions, failures, backoff, recovery, results, the session summary. |

```text
[loop] started — polling every 10s, one run at a time, --on-failure continue
[loop] press Ctrl-C to stop; an in-progress execution finishes its report first
| tiny-demo (tiny-demo-workspace) — no eligible work; next check in 7s
```

That third row is the only one that moves; five idle polls add no history at all.
The row is erased before **every** durable line and on every exit path — normal
stop, Ctrl-C, `SIGTERM`, a rejected credential, an exception on its way out — and
all writes from the loop, the live executor stream, the lease heartbeat, and the
execution go through one serialized boundary (`TerminalPresenter`), which is what
keeps three threads from splitting a line.

Every word on that row corresponds to a state the runner is really in. The runner
never displays `Thinking`, `Compiling`, or `Analyzing` unless a real executor line
or a real runner phase produced it, and it never exposes model reasoning.

**Rendering is a capability, not an assumption.** It needs an output terminal;
redirected output (a pipe, a log file, CI) gets no carriage returns, spinner frames,
or ANSI at all, and healthy idling there prints Platform's not-claimed reason once
and again only when it changes.

When nothing was claimed either command reports the reason **Platform** returned, so
a machine that is not connected (or not ready) is told to run `connect` rather than
reading a refusal as a healthy idle — on the transient row in a terminal, as a line
where there is no row to redraw.

### Live executor output

While the executor runs, safe output is streamed to the terminal between
`[core.started]` and `[verification.started]` and submitted to Platform as ordered
live log events, so a working run never looks like a hung one:

```text
[core.started] Running claude executor for YOUR-1234
  [claude:status] Provider started
  [claude:status] Reading demo-app/index.html
  [claude:status] Running test command: bundle exec rspec
  [claude:status] claude executor running for 15s on YOUR-1234 (no new output yet)
  [claude:status] Provider completed
[verification.started] Verifying 1 changed repository(ies) for YOUR-1234
```

**Structured provider output.** Both supported real profiles are structured-output
only — Claude through `--output-format stream-json --verbose`, Codex through
`exec --json` — and a claim that omits them is refused before the process is
launched. Each then writes one JSON object per line while it works, and that stream
is a transport, not operator text. The two turn contracts differ, so each provider
has its OWN Runner-owned decoder (`ClaudeStream`, `CodexStream`); each produces the
same two independent things: safe public progress, and the terminal result.

**The public transcript is projected once.** Public assistant prose, tool calls and
results are rendered from the structured stream; private reasoning, transport
wrappers, session identity and raw diagnostic bytes are not. Before any rendered
text is clipped or fanned out, absolute local paths are sanitized. A path proven
inside the assigned implementation worktree is shown repository-relative; every
other absolute path becomes `[LOCAL_PATH]`. Specification creation has no approved
root, so all of its absolute paths use the placeholder. An unquoted path followed
by ambiguous prose is conservatively withheld through the next strong shell
boundary or line end; privacy takes precedence over retaining that suffix. Quoted
paths and explicit adjacent shell operators retain their deterministic boundaries.
The attempt fails closed without displaying the frame for malformed output, a
missing terminal result, or a second terminal result without a matching refused
question turn. Both workflows use this one decoder and this one stream; there is
no lane-specific path rule.

A `core.progress` **heartbeat** still names the elapsed time after 15s of genuine
silence. It is a fallback, never a substitute: real output, when available, is what
you see.

In a terminal that heartbeat is **transient**: the `[claude:status]`
row replaces itself instead of appending a line every 15s, and real provider output
clears it before printing. Platform still receives every `core.progress` event and
the report evidence still records each one — the durable protocol and evidence
records are unchanged; only the terminal representation became transient. With no
terminal to redraw it stays a plain line at the same bounded interval.

Every line is redacted before the terminal write **and** before upload and clipped
at 2000 bytes; each uploaded event carries at most 65536 bytes and 200 whole lines.
There is no whole-attempt byte budget: those bounds SPLIT a long stream
into more events, they never stop it, so Platform receives the attempt's complete
sanitized output. Output is flushed, because Ruby block-buffers a non-terminal
stdout and an unflushed live log is just a delayed one.

It cannot break the run: a consumer that raises is swallowed, an upload failure is
counted and reported once, and the buffered capture plus the child's exit status are
observed independently of any of it.

**Delivery never blocks the work.** Reading the child only redacts, bounds, prints
and buffers; every Platform request is made by the stream's own timer thread, so a
slow or hanging Platform cannot back-pressure the provider's stdout pipe. The same
rule holds at the end of an attempt: `finish` performs no Platform request of its
own. It hands the last delivery to that thread and waits a small fixed shutdown
budget — deliberately independent of the client's 1,800-second read timeout — so a
finished provider's result, package and report are never held behind the progress
channel.

**Retries preserve identity; gaps are named.** A transport failure keeps the
envelope and a later delivery opportunity re-sends the *original* bytes at the
*original* sequence, so Platform's existing idempotency rules decide whether each
one is new or a duplicate and a reconnect can never renumber or re-render progress.
Deliveries are serialized on the one thread, so an older sequence always precedes a
newer one. A refusal — Platform read the payload and rejected it — is dropped
rather than retried forever. Whatever is still unacknowledged when the attempt ends
is reported once, locally, as a delivery gap: it says at least N updates were not
acknowledged before the attempt ended and that delivery may still have succeeded,
because a request stopped mid-flight may well have been accepted. Platform orders
by sequence and reports any gap it sees, so a missing update is visible on both
sides rather than silently absent.

**The result is not the progress.** The package, the report and the attempt's
outcome are parsed from the provider's terminal result alone, and keep their
existing authoritative validation and bytes. Progress delivery failing — or being
cut short at shutdown — changes none of them, and a run is never reclassified
because its live view was incomplete.

The report carries no copy of the live stream. Platform's accepted protocol events
are the complete sanitized transcript and the run page pages through all of it, so a
second bounded copy in the report could only ever be a shorter, staler answer to the
same question. `evidence/stdout.log` and `evidence/stderr.log` still hold the full
capture taken for review, redacted before they are written.

Platform authorizes a claim only for a workspace this machine has explicitly
connected to and been recorded `ready` for — and only while its reported
repository identity still matches that workspace. A historical `all_eligible`
claim policy grants nothing on its own.

### 3. Manage this machine's connections

```bash
bin/specrelay-runner            # in a terminal: opens the local control center
bin/specrelay-runner            # with no terminal: prints usage, exits 2
bin/specrelay-runner help       # always prints help, exits 0
```

The dashboard lists the **projects** this machine is connected to and, for a
selected one, offers: `Start live loop`, `Claim once`, `Test connection/readiness`,
`Show details`, `Set as default` / `Clear default`, `Disconnect locally`,
`Disconnect from Platform`, `Back`.

Each row leads with the project and keeps its workspace key beside it:

```text
 1  tiny-demo · tiny-demo-workspace · specrelay/tiny-demo-workspace@main · 2d ago
```

The project is the operator's concept; the workspace key is the routing fact Platform
uses, and the only thing that distinguishes two connections to the same project. A
record stored before project metadata existed falls back to the workspace key rather
than to a guessed name.

A machine may hold as many projects as it has connected — each with its own
registration and credential — and adding one never disturbs another. The list scrolls
to keep the highlighted row and the footer on screen, says how many rows are out of
sight, and gives the first nine an immediate `1`–`9` shortcut; the rest are reached
with the arrows.

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
and `Start live loop` / `Claim once` hand `["loop", "--workspace", <selector>]` to the
CLI's own dispatcher. They cannot drift from the direct commands, because they
*are* them; the command line is echoed before it runs so it can be copied.

**Ctrl-C in a menu-launched live loop returns straight to that project's menu**,
with no acknowledgement keypress: the operator pressed Ctrl-C to come back, and the
loop has already printed its own session summary. `Claim once`, and a loop that
ended in a failed run or a rejected credential, still wait for a key — the next
menu frame clears the screen, so without the pause the result would be unreadable.
Which behaviour applies is passed in explicitly per action, never inferred.

Every action is also scriptable, needs no terminal, and never prompts:

```bash
bin/specrelay-runner connections list
bin/specrelay-runner connections show <selector>
bin/specrelay-runner connections test <selector>
bin/specrelay-runner connections default <selector>
bin/specrelay-runner connections clear-default
bin/specrelay-runner connections disconnect-local <selector> [--remove-credential]
bin/specrelay-runner connections disconnect-platform <selector>
bin/specrelay-runner connections forget-legacy-credential <workspace-key>
```

The default is stored as a full selector and pinned to the connection it names before
another is added, so connecting a project that reuses a workspace key cannot move it.
Two operations fail closed as a result: connecting while the stored default no longer
names exactly one connection is refused **before the enrollment code is spent**, and
removing one of the connections an ambiguous default names is refused because the
survivor would silently inherit it. Settle it with `connections default <selector>` or
`clear-default` first.

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

The runner credential is scoped to the **registration**, one per project, so a local
disconnect keeps it while any other local connection still uses it. When nothing
depends on it any more you are asked separately (dashboard) or must pass
`--remove-credential` (script). A superseded per-workspace Keychain item is removed
only by `forget-legacy-credential`, which names the exact account it removes —
nothing else in the runner ever deletes one. That command is cleanup only: such an
item is no longer read to authenticate anything.

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
set a new machine up.

There is no command that enrols a machine from this file. A machine gets its
identity from `connect`, which is the one path that also tells Platform which
project the machine joins and which member owns it; a hand-written config only
says how to *use* a credential that already exists.

Copy [`config/runner.example.yml`](config/runner.example.yml) to a real path (for
example `~/.specrelay/runner.yml`) and edit it. The config carries **no secret**:
the runner credential and the development token are both read from environment
variables the config only *names*. Point the runner at it with `--config <path>`
or `SPECRELAY_RUNNER_CONFIG`; an explicit `--config` always wins over a stored
connection.

```bash
# Connect the machine once; the credential is stored in the OS secret store.
bin/specrelay-runner connect <connection-code>

# Claim with a hand-written config and that credential in the environment.
export SPECRELAY_RUNNER_CREDENTIAL=<the credential for this machine>
bin/specrelay-runner claim-once --config ~/.specrelay/runner.yml
```

On this path the physical local workspace root is resolved, in order, from
`SPECRELAY_RUNNER_WORKSPACE_ROOT_<WORKSPACE_KEY>`,
`SPECRELAY_RUNNER_WORKSPACE_ROOT`, then the config's `workspace_roots` map. The
shared **development token** (`platform.token_env`, default
`SPECRELAY_RUNNER_API_TOKEN`) still authenticates API calls but
**cannot claim work**: it authenticates no machine identity, so it holds no
workspace grant.

### There is no Platform-side execution command

`bin/platform runner once|loop` was removed with the runner extraction and now refuses with a
pointer here. Platform keeps only the commands that operate on **its own state**:

```bash
bin/platform runner release <run-id|task-id|ticket-key>   # free a stuck/stale claim
bin/platform runner cancel  <run-id|task-id|ticket-key>   # terminally stop a run
bin/platform runner sweep-leases               # reclaim lapsed leases
bin/platform runners list|revoke|rotate-credential
```

## The real providers: two approved profiles

The runner supports exactly **two** real provider profiles — Claude Code and Codex — plus the
deterministic fixture. Each is an *audited* profile, not an arbitrary command string that happens
to work on your laptop. Supporting a third provider requires its own approved specification; there
is no plugin registry, no auto-detection and no fallback from one provider to another.

| Provider | Command | Invocation | Prompt | Timeout |
| --- | --- | --- | --- | --- |
| `claude` | `claude` | `--print --output-format stream-json --verbose --dangerously-skip-permissions` | one argv element | 1800s |
| `codex` | `codex` | `exec --json --ephemeral --dangerously-bypass-approvals-and-sandbox` | stdin | 1800s |
| `fake` | `specrelay-fake-executor` | none | prompt file path | 120s |

Select one in your own runner config by naming the provider — and only the provider:

```yaml
runner:
  executor:
    provider: codex          # claude | codex | fake
```

A block that says anything more is refused: the command, arguments, prompt delivery, timeout and
environment belong to the profile, not to this file.

`SpecrelayRunner::ImplementationProfile`
([lib](lib/specrelay_runner/implementation_profile.rb)) is the one place that decides what may run.
`ClaudeProfile` and `CodexProfile` own only what is genuinely provider-specific — readiness probes,
the safe version fact, the claimed-versus-selected comparison and failure classification. `Executor`
and `CommandRunner` stay provider-agnostic: they launch an argv array and nothing more.

### It refuses anything that is not an approved profile

The claimed executor block is compared against the approved profile **as a whole hash** — the same
keys, the same values, nothing missing, nothing extra, nothing spelled differently — *before* a
worktree exists and *before* any process starts. That is the whole rule; there is no tolerant
validator and no denylist of individually forbidden flags to keep up to date.

So a claim is refused when it changes the command, reorders or adds an argument, alters the prompt
delivery or timeout, adds an environment entry, decorates the provider name, omits a field, or
carries a key the profile does not own. `codex` pins no model and `--ephemeral` prevents session
reuse, so a resumed conversation cannot influence an automated run.

`env:` is empty for both real profiles. That block travels to Platform in the claim request, so a
token smuggled in there would leave your machine; the runner fails closed rather than redacting
afterwards.

### Readiness is checked before any claim

With a real profile selected, `claim-once` runs a local, no-edit readiness check
and **exits non-zero having sent no claim request at all** if it fails. It runs
exactly two bounded metadata commands for that provider — `claude --version` and
`claude auth status`, or `codex --version` and `codex login status` — and nothing
else: no prompt, no inference, no repository access, no claim consumed.

```text
Executor: codex codex exec --json --ephemeral --dangerously-bypass-approvals-and-sandbox (prompt via stdin)
Readiness: codex=available, auth=authenticated, codex-cli 0.153.4
```

Only a classification is recorded: `available`, `unavailable`, `authenticated`,
`not_authenticated`, or `check_failed` — plus, for Codex, one strictly parsed and
length-bounded `codex-cli <version>` fact. An auth probe returns your account
identity; the runner reads a single classification out of it and **discards the
rest**. It never reaches a console, log, report, event, or Platform, and version
output that is not exactly the proven form becomes `check_failed` rather than
being repeated anywhere.

Not ready gives you the classification and a remedy — install the CLI so its name
resolves on this runner's `PATH`, or log in as this runner's operator on this host.

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

**A supervised command ends with its whole process group.** The provider, verification and your
project's `bin/worktree` commands each run in their own process group, and the runner goes on
only once that whole group has ended, including after the command itself exits normally. A
background process the command left in that group is terminated: TERM, then KILL, each with a
5-second bound. If the runner cannot show that the group has ended, it stops the invocation with
exit 1 and `Runner stopped: a supervised command could not be shown to have ended: process group
<N> …`. A report or a release may already have happened by then, so the environment may or may
not still be there; make sure that process group has ended before starting the runner again.
This is process supervision only: a process that moved into its own session is not covered, and
supervision itself releases no environment.

Reports keep redacted command metadata (the prompt appears only as `<PROMPT>`),
exit status, duration, a bounded redacted transcript, diff, test output, terminal
result, and publication facts. They never carry provider credentials, raw auth
output, account identity, hidden reasoning, tool-call streams, or session ids.

### When the report itself cannot be built

Report construction happens before the final result is submitted to Platform.
If it fails, the runner prints the known work outcome — including available exit,
timeout or launch facts for failed verification — separately from the sanitized
construction error. Execution and verification may have succeeded even though
the report could not be built.

The runner explicitly states that **the final result was not submitted to Platform**
and exits non-zero. A `loop` session stops even under `--on-failure continue`.
There is no automatic report-delivery retry, and this failure does not trigger
task-environment release.

Repair the reported report-generation dependency or file problem, inspect the run
in Platform, and use the existing
[`bin/platform runner release`](#recovering-a-stuck-claim) step only if the claim
still needs releasing before restarting. This diagnostic makes no claim about
the run's current state on Platform.

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

## Proportional repository verification

No project configures a test command. For every repository it changed, the executor
selects the smallest relevant verification by reading that repository's own instructions,
scripts, manifests and CI configuration, runs it, repairs what it can, and reports the
final argv in `changed-repositories.json`.

The runner then **replays** every reported command itself, after change measurement and
before any external write:

- from the verified repository root as `chdir`, never the workspace above it;
- as an argv array through `CommandRunner`, never a shell string;
- against the executor's final files, with the existing timeout, cancellation checks,
  output bounds and redaction.

`RepositoryVerification` derives one outcome per repository from what those processes
actually did — nothing the executor claims is evidence:

| Outcome | Meaning |
|---|---|
| `passed` | Every reported command exited zero. |
| `not_found` | The executor reported no applicable command. Valid and non-blocking. |
| `failed` | A command exited non-zero, timed out, or could not be launched. |

An ordinary failure does not stop the remaining bounded commands, so every changed
repository receives a complete outcome. One `failed` repository blocks the whole run: no
commit, push, pull request, or successful terminal result, and the failed report carries
the repository identity, safe argv, exit/timeout/launch result and bounded redacted
output. Cancellation and a lost claim keep their existing endings instead of becoming a
verification result, and the runner never re-invokes the executor to repair — the
executor's own session was the repair opportunity.

Because a command can change the tree it just verified, the runner re-measures the
publishable state of every prepared repository after replay and compares it with the
state that was measured before it. Tracked or untracked publishable drift, HEAD movement,
a changed selected-repository set, or a selected repository that became clean fails the
run closed with zero GitHub mutation — the report can never describe a different tree from
the one publication would push. Ignored command output is harmless.

An empty selection stays a valid no-change success and reports an empty verification
collection, which is a different thing from one changed repository reporting `not_found`.

Project commands (the project's create command, the executor and every replayed command) run
without the Runner's own Ruby, gem and Bundler activation; `PATH`, home and authentication
settings are kept. Each reported command must therefore be complete on its own: it goes through
the project's entrypoint that selects its runtime and dependency location, so the project's
installation stays separate from the Runner's. A shell `cd`, `source`, `rvm use` or `export` from
the executor's session does not carry over. If the required runtime or entrypoint is missing, that
command fails with its own reason and blocks publication; it is never replaced by another
interpreter or reported as `not_found`.

## GitHub publication

After every changed repository passes verification and before the report upload,
the runner publishes
the changed repository output to GitHub — commit, push the run's canonical task
branch, and create or reuse a draft pull request, **once per selected repository**
([`lib/specrelay_runner/publication.rb`](lib/specrelay_runner/publication.rb)).

Ownership is split. **Platform decides HOW**
(`repository_policy` / `links`: access, whether a pull request is required, whether it
is a draft) and sends **no eligible-repository list**. **The executor decides WHICH**,
because a task workspace may hold several independent repositories and only the executor
knows what its change touched. **The runner decides nothing** — it verifies the
executor's selection locally, runs git/gh, and reports facts.

The executor states its selection in one bounded document,
`changed-repositories.json`, written into the attempt's staging directory (outside the
task workspace). Each entry holds a relative path — `"."` names the task workspace
repository itself — and the verification the executor selected for that repository, as
argv arrays:

```json
{ "repositories": [ { "path": ".", "commands": [ [ "bin/test" ] ] },
                    { "path": "component-a", "commands": [] } ] }
```

Prose and terminal output are never parsed, and the document is closed: `path` and
`commands` are both required, any other key is refused, and a shell string where an argv
array belongs is refused. A missing document fails the attempt; an empty list is a valid
"nothing changed" answer that publishes nothing.

`"commands": []` is the executor's answer that this repository has no applicable
verification. It is valid and non-blocking — see
[Proportional repository verification](#proportional-repository-verification).

[`Workspace#select`](lib/specrelay_runner/workspace.rb) then proves every entry before any
external write — relative, inside the task workspace, a git repository **root**, a
supported GitHub `origin`, on the run's canonical branch, holding a change of its own, and
unique by both resolved path and normalized remote. Any failure refuses the WHOLE
selection: publication is all-or-fail, so a partially publishable selection never becomes
a partially published run.

Each repository is then published by its own `Publication` instance, so one repository's
worktree, commit or pull request cannot leak into another's. The branch is always the run's
canonical branch; the runner never invents one, and Platform rejects a reported branch that
is anything else.

Commands used, all as argv arrays through `CommandRunner` (never a shell string,
so provider or work-item text can never be interpolated into a command line):

```bash
git -C <worktree> add -A
git -C <worktree> -c user.name=… -c user.email=… commit --no-verify -m "<TASK-ID>: …"
git -C <worktree> push origin HEAD:refs/heads/<canonical-branch>  # never --force
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
  request from an earlier round on the same canonical task branch
  is never reported as this round's output — it no longer tracks the branch, so it
  may not contain the change. Such a round opens a **new** pull request instead.
- **The runner refuses to push the repository's `default_branch`**, comparing the
  canonical branch against the `default_branch` read from that repository's own
  `origin/HEAD`. Verification refuses it first; this is the runner-side half at the
  publication boundary, so a regression upstream still cannot push onto `main`.
- **A remote credential is never transmitted.** A configured `origin` may carry
  credential userinfo. It is read in exactly one place, to identify the repository, and
  what travels onward is the canonical `https://github.com/<owner>/<repo>.git` derived
  from the validated slug.
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
- **Unchanged** repositories get no commit, no branch, and no pull request. A reported
  repository with nothing to publish refuses the selection rather than publishing an
  empty change.
- **A retry in the same workspace recovers.** After a partial failure the selected
  repositories are already committed and their working trees are clean, so the change is
  measured from the task branch against the repository's default branch instead —
  exactly what the pull request contains. The existing commit, branch and pull request
  are reused and only the missing pull request is created. Nothing is retained on disk
  between attempts to make that work.
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
bin/test                        # the complete suite: one process per file, bounded
                                #   workers, one suite per checkout, one truthful total
config/runner.example.yml       # the one operator-facing config example
lib/specrelay_runner.rb         # requires
lib/specrelay_runner/
  cli.rb                        # argv -> config/connection -> client -> claim/execute
  loop_runner.rb                # the long-running poll/claim/execute loop
  preview_connector.rb          # this machine's own preview connector: one child per loop
                                #   session, token via a private file (never argv), no state
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
  dashboard.rb                  # the control center's top level
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
  executor_log_stream.rb        # live executor output: redact -> clip -> batch -> cut,
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

No gems and no test runner to install — plain minitest on the standard library.
`bin/test` is the one command that runs the complete suite:

```bash
bin/test                 # every test/*_test.rb file, two at a time, one process each
bin/test --workers 1     # the same closed set, serially
bin/test --workers 4
```

It keeps the suite's own isolation contract — each file still runs in its own
`ruby -Itest` process — and adds what a shell loop cannot state truthfully:

- **One suite per checkout.** The command holds a non-blocking advisory lock on
  the physical checkout for its whole run. A second invocation against the same
  checkout refuses immediately (exit `3`) instead of queueing, attaching, or
  competing for the host. Two checkouts are independent.
- **Bounded workers.** Only `1`, `2`, and `4` are accepted, and anything else is
  rejected (exit `2`) before a single test process starts. The worker count is
  not derived from the host's processor count. Two is the default because it is
  the smallest mode whose measured median cleared the approved threshold against
  the serial suite; four measured faster still and remains available as an
  explicit mode.
- **Attributable output.** Each file's stdout and stderr are captured and printed
  as one delimited block naming that file, its result, and its duration, so
  concurrent output never interleaves anonymously.
- **Bounded capture.** The command drains each file's output as it is produced
  into a fixed 64 KiB ring, and writes none of it to disk. A file that prints
  less than that is shown in full; a file that prints more keeps only its final
  65 536 bytes, prefixed by the exact number of earlier bytes discarded. What a
  flooding file costs the command is therefore constant, not proportional to
  what it printed — and the tail, where a failure reports itself, is what
  survives.
- **One truthful total.** The run ends with
  `Summary: discovered=… completed=… passed=… failed=… workers=… wall=…s`, and
  every failed file is named above it. Exit status is `0` only when every
  discovered file launched, completed, and passed exactly once — a discovery,
  launch, or accounting failure is never reported as a green run.

Or individually:

```bash
ruby -Itest test/config_test.rb
ruby -Itest test/repository_boundary_test.rb
ruby -Itest test/runner_flow_test.rb
ruby -Itest test/registered_credential_flow_test.rb
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

- **`repository_boundary_test.rb`** — this repository ships its own
  demo executor and resolves a bundled bare command to it; a real provider command
  and an absolute path are passed through untouched; the config path resolves from
  the canonical env var with the spike-era name still honoured as a deprecated
  alias; and the code carries no Rails/ActiveRecord reference and no path into
  `specrelay-platform`.
- **`runner_flow_test.rb`** starts a real fake Platform HTTP server on loopback and
  a real hermetic git workspace with a deterministic fake executor, then drives the
  full claim → events/heartbeat → worktree + executor + tests → report-upload flow
  over real HTTP — proving the process boundary end to end.
- **`registered_credential_flow_test.rb`** proves a machine holding a per-runner
  credential drives the full claim-once flow over HTTP authenticated by that
  **registered credential** — never storing a secret in the config file. There is
  no command that mints one from a token: a machine receives its credential by
  connecting, the one path that also names its project and its owner.
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
- **`claude_profile_test.rb`** covers the real profile as a unit: the
  accepted argv, a refusal for every forbidden flag and for a credential in `env:`,
  the readiness classifications (ready / unavailable / not authenticated / timed
  out) through an **injected** command seam that mutates no ENV and needs no live
  CLI, proof that the readiness result carries no account detail and runs only the
  two bounded metadata probes, the fail-closed payload comparison, and the four
  failure classifications.
- **`real_executor_flow_test.rb`** drives the real profile through the
  whole runner against an on-disk executable named `claude`, so PATH resolution,
  readiness, argv assembly, worktree creation, verification replay, and report
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
