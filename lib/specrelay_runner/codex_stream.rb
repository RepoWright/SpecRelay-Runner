# frozen_string_literal: true

require "json"

module SpecrelayRunner
  # The ONE boundary that turns the audited Codex profile's structured output into something two
  # surfaces may see. Its stdout is a JSON-lines transport, not operator text, and nothing
  # downstream may treat it as text.
  #
  # It produces exactly two independent products from the same bytes, and they never mix:
  #
  #   1. safe public progress, handed to the caller's sink AS IT ARRIVES, so an operator sees the
  #      provider working instead of a silent terminal; and
  #   2. the terminal implementation report, handed to the EXISTING package parsers unchanged.
  #
  # Why this is a separate class from {ClaudeStream} rather than a mode of it: the two providers
  # agree on nothing that matters here. Claude reports one `result` frame; Codex reports a stream
  # of typed items and ends a TURN. Sharing one decoder would mean one method whose every branch
  # asked which provider it was reading, and a terminal rule that had to be true of both — which is
  # exactly the false sharing that lets one provider's fail-closed rule become the other's
  # fail-open one. What IS shared is shared: {PublicProgress} owns the path projection, the
  # redaction call and the block bounds for both, and {Redaction} owns secret shapes for everything.
  #
  # Withheld, always: `reasoning` items, which are the model's private thinking, the JSONL wrappers
  # themselves, and every item or event type this decoder does not recognize — so a future CLI
  # cannot leak by being new.
  #
  # FAIL CLOSED. A turn that failed, a top-level error, malformed or truncated JSONL, no terminal
  # event, two terminal events, anything after the terminal event, and a terminal event with no
  # public message before it all mean the runner cannot prove which bytes are progress and which
  # are the authoritative report. It refuses both rather than guessing, and it never displays or
  # stores the offending frame.
  class CodexStream
    # One event's bytes, bounded because CommandRunner hands over a partial line once it passes its
    # own pending cap and a decoder that buffered forever would be a memory leak dressed as
    # reassembly.
    # It is also what bounds the implementation report: the report IS one event's `text`, so a
    # report larger than this cap can never complete a parse and needs no second bound of its own.
    MAX_PENDING_BYTES = 1_000_000

    # The runner's own stream name for normalized progress — an existing `log_source` value, not a
    # new one, so the wire contract and the Platform panel are unchanged.
    STATUS = "status"

    STARTED = "Provider started"
    COMPLETED = "Provider completed"
    COMPLETED_STEP = "< step completed"
    FAILED_STEP = "! step failed"
    DIAGNOSTIC = "Provider wrote diagnostic output"

    # Every reason is the runner's OWN sentence. None of them may carry provider bytes: a
    # classification that quoted the failure would republish exactly what failing closed withheld.
    FAILURE_UNREADABLE = "the provider's structured output could not be read"
    FAILURE_INCOMPLETE = "the provider's structured output ended mid-event"
    FAILURE_NO_TERMINAL = "the provider's turn never reached a terminal event"
    FAILURE_TWO_TERMINALS = "the provider reported more than one terminal event"
    FAILURE_AFTER_TERMINAL = "the provider continued after its terminal event"
    FAILURE_NO_REPORT = "the provider produced no implementation report before its terminal event"
    FAILURE_TURN_FAILED = "the provider reported that its turn failed"
    FAILURE_PROVIDER_ERROR = "the provider reported an error"

    # The item types this decoder is contracted for. `reasoning` is deliberately ABSENT rather than
    # mapped to nothing: absence and "recognized but withheld" behave identically here, and one
    # list is easier to audit than two.
    COMMAND_ITEM = "command_execution"
    MESSAGE_ITEM = "agent_message"

    # The nested discriminator the public Codex thread contract emits. The official SDK
    # (https://github.com/openai/codex — `sdk/typescript/src/thread.ts` and
    # `sdk/typescript/samples/basic_streaming.ts`) branches on `item.type`. This decoder first read
    # an `item_type` key that the provider does not emit; because the test double invented the same
    # key, the suite proved only that the double agreed with the decoder, and a genuine run would
    # have produced no report at all.
    ITEM_TYPE = "type"

    # `sink` receives `(stream_name, text)` exactly as CommandRunner's own consumer does, so the
    # existing ExecutorLogStream is the fan-out owner and this class shows nothing itself.
    #
    # `repository_path` is the assigned worktree — the ONE approved root a public path may be shown
    # relative to. It is handed straight to {PublicProgress}, which owns that rule.
    def initialize(sink: nil, repository_path: nil)
      @sink = sink
      @text = PublicProgress.new(repository_path: repository_path)
      @pending = +""
      @report = nil
      @terminal_seen = false
      @failure = nil
      @diagnostic_reported = false
    end

    # The consumer handed to CommandRunner. Every line the provider writes comes through here.
    def sink = ->(source, line) { accept(source, line) }

    def accept(source, line)
      return diagnostic unless source == CommandRunner::STDOUT
      # After a fatal decode failure nothing later in the stream can be trusted, so nothing later
      # in the stream is shown.
      return if @failure

      decode(line.to_s)
    end

    # stderr is provider bytes, not structured output, and it never passed an allowlist. Its bytes
    # are therefore not forwarded at all. ONE bounded notice records that the provider wrote
    # diagnostics; the COMPLETE stderr still reaches the report through the buffered capture, which
    # this class does not touch.
    def diagnostic
      return if @diagnostic_reported

      @diagnostic_reported = true
      forward(CommandRunner::STDERR, DIAGNOSTIC)
    end

    # Ends the stream and applies the rules that cannot be checked one event at a time. Returns
    # self so a caller can read `failure` in the same expression.
    def close
      return self if @failure

      return fail!(FAILURE_INCOMPLETE) unless @pending.empty?
      return fail!(FAILURE_NO_TERMINAL) unless @terminal_seen
      return fail!(FAILURE_NO_REPORT) if @report.nil?

      self
    end

    # Why the stream is unusable, or nil. A reason NEVER contains provider bytes.
    attr_reader :failure

    # The terminal implementation report, for the existing report/package parsers. Empty when the
    # stream failed, because a stream this object refused must not hand anything to a parser.
    def final_text = @failure ? "" : @report.to_s

    private

    def decode(line)
      @pending << line
      return fail!(FAILURE_UNREADABLE) if @pending.bytesize > MAX_PENDING_BYTES

      value = parse(@pending)
      # Not yet a complete event: CommandRunner splits a long line at its own pending cap, so an
      # unparseable buffer is normally a fragment. A buffer that is genuinely malformed never
      # completes and is caught by the byte cap or by `close`.
      return if value.nil?

      @pending = +""
      # Valid JSON that is not an event object means the stream is not what this decoder contracted
      # for, and continuing would be guessing.
      value.is_a?(Hash) ? handle(value) : fail!(FAILURE_UNREADABLE)
    end

    def parse(text)
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end

    # The turn's state machine. Terminal state is decided FIRST, because every rule that makes a
    # stream unusable is a statement about ordering: a second terminal, or anything at all after
    # one, is a fault no matter how ordinary the event itself looks.
    def handle(event)
      type = event["type"].to_s
      return fail!(FAILURE_AFTER_TERMINAL) if @terminal_seen && type != "turn.completed"

      case type
      when "turn.completed" then complete_turn
      when "turn.failed" then fail!(FAILURE_TURN_FAILED)
      when "error" then fail!(FAILURE_PROVIDER_ERROR)
      when "thread.started" then forward(STATUS, STARTED)
      when "item.started" then started_item(event["item"])
      when "item.completed" then completed_item(event["item"])
      end
    end

    def complete_turn
      return fail!(FAILURE_TWO_TERMINALS) if @terminal_seen

      @terminal_seen = true
      forward(STATUS, COMPLETED)
    end

    # A command as the operator would read it: what ran, announced when it starts so a long step is
    # not silence.
    def started_item(item)
      return unless item.is_a?(Hash) && item[ITEM_TYPE].to_s == COMMAND_ITEM

      forward(STATUS, "> #{clip(item['command'])}")
    end

    # A completed item is either the outcome of a command — its disposition and its bounded output
    # — or one public message. Everything else, `reasoning` included, renders nothing.
    def completed_item(item)
      return unless item.is_a?(Hash)

      case item[ITEM_TYPE].to_s
      when COMMAND_ITEM then command_outcome(item)
      when MESSAGE_ITEM then public_message(item["text"])
      end
    end

    # A failed step is progress, NOT a verdict: Codex may recover and complete the turn. Only the
    # terminal event decides whether this attempt succeeded.
    def command_outcome(item)
      forward(STATUS, item["exit_code"].to_i.zero? ? COMPLETED_STEP : FAILED_STEP)
      @text.indent(item["aggregated_output"]).each { |line| forward(STATUS, line) }
    end

    # The public message is shown AND held: the last non-empty one before the terminal event is
    # this attempt's implementation report. An empty message is not a report, so it never replaces
    # one — a provider that signs off with whitespace has not withdrawn the answer it already gave.
    def public_message(text)
      lines = @text.bounded(text)
      lines.each { |line| forward(STATUS, line) }
      return if text.to_s.strip.empty?

      @report = text.to_s
    end

    def clip(value) = @text.clip_line(@text.redact(value).tr("\n", " ").strip)

    # Redaction, clipping and the whole-run budget belong to ExecutorLogStream, which every line
    # passes through; duplicating them here would create a second owner of the same rules.
    def forward(source, text) = @sink&.call(source, text.to_s)

    # A failure is recorded, never shown and never raised: the caller decides what a broken
    # provider stream means for its own lane, and the offending bytes reach no surface at all.
    def fail!(reason)
      @failure ||= reason
      @pending = +""
      self
    end
  end
end
