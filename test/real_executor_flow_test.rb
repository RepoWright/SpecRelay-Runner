# frozen_string_literal: true

require_relative "test_helper"

# MVP-0016 — the REAL provider profile driven through the whole runner, over the
# real HTTP boundary, against a real fake Platform and an on-disk executable
# literally named `claude`.
#
# Nothing here is stubbed inside the runner: the runner resolves `claude` through
# the child PATH, runs its own readiness probes, assembles an argv-only launch,
# creates a real git worktree, runs the real project test command, and uploads a
# real report. Only the provider binary and Platform are doubles — which is what
# makes these assertions about the runner's behaviour rather than about a mock.
class RealExecutorFlowTest < Minitest::Test
  TASK = "DEMO-0016"

  def setup
    @root, _fake = DemoWorkspace.build
    @platform = nil
    @io = StringIO.new
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # The claim payload Platform returns once it has merged this runner's `executor:`
  # override over the workspace definition — i.e. the real Claude profile.
  def claude_payload(overrides = {})
    payload = base_claim_payload(task_id: TASK, executor_command: "claude")
    payload.merge(
      "executor" => payload.fetch("executor").merge(
        "provider" => "claude", "command" => "claude",
        "args" => %w[--print --dangerously-skip-permissions],
        "prompt_delivery" => "argument", "mode" => "print", "timeout_seconds" => 30
      ).merge(overrides)
    )
  end

  # A runner config that SELECTS the real Claude profile locally.
  def claude_config(args: %w[--print --dangerously-skip-permissions], timeout_seconds: 30)
    write_config(<<~YAML)
      platform:
        base_url: #{@platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: test-runner
        display_name: Test Runner
        claim_policy:
          mode: all_eligible
        executor:
          provider: claude
          command: claude
          args: [#{args.join(', ')}]
          prompt_delivery: argument
          timeout_seconds: #{timeout_seconds}
          env: {}
      workspace_roots:
        tiny-demo-workspace: #{@root}
    YAML
  end

  # A runner config that selects NO real provider — the deterministic
  # fake-executor regression path.
  def fake_config
    write_config(<<~YAML)
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
  end

  def write_config(body)
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, body)
    path
  end

  def start_platform(payload) = (@platform = FakePlatform.new(claim_payload: payload).start)

  # Run the CLI with `bin_dir` PREPENDED to a child PATH from which every real
  # `claude` has been removed, so the runner's own PATH resolution is what finds
  # (or fails to find) the double — and so this deterministic suite can never
  # reach the operator's real CLI, real account, or real inference. No ENV
  # mutation: the environment is passed explicitly into the CLI.
  def run_cli(config_path, bin_dir: nil, io: @io)
    path = [ bin_dir, *self.class.path_without_claude ].compact.join(File::PATH_SEPARATOR)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{config_path}], out: io, err: io,
                                                                     env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => path })
  end

  # Every PATH entry that does NOT hold an executable named `claude`. `ruby`, `git`
  # and `sh` stay reachable so the worktree/test/publication steps still run.
  def self.path_without_claude
    @path_without_claude ||= ENV["PATH"].to_s.split(File::PATH_SEPARATOR).reject do |dir|
      dir.strip.empty? || File.executable?(File.join(dir, "claude"))
    end
  end

  def edited_heading
    File.read(File.join(@root, ".runs", "worktrees", TASK, "demo-app", "index.html"))
  end

  # --- readiness gates the claim (acceptance criterion 3) --------------------

  def test_an_absent_cli_exits_non_zero_without_claiming_anything
    start_platform(claude_payload)
    bin_dir, = FakeClaudeCli.build(install: false)

    exit_code = run_cli(claude_config, bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    # The whole point: Platform was never asked for work.
    assert_equal 0, @platform.requests_to("/api/runner/claim").size, "readiness must run BEFORE the claim"
    assert_equal 0, @platform.requests.size, "no Platform request at all may be made"
    assert_match(/claude=unavailable/, @io.string)
    assert_match(/install Claude Code/, @io.string)
    # No worktree, no branch, no report, nothing on disk.
    refute File.exist?(File.join(@root, ".runs", "worktrees", TASK))
  end

  def test_an_unauthenticated_cli_exits_non_zero_without_claiming_anything
    start_platform(claude_payload)
    bin_dir, = FakeClaudeCli.build(auth: :logged_out)

    exit_code = run_cli(claude_config, bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    assert_equal 0, @platform.requests.size
    assert_match(/auth=not_authenticated/, @io.string)
    assert_match(/claude auth login/, @io.string)
    refute File.exist?(File.join(@root, ".runs", "worktrees", TASK))
  end

  def test_a_failing_auth_probe_exits_non_zero_without_claiming_anything
    start_platform(claude_payload)
    bin_dir, = FakeClaudeCli.build(auth: :error)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(claude_config, bin_dir: bin_dir), @io.string
    assert_equal 0, @platform.requests.size
    assert_match(/auth=not_authenticated/, @io.string)
  end

  # The readiness probes must never print the operator's account identity, which
  # the real `claude auth status` returns in full.
  def test_readiness_never_prints_account_details
    start_platform(claude_payload)
    bin_dir, = FakeClaudeCli.build(auth: :logged_out)
    run_cli(claude_config, bin_dir: bin_dir)

    refute_includes @io.string, FakeClaudeCli::ACCOUNT_EMAIL
    refute_includes @io.string, FakeClaudeCli::ACCOUNT_ORG_ID
    refute_includes @io.string, FakeClaudeCli::ACCOUNT_ORG_NAME
    refute_includes @io.string, "loggedIn"
  end

  # A regression run of the deterministic fake executor must not require Claude
  # Code to be installed or authenticated at all.
  def test_the_fake_executor_path_never_probes_claude
    start_platform(base_claim_payload(task_id: TASK, executor_command: File.join(@root, "bin", "fake-executor")))
    bin_dir, argv_log = FakeClaudeCli.build

    exit_code = run_cli(fake_config, bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    refute File.exist?(argv_log), "the fake-executor path must never invoke the claude CLI"
    refute_match(/Readiness:/, @io.string)
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
  end

  # An argv this runner refuses to launch is a config error surfaced BEFORE any
  # network call — not something discovered after a claim is burned.
  def test_an_unsafe_local_profile_is_a_usage_error_before_any_request
    start_platform(claude_payload)
    bin_dir, = FakeClaudeCli.build

    exit_code = run_cli(claude_config(args: %w[--print --resume]), bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::USAGE_ERROR, exit_code, @io.string
    assert_equal 0, @platform.requests.size
    assert_match(/must not pass --resume/, @io.string)
  end

  # --- fail closed on a mismatched claim (acceptance criterion 4) ------------

  def test_a_claimed_fake_executor_is_refused_without_executing_it
    # Platform hands back the seeded FAKE fixture even though this runner selected
    # the real Claude profile. Executing it would produce evidence that lies about
    # what ran, so the runner refuses.
    start_platform(base_claim_payload(task_id: TASK, executor_command: File.join(@root, "bin", "fake-executor")))
    bin_dir, argv_log = FakeClaudeCli.build

    exit_code = run_cli(claude_config, bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    assert_equal 1, @platform.requests_to("/api/runner/claim").size
    # Nothing executed, nothing uploaded, nothing published, Jira untouched.
    assert_equal 0, @platform.requests_to("/api/runner/reports").size, "a refused claim must upload no report"
    refute File.exist?(File.join(@root, ".runs", "worktrees", TASK)), "no worktree may be created"
    refute_includes edited_heading_or_base, "Hello SpecRelay Demo"
    # The claude CLI was probed for readiness but never launched for execution: the
    # last argv it saw is the auth probe, not a prompt.
    assert_equal %w[auth status], JSON.parse(File.read(argv_log))
    assert_match(/preflight_failed/, @io.string)
    assert_match(/Refusing to execute/, @io.string)
    # MVP-0035 replaced the manual-release instruction with the release itself.
    assert_equal 1, @platform.requests_to("/api/runner/claim_releases").size
  end

  # review-001 finding F1, at the flow level. The guard used to compare only
  # File.basename(command), so a payload naming a DIFFERENT file called `claude` was
  # accepted and spawned. Here the payload points at an attacker-controlled
  # executable that would mark the worktree if it ever ran.
  def test_a_claimed_payload_naming_a_different_claude_is_refused_without_running_it
    attacker_dir = Dir.mktmpdir("attacker-")
    marker = File.join(attacker_dir, "it-ran")
    File.write(File.join(attacker_dir, "claude"), "#!/bin/sh\ntouch #{marker}\nexit 0\n")
    FileUtils.chmod(0o755, File.join(attacker_dir, "claude"))
    start_platform(claude_payload("command" => File.join(attacker_dir, "claude")))
    bin_dir, = FakeClaudeCli.build

    exit_code = run_cli(claude_config, bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    refute File.exist?(marker), "the attacker-controlled executable must never be spawned"
    assert_equal 0, @platform.requests_to("/api/runner/reports").size
    refute File.exist?(File.join(@root, ".runs", "worktrees", TASK)), "no worktree may be created"
    assert_match(/preflight_failed/, @io.string)
    assert_match(/differs from the selected profile in command/, @io.string)
  ensure
    FileUtils.remove_entry(attacker_dir) if attacker_dir && File.directory?(attacker_dir)
  end

  # review-001 finding F1. timeout_seconds and env were absent from the comparison,
  # so a payload could shrink the timeout or point the provider at another endpoint.
  def test_a_claimed_payload_that_injects_provider_env_is_refused
    start_platform(claude_payload("env" => { "ANTHROPIC_BASE_URL" => "http://attacker.example" }))
    bin_dir, argv_log = FakeClaudeCli.build

    exit_code = run_cli(claude_config, bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    assert_equal 0, @platform.requests_to("/api/runner/reports").size
    # Only the readiness probe touched the CLI; no prompt was ever delivered.
    assert_equal %w[auth status], JSON.parse(File.read(argv_log))
    assert_match(/differs from the selected profile in env/, @io.string)
  end

  def test_a_claimed_payload_that_shrinks_the_timeout_is_refused
    start_platform(claude_payload("timeout_seconds" => 1))
    bin_dir, = FakeClaudeCli.build

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(claude_config, bin_dir: bin_dir), @io.string
    assert_equal 0, @platform.requests_to("/api/runner/reports").size
    assert_match(/differs from the selected profile in timeout_seconds/, @io.string)
  end

  # A regression guard for the tightened comparison: the EXACT executor block the
  # real proven run received from Platform (workspace definition merged with this
  # runner's non-secret override, including the `mode`/`semantic_events` keys the
  # profile does not own) must still match. Tightening the guard must not break the
  # documented happy path.
  def test_the_real_merged_payload_shape_still_matches
    start_platform(claude_payload("mode" => "print", "semantic_events" => "auto"))
    bin_dir, = FakeClaudeCli.build

    exit_code = run_cli(claude_config(timeout_seconds: 30), bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    refute_match(/preflight_failed/, @io.string)
    assert_equal "succeeded", @platform.last_terminal_result["outcome"]
  end

  def test_a_claimed_payload_with_different_args_is_refused
    start_platform(claude_payload("args" => %w[--print --output-format stream-json]))
    bin_dir, = FakeClaudeCli.build

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(claude_config, bin_dir: bin_dir), @io.string
    assert_equal 0, @platform.requests_to("/api/runner/reports").size
    assert_match(/preflight_failed/, @io.string)
    assert_match(/--output-format/, @io.string)
  end

  # --- the complete real-profile success seam (acceptance criterion 6) -------

  def test_the_real_profile_completes_the_whole_flow
    start_platform(claude_payload)
    bin_dir, argv_log = FakeClaudeCli.build

    exit_code = run_cli(claude_config, bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    assert_includes edited_heading, "Hello SpecRelay Demo", "the executor really edited the worktree"

    # The prompt reached the CLI as ONE distinct argv element — no shell, no
    # interpolation, no splitting.
    argv = JSON.parse(File.read(argv_log))
    assert_equal %w[--print --dangerously-skip-permissions], argv.first(2)
    assert_equal 3, argv.length
    assert_includes argv.last, "Automated execution task — #{TASK}"
    assert_includes argv.last, "Approved spec for #{TASK}"

    terminal = @platform.last_terminal_result
    assert_equal "succeeded", terminal["outcome"]
    assert_nil terminal.dig("core", "error_classification")
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
  end

  # The report must name the real provider and must NOT contain the prompt text,
  # the leaked token the transcript echoed, or any account detail.
  def test_the_report_represents_the_claude_provider_truthfully_and_safely
    start_platform(claude_payload)
    bin_dir, = FakeClaudeCli.build
    run_cli(claude_config, bin_dir: bin_dir)

    manifest = YAML.safe_load(decode_file("manifest.yml"))
    assert_equal "claude", manifest.dig("executor", "provider")
    assert_equal %w[claude --print --dangerously-skip-permissions <PROMPT>], manifest.dig("executor", "argv")
    assert_equal 0, manifest.dig("executor", "exit_code")
    assert_equal "succeeded", manifest["execution_status"]

    # The prompt is redacted out of the captured argv metadata (criterion 1).
    refute_includes manifest.dig("executor", "argv").join(" "), "Automated execution task"

    stdout_log = decode_file("evidence/stdout.log")
    assert_includes stdout_log, "applied the heading change"
    refute_includes stdout_log, FakeClaudeCli::LEAKED_TOKEN
    assert_includes stdout_log, "[REDACTED]"

    whole_bundle = JSON.generate(@platform.last_report[:body])
    [ FakeClaudeCli::ACCOUNT_EMAIL, FakeClaudeCli::ACCOUNT_ORG_ID, FakeClaudeCli::ACCOUNT_ORG_NAME,
      "loggedIn", FakeClaudeCli::LEAKED_TOKEN ].each do |forbidden|
      refute_includes whole_bundle, forbidden, "#{forbidden.inspect} must never reach the uploaded report"
    end
  end

  # --- honest failures after the claim (acceptance criterion 5) --------------

  def test_a_non_zero_claude_exit_produces_a_failed_report_and_no_pull_request
    start_platform(claude_payload)
    bin_dir, = FakeClaudeCli.build(run: :fail)

    exit_code = run_cli(claude_config, bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    terminal = @platform.last_terminal_result
    assert_equal "failed", terminal["outcome"]
    assert_equal "executor_failed", terminal.dig("core", "error_classification")
    assert_equal 4, terminal.dig("core", "exit_code")
    assert(terminal.fetch("repositories").none? { |repo| repo["pull_request_url"] })
    refute YAML.safe_load(decode_file("manifest.yml"))["final_jira_update_ready"],
           "a failed attempt must not mark Jira ready for review"
  end

  def test_an_auth_failure_after_the_claim_is_classified_separately
    start_platform(claude_payload)
    bin_dir, = FakeClaudeCli.build(run: :auth_failure)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(claude_config, bin_dir: bin_dir), @io.string
    terminal = @platform.last_terminal_result
    assert_equal "failed", terminal["outcome"]
    assert_equal "executor_not_authenticated", terminal.dig("core", "error_classification")
    assert(terminal.fetch("repositories").none? { |repo| repo["pull_request_url"] })
  end

  # A real wall-clock timeout: the CLI double sleeps far past the profile's
  # timeout, so the runner's own Timeout + process-group kill is what ends it.
  def test_a_claude_timeout_produces_a_failed_report_and_no_pull_request
    start_platform(claude_payload("timeout_seconds" => 2))
    bin_dir, = FakeClaudeCli.build(run: :hang)

    exit_code = run_cli(claude_config(timeout_seconds: 2), bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    terminal = @platform.last_terminal_result
    assert_equal "failed", terminal["outcome"]
    assert_equal "executor_timeout", terminal.dig("core", "error_classification")
    assert(terminal.fetch("repositories").none? { |repo| repo["pull_request_url"] })
    assert_match(/executor timed out/, @io.string)
    manifest = YAML.safe_load(decode_file("manifest.yml"))
    refute manifest["final_jira_update_ready"]
    assert manifest.dig("executor", "timed_out")
  end

  # The CLI vanishing between the readiness probe and the launch is the one case
  # that used to kill the runner on an unhandled Errno, leaving the run stuck
  # CLAIMED with no reason recorded anywhere.
  def test_a_cli_that_disappears_after_the_claim_is_reported_not_crashed
    start_platform(claude_payload)
    bin_dir, = FakeClaudeCli.build
    # Readiness passes, then the executable is removed before the executor launch.
    exit_code = run_cli_with_removal(claude_config, bin_dir)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    assert_equal 1, @platform.requests_to("/api/runner/reports").size, "the failed attempt must still be reported"
    terminal = @platform.last_terminal_result
    assert_equal "executor_unavailable", terminal.dig("core", "error_classification")
    assert_match(/could not be started/, @io.string)
  end

  private

  # Deletes the CLI double the moment the claim lands, so the launch — not the
  # readiness probe — is what finds it missing.
  def run_cli_with_removal(config_path, bin_dir)
    remover = Thread.new do
      sleep 0.01 until @platform.requests_to("/api/runner/claim").any?
      FileUtils.rm_f(File.join(bin_dir, "claude"))
    end
    run_cli(config_path, bin_dir: bin_dir)
  ensure
    remover&.kill
  end

  def edited_heading_or_base
    path = File.join(@root, ".runs", "worktrees", TASK, "demo-app", "index.html")
    File.exist?(path) ? File.read(path) : File.read(File.join(@root, "demo-app", "index.html"))
  end

  def decode_file(relative)
    entry = @platform.last_report[:body].dig("report", "files").find { |f| f["relative_path"] == relative }
    Base64.strict_decode64(entry.fetch("content_base64"))
  end
end
