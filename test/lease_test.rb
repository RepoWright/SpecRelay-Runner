# frozen_string_literal: true

require_relative "test_helper"

# MVP-0012: the standalone runner OBSERVES the lease/cancellation liveness signal
# Platform returns on heartbeat/event responses. When Platform reports the claim
# is no longer live (cancelled or lease expired), the runner stops, uploads NO
# success report, and exits non-zero. Platform owns the outcome; the thin runner
# only obeys.
class LeaseTest < Minitest::Test
  TASK = "DEMO-0005"

  def setup
    @root, @executor = DemoWorkspace.build
    @platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK)).start
    @config = build_config
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

  def run_cli(io)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{@config.source_path}],
                             out: io, err: io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] })
  end

  def test_runner_aborts_on_cancellation_without_uploading_a_report
    @platform.signal_cancelled!
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_equal 1, @platform.requests_to("/api/runner/claim").size
    assert_equal 0, @platform.requests_to("/api/runner/reports").size, "must not upload a report after cancellation"
    assert_match(/aborted/, io.string)
    assert_match(/cancelled/, io.string)
  end

  def test_runner_aborts_on_expired_lease_without_uploading_a_report
    @platform.signal_expired!
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_equal 0, @platform.requests_to("/api/runner/reports").size, "must not upload a report after lease expiry"
    assert_match(/aborted/, io.string)
  end
end
