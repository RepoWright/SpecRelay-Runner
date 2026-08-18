# frozen_string_literal: true

require_relative "test_helper"

# MVP-0013 proof for the STANDALONE runner's protocol behavior over real HTTP:
# a per-attempt monotonic sequence, well-formed v1 event envelopes, safe retry
# that never reuses a sequence for a different payload, the deterministic
# out-of-order/duplicate/conflict controls (default off), the terminal-result
# envelope submitted with the report bundle, and the absence of any Rails /
# ActiveRecord dependency.
class ProtocolFlowTest < Minitest::Test
  TASK = "DEMO-0001"

  def setup
    @root, @executor = DemoWorkspace.build
    @platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK, executor_command: @executor)).start
    @config_path = write_config
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
    io = StringIO.new
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] }.merge(extra_env)
    code = SpecrelayRunner::CLI.run(%W[claim-once --config #{@config_path}], out: io, err: io, env: env)
    [ code, io.string ]
  end

  def test_events_carry_a_v1_envelope_with_a_monotonic_sequence
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    events = @platform.protocol_events
    sequences = events.map { |e| e["sequence"] }
    assert_equal (1..events.size).to_a, sequences, "sequence must be a dense monotonic 1..N"

    events.each do |event|
      assert_equal "1", event["contract_version"]
      assert_equal 1, event["schema_version"]
      assert_equal "run_test123", event["run_id"]
      assert_equal @platform.protocol_attempt_id, event["attempt_id"]
      refute_nil event["occurred_at"]
      refute event["public_summary"].to_s.empty?
      assert_includes SpecrelayRunner::EventEmitter::CONTRACT_VERSION, "1"
    end

    types = events.map { |e| e["event_type"] }
    assert_equal "attempt.started", types.first
    assert_equal "attempt.completed", types.last
    assert_includes types, "core.started"
    assert_includes types, "verification.completed"
  end

  def test_terminal_result_envelope_is_submitted_with_the_report
    run_cli
    terminal = @platform.last_terminal_result
    refute_nil terminal, "a terminal-result envelope must accompany the report"

    assert_equal "1", terminal["contract_version"]
    assert_equal "run_test123", terminal["run_id"]
    assert_equal @platform.protocol_attempt_id, terminal["attempt_id"]
    assert_equal "succeeded", terminal["outcome"]
    assert_equal @platform.protocol_events.map { |e| e["sequence"] }.max, terminal["final_sequence"]
    assert_equal 0, terminal.dig("core", "exit_code")
    repo = terminal["repositories"].first
    # MAPIAI-84 — a repository is identified by its own normalized GitHub remote, read from the
    # repository, not by a workspace key Platform declared.
    assert_equal "SpecRelay/tiny-demo-workspace", repo["id"]
    assert_equal "git@github.com:SpecRelay/tiny-demo-workspace.git", repo["clone_url"]
    assert_equal "main", repo["default_branch"]
    assert repo["changed"]
    assert_match(/\A[0-9a-f]{40,64}\z/, repo["base_commit"])
    # This assignment carries no publication policy at all, so nothing was published: the change is
    # reported truthfully with the reason it was not, and no commit is claimed for a commit that
    # was never made.
    assert_nil repo["head_commit"]
    assert_nil repo["branch"]
    assert_match(/read-only/, repo["publication_skipped_reason"])
    assert terminal.dig("cleanup", "succeeded")
    refute_empty terminal["artifacts"]
  end

  def test_out_of_order_control_sends_a_reversed_adjacent_pair
    run_cli("SPECRELAY_RUNNER_EVENT_OUT_OF_ORDER" => "true")
    sequences = @platform.protocol_events.map { |e| e["sequence"] }
    reversed = sequences.each_cons(2).any? { |a, b| a > b }
    assert reversed, "a higher sequence must be delivered before a lower one: #{sequences.inspect}"
    # Even reversed, the full set of accepted sequences stays dense (no gap).
    assert_equal (1..sequences.max).to_a, sequences.uniq.sort
  end

  def test_duplicate_control_resends_the_same_sequence
    run_cli("SPECRELAY_RUNNER_EVENT_DUPLICATE" => "true")
    sequences = @platform.protocol_events.map { |e| e["sequence"] }
    assert_equal 2, sequences.count { |s| s == 2 }, "sequence 2 must be re-sent verbatim"
  end

  def test_conflict_control_resends_a_used_sequence_with_a_different_payload
    run_cli("SPECRELAY_RUNNER_EVENT_CONFLICT" => "true")
    seq2 = @platform.protocol_events.select { |e| e["sequence"] == 2 }
    assert_equal 2, seq2.size
    refute_equal seq2.first["public_summary"], seq2.last["public_summary"], "the conflict resend must differ"
  end

  def test_forced_terminal_failure_submits_a_failed_envelope
    run_cli("SPECRELAY_RUNNER_FORCE_TERMINAL_FAILURE" => "true")
    assert_equal "failed", @platform.last_terminal_result["outcome"]
    report = @platform.last_report[:body].fetch("report")
    manifest = YAML.safe_load(Base64.strict_decode64(report["files"].find { |f| f["relative_path"] == "manifest.yml" }["content_base64"]))
    assert_equal "failed", manifest["execution_status"]
  end

  def test_runner_has_no_rails_or_activerecord_dependency
    assert_nil defined?(Rails), "the standalone runner must not load Rails"
    assert_nil defined?(ActiveRecord), "the standalone runner must not load ActiveRecord"
  end
end
