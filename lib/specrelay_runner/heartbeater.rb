# frozen_string_literal: true

module SpecrelayRunner
  # Keeps a claimed run's lease alive and OBSERVES Platform's liveness signal
  # (MVP-0012). While an execution is in progress this beats on the cadence
  # Platform advertises (`execution_policy.lease_renewal_seconds`), so the lease
  # is renewed several times per lease window and a healthy runner never loses its
  # claim mid-run.
  #
  # It never decides anything: Platform owns expiry and cancellation. The beater
  # only reads the returned `lease` signal and, when Platform says the claim is no
  # longer live (expired / cancelled / terminal) or refuses the heartbeat, records a stop reason. The
  # Execution polls that reason at safe boundaries and stops WITHOUT uploading a
  # success report.
  #
  # A `stop_after_seconds` control (non-secret, timing-only) deliberately CEASES
  # heartbeating after N seconds to reproduce the "runner crashed / lost the
  # network" case: the lease then lapses and Platform reclaims the run. It is the
  # deterministic stand-in for killing the process.
  #
  # A lane that runs a provider also passes `lease_seconds`, and then this object is the one
  # local answer to "may this claim still do work". Authority exists only inside a window that an
  # ACKNOWLEDGED renewal opens: Platform renewed at or after the instant the request was sent, so
  # the lease it granted lasts at least `lease_seconds` from that instant — measured on this
  # machine's monotonic clock, with no wall-clock comparison. The claim response itself is never
  # an anchor, because Platform granted that lease before an unbounded response delay. No window,
  # or a passed one, is a stop; so is anything Platform says that is not a live, renewed lease.
  # Other renewals Platform accepts (live-log events) are deliberately not counted: they can only
  # make this stop earlier, never later. Without `lease_seconds` nothing here changes.
  class Heartbeater
    # The stop a lane records when this machine can no longer show the claim is its own. Not
    # something Platform said, so a caller must not describe it as one.
    UNCONFIRMED = "renewal unconfirmed"

    # The stop recorded when Platform answered a heartbeat with a definitive refusal: anything but
    # a transport failure or a server error. Asking again cannot change that answer.
    REJECTED = "rejected"

    # Platform's documented default, for a claim that does not state its own.
    DEFAULT_LEASE_SECONDS = 180

    # The lease duration a claim's `execution_policy` advertises.
    def self.lease_seconds(execution_policy)
      execution_policy.to_h["lease_duration_seconds"].to_i.then { |n| n.positive? ? n : DEFAULT_LEASE_SECONDS }
    end

    def initialize(client:, claim:, interval_seconds:, io:, stop_after_seconds: nil, lease_seconds: nil)
      @client = client
      @claim = claim
      @interval = [ interval_seconds.to_i, 1 ].max
      @io = io
      @stop_after_seconds = stop_after_seconds
      @lease_seconds = lease_seconds
      @mutex = Mutex.new
      @stop_reason = nil
      @should_stop = false
      @renewed_until = nil
      @thread = nil
      @started_at = nil
    end

    def start
      @started_at = monotonic
      @thread = Thread.new { beat_loop }
      self
    end

    # Why this claim must stop, or nil while it may continue: what Platform said, or — for a lane
    # with a lease window — that no acknowledged renewal covers this instant. Evaluated on every
    # read, so a renewal request that is still blocked cannot postpone it, and recorded once, so
    # nothing that arrives later can clear it. It never writes output: the provider's stop check
    # reads it on the thread that must then end the process group, and the lane's aborted outcome
    # is where the operator is told why.
    def stop_reason
      @mutex.synchronize do
        if @stop_reason.nil? && window_closed?
          @stop_reason = UNCONFIRMED
          @should_stop = true
        end
        @stop_reason
      end
    end

    # One renewal now, on the caller's thread, read exactly as a background beat is: the lanes'
    # own phase-boundary heartbeats go through here so that there is one reading of what a
    # heartbeat response means. A transport failure or a server error reaches the caller; a refusal
    # is a recorded stop.
    def renew = beat_once

    # Ask the beater to stop and wait for the thread to finish.
    def stop
      @mutex.synchronize { @should_stop = true }
      @thread&.join
      @thread = nil
    end

    private

    attr_reader :client, :claim, :interval, :io, :stop_after_seconds

    def beat_loop
      loop do
        sleep_interval
        break if stopping?
        break if simulated_loss?

        begin
          beat_once
        rescue StandardError => e
          # One unreachable attempt costs ONE BEAT, not the thread. Renewing this
          # lease is this object's job alone, so an exception that ended the loop
          # would strand a live claim: nothing else renews it, and nothing else
          # records the stop reason callers wait on. The next tick retries on the
          # same cadence and renews as soon as Platform answers again.
          log("[heartbeat] transient error: #{Redaction.redact(e.message)}")
        end
      end
    end

    # Sleep the interval in short slices so `stop` is responsive.
    def sleep_interval
      slept = 0.0
      while slept < interval
        return if stopping?

        sleep(0.2)
        slept += 0.2
      end
    end

    # HTTP 200 alone is not renewal. Only `acknowledged: true` on a live lease opens or extends the
    # window; `acknowledged: false`, a lease that is not live or a refused heartbeat is a stop; a
    # transient failure is neither and reaches the caller.
    def beat_once
      sent_at = monotonic
      body = begin
        client.heartbeat(claim: claim)
      rescue PlatformClient::Error => e
        raise if e.transient?

        return record_stop(REJECTED)
      end
      body = {} unless body.is_a?(Hash)
      lease = body["lease"].to_h
      state = lease["state"].to_s
      cancel = lease["cancel_requested"]
      live = state == "active" && !cancel
      return confirm(sent_at) if live && body["acknowledged"] == true
      return unless !live || body["acknowledged"] == false

      record_stop(cancel ? "cancelled" : (live || state.empty? ? "expired" : state))
    end

    # Only ever moves the window forward, and never once a stop is recorded.
    def confirm(sent_at)
      return if @lease_seconds.nil?

      @mutex.synchronize do
        @renewed_until = [ @renewed_until, sent_at + @lease_seconds ].compact.max unless @stop_reason
      end
    end

    # Called under the mutex.
    def window_closed?
      return false if @lease_seconds.nil?

      @renewed_until.nil? || monotonic >= @renewed_until
    end

    def simulated_loss?
      return false if stop_after_seconds.nil?
      return false if monotonic - @started_at < stop_after_seconds.to_f

      log("[heartbeat] ceasing heartbeats after #{stop_after_seconds}s " \
          "(SPECRELAY_RUNNER_STOP_HEARTBEAT_AFTER_SECONDS) — the lease will now lapse")
      true
    end

    def record_stop(reason)
      @mutex.synchronize do
        @stop_reason ||= reason
        @should_stop = true
      end
      log("[heartbeat] Platform signalled the claim is no longer live (#{reason}); stopping.")
    end

    def stopping? = @mutex.synchronize { @should_stop }
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def log(message) = io.puts(Redaction.redact(message.to_s))
  end
end
