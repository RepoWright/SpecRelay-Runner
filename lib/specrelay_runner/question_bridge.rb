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
    # The one state that means a FRESH session received an offline batch's answers (Stage 2a).
    RESUMED = "RESUMED"

    PROVIDER_EXITED = "the provider exited while its question was still waiting for an answer"
    ANSWER_UNDELIVERED = "the provider exited before its answers could be handed back to it"
    DELIVERY_UNCONFIRMED = "Platform did not confirm that the answers reached this session"

    # `measure` is asked for this machine's checkpoint at the instant the provider pauses — not
    # when the bridge starts — because the provider changes files right up to that moment, and a
    # later resume has to land on exactly the state it left (Stage 2a design 3).
    def initialize(client:, claim:, staging_dir:, measure: -> { nil }, io: $stdout)
      @client = client
      @claim = claim
      @path = File.join(staging_dir, DIRECTORY)
      @measure = measure
      @io = io
      @mutex = Mutex.new
      @outcome = nil
      @failure_reason = nil
      @should_stop = false
      @thread = nil
      @awaiting_verdict = false
      @resume_confirmed = false
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

    # Stage 2a — the fresh session started with an earlier batch's answers in its prompt and is
    # now running. Platform is told once, from here, because this parent is the only thing that
    # can observe that the process it launched with them is alive; the batch then settles as
    # RESUMED and the run is free to be asked again.
    #
    # Anything other than RESUMED means something else won — a cancellation, or another machine
    # — so the provider is stopped exactly as an unconfirmed live delivery stops it. Continuing
    # on answers Platform does not record as delivered is the one outcome that must not happen.
    #
    # Called from whichever output thread sees the provider first, so the claim to report it is
    # taken under the same mutex every other decision here uses: Platform is idempotent, but a
    # second acknowledgement would read the state its own predecessor wrote.
    def confirm_resume(public_id)
      return unless claim_resume_delivery

      settled = client.confirm_executor_question_delivery(claim: claim, public_id: public_id)
                      .to_h["question"].to_h
      return unconfirmed(settled) unless settled["state"].to_s == RESUMED

      log("[question] the earlier answers were delivered to this fresh session")
    rescue PlatformClient::Error => e
      record(:failed, Redaction.redact(e.message))
    end

    private

    attr_reader :client, :claim, :measure, :io

    def claim_resume_delivery
      @mutex.synchronize do
        next false if @resume_confirmed

        @resume_confirmed = true
      end
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
      body = client.submit_executor_question(claim: claim, question: document, checkpoint: measure.call)
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

    def refuse(message)
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
