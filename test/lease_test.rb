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

  # ------------------------------------------------------------ a failed renewal while the lease holds

  # One server error on a phase-boundary renewal, after an acknowledged renewal opened the window:
  # the attempt continues, the provider runs and the report is submitted.
  def test_a_server_error_on_a_phase_boundary_renewal_does_not_stop_the_attempt
    io = StringIO.new

    exit_code = with_heartbeat_answers(:platform, 503) { run_full_cli(io) }

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, io.string
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
    assert_includes io.string, "Platform could not be reached"
  end

  # Event delivery is the first request of the same boundary. A transport failure there is
  # tolerated the same way, and the terminal result is still accepted despite the missing event.
  def test_a_transport_failure_delivering_a_phase_event_does_not_stop_the_attempt
    io = StringIO.new

    exit_code = with_event_delivery_failing_on(2) { run_full_cli(io) }

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, io.string
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
    assert_includes io.string, "Platform could not be reached"
  end

  # Tolerance needs an earlier acknowledged renewal. A boundary that fails while one still covers
  # the claim continues; the same failure once that cover has run out stops it, as this machine's
  # own finding rather than something Platform said.
  def test_a_phase_boundary_tolerates_failures_only_while_an_acknowledged_renewal_covers_it
    execution = direct_execution("lease_duration_seconds" => 2)
    execution.send(:start_heartbeater)
    with_heartbeat_answers(:platform, 503, :transport, rest: :transport) do
      execution.send(:emit, "attempt.started", "acknowledged renewal", phase: "attempt")
      execution.send(:emit, "workspace.preparing", "inside the window", phase: "workspace")
      sleep 2.2

      error = assert_raises(SpecrelayRunner::Execution::Aborted) do
        execution.send(:emit, "workspace.ready", "past the window", phase: "workspace")
      end
      assert_equal SpecrelayRunner::Heartbeater::UNCONFIRMED, error.message
    end
  ensure
    execution&.instance_variable_get(:@heartbeater)&.stop
  end

  # Without an acknowledged renewal there is no window to tolerate anything in: the attempt stops
  # before its provider is launched.
  def test_a_transient_failure_before_any_acknowledged_renewal_stops_the_attempt
    use_held_provider
    io = StringIO.new

    exit_code = with_heartbeat_answers(rest: :transport) { run_held_cli(io) }

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    refute_path_exists provider_pid_file, "a provider was launched without a confirmed renewal"
    assert_empty @platform.requests_to("/api/runner/reports")
    assert_includes io.string, "no renewal of this claim was confirmed within the lease"
  end

  # A heartbeat Platform refuses is a stop the moment it is read, even inside an open window. It
  # ends this attempt as aborted rather than escaping as an error: nothing is reported, and the
  # task environment is kept because nothing here shows the Run ended.
  def test_a_refused_heartbeat_ends_the_attempt_aborted_with_no_report
    [ 401, 403, 404, 422 ].each do |status|
      reset_platform
      io = StringIO.new

      exit_code = with_heartbeat_answers(:platform, status) { run_full_cli(io) }

      assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
      assert_empty @platform.requests_to("/api/runner/reports"), "HTTP #{status}"
      assert_includes io.string, "Runner outcome: aborted (#{SpecrelayRunner::Heartbeater::REJECTED})", io.string
      assert_includes io.string, "this run's task environment is kept"
      refute_match(/Runner failed/, io.string)
    end
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

  # A claim whose workspace root is mapped and whose provider is the demo executor, so the attempt
  # really reaches a report when nothing stops it.
  def run_full_cli(io)
    @platform.claim_payload = claim_payload_for(task_id: TASK, root: @root)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{@config.source_path}],
                             out: io, err: io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
                                    "PATH" => fixture_path(@executor) })
  end

  def reset_platform
    teardown
    setup
  end

  # The real `Execution` behind the CLI, for driving one phase boundary at a time.
  def direct_execution(execution_policy)
    SpecrelayRunner::Execution.new(
      config: @config,
      client: SpecrelayRunner::PlatformClient.new(base_url: @platform.base_url, token: FakePlatform::EXPECTED_TOKEN),
      payload: claim_payload_for(task_id: TASK, root: @root).merge("execution_policy" => execution_policy),
      env: {}, io: StringIO.new
    )
  end

  # The `nth` protocol event this process sends fails in transport; every other one travels.
  def with_event_delivery_failing_on(nth)
    original = SpecrelayRunner::PlatformClient.instance_method(:submit_protocol_event)
    sent = 0
    mutex = Mutex.new
    SpecrelayRunner::PlatformClient.define_method(:submit_protocol_event) do |**arguments|
      raise SpecrelayRunner::PlatformClient::Error, "Platform is unreachable" if mutex.synchronize { (sent += 1) == nth }

      original.bind(self).call(**arguments)
    end
    yield
  ensure
    SpecrelayRunner::PlatformClient.define_method(:submit_protocol_event, original)
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
