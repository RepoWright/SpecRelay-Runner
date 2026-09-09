# frozen_string_literal: true

require "json"

module SpecrelayRunner
  # MAPIAI-60 — the ONE boundary that turns Claude Code's supported structured output into
  # something two surfaces may see, used by BOTH the implementation lane and the specification
  # lane. It exists because the supported profile is now structured-output-only: its stdout is a
  # JSON-lines transport, not operator text, and nothing downstream may treat it as text.
  #
  # It produces exactly two independent products from the same bytes:
  #
  #   1. safe public progress, handed to the caller's sink AS IT ARRIVES, so an operator sees
  #      the provider working instead of a silent terminal; and
  #   2. the terminal `result` text, handed to the EXISTING result/package parsers unchanged.
  #
  # They never mix. A displayed event can never become specification input or a report, and the
  # final result is never duplicated into the live view.
  #
  # CR-005 — the first product shows the PUBLIC TRANSCRIPT, not a title per event. Narration,
  # the tool and its description, the exact command, its stdout and stderr, file paths and
  # contents, an edit's before/after, delegated Task input and output, and the provider's own
  # timing are all rendered, in the order the provider emitted them. Normalized titles told an
  # operator that something happened and never what.
  #
  # Exactly two things are withheld: `thinking` blocks, which are the model's private reasoning
  # and are not public text even though the transport carries them, and the JSONL wrappers
  # themselves. Credentials are NOT filtered here — {Redaction} is the single boundary that
  # removes them, and it runs over every line on the way to both surfaces. A message type this
  # decoder does not recognize renders nothing rather than its object, so a future CLI cannot
  # leak by being new.
  #
  # MAPIAI-77 — an absolute LOCAL path is withheld too, and the decision belongs here because
  # this is the only place that holds the complete public content together with the verified
  # worktree root. A path this class can prove is inside that root is shown in its
  # repository-relative form; every other absolute path — and every absolute path in the
  # specification lane, which has no approved root at all — becomes {LOCAL_PATH}. That is a
  # projection rule about one lane's root, not a credential pattern, so {Redaction} keeps
  # owning secrets and is called rather than copied.
  #
  # FAIL CLOSED. Malformed output, no terminal result, or two terminal results all mean the
  # runner can no longer prove which bytes are progress and which are the authoritative result.
  # It refuses both rather than guessing, and it never displays or stores the offending frame.
  # The ONE exception is causal and is not this decoder's to grant: a question turn the attempt's
  # bridge refused ends in a result frame of its own, and the same process then continues. Such a
  # result is superseded by the frame that follows it — see {#capture_result}.
  #
  # Deliberately Claude-specific: there is no provider registry, no event SDK and no plugin
  # surface here, because exactly one provider emits this format.
  class ClaudeStream
    # One message's bytes, bounded because CommandRunner hands over a partial line once it
    # passes its own pending cap and a decoder that buffered forever would be a memory leak
    # dressed as reassembly.
    MAX_PENDING_BYTES = 1_000_000
    # The terminal result the existing parsers receive. Anything larger is a provider fault,
    # not a very thorough answer.
    MAX_RESULT_BYTES = 4_000_000
    # How deep a public input value is unwrapped before it stops being readable as one line.
    MAX_VALUE_DEPTH = 2

    # The local-path projection rule, the block bounds and the call into {Redaction} live in
    # {PublicProgress}, which the Codex decoder consumes too. They are one privacy policy for a
    # lane with an approved root, not a Claude one — so they are asked of that owner rather than
    # kept here in a second copy that could drift.

    # Input keys the specialized presentation already showed, and the transport's own identity.
    # Everything else a tool declares publicly goes through the generic renderer.
    SUBJECT_KEYS = %w[file_path path notebook_path command description].freeze
    SPECIALIZED_KEYS = %w[old_string new_string content contents prompt].freeze
    WRAPPER_KEYS = %w[id type caller].freeze

    # The runner's own stream name for normalized progress — an existing `log_source` value, not
    # a new one, so the wire contract and the Platform panel are unchanged.
    STATUS = "status"

    STARTED = "Provider started"
    COMPLETED = "Provider completed"
    FAILED = "Provider failed"
    COMPLETED_STEP = "< step completed"
    FAILED_STEP = "! step failed"
    INTERRUPTED_STEP = "! step interrupted"
    RATE_LIMIT = "Rate limit"
    DIAGNOSTIC = "Provider wrote diagnostic output"

    FAILURE_UNREADABLE = "the provider's structured output could not be read"
    FAILURE_INCOMPLETE = "the provider's structured output ended mid-message"
    FAILURE_NO_RESULT = "the provider produced no terminal result"
    FAILURE_TWO_RESULTS = "the provider reported more than one terminal result"
    FAILURE_RESULT_TOO_LARGE = "the provider's terminal result exceeded #{MAX_RESULT_BYTES} bytes"

    # `sink` receives `(stream_name, text)` exactly as CommandRunner's own consumer does, so the
    # existing ExecutorLogStream is the fan-out owner and this class shows nothing itself.
    #
    # `repository_path` is the assigned worktree, or nil for a lane that has none. MAPIAI-77 makes
    # it the ONE approved root: it is the only filesystem location this boundary can prove a path
    # belongs to, so it is the only prefix a public path may be shown relative to. A lane without
    # one (specification creation, whose provider works in a private temporary directory) can
    # prove nothing and therefore shows no absolute path at all.
    # `refusals`, when given, is the attempt's question bridge counting the question turns it has
    # refused back to this same provider process. A lane without a bridge passes nothing and keeps
    # the strict one-result rule.
    def initialize(sink: nil, repository_path: nil, refusals: nil)
      @sink = sink
      @refusals = refusals
      @text = PublicProgress.new(repository_path: repository_path)
      @pending = +""
      @result = nil
      @result_seen = false
      @result_refusals = 0
      @superseded = 0
      @failure = nil
      @diagnostic_reported = false
    end

    # The consumer handed to CommandRunner. Every line the provider writes comes through here.
    def sink = ->(source, line) { accept(source, line) }

    def accept(source, line)
      return diagnostic unless source == CommandRunner::STDOUT
      # After a fatal decode failure nothing later in the stream can be trusted, so nothing
      # later in the stream is shown.
      return if @failure

      decode(line.to_s)
    end

    # stderr is provider bytes, not structured output, and it never passed this allowlist:
    # review 001 sent an account-like email and an absolute home path there and both reached the
    # public sink. Its bytes are therefore not forwarded at all. ONE bounded notice records that
    # the provider wrote diagnostics; the COMPLETE stderr still reaches the report through the
    # buffered capture, which this class does not touch (CR-001 F2).
    def diagnostic
      return if @diagnostic_reported

      @diagnostic_reported = true
      forward(CommandRunner::STDERR, DIAGNOSTIC)
    end

    # Ends the stream and applies the two rules that cannot be checked one message at a time.
    # Returns self so a caller can read `failure` in the same expression.
    def close
      return self if @failure

      return fail!(FAILURE_INCOMPLETE) unless @pending.empty?
      return fail!(FAILURE_NO_RESULT) unless @result_seen

      self
    end

    # Why the stream is unusable, or nil. A reason NEVER contains provider bytes.
    attr_reader :failure

    # The terminal result, for the existing report/package parsers. Empty when the stream failed,
    # because a stream this object refused must not hand anything to a parser.
    def final_text = @failure ? "" : @result.to_s

    private

    def decode(line)
      @pending << line
      return fail!(FAILURE_UNREADABLE) if @pending.bytesize > MAX_PENDING_BYTES

      value = parse(@pending)
      # Not yet a complete message: CommandRunner splits a long line at its own pending cap, so
      # an unparseable buffer is normally a fragment. A buffer that is genuinely malformed never
      # completes and is caught by the byte cap or by `close`.
      return if value.nil?

      @pending = +""
      # Valid JSON that is not a message object means the stream is not what this decoder
      # contracted for, and continuing would be guessing.
      value.is_a?(Hash) ? handle(value) : fail!(FAILURE_UNREADABLE)
    end

    def parse(text)
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end

    def handle(message)
      capture_result(message) if message["type"].to_s == "result"
      return if @failure

      statuses(message).each { |text| forward(STATUS, text) }
    end

    # ---- the public transcript ----------------------------------------------
    #
    # CR-005: what an operator reads must be the provider's own public transcript, not a title
    # per event. Every PUBLIC item the supported stream-json contract carries is rendered here —
    # narration, the tool and its description, the exact command, its stdout and stderr, file
    # paths and contents, the before/after of an edit, delegated Task input and output, and the
    # provider's own timing — in the order the provider emitted it.
    #
    # Two things, and only two, are still withheld: the model's `thinking` blocks, which are the
    # private reasoning the CLI itself does not present as public text, and the JSONL wrappers
    # themselves. Credentials are not filtered here at all: {Redaction} is the ONE boundary that
    # removes them, and it already runs over every line on its way to both surfaces.
    def statuses(message)
      case message["type"].to_s
      when "system" then system_lines(message)
      when "assistant" then assistant_lines(message)
      when "user" then result_lines(message)
      when "result" then [ terminal_status(message) ]
      when "rate_limit_event" then rate_limit_lines(message)
      else []
      end
    end

    # `system/thinking_tokens` carries an estimated token COUNT and no duration, so it cannot
    # reproduce the Claude Code UI's "Thought for 1s" and is not rendered: a running count of
    # tokens for reasoning the operator may not read is noise, not status. The contract has no
    # thinking-duration field to render instead. Public timing does reach the operator — from
    # the terminal `result`, which reports the run's own duration and turn count.
    def system_lines(message)
      message["subtype"].to_s == "init" ? [ STARTED ] : []
    end

    def rate_limit_lines(message)
      info = message["rate_limit_info"]
      return [] unless info.is_a?(Hash)

      [ "#{RATE_LIMIT}: #{info['status']} (#{info['rateLimitType']})" ]
    end

    def assistant_lines(message)
      blocks(message).flat_map do |block|
        case block["type"].to_s
        when "text" then bounded(block["text"].to_s)
        when "tool_use" then tool_use_lines(block)
        else []                                  # `thinking` and anything else: never public
        end
      end
    end

    def blocks(message)
      content = message.dig("message", "content")
      content.is_a?(Array) ? content.grep(Hash) : []
    end

    # The call as the operator would read it: what ran, why, and — for an edit — exactly what
    # changed. `input` is the provider's own public tool input; it is shown rather than
    # summarized, because a summary is what made the old log useless.
    def tool_use_lines(block)
      name = block["name"].to_s
      input = block["input"].is_a?(Hash) ? block["input"] : {}
      [ "> #{name}#{subject(input) && " #{subject(input)}"}" ] +
        indent(input["description"].to_s) + indent(*call_body(name, input))
    end

    def subject(input)
      value = SUBJECT_KEYS.filter_map { |key| input[key] }.first
      value.to_s.empty? ? nil : clip_line(redact(value))
    end

    # What is worth showing BEYOND the subject line. The specialized forms come first because an
    # edit's before/after and a delegated Task's prompt are the point of those events; everything
    # else the tool declared publicly is then rendered by ONE generic renderer, so a new tool's
    # input is shown rather than silently dropped (CR-006 F2). No per-tool registry, and nothing
    # already shown above is repeated.
    def call_body(name, input)
      specialized =
        if input.key?("new_string") then diff(input["old_string"], input["new_string"])
        elsif name == "Write" then bounded(input["contents"] || input["content"])
        elsif input.key?("prompt") then bounded(input["prompt"])
        else []
        end
      specialized + generic_input(input)
    end

    # Every remaining public input field, in the provider's own key order so two identical calls
    # render identically. Wrapper identity (`id`, `caller`, `type`) belongs to the transport and
    # is never printed.
    def generic_input(input)
      (input.keys - SUBJECT_KEYS - SPECIALIZED_KEYS - WRAPPER_KEYS).filter_map do |key|
        rendered = render_value(input[key])
        rendered.empty? ? nil : clip_line("#{key}: #{rendered}")
      end
    end

    # A public value as an operator would read it: a scalar as itself, a list comma-separated, an
    # object as `key=value` pairs. Never a Ruby or JSON transport dump.
    def render_value(value, depth = 0)
      case value
      when nil then ""
      when String then redact(value).tr("\n", " ").strip
      when Array then depth < MAX_VALUE_DEPTH ? value.map { |v| render_value(v, depth + 1) }.reject(&:empty?).join(", ") : ""
      when Hash
        return "" unless depth < MAX_VALUE_DEPTH

        value.filter_map { |k, v| "#{k}=#{render_value(v, depth + 1)}" unless render_value(v, depth + 1).empty? }.join(", ")
      else value.to_s
      end
    end

    def diff(before, after)
      bounded(before).map { |line| "-#{line}" } + bounded(after).map { |line| "+#{line}" }
    end

    # A tool result. `tool_use_result` is the structured form the contract provides and is
    # preferred because it separates stdout from stderr and names the file it read; the
    # `tool_result` block's own `content` is the fallback when there is no structured form.
    # CR-006 F3: EVERY result states its disposition exactly once, including a success that
    # produced no output at all — silence used to be indistinguishable from an interruption.
    # The three dispositions come only from fields the real capture carries: the block's own
    # `is_error`, and `tool_use_result.interrupted`. No timeout is inferred from anything else.
    def result_lines(message)
      detail = message["tool_use_result"]
      blocks(message).flat_map do |block|
        next [] unless block["type"].to_s == "tool_result"

        [ disposition(block, detail) ] + indent(*outcome(detail, block["content"]))
      end
    end

    def disposition(block, detail)
      return FAILED_STEP if block["is_error"]
      return INTERRUPTED_STEP if detail.is_a?(Hash) && detail["interrupted"]

      COMPLETED_STEP
    end

    def outcome(detail, fallback)
      return bounded(fallback) unless detail.is_a?(Hash)
      # A background/TaskOutput poll, exactly as the supported CLI emitted it in the CR-006
      # probe: the answer is the task's own output, not the retrieval envelope around it.
      return bounded(detail.dig("task", "output")) if detail["task"].is_a?(Hash)
      return bounded(detail.dig("file", "content")) if detail["file"].is_a?(Hash)
      # An edit's change was already shown as the diff on the call itself.
      return [] if detail.key?("oldString")
      return bounded(detail["stdout"]) + bounded(detail["stderr"]) if detail.key?("stdout")

      bounded(fallback)
    end

    def terminal_status(message)
      outcome = message["is_error"] || message["subtype"].to_s != "success" ? FAILED : COMPLETED
      "#{outcome}#{timing(message)}"
    end

    # The provider's own public timing, when it reports it.
    def timing(message)
      duration, turns = message["duration_ms"], message["num_turns"]
      return "" unless duration.is_a?(Numeric) || turns.is_a?(Numeric)

      parts = []
      parts << "#{(duration / 1000.0).round(1)}s" if duration.is_a?(Numeric)
      parts << "#{turns} turns" if turns.is_a?(Numeric)
      " in #{parts.join(', ')}"
    end

    # ---- bounds and path policy ---------------------------------------------
    #
    # Asked of {PublicProgress}, which owns them for every lane that has an approved root.

    def bounded(value) = @text.bounded(value)
    def indent(*values) = @text.indent(*values)
    def redact(value) = @text.redact(value)
    def clip_line(line) = @text.clip_line(line)

    # ---- the terminal result ------------------------------------------------

    # ONE result, with one causal exception. A refused question turn ends in a result frame of its
    # own and the session then continues, so a held result may be SUPERSEDED by a later frame — from
    # the same process, on the same stream — when a refusal the bridge recorded BEFORE the held
    # result has not already explained an earlier one. Nothing else lets a second result through:
    # no refusal, a refusal recorded only after the result, or one more result than refusals all
    # still fail closed. A superseded result is dropped, never kept in a list, and never shown.
    def capture_result(message)
      return fail!(FAILURE_TWO_RESULTS) if @result_seen && !supersede

      text = message["result"].to_s
      return fail!(FAILURE_RESULT_TOO_LARGE) if text.bytesize > MAX_RESULT_BYTES

      @result_seen = true
      @result = text
      @result_refusals = refusals_observed
    end

    # Explaining the held result spends one refusal, so the allowance is exactly the count.
    def supersede
      return false unless @result_refusals > @superseded

      @superseded += 1
      true
    end

    def refusals_observed = @refusals ? @refusals.call.to_i : 0

    # ---- output -------------------------------------------------------------

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
