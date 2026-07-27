# frozen_string_literal: true

module SpecrelayRunner
  # MVP-0018 — the long-running mode a connected personal runner is left in.
  #
  # `claim-once` is a controlled single shot, which is right for a manual test and
  # wrong for daily use: it means running a command every time a Jira ticket
  # becomes ready. This polls for eligible work at a bounded interval and claims it
  # when it appears.
  #
  # The safety properties are structural rather than defensive:
  #
  #   - ONE RUN AT A TIME falls out of the design. The loop body is synchronous:
  #     `Execution#call` must return before the next poll is even attempted, so
  #     there is no code path that can start a second executor.
  #   - A FAILED RUN IS NEVER IDLE. The failure has already travelled the normal
  #     terminal-result/report contract by the time `execute` returns; this records
  #     it, says so on the terminal, and exits non-zero at the end of the session
  #     even if it kept polling afterwards.
  #   - AN EXPECTED FAILURE KEEPS THE RUNNER ALIVE, an unexpected one does not. A
  #     transport error (Platform restarting, laptop off the network) backs off and
  #     retries. A `401` does NOT: a revoked or rotated credential will never start
  #     working by being retried, and a machine silently spinning on it is worse
  #     than one that stops and says why.
  #
  # Everything about the CLAIM is still Platform's decision. This adds no
  # eligibility logic; it only asks more than once.
  #
  # Foreground only, deliberately (see the spec's non-goals): no LaunchAgent, no
  # daemonization, no supervisor. The status output is shaped so that a future
  # supervisor could read it, but nothing here assumes one.
  class LoopRunner
    # Exponential backoff after a nonfatal polling failure, capped so a long
    # outage still retries at a sane cadence instead of drifting to hours.
    MAX_BACKOFF_SECONDS = 300
    BACKOFF_FACTOR = 2

    # Sleep is served in slices so SIGINT is observed promptly instead of after a
    # full poll interval.
    SLICE_SECONDS = 0.25

    ON_FAILURE_CONTINUE = "continue"
    ON_FAILURE_STOP = "stop"
    FAILURE_POLICIES = [ ON_FAILURE_CONTINUE, ON_FAILURE_STOP ].freeze

    # The session result, mapped to an exit code by the CLI. Returning a symbol
    # rather than an integer keeps this class independent of CLI's exit codes.
    OK = :ok
    FAILED = :failed

    def self.call(**kwargs) = new(**kwargs).call

    # `claim` and `execute` are injected so this class owns the LOOP and nothing
    # else: resolving a connection, building a client, and running one claim stay
    # in the CLI, and a test can drive the loop without a process or a socket.
    #
    #   claim   -> PlatformClient::ClaimResult
    #   execute -> truthy when the claimed run succeeded
    def initialize(out:, err:, claim:, execute:, poll_seconds:, on_failure: ON_FAILURE_CONTINUE,
                   install_signals: true, max_iterations: nil, sleeper: nil)
      @out = out
      @err = err
      @claim = claim
      @execute = execute
      @poll_seconds = poll_seconds
      @on_failure = on_failure
      @install_signals = install_signals
      @max_iterations = max_iterations
      @sleeper = sleeper || ->(seconds) { sleep seconds }
      @stop_requested = false
      @stopped_during_execution = false
      @failures = 0
      @consecutive_errors = 0
      @executed = 0
      @previous_traps = {}
    end

    def call
      trap_signals
      announce_start
      status = poll_loop
      announce_stop
      status
    ensure
      restore_signals
    end

    private

    attr_reader :out, :err, :claim, :execute, :poll_seconds, :on_failure, :max_iterations, :sleeper

    def poll_loop
      iterations = 0
      until stop?(iterations)
        iterations += 1
        break unless one_iteration == :continue
      end
      @failures.positive? ? FAILED : OK
    end

    def stop?(iterations)
      return true if @stop_requested

      !max_iterations.nil? && iterations >= max_iterations
    end

    # One poll. Returns :continue to keep looping or :stop to end the session.
    def one_iteration
      status "waiting — polling Platform for eligible work"
      result = claim.call
      @consecutive_errors = 0
      result.claimed? ? run_claimed(result.payload) : idle(result)
    rescue PlatformClient::Unauthorized => e
      fatal("this runner's credential was rejected by Platform (#{Redaction.redact(e.message)})",
            "Reconnect this machine: specrelay-runner connect <enrollment-code>")
    rescue PlatformClient::Error => e
      back_off(e)
    end

    def idle(result)
      status "idle — #{idle_reason(result)}"
      pause(poll_seconds, "next poll")
    end

    # Platform's own explanation, so an unconnected runner is told that rather than
    # being left to read "nothing eligible" as a healthy idle.
    def idle_reason(result)
      reason = Redaction.redact(result.reason.to_s).strip
      reason.empty? ? "no eligible work (Platform authorized no run for this runner)" : reason
    end

    # A claimed run executes to completion before the loop polls again. The next
    # poll happens immediately rather than after the interval, because a queue of
    # ready tickets should drain without an artificial wait.
    def run_claimed(payload)
      status "executing — claimed #{payload.dig('run', 'task_id')} (#{payload.dig('run', 'id')})"
      succeeded = execute.call(payload)
      # Remembered separately from @stop_requested: an operator who interrupts
      # DURING an execution needs to be told the run finished reporting first, which
      # is a materially different situation from an interrupt while idle.
      @stopped_during_execution ||= @stop_requested
      @executed += 1
      succeeded ? run_succeeded : run_failed
    end

    def run_succeeded
      status "run completed — polling again immediately"
      :continue
    end

    # The failure has already been reported to Platform through the terminal-result
    # contract by this point. What matters here is that the loop never presents it
    # as a quiet idle, and that the session's exit code remembers it.
    def run_failed
      @failures += 1
      status "run FAILED — the failure was reported to Platform through the terminal-result contract"
      unless continue_on_failure?
        status "stopping after a failed run (--on-failure #{ON_FAILURE_STOP})"
        return :stop
      end

      status "continuing to poll (--on-failure #{ON_FAILURE_CONTINUE})"
      :continue
    end

    def continue_on_failure? = on_failure.to_s != ON_FAILURE_STOP

    def back_off(error)
      @consecutive_errors += 1
      seconds = backoff_seconds
      status "polling failed — #{Redaction.redact(error.message)}"
      pause(seconds, "retry ##{@consecutive_errors}")
    end

    def backoff_seconds
      raw = poll_seconds * (BACKOFF_FACTOR**(@consecutive_errors - 1))
      [ raw, MAX_BACKOFF_SECONDS ].min
    end

    def fatal(reason, remedy)
      @failures += 1
      out.flush if out.respond_to?(:flush)
      err.puts "[loop] stopping — #{reason}"
      err.puts "[loop] remedy: #{remedy}"
      :stop
    end

    # Sleeps in slices so a signal is noticed promptly. Returns :stop when the
    # operator interrupted mid-wait, so the caller does not poll one more time.
    def pause(seconds, label)
      status "sleeping #{format_seconds(seconds)} until #{label}"
      remaining = seconds.to_f
      while remaining > 0
        return :stop if @stop_requested

        sleeper.call([ remaining, SLICE_SECONDS ].min)
        remaining -= SLICE_SECONDS
      end
      @stop_requested ? :stop : :continue
    end

    def format_seconds(seconds) = seconds == seconds.to_i ? "#{seconds.to_i}s" : format("%.1fs", seconds)

    # Only an assignment happens in the handler — nothing that allocates, logs, or
    # takes a lock, because a trap can interrupt any of those mid-operation. The
    # loop prints and unwinds on the main thread.
    def trap_signals
      return unless @install_signals

      %w[INT TERM].each { |name| @previous_traps[name] = Signal.trap(name) { @stop_requested = true } }
    end

    def restore_signals
      @previous_traps.each { |name, handler| Signal.trap(name, handler || "DEFAULT") }
      @previous_traps.clear
    end

    # Flushed, because Ruby block-buffers a non-terminal stdout: a loop whose output
    # is redirected to a log file would otherwise show nothing until it exited, and
    # "is it alive?" is the exact question this status line exists to answer.
    def status(message)
      out.puts "[loop] #{message}"
      out.flush if out.respond_to?(:flush)
    end

    def announce_start
      status "started — polling every #{poll_seconds}s, one run at a time, --on-failure #{on_failure}"
      status "press Ctrl-C to stop; an in-progress execution finishes its report first"
    end

    # Names what the runner was doing when it stopped, so an operator who hits
    # Ctrl-C knows whether a run is mid-flight.
    def announce_stop
      status(stop_description)
      status "session totals — #{@executed} run(s) executed, #{@failures} failed"
    end

    def stop_description
      return "stopped — no further iterations requested" unless @stop_requested
      if @stopped_during_execution
        return "stopped by signal DURING an execution — the run finished and reported its result first"
      end

      "stopped by signal while IDLE — no execution was in progress and nothing was claimed"
    end
  end
end
