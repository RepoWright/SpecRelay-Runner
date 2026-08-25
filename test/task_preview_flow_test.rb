# frozen_string_literal: true

require_relative "test_helper"

# MAPIAI-97 — the implementation preview inside a REAL execution: which project-owned commands the
# run invokes and in what order, and that no preview outcome can change what the attempt reported.
class TaskPreviewFlowTest < Minitest::Test
  TASK = "DEMO-0001"

  def setup
    @root, @executor = DemoWorkspace.build
    @platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK, executor_command: @executor)).start
    @config_path = write_config
    @io = StringIO.new
  end

  def teardown
    @platform.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def write_config
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
    path
  end

  def run_cli(extra_env = {})
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] }.merge(extra_env)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{@config_path}], out: @io, err: @io, env: env)
  end

  def invocations = DemoWorkspace.worktree_invocations(@root)
  def terminal = @platform.last_terminal_result
  def preview = terminal["preview"]

  def test_a_successful_implementation_starts_the_preview_through_the_project_command_only
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    assert_equal [ "create #{TASK}", "up #{TASK}", "status #{TASK} --json" ], invocations
    assert_equal "succeeded", terminal["outcome"]
    assert_equal "available", preview["status"]
    assert_nil preview["reason"]
    assert_equal "RUNNING", preview["runtime_state"]
    assert_equal "http://127.0.0.1:3700", preview["primary_url"]
    assert_equal %w[platform runner], preview["services"].map { |service| service["name"] }
    refute_includes JSON.generate(preview), ".runs/worktrees", "no local path may travel on the wire"
  end

  def test_a_project_without_the_task_environment_command_reports_unsupported_and_probes_nothing
    dev_log = DemoWorkspace.without_project_command(@root)
    # Without `bin/worktree` the workspace is built by the native command the assignment names,
    # exactly as MAPIAI-84 S06 established — so this proves the preview alone is unsupported.
    @platform.stop
    @platform = FakePlatform.new(claim_payload: claim_payload_for(
      task_id: TASK, executor_command: @executor,
      worktree_create_command: "git worktree add .runs/worktrees/#{TASK} -b #{TASK}"
    )).start
    @config_path = write_config

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    assert_equal "succeeded", terminal["outcome"]
    assert_equal "unavailable", preview["status"]
    assert_equal "unsupported", preview["reason"]
    assert_empty preview["services"]
    refute File.exist?(dev_log), "an unsupported project must never fall back to bin/dev"
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
  end

  def test_a_failing_preview_startup_never_changes_the_successful_implementation
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli("SPECRELAY_TEST_PREVIEW_UP_EXIT" => "1"), @io.string

    assert_equal [ "create #{TASK}", "up #{TASK}" ], invocations, "a failed startup must not ask for status"
    assert_equal "failed", preview["status"]
    assert_equal "startup_failed", preview["reason"]
    # The attempt itself is untouched: same outcome, same report, same publication evidence.
    assert_equal "succeeded", terminal["outcome"]
    assert_nil terminal.dig("core", "error_classification")
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
    assert_includes uploaded_manifest, "execution_status: succeeded"
  end

  def test_an_unusable_status_payload_is_reported_as_invalid_status
    code = run_cli("SPECRELAY_TEST_PREVIEW_STATUS_JSON" => "{ not json")

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, @io.string
    assert_equal "failed", preview["status"]
    assert_equal "invalid_status", preview["reason"]
    assert_equal "succeeded", terminal["outcome"]
  end

  def test_a_failed_implementation_reports_no_preview_and_starts_nothing
    File.write(@executor, <<~RUBY)
      #!/usr/bin/env ruby
      warn "[fake-executor] provider call failed"
      exit 3
    RUBY
    FileUtils.chmod(0o755, @executor)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_equal [ "create #{TASK}" ], invocations, "a failed implementation must start no preview"
    assert_equal "failed", terminal["outcome"]
    assert_nil preview
    assert terminal.key?("preview"), "the key is part of the contract even when it is null"
  end

  # CR-001 F1 — the project command passes the executable check and still cannot be spawned. Both
  # phases are covered, because the phase decides the reason a reviewer is shown.
  { "up" => [ "create", "startup_failed" ], "status" => [ "up", "status_failed" ] }.each do |phase, (after, reason)|
    define_method(:"test_an_unlaunchable_#{phase}_leaves_the_successful_implementation_intact") do
      DemoWorkspace.break_launch_after(@root, after)
      code = run_cli

      assert_equal SpecrelayRunner::CLI::SUCCESS, code, @io.string
      assert_equal "failed", preview["status"]
      assert_equal reason, preview["reason"]
      assert_empty preview["services"]
      assert_nil preview["primary_url"]
      # The attempt is untouched: same outcome, no error classification, one report, and the
      # report still describes a successful execution.
      assert_equal "succeeded", terminal["outcome"]
      assert_nil terminal.dig("core", "error_classification")
      assert_equal 1, @platform.requests_to("/api/runner/reports").size
      assert_includes uploaded_manifest, "execution_status: succeeded"
    end
  end

  # CR-001 F1 — the same failure against a run that really PUBLISHES, so "publication evidence is
  # intact" is a fact about a pushed branch and a reported pull request rather than an empty list.
  def test_an_unlaunchable_preview_leaves_the_published_implementation_intact
    bare = FakeGithub.add_remote(@root)
    gh_dir, gh_log, = FakeGithub.gh_bin(bare: bare)
    @platform.stop
    @platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK, executor_command: @executor,
                                                                  publication: {})).start
    @config_path = write_config

    DemoWorkspace.break_launch_after(@root, "create")
    code = run_cli("PATH" => "#{gh_dir}:#{ENV['PATH']}", "HOME" => ENV["HOME"].to_s)

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, @io.string
    assert_equal "startup_failed", preview["reason"]
    assert_equal "succeeded", terminal["outcome"]
    repositories = terminal.fetch("repositories")
    assert_equal 1, repositories.size
    repository = repositories.first
    assert_equal TASK, repository["branch"]
    refute_nil repository["pull_request_url"], "the publication result must still name its pull request"
    assert_nil repository["publication_error"]
    assert_equal 1, FakeGithub.pr_creates(gh_log)
    assert_includes FakeGithub.remote_branches(bare).keys, TASK, "the branch really reached the remote"
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
  end

  # MAPIAI-97 section 6 — starting a preview deliberately LEAVES the runtime alive, and
  # `bin/worktree release <TASK-ID>` stays the only thing that stops it. Asserted as a named
  # regression rather than inferred from the invocation list above, because "we did not add a
  # second cleanup owner" is the claim a later change is most likely to break silently.
  def test_the_runner_never_stops_removes_or_releases_the_environment_it_started
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    verbs = invocations.map { |invocation| invocation.split.first }
    assert_equal %w[create up status], verbs
    %w[down stop restart release discard migrate].each do |verb|
      refute_includes verbs, verb, "#{verb} is the release command's business, never the runner's"
    end
  end

  private

  def uploaded_manifest
    entry = @platform.last_report[:body].dig("report", "files").find { |file| file["relative_path"] == "manifest.yml" }
    Base64.strict_decode64(entry.fetch("content_base64"))
  end
end
