# frozen_string_literal: true

require "json"

module SpecrelayRunner
  # The connected machine's independent status signal, and deliberately the LEAST important
  # thing this runner does.
  #
  # It is a sibling of {Presence} and {Heartbeater}, never a shape of either, and the
  # separation is the safety property rather than a tidiness preference. A lease heartbeat
  # keeps a claimed run alive and a presence beat says a loop is watching; both are on the
  # critical path and both have a deadline Platform enforces. This has neither. It describes
  # the machine's provider — how much capacity is left, which MCP servers answered, whether
  # the CLI is there — and nobody waits on the answer.
  #
  # So it runs on its OWN thread and touches nothing else. It cannot delay a claim, a lease, a
  # presence transition, an execution, a stream, a socket, a cleanup or an exit result, because
  # it shares no lock, no cadence and no failure path with any of them. The bounded provider
  # commands it runs are the slow part, and they are slow in here where nothing is waiting.
  #
  # WHAT FAILURE MEANS HERE. A section that cannot be collected is reported as `unavailable`
  # when this machine has never measured it, and as `stale` when it holds a real earlier
  # measurement it could no longer refresh. Neither is a cycle failure, and a cycle failure is
  # never a session failure: an unreachable Platform costs one report and nothing more. There
  # is no retry schedule, no backoff and no queue — the next tick is sixty seconds away and
  # re-sending a status nobody read is not worth a line of code.
  #
  # CADENCE IS FIXED. One report at start and one a minute after that, with each section under
  # its own collection ceiling, so a fleet of connected machines cannot turn status into a load
  # pattern and a five-minute fact is not measured sixty times an hour.
  class StatusReporter
    SNAPSHOT_VERSION = 1
    PROVIDER = "claude"

    # One report a minute, from the first one at start.
    REPORT_INTERVAL_SECONDS = 60
    # Per-section collection ceilings. Capacity moves with the report; the MCP inventory is a
    # five-minute fact; the local CLI facts are static.
    CAPACITY_INTERVAL_SECONDS = 60
    MCP_INTERVAL_SECONDS = 300

    # How often the thread wakes to see whether a report is due or a stop was asked for. Short
    # enough that `stop` is answered promptly, slow enough to cost nothing.
    TICK_SECONDS = 0.25

    FRESH = "fresh"
    STALE = "stale"
    UNAVAILABLE = "unavailable"

    # A loop with no workspace connection addresses no runner identity, so it reports no
    # status. A null object rather than a nil check at each call site in LoopRunner.
    class Disabled
      def start(executing: nil) = nil
      def stop = nil
      def report_if_due(_now = nil, executing: false) = false
      def enabled? = false
    end

    NONE = Disabled.new

    # One collected section: the value, the instant it was really measured at, and whether the
    # last attempt to refresh it succeeded. Carrying the original instant is what makes
    # "resending a value never renews its observation time" a property of the object rather
    # than a rule somebody has to remember at each call site.
    Section = Struct.new(:value, :observed_at, :refreshed, keyword_init: true) do
      def freshness
        return UNAVAILABLE if value.nil?

        refreshed ? FRESH : STALE
      end
    end

    EMPTY = Section.new(value: nil, observed_at: nil, refreshed: false).freeze

    def initialize(client:, reader:, on_notice: nil)
      @client = client
      @reader = reader
      @on_notice = on_notice || ->(_message) { }
      @sections = { capacity: EMPTY, mcp: EMPTY, readiness: EMPTY }
      @collected_at = {}
      @next_report_at = nil
      @should_stop = false
      @thread = nil
    end

    def enabled? = true

    # `executing` is a PREDICATE rather than a reference to the execution: this object must be
    # able to say whether the machine is working without holding anything that could let it
    # interfere with the work. It is supplied here rather than at construction because the loop
    # that owns the answer is also the thing that starts this thread.
    def start(executing:)
      @executing = executing
      @thread = Thread.new { report_loop }
      self
    end

    # Bounded, because this runs on the session's exit path and the exit result is one of the
    # things this object may never delay. The short join is a courtesy that lets a delivery
    # already in flight finish; a cycle stuck in a provider command is simply left, and the
    # process ends it. Nothing waits on a status report, so there is nothing to lose by it.
    STOP_JOIN_SECONDS = 1

    def stop
      @should_stop = true
      @thread&.join(STOP_JOIN_SECONDS)
      @thread = nil
    end

    # One cadence decision. Collects the sections that are due, delivers the snapshot, and
    # answers whether Platform accepted it. Public because it is the whole behaviour of this
    # class: the thread above only decides WHEN to call it, and every cadence test drives it
    # directly with an explicit instant rather than a clock.
    def report_if_due(now, executing: false)
      return false unless due?(now)

      @next_report_at = now + REPORT_INTERVAL_SECONDS
      collect(now)
      deliver(snapshot(now, executing))
    end

    private

    attr_reader :client, :reader

    def due?(now) = @next_report_at.nil? || now >= @next_report_at

    # The thread is a timer and nothing else. Asking the predicate here — rather than inside
    # the cycle — keeps the tested path free of a collaborator that can raise, and a loop whose
    # predicate failed must not lose its status signal over it.
    def report_loop
      until @should_stop
        report_if_due(Time.now.utc, executing: executing?)
        sleep TICK_SECONDS
      end
    end

    # Never as an exception: the predicate belongs to the loop, and a status cycle may not fail
    # on the loop's behalf.
    def executing?
      @executing&.call ? true : false
    rescue StandardError
      false
    end

    def collect(now)
      refresh(:capacity, now, CAPACITY_INTERVAL_SECONDS) { reader.capacity(now: now) }
      refresh(:mcp, now, MCP_INTERVAL_SECONDS) { reader.mcp_servers(now: now) }
      # Static local facts, collected once at start — and again only while they say the CLI is
      # absent, which is the one local change that can still turn into a different answer.
      refresh(:readiness, now, nil) { reader.readiness(now: now) } if readiness_due?
    end

    # Collect one section when its own ceiling allows, and record what came back. A nil result
    # and a raising collector are the SAME outcome: this machine measured nothing this time, so
    # whatever it already held is carried and marked no longer fresh.
    #
    # `rescue StandardError` is deliberate and is the narrowest correct choice here. A collector
    # reaches the local filesystem, the PATH and a child process, so the exceptions it can raise
    # are not a list this object can usefully enumerate — and every one of them means the same
    # thing to a signal nobody waits on.
    def refresh(name, now, interval)
      return unless collection_due?(name, now, interval)

      @collected_at[name] = now
      value = yield
      store(name, value, now)
    rescue StandardError
      store(name, nil, now)
    end

    def collection_due?(name, now, interval)
      last = @collected_at[name]
      return true if last.nil?

      !interval.nil? && now - last >= interval
    end

    def readiness_due? = @sections[:readiness].value.nil?

    # A fresh value replaces the stored one and carries the instant it was measured at. A
    # failure keeps the earlier value and its ORIGINAL instant, and only clears the fresh flag.
    def store(name, value, now)
      previous = @sections[name]
      @sections[name] =
        if value.nil?
          Section.new(value: previous.value, observed_at: previous.observed_at, refreshed: false)
        else
          Section.new(value: value, observed_at: instant(now), refreshed: true)
        end
    end

    # The closed v1 object. Every key here is one this product decided to publish; there is no
    # free-form block, no raw text, no configuration body and no path for an unknown field to
    # reach Platform, because the object is BUILT from a fixed shape rather than filtered into
    # one.
    #
    # No model and no effort appear at all. There is no documented local source that names
    # either exactly, and Platform already owns the assigned provider and profile — so
    # reporting a guess here would overwrite an authoritative fact with an invented one.
    def snapshot(now, executing)
      {
        "version" => SNAPSHOT_VERSION,
        "provider" => PROVIDER,
        "observed_at" => instant(now),
        "readiness" => section(:readiness) { |value| value },
        "capacity" => section(:capacity) { |value| value },
        "mcp" => section(:mcp) { |value| { "state" => "available", "servers" => value } },
        "execution" => { "observed_at" => instant(now), "freshness" => FRESH,
                         "active" => executing ? true : false }
      }
    end

    # One section, with its own observation time and freshness beside whatever it measured. An
    # unavailable section carries the state and the times and NO measurement: a zero or an
    # empty list standing in for data nobody sent is the untruth this object exists to avoid.
    def section(name)
      stored = @sections.fetch(name)
      head = { "observed_at" => stored.observed_at, "freshness" => stored.freshness }
      return head.merge("state" => UNAVAILABLE) if stored.value.nil?

      head.merge(yield(stored.value))
    end

    # Delivery is best effort BY CONTRACT. Platform being unreachable, restarting or refusing
    # the body all cost this one report; the next tick sends the current state again. Nothing
    # here may raise, because this thread's death would silently end status for the session.
    def deliver(snapshot)
      client.report_status(snapshot: snapshot)
      true
    rescue StandardError => e
      notice "status report not delivered — #{Redaction.redact(e.message)}"
      false
    end

    def instant(time) = time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

    # Reported once per outage rather than per cycle: a status retry printing a line a minute
    # would bury the run history it sits in.
    def notice(message)
      return if message == @last_notice

      @last_notice = message
      @on_notice.call(message)
    end
  end
end
