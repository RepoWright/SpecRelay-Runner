# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "json"
require "tmpdir"
require "stringio"
require "fileutils"
require "shellwords"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "specrelay_runner"

require_relative "support/fake_platform"
require_relative "support/fake_secret_store"
require_relative "support/demo_workspace"
require_relative "support/multi_repository_workspace"
require_relative "support/preview_workspace"
require_relative "support/fake_github"
require_relative "support/fake_claude_cli"
require_relative "support/fake_codex_cli"
require_relative "support/specification_workspace"
require_relative "support/recording_terminal"

# A specification-creation assignment exactly as Runner::Api::SpecCreationPayload builds it
# (MVP-0025 scope 3, consumed by MVP-0026). It deliberately carries NO `executor`,
# `repositories`, or `report_contract` block, because Platform sends none for this lane — a
# fixture that included them would be testing a payload this product does not produce.
# Install `script` as the approved bare fixture name on its own bin directory and return that
# directory. A test prepends it to the CHILD PATH it hands the CLI, so the runner resolves the
# approved name to the double exactly the way it resolves it to the shipped fixture on a real host.
#
# This is the explicit test seam that replaced writing an arbitrary executable path — and, since
# the fixture environment became exact, an arbitrary set of fixture instructions — into a `fake`
# payload. It adds no production bypass, no environment override and no test-only branch: the
# payload is always the canonical profile, and what a bare name resolves to on a host, under which
# environment, is the host's business.
def fixture_bin(script = nil, env: {})
  dir = Dir.mktmpdir("fixture-bin-")
  script ? use_fixture(dir, script, env: env) : dir
end

# Point the approved fixture name at `script`, replacing whatever it pointed at before. A suite that
# chooses a different double per example re-points one directory rather than rebuilding its PATH.
#
# `env` is the host-side environment the double runs under: the controls a particular example needs
# it to read. It is installed HERE, on this machine, next to the choice of which file the name
# resolves to — which is the same decision, and the one an operator owns.
#
# A launcher that `exec`s the script rather than a copy of it, so a test that rewrites its double
# mid-example still runs the script it just wrote. `exec` replaces the shell, so the child the
# runner waits on, times out and signals is the double itself.
def use_fixture(dir, script, env: {})
  target = File.join(dir, SpecrelayRunner::ImplementationProfile::FIXTURE_COMMAND)
  File.delete(target) if File.symlink?(target) || File.exist?(target)
  exports = env.map { |name, value| "export #{name}=#{Shellwords.escape(value.to_s)}\n" }.join
  File.write(target, "#!/bin/sh\n#{exports}exec #{Shellwords.escape(File.expand_path(script))} \"$@\"\n")
  FileUtils.chmod(0o755, target)
  dir
end

# The child PATH that resolves the approved fixture name to `script`.
def fixture_path(script, base: ENV["PATH"], env: {})
  [ fixture_bin(script, env: env), base.to_s ].reject(&:empty?).join(File::PATH_SEPARATOR)
end

