# frozen_string_literal: true

require "securerandom"

module SpecrelayRunner
  # This terminal's admitted session.
  #
  # Platform admits each `loop` or `claim-once` terminal of a registration against that
  # registration's stored maximum. `started` is the request for admission, sent before the provider
  # probe, the preview connector and the first claim; every claim then names this session. While
  # the loop is idle it keeps the session current; its whole job is to be HONEST about idleness:
  #
  #   - heartbeats are sent only while the loop owns NOTHING. During an execution they are PAUSED,
  #     because the run's own lease is the authority on a claimed run and keeps the session's slot;
  #   - the final `stopped` is BEST EFFORT. A terminal that failed to say goodbye is one Platform
  #     will age out on its own, so this must never turn a successful session into a failed one.
  #
  # Failure handling splits the way the rest of the runner splits it. A transport failure is
  # transient: back off and keep going, and let Platform's window decide. A 401, a `superseded`
  # answer or a `full` start is PERMANENT — a rotated credential, a session Platform no longer
  # holds and a registration with no free slot all mean this process will not work, and a terminal
  # silently spinning on that is worse than one that stops and says why.
  class Presence
    STARTED = "started"
    HEARTBEAT = "heartbeat"
    STOPPED = "stopped"

    # Platform's answers. Only an explicit ACCEPTED lets this terminal continue: an unknown, missing
    # or malformed answer admits nothing.
    ACCEPTED = "accepted"
    SUPERSEDED = "superseded"
    FULL = "full"

    # What the terminal must do next.
    OK = :ok
    # Permanent: stop the session and tell the operator why.
    STOP = :stop
    # Transient: Platform is unreachable.
    TRANSIENT = :transient

    # Bounded backoff for a presence outage, so a long network failure retries at a sane
    # cadence rather than once per slice.
    MAX_BACKOFF_SECONDS = 300
    BACKOFF_FACTOR = 2

    Outcome = Struct.new(:status, :message, :remedy, keyword_init: true) do
      def ok? = status == OK
      def stop? = status == STOP
    end

    # A development-token invocation identifies no registration, so Platform has nothing to admit it
    # against and it reports no session. A null object rather than a nil check at every call site.
    class Disabled
      def started = Outcome.new(status: OK)
      def heartbeat_if_due(_now = nil) = Outcome.new(status: OK)
      def pause = nil
      def resume = Outcome.new(status: OK)
      def stopped = nil
      def enabled? = false
      def session_id = nil
    end

    NONE = Disabled.new

    def self.session_id = SecureRandom.hex(16)

    attr_reader :session_id

    # `workspace_key` names the saved connection this terminal selected; a hand-written config has
    # none. `interval_seconds` is a FALLBACK only: the cadence is Platform's decision and arrives in
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

    # Admission. Repeating it once admitted asks nothing more of Platform: the session is the same.
    def started = @established ? Outcome.new(status: OK) : establish

    # Called from the poll wait. Does nothing until the advertised cadence is due, so the wait
    # loop can call it on every slice without generating a request per slice.
    def heartbeat_if_due(now = monotonic)
      return Outcome.new(status: OK) if @paused
      return Outcome.new(status: OK) if @next_due && now < @next_due

      @established ? deliver(HEARTBEAT) : establish
    end

    # A claim is starting. Heartbeats stop until the attempt reaches a terminal result: while the run
    # is executing, its lease is the authoritative liveness signal and keeps this session's slot.
    def pause
      @paused = true
      nil
    end

    # The attempt finished. Signal immediately rather than waiting for the next cadence tick, so the
    # session is current again as soon as it is true — and as the SAME session.
    def resume
      @paused = false
      @next_due = nil
      @established ? deliver(HEARTBEAT) : establish
    end

    # Best effort, by contract. Every failure is swallowed: the session's real result has already
    # been decided by the work it did, and a failed goodbye must not change it. A session Platform
    # never admitted has nothing to say goodbye about, and one already stopped says it once.
    def stopped
      return nil unless @established

      @established = false
      deliver(STOPPED)
      nil
    rescue StandardError
      nil
    end

    private

    attr_reader :client, :workspace_key, :interval_seconds, :clock

    def establish
      admitted = deliver(STARTED)
      @established = admitted.ok?
      admitted
    end

    def deliver(event)
      body = client.report_presence(event: event, session_id: session_id,
                                    workspace_key: (workspace_key if event == STARTED))
      recovered
      outcome_for(body)
    rescue PlatformClient::Unauthorized => e
      Outcome.new(status: STOP, message: "Platform rejected this runner's credential " \
                                         "(#{Redaction.redact(e.message)})",
                  remedy: "Reconnect this machine: specrelay-runner connect <enrollment-code>")
    rescue PlatformClient::Error => e
      transient(e)
    end

    def outcome_for(body)
      presence = body.is_a?(Hash) && body["presence"].is_a?(Hash) ? body["presence"] : {}
      schedule_next(advertised_interval(presence))
      case presence["outcome"]
      when ACCEPTED then Outcome.new(status: OK)
      when FULL then full(presence)
      when SUPERSEDED
        Outcome.new(status: STOP, message: "Platform no longer holds this terminal's session",
                    remedy: "Start this runner again to be admitted afresh.")
      else
        Outcome.new(status: STOP, message: "Platform's presence answer did not admit this terminal",
                    remedy: "Update this runner or Platform so both speak the same presence contract.")
      end
    end

    # The count and maximum are Platform's own numbers; the operator can act on either.
    def full(presence)
      Outcome.new(status: STOP,
                  message: "this runner already has #{presence['active_sessions'].to_i} of " \
                           "#{presence['maximum_sessions'].to_i} sessions running",
                  remedy: "Stop one of its other terminals, then start this one again.")
    end

    # Platform's advertised cadence, falling back to the poll interval when a response does not
    # carry one. The fallback is the loop's own bounded wait, never a second hardcoded copy of
    # Platform's window.
    def advertised_interval(presence)
      advertised = presence["heartbeat_seconds"].to_f
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
      message = "presence paused — #{Redaction.redact(error.message)}"
      notice message
      Outcome.new(status: TRANSIENT, message: message)
    end

    def recovered
      return if @consecutive_errors.zero?

      @consecutive_errors = 0
      notice "presence resumed — Platform accepted this terminal's signal again"
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
