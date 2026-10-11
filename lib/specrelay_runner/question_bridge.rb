# frozen_string_literal: true

require "fileutils"
require "json"

module SpecrelayRunner
  # The SpecRelay-owned local question bridge (MVP-0036 Stage 1).
  #
  # Platform cannot click a provider's private question dialog, and this runner never scrapes
  # one: the contract is two files in an attempt-local directory OUTSIDE the worktree, so it
  # can never reach the diff, and it is the ONLY thing the provider is told about.
  #
  #   question-request.json — the provider writes its batch here, then blocks;
  #   question-error.json   — a refusal, so the same session can correct and try again.
  #
  # An accepted batch is never answered in the session that asked it. Platform stores it and
  # releases the attempt at once, so this session ends and a FRESH one continues from the recorded
  # checkpoint once the Product Owner has answered.
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
    ERROR = "question-error.json"

    MAX_REQUEST_BYTES = 64 * 1024
    # How often the parent looks for a request the provider just wrote. Short, because the
    # provider is blocked from the moment it writes.
    WATCH_SECONDS = 0.25

    # The state Platform settles an accepted batch in, which ends this session.
    OFFLINE_WAIT = "OFFLINE_WAIT"
    # The one state that means a FRESH session received an offline batch's answers.
    RESUMED = "RESUMED"

    NOT_RELEASED = "Platform accepted the question without releasing this session"
    DELIVERY_UNCONFIRMED = "Platform did not confirm that the answers reached this session"

    # `capture` is asked for this machine's checkpoint at the instant the provider pauses — not
    # when the bridge starts — because the provider changes files right up to that moment, and a
    # later resume has to land on exactly the state it left. It answers with a manifest or with ONE
    # reason. A reason ends the session through the input-capture failure path: nothing the provider
    # could correct makes an unpushable or unresolvable checkpoint continuable.
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
      @resume_confirmed = false
      @refusals = 0
    end

    attr_reader :path

    def start
      FileUtils.mkdir_p(path)
      @thread = Thread.new { watch }
      self
    end

    # Called once the provider process has ended, on every path. A submission in flight is
    # finished first, so its ending is recorded before the attempt is classified.
    def stop
      @mutex.synchronize { @should_stop = true }
      @thread&.join
      @thread = nil
    end

    # The provider must be ended. True for BOTH endings, because both leave a process blocked
    # on a question this session will never be answered: Platform released the session, or the
    # bridge cannot recover. Read by CommandRunner's stop check, which owns the bounded
    # TERM-then-KILL grace.
    def stop_provider? = !outcome.nil?

    # Platform stored the question and released this session. The question and its context are
    # durable.
    def released? = outcome == :released

    # This session could not carry the question through: its work could not be checkpointed,
    # nothing became durable, or Platform did not release it. What failed is this session's part;
    # the runner reports that, PLATFORM decides what the attempt becomes, and the dirty worktree is
    # preserved either way.
    def failed? = outcome == :failed

    def outcome = @mutex.synchronize { @outcome }
    def failure_reason = @mutex.synchronize { @failure_reason }

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
    # so the provider is stopped. Continuing on answers Platform does not record as delivered is
    # the one outcome that must not happen.
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
    # rather than being re-read forever, and any previous refusal is cleared with it.
    def consume_request
      raw = File.read(request_path)
      [ REQUEST, ERROR ].each { |name| FileUtils.rm_f(File.join(path, name)) }
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
      return record(:failed, Redaction.redact(captured.error)) unless captured.ok?

      body = client.submit_executor_question(claim: claim, question: document,
                                             checkpoint: captured.checkpoint)
      settled(body.to_h["question"].to_h)
    rescue PlatformClient::Error => e
      # A refusal is Platform having READ the request and declined it, so the same session may
      # correct and retry, and no stored question names the refs this capture pushed. Anything
      # else — a transport fault or a 5xx — leaves the question's fate unknown, and re-sending a
      # batch that may already be durable is exactly what the one-open-batch rule exists to
      # prevent. Fail closed, and keep the refs: the question they belong to may exist.
      return record(:failed, Redaction.redact(e.message)) unless e.respond_to?(:refused?) && e.refused?

      withdraw(captured)
      refuse(Redaction.redact(e.message))
    end

    def withdraw(captured)
      orphans = Checkpoint.withdraw(captured)
      log("[question] these checkpoint refs could not be removed: #{orphans.join(', ')}") if orphans.any?
    end

    # Platform releases an accepted batch at once. Anything else is not a state this session may
    # continue in, so it ends closed rather than waiting for an answer that never comes here.
    def settled(question)
      state = question["state"].to_s
      return record(:released, nil) if state == OFFLINE_WAIT

      record(:failed, "#{NOT_RELEASED} (#{question['id']} is #{state})")
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
      end
      log("[question] the provider session is ending: #{reason || 'Platform released it'}")
    end

    def log(message)
      io.puts(Redaction.redact(message.to_s))
      io.flush if io.respond_to?(:flush)
    end
  end
end
