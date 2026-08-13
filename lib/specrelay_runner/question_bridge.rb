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
    ANSWERED = "ANSWERED"
    OFFLINE_WAIT = "OFFLINE_WAIT"

    PROVIDER_EXITED = "the provider exited while its question was still waiting for an answer"

    def initialize(client:, claim:, staging_dir:, io: $stdout)
      @client = client
      @claim = claim
      @path = File.join(staging_dir, DIRECTORY)
      @io = io
      @mutex = Mutex.new
      @outcome = nil
      @failure_reason = nil
      @should_stop = false
      @thread = nil
      @awaiting_verdict = false
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

    # No question ever became durable and the bridge cannot recover. The attempt ends as
    # INPUT_CAPTURE_FAILED with the dirty worktree preserved.
    def failed? = outcome == :failed

    def outcome = @mutex.synchronize { @outcome }
    def failure_reason = @mutex.synchronize { @failure_reason }

    # A batch Platform accepted that nobody has settled yet. True only between the accepted
    # submission and the answer or release that ends it.
    def awaiting_verdict? = @mutex.synchronize { @awaiting_verdict && @outcome.nil? }

    private

    attr_reader :client, :claim, :io

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
      body = client.submit_executor_question(claim: claim, question: document)
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
        return deliver(question) if state == ANSWERED
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
    def deliver(question)
      @mutex.synchronize { @awaiting_verdict = false }
      write(ANSWER, { "answers" => question["answers"] })
      log("[question] answers delivered to the waiting provider session")
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
