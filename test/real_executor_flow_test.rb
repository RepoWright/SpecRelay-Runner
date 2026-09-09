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

  # The supported argv, in ONE place: MAPIAI-60 made structured output mandatory, so a fixture
  # that spelled the flags out per test would drift from the profile it is meant to exercise.
  ARGS = %w[--print --output-format stream-json --verbose --dangerously-skip-permissions].freeze

  # The claim payload Platform returns once it has merged this runner's `executor:`
  # override over the workspace definition — i.e. the real Claude profile.
  # The CANONICAL Claude profile, byte-for-byte what Platform serves. An override here produces a
  # payload the runner must refuse, which is what the refusal examples assert.
  def claude_payload(overrides = {})
    base_claim_payload(task_id: TASK)
      .merge("executor" => SpecrelayRunner::ClaudeProfile::CANONICAL.merge(overrides))
  end

  # A PROVIDER-ONLY local selection — the same shape Platform accepts and expands from its own
  # fixed map. `extra` is how a test writes a local block that tries to describe a profile.
  def claude_config(extra: nil)
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
      #{extra ? "    #{extra}" : ""}
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
    root, executor = DemoWorkspace.build
    @root = root
    start_platform(base_claim_payload(task_id: TASK))
    bin_dir, argv_log = FakeClaudeCli.build

    exit_code = run_cli(fake_config, bin_dir: "#{fixture_bin(executor)}:#{bin_dir}")

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    refute File.exist?(argv_log), "the fake-executor path must never invoke the claude CLI"
    refute_match(/Readiness:/, @io.string)
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
  end

  # An argv this runner refuses to launch is a config error surfaced BEFORE any
  # network call — not something discovered after a claim is burned.
  def test_a_local_block_that_composes_a_profile_is_a_usage_error_before_any_request
    start_platform(claude_payload)
    bin_dir, = FakeClaudeCli.build

    exit_code = run_cli(claude_config(extra: "args: [--print, --resume]"), bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::USAGE_ERROR, exit_code, @io.string
    assert_equal 0, @platform.requests.size
    assert_match(/only a provider/, @io.string)
  end

  # --- fail closed on a mismatched claim (acceptance criterion 4) ------------

  def test_a_claimed_fake_executor_is_refused_without_executing_it
    # Platform hands back the seeded FAKE fixture even though this runner selected
    # the real Claude profile. Executing it would produce evidence that lies about
    # what ran, so the runner refuses.
    start_platform(base_claim_payload(task_id: TASK))
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
    assert_match(%r{bin/platform runner release #{TASK}}, @io.string)
    # An executor-policy mismatch keeps its manual recovery step for the same reason (CR-001 F3).
    assert_equal 0, @platform.requests_to("/api/runner/claim_releases").size
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
    assert_match(/executor\.command is not the approved claude profile/, @io.string)
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
    assert_match(/executor\.env is not the approved claude profile/, @io.string)
  end

  def test_a_claimed_payload_that_shrinks_the_timeout_is_refused
    start_platform(claude_payload("timeout_seconds" => 1))
    bin_dir, = FakeClaudeCli.build

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(claude_config, bin_dir: bin_dir), @io.string
    assert_equal 0, @platform.requests_to("/api/runner/reports").size
    assert_match(/executor\.timeout_seconds is not the approved claude profile/, @io.string)
  end

  # This example used to assert the opposite. It guarded the merged block Platform once produced —
  # a workspace definition composed with a runner-local override, carrying a `semantic_events` key
  # the profile never owned — and required that shape to still launch.
  #
  # Two things retired it. Platform stopped composing overrides into the executor block and dropped
  # `semantic_events` from its default configuration entirely, so no assignment carries the key any
  # more; and the claim gate now reads the whole hash, so a key the runner cannot account for
  # is a claim it will not launch on. What was a compatibility guarantee is now a refusal, and the
  # refusal is the boundary worth guarding.
  def test_a_claimed_payload_carrying_an_unknown_key_is_refused
    start_platform(claude_payload("semantic_events" => "auto"))
    bin_dir, = FakeClaudeCli.build

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(claude_config, bin_dir: bin_dir), @io.string
    assert_equal 0, @platform.requests_to("/api/runner/reports").size
    assert_match(/executor carries semantic_events/, @io.string)
  end

  def test_a_claimed_payload_with_different_args_is_refused
    start_platform(claude_payload("args" => ARGS + %w[--model opus]))
    bin_dir, = FakeClaudeCli.build

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(claude_config, bin_dir: bin_dir), @io.string
    assert_equal 0, @platform.requests_to("/api/runner/reports").size
    assert_match(/preflight_failed/, @io.string)
    assert_match(/executor\.args is not the approved claude profile/, @io.string)
  end

  # --- the complete real-profile success seam (acceptance criterion 6) -------

  def test_the_real_profile_completes_the_whole_flow
    start_platform(claude_payload)
    bin_dir, argv_log = FakeClaudeCli.build

    exit_code = run_cli(claude_config, bin_dir: bin_dir)

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    # Read from the uploaded diff rather than from disk: a successful implementation hands its
    # task environment back before this machine claims again (MAPIAI-97), and the report is where
    # the edit durably lives.
    assert_includes decode_file("evidence/diff.txt"), "Hello SpecRelay Demo",
                    "the executor really edited the worktree"

    # The prompt reached the CLI as ONE distinct argv element — no shell, no
    # interpolation, no splitting.
    argv = JSON.parse(File.read(argv_log))
    assert_equal ARGS, argv.first(ARGS.length)
    assert_equal ARGS.length + 1, argv.length
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
    assert_equal [ "claude", *ARGS, "<PROMPT>" ], manifest.dig("executor", "argv")
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

  # --- MAPIAI-60: live provider progress on both surfaces --------------------

  # The whole point of the ticket, proven on the real profile seam: while Claude works, the
  # operator's terminal and Platform receive the SAME transcript, from the same decoder, in the
  # same order — and neither ever receives a raw frame.
  def test_claude_progress_reaches_the_terminal_and_platform_before_the_attempt_finishes
    start_platform(claude_payload)
    bin_dir, = FakeClaudeCli.build

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli(claude_config, bin_dir: bin_dir), @io.string

    expected = [ "Provider started", "> Read ", "> Edit ", "> Bash npm test" ]
    expected.each { |line| assert_includes @io.string, line }
    assert_includes @io.string, "demo-app/index.html", "the file the provider worked on is named"

    types = @platform.protocol_events.map { |event| event["event_type"] }
    chunks = @platform.protocol_events.select { |event| event["event_type"] == "log.chunk" }
    assert_operator types.index("core.started"), :<, types.index("log.chunk")
    assert_operator types.index("log.chunk"), :<, types.index("verification.started")
    assert_equal [ "status" ], chunks.map { |event| event.dig("attributes", "log_source") }.uniq,
                 "normalized progress reuses the existing status stream; it adds no log_source"

    delivered = chunks.map { |event| event["sanitized_log_chunk"].to_s }.join("\n")
    expected.each { |fragment| assert_includes delivered, fragment }
    positions = expected.map { |fragment| delivered.index(fragment) }
    assert_equal positions.sort, positions,
                 "both surfaces must show the same events in the same canonical order"
  end

  def test_no_raw_structured_frame_reaches_a_surface_and_the_result_stays_authoritative
    start_platform(claude_payload)
    bin_dir, = FakeClaudeCli.build
    run_cli(claude_config, bin_dir: bin_dir)

    # MAPIAI-75 — the live surface is what Platform accepted, not a report copy of it.
    live_log = @platform.protocol_events.filter_map { |event| event["sanitized_log_chunk"] }.join("\n")
    [ @io.string, live_log, JSON.generate(@platform.last_report[:body]) ].each do |surface|
      refute_includes surface, %("type":"assistant"), "a raw provider frame reached a surface"
      refute_includes surface, FakeClaudeCli::LEAKED_TOKEN, "a credential reached a surface"
    end

    # CR-005 reverses the other half of this assertion. The provider's PUBLIC narration and its
    # tool output are exactly what an operator needs, so they must now be present — with the
    # credential planted inside that same narration redacted by the one boundary that owns it.
    [ @io.string, live_log ].each do |surface|
      assert_includes surface, "considering the task", "public narration must reach the operator"
      assert_includes surface, "raw tool output", "tool output must reach the operator"
      assert_includes surface, "[REDACTED]", "the planted credential must be redacted in place"
    end

    # The report's stdout evidence is the DECODED terminal result — the provider's answer, not
    # the transport that carried it.
    stdout_log = decode_file("evidence/stdout.log")
    assert_includes stdout_log, "applied the heading change"
    refute_includes stdout_log, %("type":"result")
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

  # The wall-clock timeout proof moved to executor_timeout_test.rb when the claimed profile became
  # EXACT: a payload may no longer shorten the approved 1800-second timeout, so a flow-level timeout
  # can no longer be provoked without waiting half an hour. The mechanism (real Timeout, real
  # process-group kill, `timed_out` result) is proven there against a real hanging process, and the
  # classification it produces is proven in claude_profile_test.rb and codex_profile_test.rb.

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

# --- a question Platform refused, corrected in the same session ------------

REFUSAL = [ "continuation_context.progress is required" ].freeze
QUESTION_ANSWERS = [ { "option" => "keep" } ].freeze

def worktree_path = File.join(@root, ".runs", "worktrees", TASK)

# The complete observed chain against the real Runner boundary: a changed worktree, one Platform
# validation refusal, a corrected request from the SAME process, one result frame for the
# refused turn and one final result. Exactly one terminal result and one contract-valid report
# may follow, and only the final result is evidence.
def test_a_question_refused_and_corrected_in_the_same_session_ends_in_one_valid_report
  start_platform(claude_payload)
  @platform.refuse_next_question!(REFUSAL)
  @platform.answer_question!(QUESTION_ANSWERS)
  bin_dir, = FakeClaudeCli.build(run: :refused_question)

  exit_code = run_cli(claude_config, bin_dir: bin_dir)

  assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
  # The refusal reached the same live process with the field error it can act on, and that
  # process — not a new one — corrected and asked again.
  assert_includes @io.string, "question refused:"
  assert_includes @io.string, REFUSAL.first
  assert_equal 2, @platform.question_submissions.size, "the refused turn and its correction"
  assert_empty @platform.capture_failures
  assert_equal 1, @platform.delivery_acknowledgements.size
  assert_equal 1, @platform.requests_to("/api/runner/reports").size
  assert_equal "succeeded", @platform.last_terminal_result["outcome"]
  manifest = YAML.safe_load(decode_file("manifest.yml"))
  assert_equal [ "demo-app/index.html" ], manifest.dig("git", "changed_files")
  assert_equal [ "." ], manifest["repository_verifications"].map { |row| row["repository_path"] }
  assert_coherent(manifest)
  stdout_log = decode_file("evidence/stdout.log")
  assert_includes stdout_log, FakeClaudeCli::FINAL_RESULT
  refute_includes stdout_log, FakeClaudeCli::INTERMEDIATE_RESULT
  refute_includes @io.string, SpecrelayRunner::ClaudeStream::FAILURE_TWO_RESULTS
  assert_equal 1, @platform.protocol_events.count { |event| event["event_type"] == "verification.started" }
  assert_empty @platform.protocol_events.select { |event| event["event_type"].start_with?("publication.") }
end

# The refused turn is followed by the provider leaving. Nothing coherent can be reported about
# the changed worktree, so the attempt ends through the question lifecycle: no report, no
# verification, no publication, the work preserved, one actionable line.
def test_a_refused_question_followed_by_provider_exit_uploads_no_report
  start_platform(claude_payload)
  @platform.refuse_next_question!(REFUSAL)
  bin_dir, = FakeClaudeCli.build(run: :refused_question, refused_turn: :exit)

  exit_code = run_cli(claude_config, bin_dir: bin_dir)

  assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
  assert_equal 1, @platform.question_submissions.size
  assert_equal 1, @platform.capture_failures.size, "the ending is reported once, through the question lifecycle"
  assert_empty @platform.requests_to("/api/runner/reports"),
               "a changed worktree with no verification rows must never become a report"
  assert_empty @platform.protocol_events.select { |event| event["event_type"].start_with?("verification.", "publication.") }
  assert_match(/input_capture_failed/, @io.string)
  assert_includes @io.string, REFUSAL.first
  refute_includes @io.string, SpecrelayRunner::ClaudeStream::FAILURE_TWO_RESULTS
  assert_path_exists worktree_path, "the dirty worktree is preserved"
  assert_includes edited_heading, "Hello SpecRelay Demo"
end

# One refusal explains one intermediate result and no more. A sequence that outruns the
# refusals this attempt recorded is still unusable output — but after a refused question it
# ends the same way the exit above does, never as a report about an unproven result.
def test_a_result_sequence_that_outruns_the_recorded_refusals_fails_closed_without_a_report
  start_platform(claude_payload)
  @platform.refuse_next_question!(REFUSAL)
  @platform.answer_question!(QUESTION_ANSWERS)
  bin_dir, = FakeClaudeCli.build(run: :refused_question, refused_turn: :repeat)

  exit_code = run_cli(claude_config, bin_dir: bin_dir)

  assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
  assert_equal 1, @platform.capture_failures.size
  assert_empty @platform.requests_to("/api/runner/reports")
  assert_includes @io.string, SpecrelayRunner::ClaudeStream::FAILURE_TWO_RESULTS
  assert_match(/input_capture_failed/, @io.string)
  assert_empty @platform.protocol_events.select { |event| event["event_type"].start_with?("verification.", "publication.") }
  assert_path_exists worktree_path, "the dirty worktree is preserved"
end

# Platform's report contract, asserted on what the runner SENT: a measured change and the
# verification collection must agree about whether anything changed.
def assert_coherent(manifest)
  assert_equal Array(manifest.dig("git", "changed_files")).any?, Array(manifest["repository_verifications"]).any?,
               "changed files and repository verification rows disagree: #{manifest.slice('git', 'repository_verifications')}"
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
