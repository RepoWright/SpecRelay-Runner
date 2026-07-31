# frozen_string_literal: true

require_relative "test_helper"

# MVP-0025 scope 5 / criteria 7 and 8 — the runner recognizes a SPECIFICATION assignment
# and stops at the assignment boundary.
#
# Driven through the real `claim-once` CLI against the real fake Platform HTTP server, not
# by calling SpecificationAssignment directly. The whole point of criterion 8 is what the
# runner does NOT do after a claim, and only the end-to-end path can prove that: the
# assertions read the fake Platform's recorded REQUEST LOG, so "uploaded no report" is a
# fact about the wire rather than about a method that was not called.
class SpecificationAssignmentTest < Minitest::Test
  ISSUE = "SR-700"

  def setup
    @root, @executor = DemoWorkspace.build
    @platform = FakePlatform.new(claim_payload: spec_creation_payload).start
    @config = build_config
    @io = StringIO.new
  end

  def teardown
    @platform.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # A specification assignment exactly as Runner::Api::SpecCreationPayload builds it. It
  # deliberately carries NO `executor`, `repositories`, or `report_contract` block, because
  # Platform sends none — a fixture that included them would be testing a payload this
  # product does not produce.
  def spec_creation_payload
    {
      "contract_version" => "mvp-0025",
      "claim" => { "runner_execution_id" => "rex_spec123", "runner_id" => "test-runner",
                   "runner_display_name" => "Test Runner", "claim_policy_mode" => "all_eligible",
                   "assignee_match_field" => nil, "claimed_at" => "2026-07-31T12:00:00Z" },
      "run" => { "id" => "run_spec123", "type" => "spec_creation",
                 "state" => "AWAITING_SPECIFICATION_CREATION" },
      "work_item" => { "provider" => "jira", "issue_key" => ISSUE,
                       "issue_url" => "https://example.atlassian.net/browse/#{ISSUE}",
                       "title" => "Add an export button" },
      "input_bundle" => {
        "artifact_id" => "art_spec123", "url" => "http://127.0.0.1:3200/artifacts/art_spec123",
        "complete" => true, "trace_id" => "bundle_abc123", "captured_at" => "2026-07-31T12:00:00Z",
        "blocking_inputs" => [], "inputs" => [ { "kind" => "description", "name" => "Jira description",
                                                 "read_status" => "available", "reason" => "read from the Jira issue" } ],
        "content_markdown" => "# Specification input bundle\n\nThe reporter's requirements."
      },
      "specification_target" => {
        "repository_url" => "https://github.com/SpecRelay/SpecRelay-Specs", "default_branch" => "main",
        "specification_root" => "specs", "host" => "github.com", "owner" => "SpecRelay",
        "repository" => "SpecRelay-Specs"
      },
      "workspace" => { "project_key" => "tiny-demo", "workspace_key" => "tiny-demo-workspace",
                       "display_name" => "Tiny Demo Workspace" },
      "links" => { "run_url" => "http://127.0.0.1:3200/runs/run_spec123",
                   "work_item_url" => "https://example.atlassian.net/browse/#{ISSUE}" },
      "execution_policy" => { "timeout_seconds" => 120, "lease_renewal_seconds" => 30,
                              "lease_expires_at" => "2026-07-31T12:05:00Z" },
      "assignment_boundary" => { "generation" => "deferred_to_mvp_0026",
                                 "expected_runner_action" => "acknowledge_assignment_and_stop",
                                 "release_command" => "bin/platform runner release run_spec123" }
    }
  end

  def build_config
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{@platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: test-runner
        display_name: Test Runner
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{@root}
    YAML
    SpecrelayRunner::Config.load(path)
  end

  def run_cli
    SpecrelayRunner::CLI.run(%W[claim-once --config #{@config.source_path}],
                             out: @io, err: @io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] })
  end

  def output = @io.string

  # Criterion 7 — the documented exit status. Explicitly NOT the failed-execution code: a
  # correct assignment-only stop must be distinguishable from a broken executor by anything
  # that reads the status, which is every loop and CI job that wraps this command.
  def test_exit_status_is_success_not_run_failed
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli
    refute_equal SpecrelayRunner::CLI::RUN_FAILED, SpecrelayRunner::CLI::SUCCESS
  end

  def test_prints_the_assignment_summary
    run_cli

    assert_includes output, "SPECIFICATION assignment"
    assert_includes output, "run_spec123"
    assert_includes output, ISSUE
    assert_includes output, "spec_creation"
    assert_includes output, "art_spec123"
    assert_includes output, "https://github.com/SpecRelay/SpecRelay-Specs"
  end

  def test_states_that_generation_is_deferred
    run_cli

    assert_includes output, "MVP-0025"
    assert_includes output, "assignment_received"
    assert_includes output, "deferred to MVP-0026"
  end

  # The recovery path, printed rather than assumed known — the same convention the
  # pre-execution failure paths follow.
  def test_prints_the_release_command_platform_sent
    run_cli

    assert_includes output, "bin/platform runner release run_spec123"
  end

  # Criterion 8, as facts about the wire. The runner claimed and then made no further call:
  # no protocol event, no heartbeat, no report.
  def test_uploads_no_report_and_sends_no_events
    run_cli

    assert_equal 1, @platform.requests_to("/api/runner/claim").length
    assert_empty @platform.requests_to("/api/runner/events")
    assert_empty @platform.requests_to("/api/runner/heartbeat")
    assert_empty @platform.requests_to("/api/runner/reports")
  end

  def test_touches_only_the_claim_endpoint
    run_cli

    assert_equal [ "/api/runner/claim" ], @platform.requests.map { |request| request[:path] }.uniq
  end

  # Criterion 8's local half: no worktree, and no file written anywhere in the workspace
  # checkout. Compared as a full recursive snapshot, so a stray file ANYWHERE under the root
  # fails — not only one this test thought to name.
  def test_creates_no_worktree_and_writes_no_repository_file
    before = workspace_snapshot

    run_cli

    assert_equal before, workspace_snapshot
  end

  def test_launches_no_executor
    run_cli

    # The fake executor records every invocation by appending to a marker file; the demo
    # workspace's executor is never invoked, so no marker exists.
    refute_includes output, "Running fake executor"
    refute_includes output, "Preparing worktree"
  end

  def workspace_snapshot
    Dir.glob(File.join(@root, "**", "*"), File::FNM_DOTMATCH).sort
  end
end
