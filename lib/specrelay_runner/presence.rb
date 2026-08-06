# frozen_string_literal: true

require "securerandom"

module SpecrelayRunner
  # MVP-0031 — the loop's idle presence session.
  #
  # `loop` polls, and between polls it is idle and silent. Platform therefore could not tell a
  # watching machine from one that was switched off an hour ago. This is the signal that closes
  # that gap, and its whole job is to be HONEST about idleness:
  #
  #   - it is sent only while the loop owns NOTHING. During an execution it is PAUSED, because
  #     the run's own heartbeat is the authority on a claimed run and a second liveness signal
  #     would let an idle watcher look like it owned work;
  #   - it authorizes nothing. Platform never consults it to decide a claim;
  #   - the final `stopped` is BEST EFFORT. A loop that failed to say goodbye is a machine
  #     Platform will age to Offline on its own, which is the correct answer anyway — so this
  #     must never turn a successful session into a failed one.
  #
  # Failure handling splits the way the rest of the runner splits it. A transport failure is
  # transient: back off, keep looping, and let Platform's presence window show Offline until the
  # network returns. A 401, or Platform answering `superseded`, is PERMANENT — a rotated
  # credential and a newer session both mean this process will never be current again, and a
  # machine silently spinning on that is worse than one that stops and says why.
  class Presence
    # A session is ESTABLISHED in two steps, because its order is Platform's to decide and no
    # clock on this machine may be trusted with it. `open` asks for this loop's place in line;
    # `started` then claims the connection with it, and Platform refuses a place in line it has
    # already passed. That is what stops a loop whose start was delayed — by a suspended
    # laptop or a dropped network — from displacing the machine that is watching right now.
    OPEN = "open"
    STARTED = "started"
    HEARTBEAT = "heartbeat"
    STOPPED = "stopped"

    # Platform's two answers. Only SUPERSEDED changes what this loop does, but both are named
    # because they are the wire contract this client speaks — a reader should not have to infer
    # the accepted case from its absence.
    ACCEPTED = "accepted"
    SUPERSEDED = "superseded"

    # What the loop must do next.
    OK = :ok
    # Permanent: stop the session and tell the operator why.
    STOP = :stop
    # Transient: Platform is unreachable. Keep looping; presence resumes on its own.
    TRANSIENT = :transient

    # Bounded backoff for a presence outage, so a long network failure retries at a sane
    # cadence rather than once per slice.
    MAX_BACKOFF_SECONDS = 300
    BACKOFF_FACTOR = 2

    Outcome = Struct.new(:status, :message, :remedy, keyword_init: true) do
      def ok? = status == OK
      def stop? = status == STOP
    end

    # A loop with no workspace connection — an advanced `--config` invocation — can address no
    # connection, so it reports no presence. A null object rather than a nil check at four call
    # sites in LoopRunner.
    class Disabled
      def started = Outcome.new(status: OK)
      def heartbeat_if_due(_now = nil) = Outcome.new(status: OK)
      def pause = nil
      def resume = Outcome.new(status: OK)
      def stopped = nil
      def enabled? = false
    end

    NONE = Disabled.new

    def self.session_id = SecureRandom.hex(16)

    # `interval_seconds` is a FALLBACK only. The cadence is Platform's decision and arrives in
    # every accepted response, so the runner does not ship its own copy of the policy.
    def initialize(client:, workspace_key:, interval_seconds:, session_id: self.class.session_id,
                   clock: Process, on_notice: nil)
      @client = client
      @workspace_key = workspace_key
      @session_id = session_id
      @interval_seconds = interval_seconds.to_f
      @clock = clock
      @on_notice = on_notice || ->(_message) { }
      @paused = false
      @next_due = nil
      @consecutive_errors = 0
      @last_notice = nil
      @established = false
    end

    def enabled? = true

    # Sent before the first claim poll, so Platform shows Watching from the moment the command
    # is running rather than from the first idle wait.
    def started = establish

    # Called from the poll wait. Does nothing until the advertised cadence is due, so the wait
    # loop can call it on every slice without generating a request per slice.
    #
    # A session that never got established — Platform was unreachable when the loop began —
    # is retried here rather than heartbeated. Beating for a session Platform never recorded
    # would be answered `superseded` and would stop a loop that is perfectly healthy.
    def heartbeat_if_due(now = monotonic)
      return Outcome.new(status: OK) if @paused
      return Outcome.new(status: OK) if @next_due && now < @next_due

      @established ? deliver(HEARTBEAT) : establish
    end

    # A claim is starting. Idle presence stops until the attempt reaches a terminal result:
    # while the run is executing, its lease heartbeat is the authoritative liveness signal.
    def pause
      @paused = true
      nil
    end

    # The attempt finished. Signal immediately rather than waiting for the next cadence tick,
    # so the row returns to Watching as soon as it is true — and as the SAME session, which is
    # what stops a completed run from creating a duplicate presence session.
    def resume
      @paused = false
      @next_due = nil
      @established ? deliver(HEARTBEAT) : establish
    end

    # Best effort, by contract. Every failure is swallowed: the session's real result has
    # already been decided by the work it did, and a failed goodbye must not change it. A
    # session Platform never recorded has nothing to say goodbye about.
    def stopped
      deliver(STOPPED) if @established
      nil
    rescue StandardError
      nil
    end

    private

    attr_reader :client, :workspace_key, :session_id, :interval_seconds, :clock

    # The two-step handshake. The opening call is the one that can be refused on ordering
    # grounds later, so nothing is considered established until Platform has accepted the
    # `started` that presents the sequence it issued.
    def establish
      opened = deliver(OPEN)
      return opened unless opened.ok?

      started = deliver(STARTED, session_seq: @session_seq)
      @established = started.ok?
      started
    end

    def deliver(event, session_seq: nil)
      body = client.report_presence(workspace_key: workspace_key, event: event,
                                    session_id: (session_id unless event == OPEN),
                                    session_seq: session_seq)
      @session_seq = body.dig("presence", "session_seq") if event == OPEN && body.is_a?(Hash)
      recovered
      outcome_for(body)
    rescue PlatformClient::Unauthorized => e
      Outcome.new(status: STOP, message: "Platform rejected this runner's credential " \
                                         "(#{Redaction.redact(e.message)})",
                  remedy: "Reconnect this machine: specrelay-runner connect <enrollment-code>")
    rescue PlatformClient::Error => e
      transient(e)
    end

    # Platform decided this session is no longer current — a newer loop took the connection
    # over, or this one already stopped. Either way this process is obsolete.
    def outcome_for(body)
      schedule_next(advertised_interval(body))
      return Outcome.new(status: OK) unless superseded?(body)

      Outcome.new(status: STOP,
                  message: "another loop session is now watching this workspace",
                  remedy: "Only one loop per workspace is needed; this one is no longer current.")
    end

    def superseded?(body) = body.is_a?(Hash) && body.dig("presence", "outcome") == SUPERSEDED

    # Platform's advertised cadence, falling back to the poll interval when a response does not
    # carry one. The fallback is the loop's own bounded wait, never a second hardcoded copy of
    # Platform's window.
    def advertised_interval(body)
      advertised = body.is_a?(Hash) ? body.dig("presence", "heartbeat_seconds").to_f : 0.0
      advertised.positive? ? advertised : interval_seconds
    end

    def schedule_next(seconds)
      @next_due = monotonic + seconds
    end

    # Reported ONCE per outage rather than per interval: a presence retry that printed a line
    # every 30 seconds would bury the run history it sits in.
    def transient(error)
      @consecutive_errors += 1
      schedule_next(backoff_seconds)
      notice "presence paused — #{Redaction.redact(error.message)}"
      Outcome.new(status: TRANSIENT)
    end

    def recovered
      return if @consecutive_errors.zero?

      @consecutive_errors = 0
      notice "presence resumed — Platform accepted this loop's signal again"
    end

    def backoff_seconds
      raw = interval_seconds * (BACKOFF_FACTOR**(@consecutive_errors - 1))
      [ raw, MAX_BACKOFF_SECONDS ].min
    end

    def notice(message)
      return if message == @last_notice

      @last_notice = message
      @on_notice.call(message)
    end

    def monotonic = clock.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
