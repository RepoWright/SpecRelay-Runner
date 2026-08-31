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
