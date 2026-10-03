# frozen_string_literal: true

require_relative "test_helper"

# The beater renews the lease Platform owns, and it is the only thing in this runner that
# renews it on a cadence. So one unreachable attempt must cost ONE BEAT, not the thread: a
# network blip that ends the loop silently strands a live claim, because nothing else will
# ever renew it and nothing else records the stop reason the session waits on.
#
# Recovery is only half the boundary. A beater that survived by retrying as fast as it could
# would pass a liveness check and hammer Platform, so the cadence is asserted alongside the
# survival. Platform stays the only owner of expiry and cancellation.
class HeartbeaterTest < Minitest::Test
  ACTIVE = { "lease" => { "state" => "active", "cancel_requested" => false } }.freeze
  CANCELLED = { "lease" => { "state" => "active", "cancel_requested" => true } }.freeze
  EXPIRED = { "lease" => { "state" => "expired", "cancel_requested" => false } }.freeze

  # The beater sleeps its one-second interval in 0.2 s slices, so a real gap cannot fall
  # below one second. The floor is set below that to tolerate scheduler jitter while still
  # failing an immediate retry, which would show a gap near zero.
  CADENCE_FLOOR_SECONDS = 0.8

  # A synthetic transient failure with credential-shaped userinfo, so the redaction test has
  # something real to strip. The value is not a credential and never was one.
  SYNTHETIC_USERINFO_URL = "https://runner:synthetic-not-a-credential@platform.invalid/api/runner/heartbeat"

  # Answers each heartbeat from a script and repeats the last entry once the script runs out.
  # An Exception entry is RAISED rather than returned. Each attempt records its own monotonic
  # timestamp before the answer is given, so a failing attempt is observable too and a test
  # can measure the gap between attempts instead of sleeping a guessed amount.
  class ScriptedClient
    def initialize(*script)
      @script = script
      @attempts = []
      @mutex = Mutex.new
    end

    def attempts = @mutex.synchronize { @attempts.dup }

    def heartbeat(claim:)
      answer = @mutex.synchronize do
        @attempts << Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @script.length > 1 ? @script.shift : @script.first
      end
      raise answer if answer.is_a?(Exception)

      answer
    end
  end

  def setup
    @io = StringIO.new
    @threads_before = live_threads
    @beater = nil
  end

  def teardown
    @beater&.stop
  end

  def build(client, stop_after_seconds: nil)
    @beater = SpecrelayRunner::Heartbeater.new(
      client: client, claim: "rex_test", interval_seconds: 1, io: @io,
      stop_after_seconds: stop_after_seconds
    )
  end

  def test_a_transient_failure_costs_one_beat_and_the_beater_keeps_its_cadence
    client = ScriptedClient.new(timeout_error, ACTIVE)

    build(client).start
    wait_until("three heartbeat attempts") { client.attempts.length >= 3 }
    attempts = client.attempts
    @beater.stop

    assert_operator attempts.length, :>=, 3,
                    "the loop must still be beating after it recovered, not merely once more"
    assert_nil @beater.stop_reason, @io.string
    gaps = attempts.each_cons(2).map { |earlier, later| later - earlier }
    gaps.each_with_index do |gap, index|
      assert_operator gap, :>=, CADENCE_FLOOR_SECONDS,
                      "gap #{index + 1} was #{gap.round(3)}s — a recovered beater must wait for the " \
                      "existing cadence, not retry immediately (gaps: #{gaps.map { |g| g.round(3) }})"
    end
    assert_empty new_threads, "the beater must not leave a thread behind"
  end

  def test_a_cancelled_lease_after_a_transient_failure_records_the_reason_and_exits
    client = ScriptedClient.new(timeout_error, CANCELLED)

    build(client).start
    wait_until("the cancelled lease to be recorded") { @beater.stop_reason }

    assert_equal "cancelled", @beater.stop_reason
    @beater.stop
    assert_empty new_threads, "the beater must not leave a thread behind"
  end

  def test_an_expired_lease_after_a_transient_failure_records_the_reason
    client = ScriptedClient.new(timeout_error, EXPIRED)

    build(client).start
    wait_until("the expired lease to be recorded") { @beater.stop_reason }

    assert_equal "expired", @beater.stop_reason
  end

  def test_the_logged_transient_error_is_redacted
    client = ScriptedClient.new(timeout_error, ACTIVE)

    build(client).start
    wait_until("a heartbeat attempt after the transient failure") { client.attempts.length >= 2 }

    assert_includes @io.string, "[REDACTED]"
    refute_includes @io.string, "synthetic-not-a-credential"
  end

  def test_the_simulated_heartbeat_loss_still_ceases_beating
    client = ScriptedClient.new(ACTIVE)

    build(client, stop_after_seconds: 0).start
    wait_until("the simulated loss to be reported") { @io.string.include?("ceasing heartbeats") }

    assert_empty client.attempts, "a ceased beater must not renew the lease"
    assert_nil @beater.stop_reason, "a lapsed lease is Platform's call, not the runner's"
  end

  # ------------------------------------------------------------ authority window

  # What Platform answers when it renewed: an explicit acknowledgement on a live lease.
  RENEWED = { "acknowledged" => true, "lease" => { "state" => "active", "cancel_requested" => false } }.freeze

  # A heartbeat whose answer the test releases, so "a request is still in flight" is a state the
  # test holds rather than a race it hopes for. Every other call answers from the script.
  class HeldClient < ScriptedClient
    def initialize(*script)
      super
      @held = Queue.new
      @holding = false
    end

    def hold_next! = @mutex.synchronize { @holding = true }
    def release!(answer) = @held << answer
    def in_flight? = @mutex.synchronize { @in_flight }

    def heartbeat(claim:)
      held = @mutex.synchronize { @holding.tap { @holding = false } }
      return super unless held

      @mutex.synchronize { @in_flight = true }
      answer = @held.pop
      @mutex.synchronize { @in_flight = false }
      answer
    end
  end

  def build_with_window(client, lease_seconds:)
    @beater = SpecrelayRunner::Heartbeater.new(client: client, claim: "rex_test", interval_seconds: 1,
                                               io: @io, lease_seconds: lease_seconds)
  end

  # An output sink that blocks every write until the test releases it, and counts the writes.
  class BlockingSink
    def initialize
      @gate = Queue.new
      @writes = 0
      @mutex = Mutex.new
    end

    def writes = @mutex.synchronize { @writes }
    def release! = @gate << :open

    def puts(*)
      @mutex.synchronize { @writes += 1 }
      @gate.pop
    end
  end

  # The provider's stop check reads the stop reason on the thread that must then send TERM/KILL,
  # so the read may not wait on anything — not even a terminal that has stopped draining. The
  # operator copy for this stop belongs to the lane's aborted outcome, after the shutdown.
  def test_reading_an_elapsed_window_returns_at_once_without_writing_output
    sink = BlockingSink.new
    @beater = SpecrelayRunner::Heartbeater.new(client: ScriptedClient.new(RENEWED), claim: "rex_test",
                                               interval_seconds: 1, io: sink, lease_seconds: 60)

    reader = Thread.new { @beater.stop_reason }

    assert reader.join(0.5), "reading the stop reason did not return while output was blocked"
    assert_equal SpecrelayRunner::Heartbeater::UNCONFIRMED, reader.value
    assert_equal 0, sink.writes, "the stop reason read must not write output"
  ensure
    sink&.release!
    reader&.join(1)
  end

  # Platform granted the claim's lease before its response left, after an unbounded delay, so the
  # claim alone gives this machine no authority to start work: only an acknowledged renewal does.
  def test_a_claim_has_no_authority_until_a_renewal_is_acknowledged
    build_with_window(ScriptedClient.new(RENEWED), lease_seconds: 60)

    assert_equal SpecrelayRunner::Heartbeater::UNCONFIRMED, @beater.stop_reason
  end

  # The delayed claim response: by the time the first renewal reaches Platform the lease has
  # lapsed, and Platform declines to renew it.
  def test_a_renewal_platform_declines_is_a_stop_not_authority
    declined = { "acknowledged" => false, "lease" => { "state" => "expired", "cancel_requested" => false } }
    build_with_window(ScriptedClient.new(declined), lease_seconds: 60)

    @beater.renew

    assert_equal "expired", @beater.stop_reason
  end

  # HTTP 200 alone is not renewal: an answer that does not acknowledge the renewal stops the claim
  # even when the lease it describes still reads active, and a terminal lease stops it too.
  def test_an_unacknowledged_or_terminal_answer_is_a_stop
    unacknowledged = { "acknowledged" => false, "lease" => { "state" => "active", "cancel_requested" => false } }
    terminal = { "acknowledged" => false, "lease" => { "state" => "terminal", "cancel_requested" => false } }
    { unacknowledged => "expired", terminal => "terminal" }.each do |answer, reason|
      build_with_window(ScriptedClient.new(answer), lease_seconds: 60)
      @beater.renew

      assert_equal reason, @beater.stop_reason, answer.inspect
    end
  end

  # Transport failures inside a confirmed window cost nothing: the next acknowledged renewal
  # extends the window and the claim never stops.
  def test_transient_failures_inside_the_window_do_not_stop_the_claim
    client = ScriptedClient.new(RENEWED, timeout_error, timeout_error, RENEWED)
    build_with_window(client, lease_seconds: 4)
    @beater.renew
    @beater.start

    observed = []
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5.5
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      observed << @beater.stop_reason
      sleep 0.1
    end

    assert_operator client.attempts.length, :>=, 4, "the window must have been renewed after the failures"
    assert_equal [ nil ], observed.uniq, @io.string
  end

  # A renewal request that never returns cannot postpone the stop: the window is read on every
  # check, not when the beat thread next gets a chance.
  def test_a_blocked_renewal_request_cannot_postpone_the_stop
    client = HeldClient.new(RENEWED)
    build_with_window(client, lease_seconds: 2)
    @beater.renew
    client.hold_next!
    @beater.start

    wait_until("the window to close while a renewal is still in flight", timeout: 6) { @beater.stop_reason }

    assert client.in_flight?, "the renewal request must still be blocked when the claim stops"
    assert_equal SpecrelayRunner::Heartbeater::UNCONFIRMED, @beater.stop_reason
  ensure
    client&.release!(RENEWED)
  end

  # A stop is final: an acknowledgement that arrives after it was recorded — the late answer to the
  # request that was blocked — never revives the claim.
  def test_a_late_acknowledgement_never_revives_a_stopped_claim
    client = HeldClient.new(RENEWED)
    build_with_window(client, lease_seconds: 2)
    @beater.renew
    client.hold_next!
    @beater.start
    wait_until("the window to close", timeout: 6) { @beater.stop_reason }

    client.release!(RENEWED)
    wait_until("the late acknowledgement to be read") { !client.in_flight? }
    @beater.renew

    assert_equal SpecrelayRunner::Heartbeater::UNCONFIRMED, @beater.stop_reason
  end

  private

  def timeout_error = Net::OpenTimeout.new("execution expired connecting to #{SYNTHETIC_USERINFO_URL}")

  def live_threads = Thread.list.select(&:alive?)

  def new_threads = live_threads - @threads_before

  # Bounded wait on an observable condition, so a slow machine reports what it was waiting
  # for instead of hanging or passing by luck.
  def wait_until(what, timeout: 20)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk("timed out after #{timeout}s waiting for #{what}\n#{@io.string}") if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end
end
