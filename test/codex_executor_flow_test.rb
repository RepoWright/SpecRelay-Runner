# frozen_string_literal: true

require_relative "test_helper"

# The audited Codex profile driven through the WHOLE runner, over the real HTTP boundary, against
# a real fake Platform and an on-disk executable literally named `codex`.
#
# Nothing here is stubbed inside the runner: it resolves `codex` through the child PATH, runs its
# own readiness probes, assembles an argv-only launch with the prompt on stdin, creates a real git
# worktree, runs the real project test command, decodes the real JSONL, and uploads a real report.
# Only the provider binary and Platform are doubles — which is what makes these assertions about
# the runner's behaviour rather than about a mock.
class CodexExecutorFlowTest < Minitest::Test
  TASK = "DEMO-0144"

  # The audited argv, in ONE place, so a fixture cannot drift from the profile it exercises.
  ARGS = %w[exec --json --ephemeral --dangerously-bypass-approvals-and-sandbox].freeze

  def setup
    @root, _fake = DemoWorkspace.build
    @platform = nil
    @io = StringIO.new
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # The claim payload Platform returns for the Codex profile.
  # The CANONICAL Codex profile, byte-for-byte what Platform serves. An override here produces a
  # payload the runner must refuse, which is exactly what the refusal examples assert.
  def codex_payload(overrides = {})
    base_claim_payload(task_id: TASK)
      .merge("executor" => SpecrelayRunner::CodexProfile::CANONICAL.merge(overrides))
  end

  # A PROVIDER-ONLY local selection — the same shape Platform accepts and expands from its own
  # fixed map. `extra` is how a test writes a local block that tries to describe a profile.
  def codex_config(extra: nil)
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
          provider: codex
      #{extra ? "    #{extra}" : ""}
      workspace_roots:
        tiny-demo-workspace: #{@root}
    YAML
  end

  # A runner config that selects NO real provider — the deterministic fixture regression path.
  def fixture_config
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

  # Runs the CLI with `bin_dir` PREPENDED to a child PATH from which every real `codex` has been
  # removed, so the runner's own PATH resolution finds (or fails to find) the double — and so this
  # deterministic suite can never reach the operator's real CLI, account, or inference.
  def run_cli(config_path, bin_dir: nil, io: @io)
    path = [ bin_dir, *self.class.path_without_codex ].compact.join(File::PATH_SEPARATOR)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{config_path}], out: io, err: io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => path })
  end

  def self.path_without_codex
    @path_without_codex ||= ENV["PATH"].to_s.split(File::PATH_SEPARATOR).reject do |dir|
      dir.strip.empty? || File.executable?(File.join(dir, "codex"))
    end
  end

  # --- readiness gates the claim (S02) ---------------------------------------

  def test_an_absent_cli_exits_non_zero_without_claiming_anything
    start_platform(codex_payload)
    bin_dir, = FakeCodexCli.build(install: false)

    exit_code = run_cli(codex_config, bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    assert_equal 0, @platform.requests.size, "the ordinary claim-loop preflight makes no Platform request"
    assert_match(/codex=unavailable/, @io.string)
    assert_match(/install Codex/i, @io.string)
    refute File.exist?(File.join(@root, ".runs", "worktrees", TASK)), "no worktree may be created"
  end

  def test_a_logged_out_cli_exits_non_zero_without_claiming_anything
    start_platform(codex_payload)
    bin_dir, = FakeCodexCli.build(login: :logged_out)

    exit_code = run_cli(codex_config, bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    assert_equal 0, @platform.requests.size
    assert_match(/auth=not_authenticated/, @io.string)
    assert_match(/codex login/, @io.string)
  end

  def test_a_failing_login_probe_exits_non_zero_without_claiming_anything
    start_platform(codex_payload)
    bin_dir, = FakeCodexCli.build(login: :error)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(codex_config, bin_dir: bin_dir), @io.string
    assert_equal 0, @platform.requests.size
  end

  def test_malformed_version_output_blocks_the_claim_without_echoing_it
    start_platform(codex_payload)
    bin_dir, = FakeCodexCli.build(version: :unexpected)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(codex_config, bin_dir: bin_dir), @io.string
    assert_equal 0, @platform.requests.size
    refute_includes @io.string, FakeCodexCli::ACCOUNT_EMAIL
  end

  # The readiness probes must never print the operator's account identity.
  def test_readiness_never_prints_account_details
    start_platform(codex_payload)
    bin_dir, = FakeCodexCli.build(login: :logged_out)
    run_cli(codex_config, bin_dir: bin_dir)

    refute_includes @io.string, FakeCodexCli::ACCOUNT_EMAIL
    refute_includes @io.string, FakeCodexCli::ACCOUNT_ORG
  end

  # S03 — the safe, bounded version fact is reported; nothing else from the probe is.
  def test_the_safe_cli_version_reaches_the_local_summary
    start_platform(codex_payload)
    bin_dir, = FakeCodexCli.build

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli(codex_config, bin_dir: bin_dir), @io.string
    assert_includes @io.string, FakeCodexCli::VERSION_LINE
    refute_includes @io.string, FakeCodexCli::ACCOUNT_EMAIL
  end

  # --- the deterministic fixture stays offline (S11) -------------------------

  def test_the_fixture_path_never_probes_either_real_provider
    root, executor = DemoWorkspace.build
    @root = root
    start_platform(base_claim_payload(task_id: TASK))
    codex_bin, codex_argv = FakeCodexCli.build
    claude_bin, claude_argv = FakeClaudeCli.build
    path = [ fixture_bin(executor), codex_bin, claude_bin ].join(File::PATH_SEPARATOR)

    exit_code = run_cli(fixture_config, bin_dir: path)

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    refute File.exist?(codex_argv), "the fixture path must never invoke the codex CLI"
    refute File.exist?(claude_argv), "the fixture path must never invoke the claude CLI"
    refute_match(/Readiness:/, @io.string)
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
  end

  # --- exact-profile enforcement (S04) ---------------------------------------

  def test_a_local_block_that_composes_a_profile_is_a_usage_error_before_any_request
    start_platform(codex_payload)
    bin_dir, = FakeCodexCli.build

    exit_code = run_cli(codex_config(extra: "args: [exec, --json, --model, o3]"), bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::USAGE_ERROR, exit_code, @io.string
    assert_equal 0, @platform.requests.size
    assert_match(/only a provider/, @io.string)
  end

  def test_a_claimed_payload_with_different_args_is_refused_before_the_worktree
    start_platform(codex_payload("args" => ARGS + %w[--skip-git-repo-check]))
    bin_dir, argv_log = FakeCodexCli.build

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(codex_config, bin_dir: bin_dir), @io.string
    assert_equal 0, @platform.requests_to("/api/runner/reports").size
    refute File.exist?(File.join(@root, ".runs", "worktrees", TASK)), "no worktree may be created"
    assert_match(/executor\.args is not the approved codex profile/, @io.string)
    # Only the readiness probes touched the CLI; no prompt was ever delivered.
    assert_equal %w[login status], JSON.parse(File.read(argv_log))
  end

  def test_a_claimed_payload_naming_a_different_codex_is_refused_without_running_it
    attacker_dir = Dir.mktmpdir("attacker-codex-")
    marker = File.join(attacker_dir, "it-ran")
    File.write(File.join(attacker_dir, "codex"), "#!/bin/sh\ntouch #{marker}\nexit 0\n")
    FileUtils.chmod(0o755, File.join(attacker_dir, "codex"))
    start_platform(codex_payload("command" => File.join(attacker_dir, "codex")))
    bin_dir, = FakeCodexCli.build

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(codex_config, bin_dir: bin_dir), @io.string
    refute File.exist?(marker), "the attacker-controlled executable must never be spawned"
    assert_equal 0, @platform.requests_to("/api/runner/reports").size
    assert_match(/executor\.command is not the approved codex profile/, @io.string)
  ensure
    FileUtils.remove_entry(attacker_dir) if attacker_dir && File.directory?(attacker_dir)
  end

  # An unknown provider is refused before the worktree rather than silently treated as the
  # fixture, which is what a non-closed selection used to do.
  def test_an_unknown_claimed_provider_is_refused_before_the_worktree
    start_platform(codex_payload("provider" => "some-other-agent"))
    bin_dir, = FakeCodexCli.build

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(codex_config, bin_dir: bin_dir), @io.string
    assert_equal 0, @platform.requests_to("/api/runner/reports").size
    refute File.exist?(File.join(@root, ".runs", "worktrees", TASK)), "no worktree may be created"
  end

  # --- the complete shared lifecycle (S09) -----------------------------------

  def test_the_codex_profile_completes_the_whole_shared_flow_exactly_once
    start_platform(codex_payload)
    bin_dir, argv_log = FakeCodexCli.build

    exit_code = run_cli(codex_config, bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    assert_includes decode_file("evidence/diff.txt"), "Hello SpecRelay Demo",
                    "the executor really edited the worktree"

    # The prompt was delivered on STDIN: it is not an argv element at all.
    argv = JSON.parse(File.read(argv_log))
    assert_equal ARGS, argv
    refute_includes argv.join(" "), "Automated execution task"

    manifest = YAML.safe_load(decode_file("manifest.yml"))
    assert_equal "codex", manifest.dig("executor", "provider")
    assert_equal [ "codex", *ARGS ], manifest.dig("executor", "argv")
    assert_equal "succeeded", manifest["execution_status"]

    assert_equal 1, @platform.requests_to("/api/runner/reports").size
    assert_equal "succeeded", @platform.last_terminal_result["outcome"]
    assert_nil @platform.last_terminal_result.dig("core", "error_classification")
  end

  # S04/S08 — the report and both live surfaces carry the decoded public transcript and never a
  # raw frame, a credential, private reasoning, or an account identity.
  def test_codex_progress_is_public_ordered_and_free_of_private_material
    start_platform(codex_payload)
    bin_dir, = FakeCodexCli.build
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli(codex_config, bin_dir: bin_dir), @io.string

    live_log = @platform.protocol_events.filter_map { |event| event["sanitized_log_chunk"] }.join("\n")
    [ @io.string, live_log ].each do |surface|
      assert_includes surface, "Provider started"
      assert_includes surface, "working on the heading"
      assert_includes surface, "Provider completed"
      refute_includes surface, %("item_type"), "a raw provider frame reached a surface"
      refute_includes surface, FakeCodexCli::PRIVATE_REASONING
      refute_includes surface, FakeCodexCli::LEAKED_TOKEN
      refute_includes surface, FakeCodexCli::ACCOUNT_EMAIL
    end

    whole_bundle = JSON.generate(@platform.last_report[:body])
    [ FakeCodexCli::ACCOUNT_EMAIL, FakeCodexCli::ACCOUNT_ORG,
      FakeCodexCli::PRIVATE_REASONING, FakeCodexCli::LEAKED_TOKEN ].each do |forbidden|
      refute_includes whole_bundle, forbidden, "#{forbidden.inspect} must never reach the uploaded report"
    end

    # Only the LAST public agent message became the implementation report.
    stdout_log = decode_file("evidence/stdout.log")
    assert_includes stdout_log, "applied the heading change"
    refute_includes stdout_log, "working on the heading"
  end

  # --- fail closed after the claim (S06, S07) --------------------------------

  def test_a_failed_turn_uploads_a_failed_report_and_never_a_success
    start_platform(codex_payload)
    bin_dir, = FakeCodexCli.build(run: :turn_failed)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(codex_config, bin_dir: bin_dir), @io.string
    assert_equal "failed", @platform.last_terminal_result["outcome"]
    refute_includes JSON.generate(@platform.last_report[:body]), FakeCodexCli::ACCOUNT_EMAIL
  end

  def test_a_stream_without_a_terminal_event_cannot_produce_a_successful_report
    start_platform(codex_payload)
    bin_dir, = FakeCodexCli.build(run: :no_terminal)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(codex_config, bin_dir: bin_dir), @io.string
    assert_equal "failed", @platform.last_terminal_result["outcome"]
    assert_match(/unusable output/, @io.string)
  end

  def test_an_auth_indicated_exit_keeps_its_own_classification
    start_platform(codex_payload)
    bin_dir, = FakeCodexCli.build(run: :auth_failure)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(codex_config, bin_dir: bin_dir), @io.string
    assert_equal "executor_not_authenticated", @platform.last_terminal_result.dig("core", "error_classification")
  end

  def test_an_ordinary_nonzero_exit_is_reported_as_a_plain_executor_failure
    start_platform(codex_payload)
    bin_dir, = FakeCodexCli.build(run: :fail)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(codex_config, bin_dir: bin_dir), @io.string
    assert_equal "executor_failed", @platform.last_terminal_result.dig("core", "error_classification")
  end

  private

  def decode_file(relative)
    entry = @platform.last_report[:body].dig("report", "files").find { |f| f["relative_path"] == relative }
    Base64.strict_decode64(entry.fetch("content_base64"))
  end
end
