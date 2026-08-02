# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "json"
require "tmpdir"
require "stringio"
require "fileutils"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "specrelay_runner"

require_relative "support/fake_platform"
require_relative "support/fake_secret_store"
require_relative "support/demo_workspace"
require_relative "support/fake_github"
require_relative "support/fake_claude_cli"
require_relative "support/specification_workspace"

# A specification-creation assignment exactly as Runner::Api::SpecCreationPayload builds it
# (MVP-0025 scope 3, consumed by MVP-0026). It deliberately carries NO `executor`,
# `repositories`, or `report_contract` block, because Platform sends none for this lane — a
# fixture that included them would be testing a payload this product does not produce.
def spec_creation_payload_for(issue_key:, title: "Add an export button", inputs: nil,
                              specification_root: "specs", complete: true, content: nil)
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
def spec_publication_payload_for(issue_key:, files:, package_path:, branch:,
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
    "generated_package" => { "path" => package_path, "generated_at" => "2026-08-01T09:00:00Z",
                             "files" => files },
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
def claim_payload_for(task_id:, executor_command:, publication: nil)
  payload = base_claim_payload(task_id: task_id, executor_command: executor_command)
  return payload if publication.nil?

  payload.merge(
    "repositories" => [ {
      "id" => "tiny-demo-workspace",
      "clone_url" => publication.fetch(:clone_url, "https://github.com/SpecRelay/tiny-demo-runs"),
      "default_branch" => "main",
      "access" => publication.fetch(:access, "write"),
      "branch" => publication.fetch(:branch, "specrelay/#{task_id}")
    } ],
    "repository_policy" => {
      "branch_pattern" => "specrelay/<TASK-ID>",
      "create_pull_requests" => publication.fetch(:create_pull_requests, true),
      "pull_request_draft" => publication.fetch(:pull_request_draft, true)
    },
    "links" => { "run_url" => "http://127.0.0.1:3200/runs/run_test123",
                 "work_item_url" => "https://example.atlassian.net/browse/#{task_id}" }
  )
end

def base_claim_payload(task_id:, executor_command:)
  {
    "contract_version" => "mvp-0010",
    "claim" => { "runner_execution_id" => "rex_test123", "claim_policy_mode" => "all_eligible" },
    "run" => { "id" => "run_test123", "task_id" => task_id, "canonical_branch" => task_id },
    "workspace" => {
      "project_key" => "tiny-demo", "workspace_key" => "tiny-demo-workspace",
      "display_name" => "Tiny Demo Workspace", "repository_url" => "https://github.com/SpecRelay/tiny-demo-runs",
      "default_branch" => "main",
      "worktree_create_command" => "./bin/worktree create #{task_id}",
      "worktree_release_command" => "./bin/worktree release #{task_id}",
      "test_command" => "./bin/test"
    },
    "executor" => {
      "provider" => "fake", "command" => executor_command, "args" => [],
      "prompt_delivery" => "file_argument", "mode" => "", "semantic_events" => "auto",
      "timeout_seconds" => 120, "env" => {}
    },
    "approved_specification" => { "authority" => "approved_existing_specification",
                                 "handoff_prompt" => "# Approved spec for #{task_id}\nImplement it." },
    "report_contract" => { "round_label" => "001-initial",
                          "release_instructions" => "./bin/worktree release #{task_id}",
                          "report_path" => "specs/#{task_id}/execution-reports/001-initial" }
  }
end