def spec_creation_payload_for(issue_key:, title: "Add an export button", inputs: nil,
                              specification_root: "specs", complete: true, content: nil,
                              existing_pull_request_url: nil, specification_provider: nil)
  {
    "contract_version" => "mvp-0025",
    "claim" => { "runner_execution_id" => "rex_spec123", "runner_id" => "test-runner",
                 "runner_display_name" => "Test Runner", "claim_policy_mode" => "all_eligible",
                 "assignee_match_field" => nil, "claimed_at" => "2026-07-31T12:00:00Z" },
    "run" => { "id" => "run_spec123", "type" => "spec_creation",
               "state" => "AWAITING_SPECIFICATION_CREATION" },
    "work_item" => { "provider" => "jira", "issue_key" => issue_key,
                     "issue_url" => "https://example.atlassian.net/browse/#{issue_key}",
                     "title" => title },
    "input_bundle" => {
      "artifact_id" => "art_spec123", "url" => "http://127.0.0.1:3200/artifacts/art_spec123",
      "complete" => complete, "trace_id" => "bundle_abc123", "captured_at" => "2026-07-31T12:00:00Z",
      "blocking_inputs" => complete ? [] : [ { "kind" => "description", "read_status" => "unavailable",
                                               "reason" => "the issue has no description" } ],
      "inputs" => inputs || [ { "kind" => "description", "name" => "Jira description",
                                "read_status" => "available", "reason" => "read from the Jira issue" } ],
      "content_markdown" => content || spec_bundle_markdown(issue_key)
    },
    "specification_target" => {
      "repository_url" => "https://github.com/SpecRelay/SpecRelay-Specs", "default_branch" => "main",
      "specification_root" => specification_root, "host" => "github.com", "owner" => "SpecRelay",
      "repository" => "SpecRelay-Specs"
    },
    # MVP-0028 decision D6 — nil for a first specification, present on EVERY spec_creation
    # assignment (unlike `publication`, which only exists once a package has been generated).
    "specification_revision" => { "existing_pull_request_url" => existing_pull_request_url },
    # MAPIAI-87 — required on EVERY assignment and null only when the ticket has no accepted
    # implementation. Null here so the fixture is the document Platform now produces; the tests
    # that care about a populated block set one.
    "previous_accepted_package" => nil,
    # The profile Project Setup selected, and the ONLY channel a
    # specification provider can arrive through besides this runner's own `runner.executor:`
    # selection. The exact approved Claude profile by default, because that is what Platform sends
    # for an ordinary project; a test that needs another selection, or none, passes its own.
    "specification_provider" => specification_provider ||
      { "profile" => SpecrelayRunner::ClaudeProfile::PROVIDER,
        "executor" => SpecrelayRunner::ClaudeProfile::CANONICAL },
    "workspace" => { "project_key" => "tiny-demo", "workspace_key" => "tiny-demo-workspace",
                     "display_name" => "Tiny Demo Workspace" },
    "links" => { "run_url" => "http://127.0.0.1:3200/runs/run_spec123",
                 "work_item_url" => "https://example.atlassian.net/browse/#{issue_key}" },
    "execution_policy" => { "timeout_seconds" => 120, "lease_renewal_seconds" => 30,
                            "lease_expires_at" => "2026-07-31T12:05:00Z" },
    "assignment_boundary" => { "generation" => "runner_generates_package",
                               "expected_runner_action" => "generate_specification_package",
                               "release_command" => "bin/platform runner release run_spec123" }
  }
end

# A specification-PUBLICATION assignment exactly as Runner::Api::SpecCreationPayload builds one
# for a run in AWAITING_SPECIFICATION_PUBLICATION (MVP-0027).
#
# It is the generation payload plus the two blocks that make publication possible and a
# different `expected_runner_action` — the same document with a different authorization, which
# is precisely what the runner branches on. `files` carries REAL digests supplied by the caller,
# because every interesting case here is about whether the bytes on disk match them.
def spec_publication_payload_for(issue_key:, files:, package_path:, branch:, workspace_id:,
                                 repository_url: "https://github.com/SpecRelay/SpecRelay-Specs",
                                 slug: "SpecRelay/SpecRelay-Specs", base_branch: "main",
                                 draft: true, title: "Add an export button",
                                 existing_pull_request_url: nil)
  spec_creation_payload_for(issue_key: issue_key, title: title).merge(
    "run" => { "id" => "run_spec123", "type" => "spec_creation",
               "state" => "AWAITING_SPECIFICATION_PUBLICATION" },
    "assignment_boundary" => { "generation" => "generate_package_only",
                               "publication" => "publish_draft_pull_request_only",
                               "expected_runner_action" => "publish_specification_package",
                               "release_command" => "bin/platform runner release run_spec123" },
    # MAPIAI-62 — `workspace_id` is the opaque address of the Runner-owned workspace that
    # generated this package. Required by the contract, so it is required by the fixture: a
    # publication payload without one is not a document Platform can produce.
    "generated_package" => { "path" => package_path, "generated_at" => "2026-08-01T09:00:00Z",
                             "workspace_id" => workspace_id, "files" => files },
    "publication" => { "repository_url" => repository_url, "slug" => slug,
                       "specification_root" => "specs", "branch" => branch,
                       "base_branch" => base_branch, "create_pull_request" => true,
                       "pull_request_draft" => draft,
                       # MVP-0028: nil for a first publication, which is what tells the runner to
                       # use `branch`. Present for a later run on the same ticket.
                       "existing_pull_request_url" => existing_pull_request_url }
  )
end

