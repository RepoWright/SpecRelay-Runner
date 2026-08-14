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
  # PROJECTION IS AN ALLOWLIST, not a filter. Only the facts named below reach a surface; every
  # other field — prompts, reasoning, assistant prose, raw tool inputs and results, file content,
  # environment, account identity, model, cwd, MCP configuration — is simply never read. A valid
  # message this decoder does not recognize produces one bounded generic status rather than its
  # object, so a future CLI cannot leak by being new.
  #
  # FAIL CLOSED. Malformed output, no terminal result, or two terminal results all mean the
  # runner can no longer prove which bytes are progress and which are the authoritative result.
  # It refuses both rather than guessing, and it never displays or stores the offending frame.
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
    # A previewed command line, kept short enough to read on one terminal row.
    MAX_COMMAND_CHARS = 120

    # The runner's own stream name for normalized progress — an existing `log_source` value, not
    # a new one, so the wire contract and the Platform panel are unchanged.
    STATUS = "status"

    STARTED = "Provider started"
    ACTIVITY = "Provider activity"
    GENERIC_COMMAND = "Running a command"
    STEP_COMPLETED = "Step completed"
    STEP_FAILED = "Step failed"
    COMPLETED = "Provider completed"
    FAILED = "Provider failed"
    DIAGNOSTIC = "Provider wrote diagnostic output"

    # Tool categories, matched case-insensitively so a renamed-casing tool still projects safely.
    READ_TOOLS = %w[read glob grep notebookread].freeze
    EDIT_TOOLS = %w[edit write multiedit notebookedit].freeze
    COMMAND_TOOLS = %w[bash bashoutput].freeze

    # A command may be PREVIEWED only when EVERY token is a fact this class already recognises:
    # an approved executable, one of a closed set of subcommands, or a path the existing
    # repository-containment projection proves. What is shown is then REBUILT from those facts —
    # provider text is never echoed.
    #
    # CR-001 F2: the previous rule was a permissive character pattern over the whole line, which
    # passed `python3 /Users/alice/private.py` and `bundle exec rspec --seed <secret>` intact. A
    # pattern says what a string looks like; only an allowlist says what it is.
    PREVIEWABLE_COMMANDS = %w[bundle rake rails rspec ruby rubocop npm npx yarn pnpm node
                              pytest python python3 go cargo make bin/rails bin/rspec
                              bin/rake bin/dev].freeze
    PREVIEWABLE_WORDS = %w[exec run test check lint build install ci].freeze
    # A path-shaped token: no shell metacharacter, no whitespace, and an actual separator or
    # extension, so a bare word can never be mistaken for a repository-relative path.
    PATH_TOKEN = %r{\A[A-Za-z0-9_./-]+\z}
    TEST_HINT = /\b(test|tests|spec|specs|rspec|minitest|pytest|jest)\b/i

    FAILURE_UNREADABLE = "the provider's structured output could not be read"
    FAILURE_INCOMPLETE = "the provider's structured output ended mid-message"
    FAILURE_NO_RESULT = "the provider produced no terminal result"
    FAILURE_TWO_RESULTS = "the provider reported more than one terminal result"
    FAILURE_RESULT_TOO_LARGE = "the provider's terminal result exceeded #{MAX_RESULT_BYTES} bytes"

    # `sink` receives `(stream_name, text)` exactly as CommandRunner's own consumer does, so the
    # existing ExecutorLogStream is the fan-out owner and this class shows nothing itself.
    # `repository_path` is the assigned worktree, or nil for a lane that has none — a path may
    # only be shown when containment in it is provable, so nil means no path is ever shown.
    def initialize(sink: nil, repository_path: nil)
      @sink = sink
      @repository_path = repository_path && File.expand_path(repository_path.to_s)
      @pending = +""
      @result = nil
      @result_seen = false
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

    attr_reader :repository_path

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

    # ---- projection ---------------------------------------------------------

    def statuses(message)
      case message["type"].to_s
      when "system" then [ message["subtype"].to_s == "init" ? STARTED : ACTIVITY ]
      when "assistant" then tool_statuses(message)
      when "user" then tool_result_statuses(message)
      when "result" then [ terminal_status(message) ]
      else [ ACTIVITY ]
      end
    end

    # Only `tool_use` blocks are read. Assistant text and reasoning are not progress and are not
    # this product: an operator watching a run must never be shown private model prose.
    def tool_statuses(message)
      blocks(message).select { |block| block["type"].to_s == "tool_use" }.map { |block| tool_status(block) }
    end

    # A tool result says only that a step ended and how. Its content is raw provider/tool output
    # — file bytes, command output, stack traces — and is never read.
    def tool_result_statuses(message)
      blocks(message).select { |block| block["type"].to_s == "tool_result" }
                     .map { |block| block["is_error"] ? STEP_FAILED : STEP_COMPLETED }
    end

    def blocks(message)
      content = message.dig("message", "content")
      content.is_a?(Array) ? content.grep(Hash) : []
    end

    def tool_status(block)
      name = block["name"].to_s.downcase
      input = block["input"].is_a?(Hash) ? block["input"] : {}
      return path_status("Inspecting", input) if READ_TOOLS.include?(name)
      return path_status("Editing", input) if EDIT_TOOLS.include?(name)
      return command_status(input) if COMMAND_TOOLS.include?(name)

      ACTIVITY
    end

    def path_status(verb, input)
      path = contained_path(input["file_path"] || input["path"] || input["notebook_path"])
      path ? "#{verb} #{path}" : "#{verb} a file"
    end

    # A path is shown ONLY when it is provably inside the assigned repository. `expand_path`
    # resolves `..` first, so a traversal-shaped value is compared as the location it really
    # names rather than as the string it was written as.
    def contained_path(value)
      raw = value.to_s
      return nil if repository_path.nil? || raw.empty?

      absolute = File.expand_path(raw, repository_path)
      return nil unless absolute.start_with?("#{repository_path}#{File::SEPARATOR}")

      absolute.delete_prefix("#{repository_path}#{File::SEPARATOR}")
    end

    def command_status(input)
      preview = previewable_command(input["command"])
      return GENERIC_COMMAND if preview.nil?

      "#{TEST_HINT.match?(preview) ? 'Running test command' : 'Running command'}: #{preview}"
    end

    def previewable_command(value)
      text = value.to_s.strip
      return nil if text.empty? || text.length > MAX_COMMAND_CHARS

      tokens = text.split(/\s+/)
      return nil unless PREVIEWABLE_COMMANDS.include?(tokens.first)

      projected = tokens.map { |token| approved_token(token) }
      projected.all? ? projected.join(" ") : nil
    end

    # The token as it may be SHOWN, or nil when it is not an approved fact. A path is returned as
    # its repository-relative projection — the same rule a tool path passes — so an absolute or
    # escaping path is refused here rather than displayed.
    def approved_token(token)
      return token if PREVIEWABLE_COMMANDS.include?(token) || PREVIEWABLE_WORDS.include?(token)
      return nil unless PATH_TOKEN.match?(token) && token.match?(%r{[/.]})

      contained_path(token)
    end

    def terminal_status(message)
      message["is_error"] || message["subtype"].to_s != "success" ? FAILED : COMPLETED
    end

    # ---- the terminal result ------------------------------------------------

    def capture_result(message)
      return fail!(FAILURE_TWO_RESULTS) if @result_seen

      text = message["result"].to_s
      return fail!(FAILURE_RESULT_TOO_LARGE) if text.bytesize > MAX_RESULT_BYTES

      @result_seen = true
      @result = text
    end

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
