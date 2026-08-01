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

# The bundle body as Jira::SpecCreation::Markdown really renders it: a completeness verdict
# and several tables BEFORE the reporter's own words, which arrive last under
# `## Jira description` in a fenced block.
#
# The original fixture put the reporter's prose first, and that politeness hid a real defect —
# the composer quoted the first paragraph as the problem statement, which against a real
# bundle is SpecRelay's own "Every expected input was readable." bookkeeping. A fixture that
# is tidier than the document it stands in for tests nothing.
def spec_bundle_markdown(issue_key)
  <<~MD
    # Specification-creation input bundle — #{issue_key}

    ## Input completeness

    Every expected input was readable.

    ## Issue

    - Issue: [#{issue_key}](https://example.atlassian.net/browse/#{issue_key}) — Add an export button
    - Reporter: Dana Reporter
    - Bundle trace id: `bundle_abc123`

    ## Classified inputs

    | Kind | Name | Read status | Reason |
    | --- | --- | --- | --- |
    | description | Jira description | available | read from the Jira issue |

    ## Jira description

    ```text
    Reporting analysts need to take the weekly report out of the app and into a
    spreadsheet. Today they retype it by hand, which takes about an hour a week and
    introduces transcription mistakes that are only caught at month end.

    Add a way to export the report the analysts already look at, in a format a
    spreadsheet can open.
    ```
  MD
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
