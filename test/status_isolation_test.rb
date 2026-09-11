# frozen_string_literal: true

require_relative "test_helper"

# THE protected invariant of this delivery, asserted as behaviour rather than as a comment.
#
# The lease heartbeat and the idle presence signal both have deadlines Platform enforces: a
# late lease loses a claim mid-run, and a late presence beat drops a healthy machine to
# Offline. Status collection has no deadline at all and runs bounded provider commands that
# can take seconds — so the whole design rests on those commands never being on either path.
#
# A comment cannot prove that. What proves it is a status collector that BLOCKS, held open for
# the whole session, while the loop claims, executes, waits and exits on its original timing
# and with its original result.
class StatusIsolationTest < Minitest::Test
  # Long enough that any shared path would be unmistakable in the measured elapsed time, and
  # released in `ensure` so a failing assertion can never wedge the suite.
  BLOCK_SECONDS = 30

  # A reader whose every collection blocks until it is released. It is the stand-in for a
  # provider command that has hung: the reporter's own timeout would eventually end it, and the
  # point here is that the loop does not wait for either.
  class BlockingReader
    def initialize
      @gate = Queue.new
      @entered = Queue.new
    end

    # Blocks until `release` is called or the bound elapses.
    def capacity(now:) = block!
    def mcp_servers(now:) = block!
    def readiness(now:) = block!

    # Waits until the reporter really is inside a collection, so the test measures a loop
    # running BESIDE a stuck collector rather than one that happened to finish first.
    def wait_until_collecting = @entered.pop

    def release = @gate.close

    private

    def block!
      @entered << true
      @gate.pop
      nil
    end
  end

  # Records when each presence signal happened, so the cadence can be measured rather than
  # merely counted.
  class TimingPresence
    attr_reader :events

    def initialize
      @events = []
      @mutex = Mutex.new
    end

    def enabled? = true
    def started = record(:started)
    def heartbeat_if_due(_now = nil) = record(:heartbeat)
    def pause = record(:pause)
    def resume = record(:resume)
    def stopped = record(:stopped)

    private

    def record(event)
      @mutex.synchronize { @events << [ event, Process.clock_gettime(Process::CLOCK_MONOTONIC) ] }
      SpecrelayRunner::Presence::Outcome.new(status: SpecrelayRunner::Presence::OK)
    end
  end

  # Platform answers every status delivery, so nothing about the outcome depends on the
  # reporter failing — only on it being slow.
  class AcceptingClient
    def report_status(snapshot:) = {}
  end

  def test_a_hung_status_collector_never_delays_the_loop_its_presence_or_its_result
    reader = BlockingReader.new
    presence = TimingPresence.new
    reporter = SpecrelayRunner::StatusReporter.new(client: AcceptingClient.new, reader: reader)
    executed = []

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status = SpecrelayRunner::LoopRunner.call(
      out: StringIO.new, err: StringIO.new, poll_seconds: 0.05, install_signals: false,
      max_iterations: 3, sleeper: ->(seconds) { sleep(seconds) }, presence: presence,
      status_reporter: reporter,
      claim: lambda {
        # The collector is stuck from the first poll onward, so every claim, execution and
        # wait below happens WHILE it is stuck.
        reader.wait_until_collecting if executed.empty?
        SpecrelayRunner::PlatformClient::ClaimResult.new(claimed: true, payload: claim_payload)
      },
      execute: ->(_payload) { executed << Process.clock_gettime(Process::CLOCK_MONOTONIC); true }
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal SpecrelayRunner::LoopRunner::OK, status, "the session result must be unchanged"
    assert_equal 3, executed.length, "every iteration must have run"
    # The collector is still blocked at this point. A loop that shared a path with it could not
    # have finished three iterations in a fraction of the block.
    assert_operator elapsed, :<, BLOCK_SECONDS / 3.0,
                    "the session waited on the status collector"
    assert_includes presence.events.map(&:first), :started
    assert_includes presence.events.map(&:first), :stopped
  ensure
    reader&.release
  end

  # The lease is the other deadline, and it is renewed by a different object entirely. This
  # asserts the beater keeps its cadence while status is stuck — the case that would otherwise
  # lose a claim in the middle of a long run.
  def test_a_hung_status_collector_never_delays_the_lease_heartbeat
    reader = BlockingReader.new
    reporter = SpecrelayRunner::StatusReporter.new(client: AcceptingClient.new, reader: reader)
    reporter.start(executing: -> { true })
    reader.wait_until_collecting

    beats = []
    client = Class.new do
      def initialize(beats) = @beats = beats
      def heartbeat(claim:)
        @beats << Process.clock_gettime(Process::CLOCK_MONOTONIC)
        { "lease" => { "state" => "active", "cancel_requested" => false } }
      end
    end.new(beats)

    beater = SpecrelayRunner::Heartbeater.new(client: client, claim: "clm_test", interval_seconds: 1,
                                              io: StringIO.new).start
    sleep 2.5
    beater.stop

    assert_operator beats.length, :>=, 2, "the lease was not renewed while status was stuck"
    # Renewed on ITS cadence, not the status collector's: consecutive beats stay about a second
    # apart rather than drifting toward the blocked collection.
    beats.each_cons(2) { |first, second| assert_operator second - first, :<, 2.0 }
  ensure
    reader&.release
    reporter&.stop
  end

  # The session's exit is the third thing status may not hold up. `stop` is bounded, so a
  # collector that is still stuck costs a known fraction of a second and never the session.
  def test_stopping_a_reporter_mid_collection_is_bounded
    reader = BlockingReader.new
    reporter = SpecrelayRunner::StatusReporter.new(client: AcceptingClient.new, reader: reader)
    reporter.start(executing: -> { false })
    reader.wait_until_collecting

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    reporter.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<=, SpecrelayRunner::StatusReporter::STOP_JOIN_SECONDS + 0.5
  ensure
    reader&.release
  end

  private

  def claim_payload
    { "run" => { "id" => "run_test", "task_id" => "TASK-1" } }
  end
end
