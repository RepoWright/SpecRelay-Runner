# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "json"
require "tmpdir"
require "fileutils"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "specrelay_runner"

require_relative "support/fake_platform"
require_relative "support/demo_workspace"
require_relative "support/fake_github"

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
