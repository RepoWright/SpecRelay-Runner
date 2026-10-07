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
  # Erasing is CR-and-spaces only — no `\e[K`. That would be shorter but assumes the sink
  # understands it; returning the cursor and overwriting with spaces is true of every
  # terminal, and keeps a captured transcript readable.
  #
  # WHICH WORK A LINE BELONGS TO is the one fact the output could not answer. A machine left
  # in `loop` mode writes one run after another into the same scrollback, so the presenter
  # carries the ticket key of the run that is active and puts it in front of every logical
  # line and the transient row. It is SET from outside rather than derived here: nothing in
  # this class parses a key out of a message, and a presenter holding none writes exactly
  # what it wrote before.
  #
  # A loop session also draws two FRAMES. A run's result is a framed durable block. Its waiting
  # state is a framed transient REGION of several rows, drawn below that result and redrawn in
  # place; on a terminal too small to hold it whole, the one-row status stands in for it. Moving
  # back over several rows needs cursor control, so the region is erased with cursor-up and
  # erase-below — the same erase-before-every-durable-write rule, under the same mutex. Both are
  # MEASURED as plain text after redaction and RENDERED with colour, which never carries a state
  # on its own: every state also has its text label.
  #
  # It owns rendering and nothing else. Claim, eligibility, execution, upload, and
  # report decisions stay with their own objects.
  class TerminalPresenter
    DEFAULT_COLUMNS = 96
    DEFAULT_LINES = 24
    # Every frame shares one left edge and this outer width, so a result and the waiting region
    # below it line up however wide the window is.
    FRAME_WIDTH = 60
    # Inside the borders and their one-character padding.
    FRAME_INNER = FRAME_WIDTH - 4
    # Corners, horizontal and vertical edge, and the countdown ink — with an ASCII equivalent for
    # a terminal whose encoding cannot show box drawing.
    BOX = { top_left: "┌", top_right: "┐", bottom_left: "└", bottom_right: "┘", across: "─", side: "│",
            ink: "█" }.freeze
    PLAIN_BOX = { top_left: "+", top_right: "+", bottom_left: "+", bottom_right: "+", across: "-", side: "|",
                  ink: "#" }.freeze
    TONES = { green: "32", amber: "33", red: "31", blue: "34", cyan: "36" }.freeze
    # Five-row character-cell digits for the countdown.
    DIGITS = {
      "0" => [ "###", "# #", "# #", "# #", "###" ], "1" => [ " # ", "## ", " # ", " # ", "###" ],
      "2" => [ "###", "  #", "###", "#  ", "###" ], "3" => [ "###", "  #", "###", "  #", "###" ],
      "4" => [ "# #", "# #", "###", "  #", "  #" ], "5" => [ "###", "#  ", "###", "  #", "###" ],
      "6" => [ "###", "#  ", "###", "# #", "###" ], "7" => [ "###", "  #", "  #", "  #", "  #" ],
      "8" => [ "###", "# #", "###", "# #", "###" ], "9" => [ "###", "# #", "###", "  #", "###" ]
    }.freeze
    # Colour for the ticket key and nothing else, in the one style TerminalMenu already uses
    # for emphasis. Applied only to a terminal, and never carrying information on its own:
    # the key is bracketed plain text first, so a pipe, a CI log, and a screenshot all still
    # name the ticket.
    KEY_STYLE = "36"
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
      @ticket_key = nil
    end

    def transient? = @transient

    # The ticket whose run is producing output right now, or nil between runs.
    #
    # Under the same mutex as every write, so a heartbeat timer or an executor reader thread
    # cannot observe half a change — and so a line can only ever carry the key of the run that
    # was active when it was written. Blank is the same as nothing: an assignment that states
    # no key prefixes nothing rather than printing an empty pair of brackets.
    def ticket_key=(key)
      stated = key.to_s.strip
      @mutex.synchronize { @ticket_key = stated.empty? ? nil : stated }
    end

    # The terminal's own width, read on every draw so a resized window is respected. Only an
    # UNREPORTED width falls back to a default.
    def columns
      return @fixed_columns if @fixed_columns

      reported = @out.respond_to?(:winsize) ? @out.winsize[1].to_i : 0
      reported.positive? ? reported : DEFAULT_COLUMNS
    rescue IOError, SystemCallError, NoMethodError
      DEFAULT_COLUMNS
    end

    # The terminal's own height, read on every draw like the width.
    def lines
      reported = @out.respond_to?(:winsize) ? @out.winsize[0].to_i : 0
      reported.positive? ? reported : DEFAULT_LINES
    rescue IOError, SystemCallError, NoMethodError
      DEFAULT_LINES
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

    # A framed block that stays in the record. `emphasis` is the index of the row that names the
    # state. A sink that cannot show the frame whole — no terminal, or one narrower than the
    # frame — gets the same rows as plain lines.
    def frame(rows, tone:, emphasis: nil)
      texts = rows.map { |row| Redaction.redact(row.to_s) }
      @mutex.synchronize do
        next write_line(texts.join("\n")) unless @transient && columns > FRAME_WIDTH

        erase
        push_text(@out, "\n#{framed(texts, tone, emphasis).map { |_, painted| "#{painted}\n" }.join}")
        nil
      end
    end

    # The framed waiting region, redrawn in place. A row given as `[seconds, label]` is the
    # countdown: large centered digits with their label. `compact` is the one-row status shown
    # instead when the frame does not fit the terminal. Like `status`, it is dropped when there
    # is no terminal to redraw.
    def panel(rows, tone:, compact:, emphasis: nil)
      texts = rows.map { |row| row.is_a?(Array) ? [ row[0].to_i, Redaction.redact(row[1].to_s) ] : Redaction.redact(row.to_s) }
      summary = Redaction.redact(compact.to_s)
      @mutex.synchronize do
        next nil unless @transient && !@finished

        block = framed(texts, tone, emphasis)
        block.length < lines - 1 && columns > FRAME_WIDTH ? draw_region(block) : draw(summary)
      end
    end

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
    #
    # The row is MEASURED as the plain text it occupies and RENDERED with the key painted.
    # Escape sequences have length but occupy no columns, so clipping or padding a painted
    # string would turn one row into two and leave debris behind a shorter replacement.
    def draw(message)
      text = clip(prefixed("#{glyph} #{message}"))
      erase unless single_row?
      padding = " " * [ @rendered.to_a.first.to_s.length - text.length, 0 ].max
      @rendered = [ text ]
      push_text(@out, "\r#{paint_key(text, @out)}#{padding}\r")
      nil
    rescue IOError, SystemCallError
      @transient = false
      @rendered = nil
      nil
    end

    # The region's blank separator row, then the frame, as one write; the cursor is then moved
    # back to the separator row. Parking it at the TOP is what makes the erase resize-safe: rows a
    # narrowing terminal reflows grow below the cursor, and erasing everything below it removes
    # them however many rows they became, without touching the history above.
    def draw_region(block)
      visible = [ "", *block.map(&:first) ]
      return nil if visible == @rendered

      bytes = "#{erase_bytes}\n#{block.map(&:last).join("\n")}\e[#{block.length}A\r"
      @rendered = visible
      push_text(@out, bytes)
      nil
    rescue IOError, SystemCallError
      @transient = false
      @rendered = nil
      nil
    end

    # `@rendered` is cleared FIRST, so a sink that fails here cannot leave the
    # presenter believing a row is still on screen.
    def erase
      bytes = erase_bytes
      @rendered = nil
      push_text(@out, bytes) unless bytes.empty?
      nil
    rescue IOError, SystemCallError
      nil
    end

    # One row that still fits is overwritten with spaces, as it always was. A region, or a row a
    # narrowing resize has wrapped, is erased from the cursor — parked at its top — downwards.
    def erase_bytes
      return "" if @rendered.nil?
      return "\r#{' ' * @rendered.first.length}\r" if single_row?

      "\r\e[J"
    end

    def single_row? = @rendered.nil? || (@rendered.length == 1 && @rendered.first.length < columns)

    # The frame's rows as [measured, painted] pairs: borders in the tone's colour, the emphasised
    # row bold in it, and every row padded to the same width so the frame never stretches.
    def framed(texts, tone, emphasis)
      box = glyphs
      color = TONES.fetch(tone)
      edge = paint(box[:side], color)
      body = texts.each_with_index.flat_map do |text, index|
        next countdown(*text, box[:ink]).map { |row| [ row, row ] } if text.is_a?(Array)

        wrap(text).map do |row|
          padded = row.ljust(FRAME_INNER)
          [ padded, index == emphasis ? "#{paint(row, "1;#{color}")}#{padded[row.length..]}" : padded ]
        end
      end
      top = "#{box[:top_left]}#{box[:across] * (FRAME_WIDTH - 2)}#{box[:top_right]}"
      bottom = "#{box[:bottom_left]}#{box[:across] * (FRAME_WIDTH - 2)}#{box[:bottom_right]}"
      [ [ top, paint(top, color) ],
        *body.map { |row, painted| [ "#{box[:side]} #{row} #{box[:side]}", "#{edge} #{painted} #{edge}" ] },
        [ bottom, paint(bottom, color) ] ]
    end

    # Every digit is drawn; the digits and their label are the only centered rows.
    def countdown(seconds, label, ink)
      digits = seconds.to_s.chars.map { |char| DIGITS.fetch(char) }
      rows = Array.new(5) { |row| digits.map { |digit| digit[row] }.join(" ").tr("#", ink) }
      [ *rows, label ].map { |row| row.center(FRAME_INNER) }
    end

    # Word-wrapped to the frame's inner width; a word longer than a whole row is split.
    def wrap(text)
      rows = []
      text.split.each do |word|
        word.scan(/.{1,#{FRAME_INNER}}/) do |piece|
          next rows.last << " " << piece if rows.last && rows.last.length + piece.length < FRAME_INNER

          rows << piece.dup
        end
      end
      rows.empty? ? [ "" ] : rows
    end

    # Box drawing is shown only where the sink's encoding can carry it.
    def glyphs
      encoding = @out.respond_to?(:external_encoding) && @out.external_encoding || Encoding.default_external
      encoding == Encoding::UTF_8 ? BOX : PLAIN_BOX
    end

    def paint(text, style) = "\e[#{style}m#{text}\e[0m"

    # Durable writes are deliberately NOT guarded: a broken stdout is a real
    # failure for a record the operator is relying on, and swallowing it here
    # would change the failure semantics every existing writer has today.
    #
    # LOGICAL lines, not visual ones. A message carrying embedded newlines already became
    # several rows from one call, so each of them is prefixed; a row the terminal wraps
    # because it is wider than the window is not, because the prefix is attached when the
    # line is written and not when it is displayed. Still ONE write, so a concurrent status
    # frame cannot land in the middle of a multiline message.
    def write_line(message, sink: out)
      erase
      push_text(sink, logical_rows(message).map { |row| "#{paint_key(prefixed(row), sink)}\n" }.join)
      nil
    end

    # The logical lines of a message. `split` answers an EMPTY message with no lines at all,
    # which would silently drop the blank separator line `puts`/`line("")` has always written;
    # an empty message is one empty line, exactly as it was before.
    def logical_rows(message)
      rows = message.split("\n", -1)
      rows.empty? ? [ "" ] : rows
    end

    # The key as it is MEASURED: plain text, no escape sequences.
    def key_token = @ticket_key && "[#{@ticket_key}]"

    def prefixed(text)
      token = key_token
      token.nil? ? text : "#{token} #{text}"
    end

    # Painted only on a terminal, and only over a string that still opens with the whole
    # plain token — a row clipped to a very narrow width keeps its text rather than being
    # handed half an escape sequence.
    def paint_key(text, sink)
      token = key_token
      return text if token.nil? || !text.start_with?(token) || !self.class.terminal?(sink)

      "\e[#{KEY_STYLE}m#{token}\e[0m#{text[token.length..]}"
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
