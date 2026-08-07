# frozen_string_literal: true

require_relative "test_helper"

# MVP-0031 proof for the loop's idle presence session.
#
# Driven with an injected client, clock and sleeper, exactly as the MVP-0018 loop tests are:
# every property below is asserted deterministically, with no socket and no wall-clock wait.
# The one thing not faked is signal handling — the real SIGINT trap is installed and a real
# signal delivered, because the best-effort `stopped` on Ctrl-C is precisely the path an
# in-theory-only test would miss.
class LoopPresenceTest < Minitest::Test
  Loop = SpecrelayRunner::LoopRunner
  Presence = SpecrelayRunner::Presence

  # ---- the session lifecycle ----------------------------------------------

  def test_the_session_is_established_before_the_first_claim_poll
    order = []
    client = FakePresenceClient.new(on_call: ->(event) { order << event })
    run_loop(client: client, claim: -> { order << :claim; not_claimed }, max_iterations: 1)

    assert_equal %w[open started], order.first(2),
                 "presence must be established, in that order, before any claim is attempted"
    assert_includes order, :claim
  end

  # CR-001 F1. The runner ships no ordering logic of its own: it asks Platform for a place in
  # line and hands that exact value back. Anything derived on this machine — a clock, a
  # counter, a random id — is what the defect was.
  def test_the_start_presents_the_place_in_line_platform_issued
    client = FakePresenceClient.new
    run_loop(client: client, max_iterations: 1)

    opened = client.calls.find { |call| call[:event] == "open" }
    started = client.calls.find { |call| call[:event] == "started" }

    assert_nil opened[:session_id], "the opening call carries no session — it is the request for one"
    assert_nil opened[:session_seq]
    assert_equal 1, started[:session_seq]
    assert_equal "session-test-000001", started[:session_id]
  end

  # A loop whose Platform was unreachable at startup has no session to beat for. Beating anyway
  # would be answered `superseded` and would stop a perfectly healthy loop, so the establish is
  # retried instead.
  def test_a_session_that_could_not_be_established_is_retried_rather_than_heartbeated
    client = FakePresenceClient.new(fail_on: "open", fail_times: 1, heartbeat_seconds: 10)
    status = run_loop(client: client, poll_seconds: 60, max_iterations: 3)

    assert_equal Loop::OK, status, "an unreachable Platform at startup must not end the session"
    assert_equal 2, client.events.count("open"), "the handshake is retried"
    assert_includes client.events, "started"
    refute_operator client.events.index("heartbeat") || Float::INFINITY, :<,
                    client.events.index("started"),
                    "no beat may be sent for a session Platform never recorded"
  end

  def test_the_cadence_platform_advertises_drives_the_idle_heartbeat
    # Platform advertises 30s; the poll wait is 60s, so exactly one beat is due inside it.
    client = FakePresenceClient.new(heartbeat_seconds: 30)
    run_loop(client: client, poll_seconds: 60, max_iterations: 1)

    assert_equal 1, client.events.count("heartbeat"),
                 "one 30s beat is due inside a 60s wait — no more, no fewer"
  end

  def test_a_shorter_advertised_cadence_produces_proportionally_more_beats
    client = FakePresenceClient.new(heartbeat_seconds: 10)
    run_loop(client: client, poll_seconds: 60, max_iterations: 1)

    assert_equal 5, client.events.count("heartbeat")
  end

  def test_an_idle_loop_creates_no_claim_and_no_terminal_noise_per_beat
    client = FakePresenceClient.new(heartbeat_seconds: 10)
    run_loop(client: client, poll_seconds: 60, max_iterations: 1)

    refute_includes output, "presence", "a healthy beat is not a durable terminal event"
  end

  def test_presence_pauses_during_an_execution_and_resumes_immediately_afterwards
    client = FakePresenceClient.new(heartbeat_seconds: 10)
    during = nil
    execute = lambda do |_payload|
      # A real execution takes time, so the advertised cadence comes DUE while it runs. Advance
      # the clock past it and then ask presence for a beat — with the cadence gate satisfied,
      # the pause is the only thing left that can refuse, which is what makes this evidence
      # rather than an accident of timing.
      @clock.advance(3600)
      @presence.heartbeat_if_due
      during = client.events.dup
      true
    end
    # One claimed iteration, then one idle iteration so the loop reaches a wait.
    claims = [ claimed("DEMO-1"), not_claimed ]
    run_loop(client: client, claim: -> { claims.shift }, execute: execute,
             poll_seconds: 60, max_iterations: 2)

    assert_equal %w[open started], during, "no idle beat may be sent while a claim is executing"
    # The resume is a heartbeat on the SAME session, never a second `started`.
    assert_equal 1, client.events.count("started"), "a completed run must not open a new session"
    assert_operator client.events.count("heartbeat"), :>=, 1
  end

  def test_stopped_is_sent_on_a_normal_exit
    client = FakePresenceClient.new
    status = run_loop(client: client, max_iterations: 1)

    assert_equal "stopped", client.events.last
    assert_equal Loop::OK, status
  end

  def test_stopped_is_sent_when_the_operator_interrupts_while_idle
    client = FakePresenceClient.new
    signal_on_first_sleep!
    run_loop(client: client, install_signals: true, max_iterations: 5)

    assert_equal "stopped", client.events.last
    assert_includes output, "stopped by signal while IDLE"
  end

  def test_a_failing_goodbye_never_changes_the_sessions_real_result
    # An UNEXPECTED error, not a mapped transport failure: the mapped ones are already handled
    # inside `deliver`, so failing on one of those would prove nothing about the outer guard.
    client = FakePresenceClient.new(raise_on_stopped: RuntimeError.new("clipboard on fire"))
    status = run_loop(client: client, max_iterations: 1)

    assert_equal Loop::OK, status, "a best-effort stopped must not turn a good session into a failure"
  end

  def test_a_failed_run_still_reports_failure_even_though_presence_stopped_cleanly
    client = FakePresenceClient.new
    status = run_loop(client: client, claim: -> { claimed("DEMO-1") },
                      execute: ->(_p) { false }, max_iterations: 1)

    assert_equal Loop::FAILED, status
    assert_equal "stopped", client.events.last
  end

  # ---- permanent versus transient failure ---------------------------------

  def test_a_superseded_session_stops_the_loop_with_one_actionable_line
    client = FakePresenceClient.new(outcome: Presence::SUPERSEDED)
    status = run_loop(client: client, poll_seconds: 60, max_iterations: 5)

    assert_equal Loop::FAILED, status
    assert_includes output, "another loop session is now watching this workspace"
    assert_includes output, "remedy:"
    assert_equal 1, output.scan("another loop session").size, "the reason is stated once"
  end

  def test_a_rejected_credential_stops_the_loop_rather_than_spinning
    client = FakePresenceClient.new(raise_on_started: SpecrelayRunner::PlatformClient::Unauthorized.new(
      "Platform rejected the runner token (401)", status: 401
    ))
    status = run_loop(client: client, max_iterations: 5)

    assert_equal Loop::FAILED, status
    assert_includes output, "Platform rejected this runner's credential"
    assert_includes output, "specrelay-runner connect"
  end

  def test_a_transient_outage_keeps_the_loop_alive_and_is_reported_once
    client = FakePresenceClient.new(fail_on: "heartbeat", heartbeat_seconds: 10)
    status = run_loop(client: client, poll_seconds: 60, max_iterations: 2)

    assert_equal Loop::OK, status, "an unreachable Platform must not end the session"
    assert_equal 1, output.scan("presence paused").size,
                 "a presence retry must not print a line every interval"
  end

  def test_recovery_after_an_outage_is_recorded_once
    client = FakePresenceClient.new(fail_on: "heartbeat", fail_times: 1, heartbeat_seconds: 10)
    run_loop(client: client, poll_seconds: 60, max_iterations: 2)

    assert_includes output, "presence resumed"
    assert_equal 1, output.scan("presence resumed").size
  end

  # ---- what presence is NOT ------------------------------------------------

  def test_a_loop_without_a_workspace_connection_reports_no_presence_at_all
    # The advanced `--config` path has no connection record to attach a session to.
    refute_predicate Presence::NONE, :enabled?
    assert_predicate Presence::NONE.started, :ok?
  end

  def test_a_session_id_satisfies_the_bounded_shape_platform_accepts
    assert_match(/\A[A-Za-z0-9_-]{8,64}\z/, Presence.session_id)
    refute_equal Presence.session_id, Presence.session_id, "each loop process gets its own session"
  end

  private

  attr_reader :output

  def run_loop(client:, claim: -> { not_claimed }, execute: ->(_p) { true }, poll_seconds: 60,
               max_iterations: 1, install_signals: false)
    @io = StringIO.new
    @clock = FakeClock.new
    @presence = Presence.new(client: client, workspace_key: "tiny-demo-workspace",
                             interval_seconds: poll_seconds, session_id: "session-test-000001",
                             clock: @clock, on_notice: ->(message) { @io.puts "[loop] #{message}" })
    status = Loop.call(out: @io, err: @io, claim: claim, execute: execute, poll_seconds: poll_seconds,
                       install_signals: install_signals, max_iterations: max_iterations,
                       sleeper: sleeper, clock: @clock, presence: @presence)
    @output = @io.string
    status
  end

  # Advances the injected monotonic clock rather than sleeping, so the presence cadence is
  # driven by real elapsed-time arithmetic at no wall-clock cost.
  def sleeper
    lambda do |slice|
      @clock.advance(slice)
      pending = @pending_signal
      @pending_signal = nil
      pending&.call
      nil
    end
  end

  def signal_on_first_sleep!
    @pending_signal = -> { Process.kill("INT", Process.pid) }
  end

  class FakeClock
    def initialize = @now = 5_000.0
    def advance(seconds) = @now += seconds.to_f
    def clock_gettime(_id) = @now
  end

  # Records every presence call and answers exactly as Platform does, including the place in
  # line an `open` hands back (CR-001 F1).
  class FakePresenceClient
    attr_reader :events, :calls

    def initialize(outcome: SpecrelayRunner::Presence::ACCEPTED, heartbeat_seconds: 30,
                   fail_on: nil, fail_times: Float::INFINITY, raise_on_started: nil,
                   raise_on_stopped: nil, on_call: nil)
      @events = []
      @calls = []
      @outcome = outcome
      @heartbeat_seconds = heartbeat_seconds
      @fail_on = fail_on
      @fail_times = fail_times
      @failures = 0
      @issued = 0
      @raise_on_started = raise_on_started
      @raise_on_stopped = raise_on_stopped
      @on_call = on_call
    end

    def report_presence(workspace_key:, event:, session_id: nil, session_seq: nil)
      @events << event
      @calls << { event: event, session_id: session_id, session_seq: session_seq }
      @on_call&.call(event)
      raise @raise_on_started if @raise_on_started && event == SpecrelayRunner::Presence::STARTED
      raise @raise_on_stopped if @raise_on_stopped && event == SpecrelayRunner::Presence::STOPPED

      if event == @fail_on && @failures < @fail_times
        @failures += 1
        raise SpecrelayRunner::PlatformClient::Error, "could not reach Platform at http://127.0.0.1:3200"
      end

      { "contract_version" => "mvp-0031", "presence" => presence_body(workspace_key, event) }
    end

    private

    # Platform never answers `superseded` to an opening call — that call only allocates a place
    # in line. Ordering is decided when the `started` presenting it arrives.
    def presence_body(workspace_key, event)
      body = { "outcome" => @outcome, "workspace_key" => workspace_key,
               "heartbeat_seconds" => @heartbeat_seconds, "recent_for_seconds" => 90 }
      return body unless event == SpecrelayRunner::Presence::OPEN

      body.merge("outcome" => SpecrelayRunner::Presence::ACCEPTED, "session_seq" => (@issued += 1))
    end
  end

  def not_claimed(reason = "nothing eligible")
    SpecrelayRunner::PlatformClient::ClaimResult.new(claimed: false, payload: { "reason" => reason })
  end

  def claimed(task_id)
    SpecrelayRunner::PlatformClient::ClaimResult.new(
      claimed: true, payload: { "run" => { "id" => "run_#{task_id}", "task_id" => task_id } }
    )
  end
end
