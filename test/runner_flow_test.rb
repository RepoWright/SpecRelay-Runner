# frozen_string_literal: true

require_relative "test_helper"

# End-to-end proof that the standalone runner drives one Tiny Demo execution over
# the HTTP API boundary (MVP-0010): claim -> events/heartbeat -> real worktree +
# real fake executor + real tests -> report upload. The runner talks to a real
# fake Platform HTTP server on loopback; there is no in-process Platform.
class RunnerFlowTest < Minitest::Test
  TASK = "DEMO-0001"

  def setup
    @root, @executor = DemoWorkspace.build
    @platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK, executor_command: @executor)).start
    @config = build_config
    @io = StringIO.new
  end

  def teardown
    @platform.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
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
                             out: @io, err: @io, env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] })
  end

  def test_full_claim_execute_report_flow_over_http
    exit_code = run_cli

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string

    # The executor really edited the worktree and the tests really passed.
    edited = File.read(File.join(@root, ".runs", "worktrees", TASK, "demo-app", "index.html"))
    assert_includes edited, "Hello SpecRelay Demo"

    # The runner called every API endpoint over real HTTP.
    assert_equal 1, @platform.requests_to("/api/runner/claim").size
    assert_operator @platform.requests_to("/api/runner/events").size, :>=, 3
    assert_operator @platform.requests_to("/api/runner/heartbeat").size, :>=, 3
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
  end

  def test_uploaded_report_bundle_matches_the_run_identity
    run_cli
    report = @platform.last_report[:body].fetch("report")

    assert_equal "001-initial", report["round_label"]
    manifest = decode_manifest(report)
    assert_equal "run_test123", manifest["run_id"]
    assert_equal TASK, manifest["task_id"]
    assert_equal "tiny-demo", manifest["project_key"]
    assert_equal "succeeded", manifest["execution_status"]
    assert_equal "./bin/worktree release #{TASK}", manifest["release_instructions"]
    assert_includes manifest["git"]["changed_files"], "demo-app/index.html"
  end

  def test_client_side_transcript_redaction_before_upload
    run_cli
    report = @platform.last_report[:body].fetch("report")
    stdout_log = decode_file(report, "evidence/stdout.log")

    refute_includes stdout_log, "sk-live-DO-NOT-LEAK"
    assert_includes stdout_log, "[REDACTED]"
    # The bearer token is never echoed into any request body.
    @platform.requests.each { |r| refute_includes JSON.generate(r[:body]), FakePlatform::EXPECTED_TOKEN }
  end

  def test_authorization_header_carries_the_bearer_token
    run_cli
    @platform.requests.each do |request|
      assert_equal "Bearer #{FakePlatform::EXPECTED_TOKEN}", request[:headers]["authorization"]
    end
  end

  def test_no_eligible_work_exits_zero
    # Second claim returns claimed:false from the fake platform.
    run_cli
    io2 = StringIO.new
    exit_code = SpecrelayRunner::CLI.run(%W[claim-once --config #{@config.source_path}],
                                         out: io2, err: io2,
                                         env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] })
    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code
    # MVP-0017: the runner prints the reason PLATFORM returned rather than one generic idle
    # line, so an unconnected runner is told to run `connect` instead of reading a refusal as a
    # healthy poll. The fake Platform's reason here is its own "already claimed".
    assert_match(/no work claimed: already claimed/, io2.string)
  end

  def test_invalid_token_fails_without_claiming
    io = StringIO.new
    exit_code = SpecrelayRunner::CLI.run(%W[claim-once --config #{@config.source_path}],
                                         out: io, err: io,
                                         env: { "TEST_TOKEN" => "wrong", "PATH" => ENV["PATH"] })
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code
    assert_match(/rejected the runner token|401/, io.string)
  end

  # QUALITY-0002: a claim succeeds but the local workspace root is missing. The
  # runner must NOT crash and leave the run silently stuck — it must surface
  # precise, secret-safe recovery guidance (the env var to set and the release
  # command) and exit non-zero, uploading no report for the unexecuted claim.
  def test_missing_workspace_root_reports_recovery_without_crashing
    path = File.join(Dir.mktmpdir("cfg-badroot"), "runner.yml")
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
        tiny-demo-workspace: #{File.join(@root, "does-not-exist")}
    YAML

    io = StringIO.new
    exit_code = SpecrelayRunner::CLI.run(%W[claim-once --config #{path}],
                                         out: io, err: io,
                                         env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] })

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_equal 1, @platform.requests_to("/api/runner/claim").size
    assert_equal 0, @platform.requests_to("/api/runner/reports").size
    assert_match(/preflight_failed/, io.string)
    assert_match(/SPECRELAY_RUNNER_WORKSPACE_ROOT_TINY_DEMO_WORKSPACE/, io.string)
    assert_match(%r{bin/platform runner release #{TASK}}, io.string)
    # MVP-0035 automatic release is scoped to a refused change-request target. A missing
    # workspace root is a misconfiguration of THIS machine, and releasing it would let the
    # default loop policy reclaim and re-refuse the same run instead of stopping (CR-001 F3).
    assert_equal 0, @platform.requests_to("/api/runner/claim_releases").size
  end

  # A failing executor must still produce a durable FAILED attempt on Platform.
  # This previously crashed: the failure path built its Workspace with root: ""
  # so capture_changes hit Process.spawn(chdir: "") -> Errno::ENOENT, and the
  # runner died BEFORE uploading anything, leaving the run stuck with no reason
  # recorded. Asserting the report upload (not just the exit code) is what makes
  # the regression impossible to reintroduce.
  def test_failing_executor_uploads_a_failed_report_without_crashing
    File.write(@executor, <<~RUBY)
      #!/usr/bin/env ruby
      warn "[fake-executor] provider call failed"
      exit 3
    RUBY
    FileUtils.chmod(0o755, @executor)

    exit_code = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    assert_equal 1, @platform.requests_to("/api/runner/reports").size, "the failed attempt must be reported"

    terminal = @platform.last_terminal_result
    assert_equal "failed", terminal["outcome"]
    assert_equal "executor_failed", terminal.dig("core", "error_classification")
    assert_equal 3, terminal.dig("core", "exit_code")
    # Nothing was published, and the repository is still reported truthfully.
    repositories = terminal.fetch("repositories")
    refute_empty repositories
    assert(repositories.none? { |repo| repo["pull_request_url"] }, "an executor failure must publish nothing")
    manifest = decode_manifest(@platform.last_report)
    assert_equal "failed", manifest["execution_status"]
    refute manifest["final_jira_update_ready"], "a failed attempt must not mark Jira ready"
  end

  private

  def decode_manifest(report)
    require "yaml"
    YAML.safe_load(decode_file(report, "manifest.yml"))
  end

  def decode_file(_report, relative)
    files = @platform.last_report[:body].dig("report", "files")
    entry = files.find { |f| f["relative_path"] == relative }
    Base64.strict_decode64(entry.fetch("content_base64"))
  end
end
