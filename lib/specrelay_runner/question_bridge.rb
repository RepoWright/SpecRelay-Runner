# frozen_string_literal: true

require "fileutils"
require "json"

module SpecrelayRunner
  # The SpecRelay-owned local question bridge (MVP-0036 Stage 1).
  #
  # Platform cannot click a provider's private question dialog, and this runner never scrapes
  # one: the contract is three files in an attempt-local directory OUTSIDE the worktree, so it
  # can never reach the diff, and it is the ONLY thing the provider is told about.
  #
  #   question-request.json — the provider writes its batch here, then blocks;
  #   question-answer.json  — the accepted answers appear here, and the SAME session continues;
  #   question-error.json   — a refusal, so the same session can correct and try again.
  #
  # The bridge holds no credential. This object runs in the Runner PARENT, which owns the
  # Platform client, the lease and the heartbeat; the provider only reads and writes files.
  #
  # Everything durable is decided by Platform. The local checks are exactly the two the
  # specification names as "locally valid" — the document is readable, and it is within the
  # size bound — because a second copy of Platform's schema here is how the two would come to
  # disagree about what a valid question is.
  class QuestionBridge
    DIRECTORY = "question-bridge"
    REQUEST = "question-request.json"
    ANSWER = "question-answer.json"
    ERROR = "question-error.json"

    MAX_REQUEST_BYTES = 64 * 1024
    # How often the parent looks for a request the provider just wrote. Short, because the
    # provider is blocked from the moment it writes.
    WATCH_SECONDS = 0.25
    # How often Platform is asked whether the batch has been settled. Deliberately much slower:
    # the answer comes from a human reading a page, and a quarter-second poll would send
    # thousands of requests across a fifteen-minute window to learn nothing.
    ANSWER_POLL_SECONDS = 2.0

    LIVE_WAIT = "LIVE_WAIT"
    # The Product Owner answered and Platform is holding the batch for THIS session. It becomes
    # ANSWERED only when the acknowledgement below reports that the answers were handed over.
    ANSWER_READY = "ANSWER_READY"
    # The one state that means this session's delivery is what Platform recorded. Anything else
    # coming back from the acknowledgement is some OTHER ending that won (CR-003 F1).
    ANSWERED = "ANSWERED"
    OFFLINE_WAIT = "OFFLINE_WAIT"
    # The one state that means a FRESH session received an offline batch's answers.
    RESUMED = "RESUMED"

    PROVIDER_EXITED = "the provider exited while its question was still waiting for an answer"
    ANSWER_UNDELIVERED = "the provider exited before its answers could be handed back to it"
    DELIVERY_UNCONFIRMED = "Platform did not confirm that the answers reached this session"

    # `capture` is asked for this machine's portable checkpoint at the instant the provider pauses
    # — not when the bridge starts — because the provider changes files right up to that moment,
    # and a later resume has to land on exactly the state it left. It answers with a package or
    # with ONE reason, and a reason is returned to the provider rather than stored: a batch whose
    # work could not be captured is one nothing could ever continue.
    #
    # There is no default: a batch stored without a package could never be continued, so Platform
    # refuses one, and a bridge that could not name how to capture has nothing to submit.
    #
    # `resume_question_id` is the earlier batch THIS session is continuing, or nil for an ordinary
    # claim. Holding it here rather than passing it per call is what lets the two things that can
    # trigger the acknowledgement — the provider starting, and the provider asking again — share
    # one gate (CR-004 F3).
    def initialize(client:, claim:, staging_dir:, capture:, resume_question_id: nil, io: $stdout)
      @client = client
      @claim = claim
      @path = File.join(staging_dir, DIRECTORY)
      @capture = capture
      @resume_question_id = resume_question_id
      @io = io
      @mutex = Mutex.new
      # A SECOND mutex, and deliberately not `@mutex`: this one is held across an HTTP call, so
      # that the second caller WAITS for the acknowledgement rather than skipping past it. The
      # state mutex must never be held that long, and `record` takes it.
      @resume_gate = Mutex.new
      @outcome = nil
      @failure_reason = nil
      @should_stop = false
      @thread = nil
      @awaiting_verdict = false
      @resume_confirmed = false
      @refusals = 0
    end

    attr_reader :path

    def start
      FileUtils.mkdir_p(path)
      @thread = Thread.new { watch }
      self
    end

    # Called once the provider process has ended, on every path.
    #
    # A batch Platform ACCEPTED and nobody settled is the provider exiting mid-question
    # (CR-001 F1). Recording it here — the moment the child is known to be gone — is what keeps
    # that ending on the question lifecycle instead of falling through to the ordinary
    # failed-report path, where a non-zero exit would be blamed on the task and a zero exit
    # would run tests and upload a report for work that stopped on an unanswered decision.
    def stop
      @mutex.synchronize { @should_stop = true }
      @thread&.join
      @thread = nil
      record(:failed, PROVIDER_EXITED) if awaiting_verdict?
    end

    # The provider must be ended. True for BOTH endings, because both leave a process blocked
    # on an answer that will never arrive: Platform released the session, or the bridge cannot
    # recover. Read by CommandRunner's stop check, which owns the bounded TERM-then-KILL grace.
    def stop_provider? = !outcome.nil?

    # Platform closed the answer window. The question and its context are durable.
    def released? = outcome == :released

    # This session could not carry the question through: nothing became durable, the provider
    # exited while its batch was unsettled, or an accepted answer could not be handed back. A
    # durable question — and, since CR-002, possibly a durable ANSWER — may well exist; what
    # failed is this session's part in it. The runner reports that; PLATFORM decides what the
    # attempt becomes, and the dirty worktree is preserved either way.
    def failed? = outcome == :failed

    def outcome = @mutex.synchronize { @outcome }
    def failure_reason = @mutex.synchronize { @failure_reason }

    # A batch Platform accepted that nobody has settled yet. True only between the accepted
    # submission and the answer or release that ends it.
    def awaiting_verdict? = @mutex.synchronize { @awaiting_verdict && @outcome.nil? }

    # How many question turns this bridge has refused back to the same provider process —
    # Platform's refusals and its own two local checks alike, because each one ends a turn the
    # provider then corrects in place. The result decoder reads this count and nothing else about
    # questions: a result frame may belong to a refused turn only while a refusal recorded before
    # it is still unexplained. A fault never counts, because a fault ends the session instead.
    def refusals = @mutex.synchronize { @refusals }

    # The fresh session was started with an earlier batch's answers in its prompt.
    # Platform is told once, from here, and only then does that batch settle as RESUMED and the
    # run become free to be asked again.
    #
    # TWO callers, one gate (CR-004 F3). Execution calls it at the provider-start boundary, which
    # is the only honest evidence that the process received the handoff — and covers a provider
    # that finishes without ever printing. `submit` below calls it before putting a NEW batch on
    # the wire, because a resumed provider's very first action may be to ask again, and Platform's
    # one-open-batch index would refuse that valid question while this one is still open. The gate
    # is held across the call, so the second caller waits for the answer instead of racing it.
    #
    # Anything other than RESUMED means something else won — a cancellation, or another machine —
    # so the provider is stopped exactly as an unconfirmed live delivery stops it. Continuing on
    # answers Platform does not record as delivered is the one outcome that must not happen.
    def confirm_resume
      @resume_gate.synchronize do
        next if @resume_question_id.nil? || @resume_confirmed

        @resume_confirmed = true
        deliver_resume
      end
    end

    private

    attr_reader :client, :claim, :capture, :io

    # Never retried: a failure here has already ended the session, and asking again would be
    # asking Platform to contradict the decision it just reported.
    def deliver_resume
      settled = client.confirm_executor_question_delivery(claim: claim, public_id: @resume_question_id)
                      .to_h["question"].to_h
      return unconfirmed(settled) unless settled["state"].to_s == RESUMED

      log("[question] the earlier answers were delivered to this fresh session")
    rescue PlatformClient::Error => e
      record(:failed, Redaction.redact(e.message))
    end

    def request_path = File.join(path, REQUEST)
    def stopping? = @mutex.synchronize { @should_stop }

    def watch
      until stopping? || outcome
        handle_request if File.file?(request_path)
        sleep WATCH_SECONDS
      end
    rescue StandardError => e
      # The bridge is the only thing that can report why a captured question was lost. Dying
      # silently here would leave the provider blocked on a file that never appears.
      record(:failed, "the question bridge stopped: #{Redaction.redact(e.message)}")
    end

    # One request, start to finish. The file is consumed FIRST so a refusal the provider
    # corrects arrives as a new request rather than being re-read forever.
    def handle_request
      raw = consume_request
      document = parse(raw)
      return refuse(document) if document.is_a?(String)

      submit(document)
    end

    # The request is consumed FIRST so a refusal the provider corrects arrives as a new request
    # rather than being re-read forever, and any previous verdict is cleared with it — a
    # provider asking a SECOND batch must never find the first batch's answers already waiting.
    def consume_request
      raw = File.read(request_path)
      [ REQUEST, ANSWER, ERROR ].each { |name| FileUtils.rm_f(File.join(path, name)) }
      raw
    end

    # The two LOCAL checks, and no more: unreadable, or too large to be a bounded batch.
    def parse(raw)
      return "the question request is #{raw.bytesize} bytes; it must fit within #{MAX_REQUEST_BYTES}" if raw.bytesize > MAX_REQUEST_BYTES

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : "the question request must be a JSON object"
    rescue JSON::ParserError => e
      "the question request is not readable JSON: #{e.message.lines.first.to_s.strip}"
    end

    def submit(document)
      # The batch this session is CONTINUING must be settled before the one it is ASKING reaches
      # Platform (CR-004 F3). If that acknowledgement failed, the session is already ending and
      # this question must not be sent at all.
      confirm_resume
      return if stopping? || outcome

      captured = capture.call
      return refuse(captured.error) unless captured.ok?

      body = client.submit_executor_question(claim: claim, question: document,
                                             checkpoint: captured.checkpoint)
      await(body.to_h["question"].to_h)
    rescue PlatformClient::Error => e
      # A refusal is Platform having READ the request and declined it, so the same session may
      # correct and retry. Anything else — a transport fault or a 5xx — leaves the question's
      # fate unknown, and re-sending a batch that may already be durable is exactly what the
      # one-open-batch rule exists to prevent. Fail closed.
      return refuse(Redaction.redact(e.message)) if e.respond_to?(:refused?) && e.refused?

      record(:failed, Redaction.redact(e.message))
    end

    # Poll Platform until it settles the batch. Platform owns the deadline; this never decides
    # that the window has passed, it only reads what Platform decided.
    def await(question)
      public_id = question["id"].to_s
      state = question["state"].to_s
      @mutex.synchronize { @awaiting_verdict = true }
      until stopping?
        return deliver(question) if state == ANSWER_READY
        return record(:released, nil) if state == OFFLINE_WAIT

        sleep ANSWER_POLL_SECONDS
        break if stopping?

        question = client.executor_question(claim: claim, public_id: public_id).to_h["question"].to_h
        state = question["state"].to_s
      end
    rescue PlatformClient::Error => e
      record(:failed, Redaction.redact(e.message))
    end

    # The answers reach the SAME session, exactly once: written to a temporary name and renamed
    # into place, so a provider polling for the file never reads a half-written document.
    #
    # Platform is told only AFTER that write, and only while the session that asked is still
    # running (CR-002 F1). "The Product Owner answered" and "the provider received it" are two
    # different facts separated by a process boundary, and this parent is the only thing that
    # can report the second one.
    def deliver(question)
      write(ANSWER, { "answers" => question["answers"] })
      return record(:failed, ANSWER_UNDELIVERED) if stopping?

      settled = client.confirm_executor_question_delivery(claim: claim, public_id: question["id"])
                      .to_h["question"].to_h
      return unconfirmed(settled) unless delivered?(question, settled)

      @mutex.synchronize { @awaiting_verdict = false }
      log("[question] answers delivered to the waiting provider session")
    rescue PlatformClient::Error => e
      # Fail closed, exactly as an unknown submission outcome does. An unacknowledged delivery
      # would leave Platform holding an answer it cannot say was handed over, on a run that
      # carried on and finished; ending the session here keeps that answer durable for Stage 2.
      record(:failed, Redaction.redact(e.message))
    end

    # Platform ANSWERING is not Platform agreeing (CR-003 F1). A cancellation, a release or the
    # deadline may have won this batch while the answers were being written, and the response
    # says which — so only THIS batch, reported ANSWERED, is a delivery this session may act on.
    def delivered?(asked, settled)
      settled["id"].to_s == asked["id"].to_s && settled["state"].to_s == ANSWERED
    end

    # Something else ended the batch. The provider is stopped and the attempt fails closed: it
    # must not carry on working from answers Platform does not record as delivered.
    def unconfirmed(settled)
      record(:failed, "#{DELIVERY_UNCONFIRMED} (#{settled['id']} is #{settled['state']})")
    end

    # Counted BEFORE the file appears, so the refusal exists by the time the provider can act on it.
    def refuse(message)
      @mutex.synchronize { @refusals += 1 }
      write(ERROR, { "error" => message })
      log("[question] the request was refused: #{message}")
    end

    def write(name, body)
      target = File.join(path, name)
      temporary = "#{target}.partial"
      File.write(temporary, JSON.pretty_generate(body))
      File.rename(temporary, target)
    end

    def record(outcome, reason)
      @mutex.synchronize do
        @outcome ||= outcome
        @failure_reason ||= reason
        @awaiting_verdict = false
      end
      log("[question] the provider session is ending: #{reason || 'Platform released it'}")
    end

    def log(message)
      io.puts(Redaction.redact(message.to_s))
      io.flush if io.respond_to?(:flush)
    end
  end
end