# The bundle body, CAPTURED from the real renderer rather than written to resemble it.
#
# `test/fixtures/input_bundle_rendered*.md` are verbatim output of Platform's
# `Jira::SpecCreation::Markdown.render`, produced by running the real bundle engine over a
# real `IssueDetail` in the Platform container. The runner is Rails-free and cannot call that
# renderer, so the capture is committed; the command that produces it is in the fixture
# README beside it, and a reviewer can re-run it and diff.
#
# Two rounds of defects came from a hand-written approximation of this document, and both
# were invisible to the suite until a live pass:
#
#   - The first fixture put the reporter's prose FIRST, so the composer's "first paragraph"
#     heuristic looked right. Against a real bundle it quotes SpecRelay's own "Every expected
#     input was readable." bookkeeping as the problem statement.
#   - The second was structurally right but hand-shaped, and it fenced the description with
#     exactly three backticks. The real renderer LENGTHENS that fence when the description
#     contains one — so the case that broke every generated `spec.md` was never generated.
#
# A fixture that is tidier than the document it stands in for tests nothing. Both variants are
# real: `:plain` for the ordinary case, `:backticked` for a description carrying its own fenced
# block, which the renderer wraps in a four-backtick fence.
BUNDLE_FIXTURES = {
  plain: "input_bundle_rendered.md",
  backticked: "input_bundle_rendered_backticked.md"
}.freeze

# The issue key baked into the captured fixture. Substituted so one capture serves every test
# without re-rendering per key.
BUNDLE_FIXTURE_ISSUE_KEY = "SR-700"

def spec_bundle_markdown(issue_key, variant: :plain)
  path = File.expand_path("fixtures/#{BUNDLE_FIXTURES.fetch(variant)}", __dir__)
  File.read(path).gsub(BUNDLE_FIXTURE_ISSUE_KEY, issue_key)
end


# Build a claim payload shaped like the Platform RunPayload for a task, pointing
# the executor at the given fake-executor command.
#
# publication: when given, adds the MVP-0014 assignment blocks Platform sends
# (`repositories`, `repository_policy`, `links`). Omit it to model a pre-MVP-0014
# Platform that asks for no publication.
#
# rework: when given, adds the MVP-0035 change-request block and advances the assigned report
# round, exactly as Platform does for a claim that follows a CHANGES_REQUESTED review. Omit it
# to model a first execution, which carries no rework block at all.
def claim_payload_for(task_id:, publication: nil, rework: nil, restart: nil,
                      worktree_create_command: nil)
  payload = base_claim_payload(task_id: task_id, worktree_create_command: worktree_create_command)
  payload = payload.merge("rework" => rework_block(rework), "report_contract" => rework_round(task_id)) if rework
  # MVP-0036 Stage 2b — a REPLACEMENT run's recorded target. Its report round stays the first
  # one, because the replacement is a new run rather than another round of the old one.
  payload = payload.merge("restart" => restart) if restart
  return payload if publication.nil?

  # MAPIAI-84 — the assignment carries NO repository list. Platform states the global publication
  # policy (access, whether a pull request is required, whether it is a draft) and nothing about
  # WHICH repositories are eligible: that is the executor's semantic choice, read back from its
  # own selection document and verified locally by the runner.
  payload.merge(
    "repository_policy" => {
      "access" => publication.fetch(:access, "write"),
      "create_pull_requests" => publication.fetch(:create_pull_requests, true),
      "pull_request_draft" => publication.fetch(:pull_request_draft, true)
    },
    "links" => { "run_url" => "http://127.0.0.1:3200/runs/run_test123",
                 "work_item_url" => "https://example.atlassian.net/browse/#{task_id}" }
  )
end

# The pinned specification package exactly as Runner::Api::RunPayload builds it (MVP-0034
# contract 4): identity, then every document with the role, path, digest, byte size and content
# Platform recomputed itself. `digest` is real, so a test that alters one byte without restating
# it is testing the refusal rather than the fixture.
def specification_package_block(task_id, documents: nil)
  documents ||= [
    [ "specification", "spec.md", "# Approved spec for #{task_id}\nImplement it.\n" ],
    [ "input_evidence", "analysis/input-evidence.md", "# Input evidence\n" ],
    [ "business_analysis", "analysis/business.md", "# Business analysis\n" ],
    [ "technical_analysis", "analysis/technical.md", "# Technical analysis\n" ],
    [ "generation_manifest", "generation-manifest.json", "{\"round\":1}\n" ]
  ]
  head = "a" * 40
  {
    "manifest_digest" => "d" * 64,
    "spec_pull_request_url" => "https://github.com/SpecRelay/specs/pull/7",
    "repository_slug" => "SpecRelay/specs", "pull_request_number" => 7,
    "base_branch" => "main", "head_sha" => head, "package_path" => "specs/#{task_id}",
    "documents" => documents.map do |role, path, content|
      { "role" => role, "path" => path, "digest" => Digest::SHA256.hexdigest(content),
        "byte_size" => content.bytesize, "content" => content }
    end,
    "handoff_prompt" => "# Approved spec for #{task_id}\nImplement it."
  }
