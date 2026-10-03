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

    assert_equal "started", order.first, "the session must be admitted before any claim is attempted"
    assert_includes order, :claim
  end

  # The start names this terminal's session and the workspace it selected; every later signal names
  # the session alone, because Platform already knows which grant it selected.
  def test_the_start_names_the_session_and_its_workspace_and_later_signals_the_session_only
    client = FakePresenceClient.new(heartbeat_seconds: 10)
    run_loop(client: client, poll_seconds: 60, max_iterations: 1)

    started, *later = client.calls
    assert_equal [ "started", "session-test-000001", "tiny-demo-workspace" ],
                 started.values_at(:event, :session_id, :workspace_key)
    refute_empty later
    later.each do |call|
      assert_equal [ "session-test-000001", nil ], call.values_at(:session_id, :workspace_key), call[:event]
    end
  end

  # An uncertain start is not an admission. A loop whose Platform was unreachable at startup holds
  # no slot, so it stops before any claim rather than polling without one.
  def test_a_session_that_could_not_be_admitted_does_no_work
    claims = 0
    client = FakePresenceClient.new(fail_on: "started", fail_times: 1)
    status = run_loop(client: client, claim: -> { claims += 1; not_claimed }, max_iterations: 3)

    assert_equal Loop::FAILED, status
    assert_equal 0, claims
    assert_includes output, "presence paused"
  end

  # A start the registration has no room for is permanent for this invocation and names Platform's
  # own count and maximum.
  def test_a_full_registration_stops_the_loop_before_any_claim
    claims = 0
    client = FakePresenceClient.new(outcome: Presence::FULL)
    status = run_loop(client: client, claim: -> { claims += 1; not_claimed }, max_iterations: 3)

    assert_equal Loop::FAILED, status
    assert_equal 0, claims
    assert_includes output, "this runner already has 2 of 2 sessions running"
  end

  def test_an_admitted_session_is_not_admitted_twice
    client = FakePresenceClient.new
    presence = Presence.new(client: client, workspace_key: "tiny-demo-workspace", interval_seconds: 10,
                            session_id: "session-test-000001", clock: FakeClock.new)

    2.times { assert_predicate presence.started, :ok? }

    assert_equal [ "started" ], client.events
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

    assert_equal %w[started], during, "no idle beat may be sent while a claim is executing"
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
    assert_includes output, "Platform no longer holds this terminal's session"
    assert_includes output, "remedy:"
    assert_equal 1, output.scan("no longer holds").size, "the reason is stated once"
  end

  # The ending this terminal chose for itself is not the operator's interrupt. Describing it as
  # one sends an operator looking for a key nobody pressed, and tells them nothing was claimed
  # in a session that never got as far as claiming for a different reason entirely.
  def test_a_superseded_session_is_not_described_as_an_operator_signal
    client = FakePresenceClient.new(outcome: Presence::SUPERSEDED)
    run_loop(client: client, poll_seconds: 60, max_iterations: 5)

    refute_includes output, "stopped by signal"
    refute_includes output, "nothing was claimed"
  end

  # The same lost session, discovered when presence resumes after a run rather than at admission.
  # One cause must not produce two different endings depending on when it was noticed.
  def test_a_session_superseded_during_a_run_is_not_described_as_an_operator_signal
    client = FakePresenceClient.new
    execute = lambda do |_payload|
      client.outcome = Presence::SUPERSEDED
      true
    end
    status = run_loop(client: client, claim: -> { claimed("DEMO-1") }, execute: execute,
                      max_iterations: 5)

    assert_equal Loop::FAILED, status
    assert_includes output, "Platform no longer holds this terminal's session"
    refute_includes output, "stopped by signal"
    refute_includes output, "no further iterations requested"
    refute_includes output, "as requested"
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

  def test_a_development_token_invocation_reports_no_session_at_all
    # The development token identifies no registration, so there is nothing to admit it against.
    refute_predicate Presence::NONE, :enabled?
    assert_predicate Presence::NONE.started, :ok?
    assert_nil Presence::NONE.session_id
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
    # Settable, so a test can supersede a session Platform admitted — which is what actually
    # happens — rather than only one it refused from the start.
    attr_writer :outcome

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
      @raise_on_started = raise_on_started
      @raise_on_stopped = raise_on_stopped
      @on_call = on_call
    end

    def report_presence(event:, session_id:, workspace_key: nil)
      @events << event
      @calls << { event: event, session_id: session_id, workspace_key: workspace_key }
      @on_call&.call(event)
      raise @raise_on_started if @raise_on_started && event == SpecrelayRunner::Presence::STARTED
      raise @raise_on_stopped if @raise_on_stopped && event == SpecrelayRunner::Presence::STOPPED

      if event == @fail_on && @failures < @fail_times
        @failures += 1
        raise SpecrelayRunner::PlatformClient::Error, "could not reach Platform at http://127.0.0.1:3200"
      end

      { "presence" => presence_body(event) }
    end

    private

    # Only a start can be answered `full`, and it carries Platform's count and maximum. Every
    # other answer is the scripted outcome.
    def presence_body(event)
      body = { "outcome" => @outcome, "heartbeat_seconds" => @heartbeat_seconds, "recent_for_seconds" => 90 }
      if @outcome == SpecrelayRunner::Presence::FULL
        return event == SpecrelayRunner::Presence::STARTED ? body.merge("active_sessions" => 2, "maximum_sessions" => 2) : body
      end

      event == SpecrelayRunner::Presence::STARTED ? body.merge("slot_number" => 1) : body
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
