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
  # longer live (expired / cancelled / terminal), records a stop reason. The
  # Execution polls that reason at safe boundaries and stops WITHOUT uploading a
  # success report.
  #
  # A `stop_after_seconds` control (non-secret, timing-only) deliberately CEASES
  # heartbeating after N seconds to reproduce the "runner crashed / lost the
  # network" case: the lease then lapses and Platform reclaims the run. It is the
  # deterministic stand-in for killing the process.
  class Heartbeater
    def initialize(client:, claim:, interval_seconds:, io:, stop_after_seconds: nil)
      @client = client
      @claim = claim
      @interval = [ interval_seconds.to_i, 1 ].max
      @io = io
      @stop_after_seconds = stop_after_seconds
      @mutex = Mutex.new
      @stop_reason = nil
      @should_stop = false
      @thread = nil
      @started_at = nil
    end

    def start
      @started_at = monotonic
      @thread = Thread.new { beat_loop }
      self
    end

    # The reason Platform told this runner to stop, or nil while the lease is live.
    def stop_reason
      @mutex.synchronize { @stop_reason }
    end

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

    def beat_once
      body = client.heartbeat(claim: claim)
      lease = body.is_a?(Hash) ? body["lease"].to_h : {}
      state = lease["state"].to_s
      cancel = lease["cancel_requested"]
      return if state == "active" && !cancel

      reason = cancel ? "cancelled" : (state.empty? ? "expired" : state)
      record_stop(reason)
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
