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

  # ------------------------------------------------------------ claim authority while it runs

  # How long the provider would work if nothing stopped it. Long enough that finishing on its own
  # and being stopped are unmistakable apart.
  PROVIDER_HOLD_SECONDS = 25

  # The claim response arrives after Platform's lease has already lapsed. The claim itself gives
  # no authority; the first renewal is declined, and no provider is launched.
  def test_a_claim_whose_response_arrived_after_its_lease_lapsed_launches_no_provider
    use_held_provider
    platform = @platform
    @platform.claim_hold = -> { platform.signal_expired! }
    io = StringIO.new

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_held_cli(io), io.string

    refute_path_exists provider_pid_file, "a provider was launched without a confirmed renewal"
    assert_empty @platform.requests_to("/api/runner/reports")
  end

  # Platform reports the lease expired while the provider works: the provider's whole process group
  # is ended at once instead of being allowed to finish, and nothing is reported.
  def test_a_lease_that_expires_while_the_provider_runs_ends_the_provider
    use_held_provider
    io = StringIO.new

    elapsed, exit_code = timed_run(io) { @platform.signal_expired! }

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_operator elapsed, :<, PROVIDER_HOLD_SECONDS - 10, "the provider was allowed to finish:\n#{io.string}"
    assert provider_group_gone?, "the provider's process group outlived the run"
    assert_empty @platform.requests_to("/api/runner/reports")
    assert_match(/Platform reports expired/, io.string)
  end

  # Renewal stops being confirmed while the provider works. This machine stops on its own, and says
  # so: it is not something Platform reported, and nothing was handed back.
  def test_unconfirmed_renewal_while_the_provider_runs_stops_it_and_says_why
    use_held_provider(execution_policy: { "lease_duration_seconds" => 3, "lease_renewal_seconds" => 1 })
    io = StringIO.new

    elapsed, exit_code = with_heartbeats_failing_once_the_provider_starts { timed_run(io) }

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_operator elapsed, :<, PROVIDER_HOLD_SECONDS - 10, "the provider was allowed to finish:\n#{io.string}"
    assert provider_group_gone?
    assert_empty @platform.requests_to("/api/runner/reports")
    assert_includes io.string, "no renewal of this claim was confirmed within the lease"
    refute_match(/Platform reports/, io.string)
    refute_match(/claim released/, io.string)
  end

  private

  def fixture_dir = @fixture_dir ||= fixture_bin
  def provider_pid_file = File.join(@root, "provider.pid")

  # The demo executor behind the approved fixture name, held open first, with its process id
  # written down so "its process group is gone" is an observation. The claim names the workspace
  # root, so the run really reaches its provider.
  def use_held_provider(execution_policy: {})
    @platform.claim_payload = claim_payload_for(task_id: TASK, root: @root).merge(
      "execution_policy" => { "lease_renewal_seconds" => 1 }.merge(execution_policy)
    )
    held = File.join(@root, "held-provider")
    File.write(held, <<~SH)
      #!/bin/sh
      echo $$ > #{Shellwords.escape(provider_pid_file)}
      sleep #{PROVIDER_HOLD_SECONDS}
      exec #{Shellwords.escape(File.expand_path(@executor))} "$@"
    SH
    FileUtils.chmod(0o755, held)
    use_fixture(fixture_dir, held)
  end

  def run_held_cli(io)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{@config.source_path}],
                             out: io, err: io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
                                    "PATH" => "#{fixture_dir}:#{ENV['PATH']}" })
  end

  # Runs the claim, calling `on_provider` once the provider is running, and measures how long the
  # whole invocation took.
  def timed_run(io, &on_provider)
    watcher = Thread.new do
      sleep 0.05 until File.exist?(provider_pid_file)
      on_provider&.call
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    exit_code = run_held_cli(io)
    [ Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, exit_code ]
  ensure
    watcher&.kill
  end

  def provider_group_gone?
    Process.kill(0, -File.read(provider_pid_file).to_i)
    false
  rescue Errno::ESRCH
    true
  rescue Errno::EPERM
    # Members not yet reaped answer EPERM on this platform: not yet shown gone.
    false
  end

  # Platform unreachable for renewal from the moment the provider is running; every other request
  # still travels.
  def with_heartbeats_failing_once_the_provider_starts
    marker = provider_pid_file
    original = SpecrelayRunner::PlatformClient.instance_method(:heartbeat)
    SpecrelayRunner::PlatformClient.define_method(:heartbeat) do |claim:|
      raise SpecrelayRunner::PlatformClient::Error, "Platform is unreachable" if File.exist?(marker)

      original.bind(self).call(claim: claim)
    end
    yield
  ensure
    SpecrelayRunner::PlatformClient.define_method(:heartbeat, original)
  end
end
