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
  # RUNNER-0001 changed what a healthy poll LOOKS LIKE, and nothing else. Waiting,
  # the countdown, and "nothing eligible" are now TRANSIENT: one reusable row that
  # replaces itself, so an afternoon of idling adds no terminal history. Everything
  # an operator would scroll back for — the claim, executor output, failures,
  # backoff, recovery, results, the session summary — stays DURABLE, and the
  # transient row is always erased before one is written. See TerminalPresenter.
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
    # full poll interval, and so the countdown row can be redrawn as it changes.
    SLICE_SECONDS = 0.25

    # How often the stop-acknowledgement watcher looks at the flag while an
    # execution is in progress. Short enough that Ctrl-C is answered immediately,
    # slow enough to cost nothing.
    STOP_NOTICE_SECONDS = 0.1

    ON_FAILURE_CONTINUE = "continue"
    ON_FAILURE_STOP = "stop"
    FAILURE_POLICIES = [ ON_FAILURE_CONTINUE, ON_FAILURE_STOP ].freeze

    # The session result, mapped to an exit code by the CLI. Returning a symbol
    # rather than an integer keeps this class independent of CLI's exit codes.
    OK = :ok
    FAILED = :failed

    # MAPIAI-107 — the one execution disposition `execute` may return in place of a Boolean: a
    # deterministic pre-provider refusal that ATTEMPTED to release its claim.
    #
    # It exists because "did the run succeed" cannot express it. An ordinary failed run has
    # already been reported, so the run is terminal and the next poll is about different work. A
    # pre-provider refusal leaves the run exactly as this machine found it, so the next poll
    # reaches the identical refusal — a spin no wait would fix and that the failure policy is the
    # wrong control for. The session records one actionable failure and ends instead.
    #
    # ATTEMPTED, not released (CR-001 F2). Whether Platform accepted the release is observable
    # only inside the execution, which reports it there; this session must stop either way, and
    # must not restate an outcome it cannot see.
    RELEASE_ATTEMPTED_REFUSAL = :release_attempted_refusal

    def self.call(**kwargs) = new(**kwargs).call

    # `claim` and `execute` are injected so this class owns the LOOP and nothing
    # else: resolving a connection, building a client, and running one claim stay
    # in the CLI, and a test can drive the loop without a process or a socket.
    #
    #   claim   -> PlatformClient::ClaimResult
    #   execute -> truthy when the claimed run succeeded, or RELEASE_ATTEMPTED_REFUSAL
    #
    # `presenter`, `clock`, and `sleeper` are the injection seams that make the
    # terminal behaviour testable: capability, time, and waiting are all explicit
    # dependencies rather than facts about the developer's machine.
    def initialize(out:, err:, claim:, execute:, poll_seconds:, on_failure: ON_FAILURE_CONTINUE,
                   install_signals: true, max_iterations: nil, sleeper: nil, presenter: nil,
                   clock: Process, label: nil, presence: Presence::NONE,
                   connector: PreviewConnector::NONE,
                   status_reporter: StatusReporter::NONE)
      @claim = claim
      @execute = execute
      @presence = presence
      @connector = connector
      @status_reporter = status_reporter
      @poll_seconds = poll_seconds
      @on_failure = on_failure
      @install_signals = install_signals
      @max_iterations = max_iterations
      @clock = clock
      @label = label.to_s
      # OWNERSHIP decides how the row is cleaned up. A loop that built its own presenter also
      # ends it; a loop handed one — every dashboard-launched loop, which shares the CLI's
      # single write boundary — only RELEASES the row, because the presenter outlives this
      # session and the operator can start another loop from the same menu.
      @owns_presenter = presenter.nil?
      @presenter = presenter || TerminalPresenter.for(out: out, err: err)
      @sleeper = sleeper || ->(seconds) { sleep seconds }
      @stop_requested = false
      @stopped_during_execution = false
      @unreported_failure = false
      @execution_active = false
      @failures = 0
      @consecutive_errors = 0
      @executed = 0
      @previous_traps = {}
    end

    def call
      trap_signals
      announce_start
      # Started here and never consulted again. It runs on its own thread with its own cadence,
      # so from this point the session cannot wait on it, be slowed by it, or fail because of
      # it — which is the whole reason status is not on the presence or lease path.
      status_reporter.start(executing: -> { @execution_active })
      status = session_status
      announce_stop
      status
    ensure
      # Stopped FIRST and under its own bound: it is the one collaborator here that nothing
      # waits on, so it must not be between the session and any of the endings below.
      status_reporter.stop
      # The connector is this session's own child, and this is the only place that runs on every
      # exit path — so it is stopped here rather than beside the start, and before the goodbye
      # that ends the session's presence.
      connector.stopped
      # MVP-0031: the best-effort goodbye, on EVERY exit path — a normal stop, Ctrl-C,
      # SIGTERM, a fatal credential rejection, or an exception on its way past. It cannot
      # change `status`, which has already been decided: a machine that failed to say goodbye
      # ages to Offline on its own, and that is the right answer anyway.
      presence.stopped
      # The row is erased here, on EVERY exit path — a normal stop, Ctrl-C,
      # SIGTERM, a fatal credential rejection, or an exception on its way past.
      @owns_presenter ? presenter.finish : presenter.clear_status
      restore_signals
    end

    private

    attr_reader :claim, :execute, :poll_seconds, :on_failure, :max_iterations, :sleeper, :presenter,
                :clock, :label, :presence, :connector, :status_reporter

    # The session's two preconditions, LOCAL before remote: a machine that cannot run its own
    # preview connector is told so before it asks Platform for anything, so it never holds work it
    # could not have published. Either refusal has already recorded one actionable failure.
    def session_status
      return FAILED if start_connector == :stop
      return FAILED if announce_presence == :stop

      poll_loop
    end

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
      # Asked once per poll, which makes this loop's own interval the connector's recovery
      # cadence: a child that has gone is reported and started again here, on the tick after it
      # went, rather than in a retry of its own.
      return :stop if keep_connector_running == :stop

      transient "checking for eligible work"
      result = claim.call
      note_recovery
      result.claimed? ? run_claimed(result.payload) : idle(result)
    rescue CleanupRequired => e
      # MAPIAI-97 — this machine still holds a task environment it could not release. Claiming
      # again would put the next run, or a preview of this same ticket, on top of it.
      fatal(Redaction.redact(e.message), "Release it by hand, then start this runner again.")
    rescue PlatformClient::Unauthorized => e
      fatal("this runner's credential was rejected by Platform (#{Redaction.redact(e.message)})",
            "Reconnect this machine: specrelay-runner connect <enrollment-code>")
    rescue PlatformClient::Error => e
      back_off(e)
    end

    # A healthy no-work answer is the thing this loop does most and the thing an
    # operator least needs a record of, so it stays on the transient row.
    #
    # With no row to put it on — a pipe, a log file, CI — the reason is printed
    # once, and again only when it CHANGES. It is not per-poll noise, and it is the
    # only place a redirected runner can say something an operator must act on
    # ("Platform authorized no run for this runner" is not the same answer as
    # "nothing is ready yet").
    def idle(result)
      reason = idle_reason(result)
      if reason != @last_idle_reason
        @last_idle_reason = reason
        line "idle — #{reason}" unless presenter.transient?
      end
      wait(poll_seconds, state: "no eligible work", until_label: "next check")
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
      line "executing — claimed #{payload.dig('run', 'task_id')} (#{payload.dig('run', 'id')})"
      # Idle presence stops for the duration of the attempt: from here the run's own lease
      # heartbeat is the authoritative liveness signal, and a second one would let a watcher
      # look like it owned the run rather than being the process executing it.
      presence.pause
      disposition = watching_for_stop { execute.call(payload) }
      # Remembered separately from @stop_requested: an operator who interrupts
      # DURING an execution needs to be told the run finished reporting first, which
      # is a materially different situation from an interrupt while idle.
      #
      # Read BEFORE presence resumes, because a superseded presence session also sets
      # @stop_requested — and reporting that as "interrupted by signal during an execution"
      # would describe something the operator did not do.
      @stopped_during_execution ||= @stop_requested
      resume_presence
      @executed += 1
      # Read before the Boolean, because neither is a degree of failure: each is an outcome whose
      # correct answer is to stop, whatever `--on-failure` says. Both symbols are truthy, so
      # reading them afterwards would report them as successful runs.
      return run_release_attempted_refusal if disposition == RELEASE_ATTEMPTED_REFUSAL
      return run_unreported_failure if disposition == FAILED

      disposition ? run_succeeded : run_failed
    end

    # Ctrl-C during a long execution has to be ACKNOWLEDGED while the run is still
    # finishing, or the operator has no way to tell a received signal from an
    # ignored one and presses it again. The signal handler cannot say so itself —
    # it may only set a flag — so one short-lived watcher does it from a normal
    # execution path, writing through the presenter's single write boundary.
    def watching_for_stop
      @execution_active = true
      watcher = Thread.new { acknowledge_stop_while_executing }
      yield
    ensure
      @execution_active = false
      watcher&.join
    end

    # A real `sleep`, deliberately not the injected `sleeper`: the sleeper is how the
    # POLL WAIT is made instant in a test, and using it here would turn this watcher
    # into a hot spin. It runs concurrently with the execution, so no test waits on it.
    def acknowledge_stop_while_executing
      sleep(STOP_NOTICE_SECONDS) while @execution_active && !@stop_requested
      return unless @stop_requested

      line "stop requested — nothing further will be claimed; the run in progress finishes " \
           "its report first"
    rescue StandardError
      # An acknowledgement is a courtesy. It must never take an execution down.
      nil
    end

    def run_succeeded
      line(@stop_requested ? "run completed — stopping as requested" : "run completed — polling again immediately")
      :continue
    end

    # The failure has already been reported to Platform through the terminal-result
    # contract by this point. What matters here is that the loop never presents it
    # as a quiet idle, and that the session's exit code remembers it.
    def run_failed
      @failures += 1
      line "run FAILED — the failure was reported to Platform through the terminal-result contract"
      unless continue_on_failure?
        line "stopping after a failed run (--on-failure #{ON_FAILURE_STOP})"
        return :stop
      end

      line "continuing to poll (--on-failure #{ON_FAILURE_CONTINUE})"
      :continue
    end

    # MAPIAI-107 — one actionable failure, and no second attempt at the same run from this
    # session. The failure policy is deliberately not consulted: `continue` means "a failed run
    # does not end the session", and this run has not failed in that sense — it was left exactly
    # as it was found, so continuing means doing the identical thing again.
    #
    # It says nothing about the claim (CR-001 F2). The execution has already printed whether
    # Platform released it or whether its lease must expire, and those are the two different
    # things an operator has to act on; a session-level line repeating either would be guessing,
    # and the one it used to guess contradicted the truthful line above it.
    def run_release_attempted_refusal
      @failures += 1
      line "run REFUSED before the provider — nothing was executed and nothing was published"
      line "stopping after a pre-provider refusal; polling again would only reach the same " \
           "refusal. Fix what the refusal names, then start this runner again."
      :stop
    end

    # A failed run whose result never reached Platform.
    #
    # {#run_failed} says the failure travelled the terminal-result contract. That is true of every
    # ordinary failure and is exactly what this one could not do: the report could not be built,
    # so nothing was submitted. The session stops for the reason a pre-provider refusal does —
    # the next claim meets the same broken reporting dependency on this same machine — and the
    # failure policy is not consulted, because `continue` means "a REPORTED failure does not end
    # the session".
    #
    # It says nothing about the run's state on Platform. The execution has already printed what
    # this machine knows and what it did not send; a session-level line about a server this
    # process never successfully delivered to would be a guess.
    def run_unreported_failure
      @failures += 1
      @unreported_failure = true
      line "run FAILED — its report could not be built, so no final result was submitted to Platform"
      line "stopping — this machine cannot report a result until what the execution above names " \
           "is repaired. Fix it, then start this runner again."
      :stop
    end

    def continue_on_failure? = on_failure.to_s != ON_FAILURE_STOP

    # A polling failure and the wait it causes are durable: the operator has to be
    # able to see, afterwards, that Platform was unreachable and for how long.
    # Changing backoff durations therefore stay in the record; only the countdown
    # between them is transient.
    def back_off(error)
      @consecutive_errors += 1
      seconds = backoff_seconds
      line "polling failed — #{Redaction.redact(error.message)}"
      line "sleeping #{format_seconds(seconds)} until retry ##{@consecutive_errors}"
      wait(seconds, state: "polling failed", until_label: "retry ##{@consecutive_errors}")
    end

    # Printed ONCE, when Platform answers again after a failed poll: an operator
    # watching an outage needs the recovery in the record, not only the failures.
    def note_recovery
      recovered = @consecutive_errors
      @consecutive_errors = 0
      return if recovered.zero?

      line "recovered — Platform answered again after #{recovered} failed poll(s)"
    end

    def backoff_seconds
      raw = poll_seconds * (BACKOFF_FACTOR**(@consecutive_errors - 1))
      [ raw, MAX_BACKOFF_SECONDS ].min
    end

    def fatal(reason, remedy)
      @failures += 1
      presenter.error "[loop] stopping — #{reason}"
      presenter.error "[loop] remedy: #{remedy}"
      :stop
    end

    # Waits in slices so a signal is noticed promptly, redrawing the countdown on
    # the transient row as the whole second changes. Returns :stop when the
    # operator interrupted mid-wait, so the caller does not poll one more time.
    #
    # The deadline is MONOTONIC: a countdown computed from wall-clock time lies
    # when the laptop sleeps or the clock steps.
    def wait(seconds, state:, until_label:)
      deadline = monotonic + seconds.to_f
      loop do
        return :stop if @stop_requested

        remaining = deadline - monotonic
        break if remaining <= 0

        # Presence has to stay current DURING the wait, not only between polls: with the
        # default interval a poll boundary is further apart than Platform's presence window,
        # so a runner that only signalled per poll would flicker to Offline while healthy.
        # The call is cheap and cadence-gated — it sends nothing until Platform's advertised
        # interval is due.
        return :stop if keep_presence_current == :stop

        transient state, "; #{until_label} in #{format_seconds(remaining.ceil)}"
        sleeper.call([ remaining, SLICE_SECONDS ].min)
      end
      @stop_requested ? :stop : :continue
    end

    # Presence outcomes that are PERMANENT stop the session, for the same reason a rejected
    # claim credential does: a superseded session and a revoked credential both mean this
    # process will never be current again. A transient failure is left alone — the loop keeps
    # polling and Platform's own window reports Offline until the network returns.
    def keep_presence_current
      act_on_session(presence.heartbeat_if_due)
    end

    def resume_presence
      act_on_session(presence.resume)
    end

    def announce_presence
      act_on_session(presence.started)
    end

    def start_connector
      act_on_session(connector.started)
    end

    def keep_connector_running
      act_on_session(connector.restart_if_exited)
    end

    # ONE rule for every permanent session-level refusal, whatever reported it: record one
    # actionable failure, print the single thing the operator has to do, and stop. A revoked
    # credential, a superseded presence session, a machine with no stored preview connector and a
    # machine with no connector program to run are all states no wait would fix.
    def act_on_session(outcome)
      return :continue unless outcome.stop?

      @stop_requested = true
      fatal(outcome.message, outcome.remedy)
    end

    def format_seconds(seconds) = seconds == seconds.to_i ? "#{seconds.to_i}s" : format("%.1fs", seconds)
    def monotonic = clock.clock_gettime(Process::CLOCK_MONOTONIC)

    # Only an assignment happens in the handler — nothing that allocates, logs, or
    # takes a lock, because a trap can interrupt any of those mid-operation. The
    # loop prints and unwinds on the main thread; the watcher above is what turns
    # the flag into an operator-visible line.
    def trap_signals
      return unless @install_signals

      %w[INT TERM].each { |name| @previous_traps[name] = Signal.trap(name) { @stop_requested = true } }
    end

    def restore_signals
      @previous_traps.each { |name, handler| Signal.trap(name, handler || "DEFAULT") }
      @previous_traps.clear
    end

    # The record. `[loop] ` prefixed so runner lines stay distinguishable from
    # executor output, and flushed by the presenter because Ruby block-buffers a
    # redirected stdout — "is it alive?" is exactly the question this answers.
    def line(message) = presenter.line("[loop] #{message}")

    # What is true right now. One row, replaced in place, gone when it stops being
    # true.
    #
    # A narrow terminal gets the most informative message that FITS, in this order:
    # identity + state + countdown, then state + countdown, then the bare state. It
    # loses detail rather than being handed a clipped half-truth — the identity was
    # already named durably at start, and half a workspace key is worse than none.
    # The presenter still clips, but only if even the bare state does not fit.
    def transient(state, countdown = nil)
      rows = [ "#{label} — #{state}#{countdown}", "#{state}#{countdown}", state ]
      rows.shift if label.empty?
      presenter.status(rows.find { |row| row.length <= presenter.columns - 2 } || rows.last)
    end

    def announce_start
      line "started — polling every #{poll_seconds}s, one run at a time, --on-failure #{on_failure}"
      line "press Ctrl-C to stop; an in-progress execution finishes its report first"
    end

    # Names what the runner was doing when it stopped, so an operator who hits
    # Ctrl-C knows whether a run is mid-flight.
    def announce_stop
      line(stop_description)
      line "session totals — #{@executed} run(s) executed, #{@failures} failed"
    end

    def stop_description
      return "stopped — no further iterations requested" unless @stop_requested
      if @stopped_during_execution
        # "reported its result first" is the ordinary case and not a universal one. A run whose
        # report could not be built finished without submitting anything, and answering an
        # operator's Ctrl-C with the reassurance that it reported would describe a delivery that
        # did not happen.
        return "stopped by signal DURING an execution — the run finished; its result was NOT " \
               "submitted to Platform" if @unreported_failure

        return "stopped by signal DURING an execution — the run finished and reported its result first"
      end

      "stopped by signal while IDLE — no execution was in progress and nothing was claimed"
    end
  end
end
