# frozen_string_literal: true

module SpecrelayRunner
  # MAPIAI-97 — one claimed live preview, from assignment to released environment.
  #
  # {PreviewExecution} owns the commands; this owns the CLAIM. It is the long-lived half of the
  # feature: after the application is running the claim does not end, because the machine is still
  # holding a task environment that only it can take down. So this keeps beating, and the
  # heartbeat it is already sending is also the channel Stop arrives on. There is no second
  # connection, no poll for controls and nothing pushed.
  #
  # The vocabulary is Platform's, unchanged: an operator Stop reaches this runner as the same
  # `cancelled` signal every other lane obeys. `expired` and `terminal` are deliberately NOT
  # treated as Stop — a lapsed lease means nobody is coordinating this environment any more, and
  # releasing on that basis would be this runner deciding something Platform did not.
  #
  # REMOTE ACCESS IS NOT THIS CLAIM'S CONCERN. The one connector this machine runs belongs to the
  # loop session, not to a claim, and Platform publishes each service of an available preview
  # through it. So a claim starts no publishing child, keeps no per-attempt state for one, and
  # reports nothing about whether a link exists — which is also why the project-owned release has
  # nothing to be ordered against any more.
  class PreviewSession
    CANCELLED = "cancelled"
    # The beat is doing two jobs, and they pull in opposite directions: renewing a lease that must
    # not lapse over hours of human testing, and carrying Stop back promptly. Ten seconds keeps
    # the lease comfortably alive and bounds the delay between pressing Stop and the release
    # starting; the page has already withdrawn the URLs by then.
    HEARTBEAT_SECONDS = 10
    WAIT_SLICE = 0.5

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(payload:, client:, root:, io:, env: ENV, heartbeat_seconds: HEARTBEAT_SECONDS,
                   sleeper: Kernel, github: PreviousAcceptedPackage::GitHub)
      @payload = payload
      @client = client
      @root = root
      @io = io
      @env = env
      @heartbeat_seconds = heartbeat_seconds
      @sleeper = sleeper
      @github = github
    end

    # True when this claim did what it was made for. A refused assignment, a failed start and a
    # released environment are all honest outcomes; only an environment this runner could not
    # account for is not.
    def call
      assignment = PreviewAssignment.read(@payload)
      return refused(assignment.reason) unless assignment.ok?

      @assignment = assignment
      @claim = assignment.execution_id
      @task_id = assignment.task_id
      return release_only if assignment.release?

      # BEFORE the first slow thing this claim does. Resolving the ticket's pull requests is a
      # remote read that can hang, and until it returned there was nothing renewing the lease and
      # nothing listening for Stop — so a healthy machine could lose a claim it was still holding,
      # and an operator's Stop went unheard until GitHub answered (CR-005 F1).
      beat
      outcome = streaming { execution.start }
      report(outcome)
      outcome.cleanup_required? ? hold : true
    ensure
      @beat&.stop
    end

    private

    attr_reader :client, :root, :io, :env, :sleeper, :github

    def execution
      @execution ||= PreviewExecution.new(
        payload: @payload, root: root, env: env, github: github,
        # The SAME signal that will end the wait also ends a long `up`: a Stop pressed while
        # Compose is still starting must not have to wait for it to finish.
        stop_check: -> { beat.stop_reason == CANCELLED },
        # Straight into the ordered event stream that already owns secret redaction, clipping,
        # batching and local echo — through {PreviewOutput}, which owns the one thing that stream
        # does not: a project command names the machine it ran on, and that is private (CR-006).
        # It sits in FRONT of the stream so the operator's terminal and Platform receive the same
        # bytes rather than getting two chances to disagree.
        on_output: sanitizer,
        on_sources: ->(snapshot) { submit(kind: "sources", sources: snapshot) }
      )
    end

    # The live startup transcript, open only while the environment is being built. `finish` is in
    # an ensure because an unsettled stream would hold the last lines of a FAILED start — which is
    # exactly the output an operator needs.
    def streaming
      @stream = ExecutorLogStream.start(emitter: emitter, io: io, provider: "the task environment",
                                        task_id: @task_id)
      yield
    ensure
      @stream&.finish
      @stream = nil
    end

    # Stateless, so one is enough: what it needs to know about a cut arrives with the callback.
    def sanitizer = @sanitizer ||= PreviewOutput.new(->(source, text) { @stream&.accept(source, text) })

    # No run id: a preview claim has none, and the contract requires the field to be absent for
    # this lane rather than carrying an invented one.
    def emitter = @emitter ||= EventEmitter.new(client: client, run_id: nil, attempt_id: @claim)

    # A document this build cannot act on is still reported, so the ticket says why rather than
    # sitting in Starting. The claim token is read defensively from the payload: it is the one
    # field needed to answer at all, and the assignment that would have carried it was refused.
    def refused(reason)
      @claim = @payload.to_h.dig("claim", "execution_id")
      return false if @claim.to_s.empty?

      submit(kind: "failed", failure_kind: PreviewExecution::INVALID_ASSIGNMENT, reason: reason,
             cleanup_required: false)
      false
    end

    # The claim Platform handed back to the machine that went offline. It runs the
    # project-owned release and NOTHING else: the start path would rebuild the environment this
    # was sent to delete. No heartbeater either — the lease is already gone and nothing is waiting
    # on a signal. Both outcomes are honest reports and therefore a successful claim; an
    # obligation that persists returns on the next poll.
    def release_only
      release
      true
    end

    def report(outcome)
      case outcome.state
      when PreviewExecution::AVAILABLE then submit(kind: "started", status: outcome.document)
      when PreviewExecution::FAILED_CLEAN, PreviewExecution::FAILED_CLEANUP
        submit(kind: "failed", failure_kind: outcome.failure_kind, reason: outcome.reason,
               cleanup_required: outcome.cleanup_required?)
      when PreviewExecution::STOPPED
        # A Stop seen before anything was created. There is no environment, so `release` would be
        # a command with nothing to remove: the released result IS the cleanup. Without this arm
        # the claim ended silently and the ticket stayed STOPPING for ever (CR-005 F1). A Stop
        # seen AFTER creation owns cleanup and is answered by {#hold} instead.
        submit(kind: "released") unless outcome.cleanup_required?
      end
      line(outcome.reason) if outcome.reason
    end

    # The long-lived phase. Each wait gets its own beater, because a beater that has recorded a
    # stop has already ended its thread — and a Retry release is a second wait for a second Stop.
    def hold
      loop do
        signal = await_signal
        return abandoned(signal) unless signal == CANCELLED
        return true if release
      end
    end

    def await_signal
      sleeper.sleep(WAIT_SLICE) while beat.stop_reason.nil?

      reason = beat.stop_reason
      beat.stop
      @beat = nil
      reason
    end

    def release
      outcome = streaming { execution.release }
      return false unless outcome.state == PreviewExecution::RELEASED || failed_release(outcome)

      submit(kind: "released")
      line("released the task environment")
      true
    end

    # Reported, and then waited on again: the machine stays reserved, because the environment the
    # project would not release is still there and only this runner can remove it.
    def failed_release(outcome)
      submit(kind: "release_failed", reason: outcome.reason)
      line(outcome.reason)
      false
    end

    # A lease this runner no longer holds. It does NOT release: without a live claim there is
    # nothing to report the release to, and a cleanup nobody recorded is worse than none. It does
    # not ask for a manual command either — Platform holds the obligation and hands this exact
    # release back on the next poll.
    def abandoned(signal)
      line "Platform ended this claim (#{signal}) while a task environment may still exist. " \
           "It is handed back for release when this runner reconnects."
      false
    end

    def beat
      @beat ||= Heartbeater.new(client: client, claim: @claim, interval_seconds: @heartbeat_seconds,
                                io: io).start
    end

    def submit(**result) = client.submit_preview_result(claim: @claim, result: result)

    # The operator-facing narration of an outcome. It is built from command output, so it passes
    # the same two filters that output does.
    def line(text) = io.puts(PrivatePaths.sanitize(Redaction.redact(text.to_s)))
  end
end
