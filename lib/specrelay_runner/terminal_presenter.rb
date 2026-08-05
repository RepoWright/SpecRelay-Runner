# frozen_string_literal: true

require "io/console"

module SpecrelayRunner
  # The one place the runner writes to an operator's terminal while something is
  # running (RUNNER-0001 scope 2).
  #
  # It exists because two kinds of output were being written to one stream by three
  # different threads. `[loop] waiting`/`idle`/`sleeping` turned "nothing happened"
  # into three permanent lines per poll, so a runner left open for an afternoon
  # buried the claims and executor output an operator actually needs. The fix is not
  # fewer facts — it is telling the two kinds apart:
  #
  #   TRANSIENT status is what is true RIGHT NOW and worthless afterwards: polling,
  #     a countdown, a quiet executor. It occupies ONE reusable row, replaces itself
  #     in place, and leaves no history behind.
  #   DURABLE lines are the record: claims, real executor output, failures, results.
  #     They are newline-terminated and never overwritten.
  #
  # The invariant that makes them safe together: the transient row is ERASED before
  # any durable write, and every write goes through one mutex — so a heartbeat
  # timer, an executor reader thread, and the loop cannot interleave half a row with
  # a durable line.
  #
  # CAPABILITY, NOT CLASS. Transient rendering needs an output terminal that can
  # redraw a row; it does not need an input terminal (that is
  # `TerminalMenu.interactive?`, which reads keys). A pipe, a log file, or a CI step
  # gets the same facts as plain lines with no cursor control at all: erasing a row
  # that a log file will keep forever produces garbage, not animation.
  #
  # Rendering is CR-and-spaces only — no ANSI, no colour. A `\e[K` would be shorter
  # but assumes the sink understands it; returning the cursor and overwriting with
  # spaces is true of every terminal, and keeps a captured transcript readable.
  #
  # It owns rendering and nothing else. Claim, eligibility, execution, upload, and
  # report decisions stay with their own objects.
  class TerminalPresenter
    DEFAULT_COLUMNS = 96
    # A floor for the CLIP only, so a degenerate width cannot ask for a negative slice. The
    # reported width is never rounded UP the way TerminalMenu rounds a menu frame: a menu that
    # overflows a very narrow terminal is ugly, but a transient row that overflows becomes a
    # SECOND ROW, and one row is the whole property.
    MINIMUM_CLIP = 8
    # Rotated on each redraw so the row visibly changes even when the words do not.
    # ASCII, because this is decoration and a transcript should stay legible.
    GLYPHS = [ "|", "/", "-", "\\" ].freeze

    # The normal constructor: capability is read from the sink rather than assumed.
    def self.for(out: $stdout, err: $stderr) = new(out: out, err: err, transient: terminal?(out))

    # Accepts either a presenter (returned as-is, so a caller that already has one
    # keeps the single write boundary) or a plain IO to wrap. This is what lets
    # ExecutorLogStream take `io:` from anywhere and still coordinate its writes.
    def self.wrap(io, err: nil)
      return io if io.is_a?(TerminalPresenter)

      new(out: io, err: err || io, transient: terminal?(io))
    end

    def self.terminal?(io)
      io.respond_to?(:tty?) && io.tty? ? true : false
    rescue IOError, SystemCallError
      false
    end

    # `columns` is injectable so a narrow-terminal test needs no terminal.
    def initialize(out:, err: nil, transient: false, columns: nil)
      @out = out
      @err = err || out
      @transient = transient ? true : false
      @fixed_columns = columns
      @mutex = Mutex.new
      @rendered = nil
      @frame = -1
      @finished = false
    end

    def transient? = @transient

    # The terminal's own width, read on every draw so a resized window is respected. Only an
    # UNREPORTED width falls back to a default.
    def columns
      return @fixed_columns if @fixed_columns

      reported = @out.respond_to?(:winsize) ? @out.winsize[1].to_i : 0
      reported.positive? ? reported : DEFAULT_COLUMNS
    rescue IOError, SystemCallError, NoMethodError
      DEFAULT_COLUMNS
    end

    # Show the current state on the reusable row.
    #
    # `fallback: :line` is for progress that still MATTERS with no terminal to
    # redraw — a quiet executor's elapsed time in a CI log. Plain `status` is for
    # progress that is worthless as history (a countdown), and is simply dropped
    # when there is no row to put it on.
    def status(text, fallback: nil)
      message = Redaction.redact(text.to_s)
      @mutex.synchronize do
        next write_line(message) if !@transient && fallback == :line
        next nil unless @transient && !@finished

        draw(message)
      end
    end

    def clear_status = @mutex.synchronize { erase }

    def line(text = "") = @mutex.synchronize { write_line(Redaction.redact(text.to_s)) }
    def error(text = "") = @mutex.synchronize { write_line(Redaction.redact(text.to_s), sink: @err) }

    # End transient rendering for good: the row is erased and no later `status`
    # can put one back. Called from an `ensure`, so it must never raise.
    def finish
      @mutex.synchronize do
        erase
        @finished = true
      end
      nil
    end

    # --- IO-compatible surface -----------------------------------------------
    #
    # Heartbeater, Execution, Publication, and the specification lanes all write
    # with `io.puts` and guard on `io.respond_to?(:flush)`. Answering those two
    # means a presenter can be passed wherever an IO was, and every one of those
    # writers clears the transient row without knowing it exists.

    def puts(text = "") = line(text)
    def flush = @mutex.synchronize { push(@out) }

    private

    attr_reader :out, :err

    # Overwrite the row, then pad with spaces to cover a longer previous message
    # and return the cursor to column 0 — so a shorter replacement leaves no tail
    # behind and a durable line starts where it should.
    #
    # Guarded: the row is decoration, and a terminal that refuses it must not take
    # a run down. Transient rendering switches itself off rather than retrying.
    def draw(message)
      text = clip("#{glyph} #{message}")
      padding = " " * [ @rendered.to_s.length - text.length, 0 ].max
      @rendered = text
      push_text(@out, "\r#{text}#{padding}\r")
      nil
    rescue IOError, SystemCallError
      @transient = false
      @rendered = nil
      nil
    end

    # `@rendered` is cleared FIRST, so a sink that fails here cannot leave the
    # presenter believing a row is still on screen.
    def erase
      target = @rendered
      return nil if target.nil?

      @rendered = nil
      push_text(@out, "\r#{' ' * target.length}\r")
      nil
    rescue IOError, SystemCallError
      nil
    end

    # Durable writes are deliberately NOT guarded: a broken stdout is a real
    # failure for a record the operator is relying on, and swallowing it here
    # would change the failure semantics every existing writer has today.
    def write_line(message, sink: out)
      erase
      push_text(sink, "#{message}\n")
      nil
    end

    def push_text(sink, bytes)
      sink.print(bytes)
      push(sink)
    end

    # Live output has to be flushed to be live: Ruby block-buffers a non-terminal
    # stdout, so a redirected loop would otherwise show nothing until it exited.
    def push(sink)
      sink.flush if sink.respond_to?(:flush)
    end

    def glyph = GLYPHS[(@frame += 1) % GLYPHS.length]

    # Clipped to one column short of the width: a row that exactly fills the
    # terminal wraps on some of them, and a wrapped transient row is two rows.
    def clip(text)
      limit = [ columns - 1, MINIMUM_CLIP ].max
      text.length <= limit ? text : "#{text[0, limit - 1]}…"
    end
  end
end