end

# The rework block exactly as Runner::Api::RunPayload builds it (MVP-0035 design 2): the settled
# review attempt's identity, its bounded findings, and the reviewed target the runner must
# continue from. `repositories: []` models the legitimate no-change review, which has no pull
# request to continue from and must fall back to the ordinary initial checkout.
def rework_block(overrides)
  {
    "review_attempt_id" => "rvt_rework123",
    "input_manifest_digest" => "e" * 64,
    "summary" => "The heading is right, but the change is not idempotent.",
    "findings" => [ { "severity" => "blocking", "summary" => "The edit is not idempotent.",
                      "reason" => "A second run would append a second heading.",
                      "location" => "demo-app/index.html:1" } ],
    "repositories" => []
  }.merge(overrides.transform_keys(&:to_s))
end

def rework_round(task_id)
  { "round_number" => 2, "round_label" => "002-review-fixes",
    "release_instructions" => "./bin/worktree release #{task_id}",
    "report_path" => "specs/#{task_id}/execution-reports/002-review-fixes" }
end

def base_claim_payload(task_id:, worktree_create_command: nil)
  {
    "contract_version" => "mvp-0010",
    "claim" => { "runner_execution_id" => "rex_test123", "claim_policy_mode" => "all_eligible" },
    # MVP-0025 names the LANE on every assignment, and Platform's RunPayload always sends it.
    "run" => { "id" => "run_test123", "type" => "implementation", "task_id" => task_id,
               "canonical_branch" => task_id },
    "workspace" => {
      "project_key" => "tiny-demo", "workspace_key" => "tiny-demo-workspace",
      "display_name" => "Tiny Demo Workspace", "repository_url" => "https://github.com/SpecRelay/tiny-demo-workspace",
      "default_branch" => "main",
      "worktree_create_command" => worktree_create_command || "./bin/worktree create #{task_id}",
      "worktree_release_command" => "./bin/worktree release #{task_id}"
    },
    # The CANONICAL fixture identity, byte-for-byte what Platform serves and what the runner
    # refuses to deviate from — environment included. A test that needs different behaviour
    # installs a different SCRIPT, under a different host environment, behind this approved bare
    # name (see `fixture_bin`). Which file a bare name resolves to on a host, and what that file
    # reads while it runs, is the host's business — not something a payload may say.
    "executor" => SpecrelayRunner::ImplementationProfile::FIXTURE_CANONICAL,
    "specification_package" => specification_package_block(task_id),
    # MAPIAI-87 — required on EVERY assignment and null only when the ticket has no accepted
    # implementation. Absence is malformed input, not a first run, so the fixture states it.
    "previous_accepted_package" => nil,
    # MVP-0036 — the question contract exactly as Runner::Api::RunPayload builds it. Captured
    # rather than approximated, because the runner RENDERS these values into the provider's
    # fixed bridge instructions: a fixture that omitted the block would let the runner ship
    # instructions naming no required field and no size bound, and every test would still pass.
    "question_contract" => {
      "submit_path" => "/api/runner/executor_questions",
      "max_document_bytes" => 65_536,
      "continuation_context_fields" => {
        "progress" => "what has been done so far",
        "changed_areas" => "which areas of the code changed",
        "why_it_matters" => "why these decisions matter",
        "next_step" => "the next step once the answers arrive",
        "remaining_work" => "the work still remaining",
        "do_not_repeat" => "the work that must not be repeated"
      },
      "reserved_option_key" => "other",
      "wait_seconds" => 600
    },
    # MVP-0035: Platform assigns the round, so `round_number` travels with the label rather than
    # being a constant the runner holds.
    "report_contract" => { "round_number" => 1, "round_label" => "001-initial",
                          "release_instructions" => "./bin/worktree release #{task_id}",
                          "report_path" => "specs/#{task_id}/execution-reports/001-initial" }
  }
end
