# frozen_string_literal: true

require "io/console"

module SpecrelayRunner
  # A small keyboard-driven terminal menu (MVP-0021 scope 1).
  #
  # Deliberately tiny and deliberately ignorant. It knows how to hold a terminal in raw mode,
  # draw a list, decide what a keypress means, and give the answer back. It knows nothing
  # about connections, claims, Platform, or credentials — which is what keeps the dashboard a
  # presentation layer instead of a second implementation of runner behaviour.
  #
  # It matches `./bin/worktree`'s menu on purpose, so a SpecRelay operator learns one set of
  # keys: immediate single-key shortcuts (no Enter, no timing guesswork), arrow keys moving a
  # highlight that Enter then runs, and Esc or Ctrl-C cancelling out of the current view.
  #
  # Standard library only (`io/console`), like the rest of the runner.
  #
  # TERMINAL STATE IS THE HARD PART, and getting it wrong is worse than an ugly menu: a leaked
  # raw mode leaves the operator's shell with no echo and no working Ctrl-C after the program
  # exits. Three defences:
  #
  #   1. Raw mode is only ever entered through `IO#raw` WITH A BLOCK, whose ensure restores
  #      the previous attributes on a normal return, an exception, a `throw`, or a signal.
  #   2. Raw mode disables output post-processing, so every rendered line ends with an
  #      explicit CR+LF. Without that, output "staircases" down and to the right.
  #   3. `#restore` re-asserts cooked mode before anything that is not this menu writes to the
  #      terminal, so dispatched command output can never inherit a raw mode that a
  #      pathological terminal failed to restore.
  #
  # `resolve_key` is a PURE function and public, so every key binding — including Ctrl-C and
  # Escape — is unit-tested without a terminal, a pty, or a timing assumption.
  class TerminalMenu
    # A cancel/back sentinel distinct from every possible entry value, including nil and false.
    CANCEL = Object.new
    CLEAR = "\e[2J\e[H"
    # How long to wait for the rest of an escape sequence before concluding the operator
    # pressed a bare Escape. Arrow keys deliver their bytes together, so this never waits in
    # practice; a fixed blind read of the next two bytes (the shape it is easy to write) makes
    # Escape do nothing until two more keys are pressed, which reads as a hung menu.
    ESCAPE_SEQUENCE_TIMEOUT = 0.05
    DEFAULT_WIDTH = 96
    MINIMUM_WIDTH = 40

    Entry = Struct.new(:shortcut, :label, :value, keyword_init: true)

    def initialize(input: $stdin, out: $stdout)
      @input = input
      @out = out
    end

    # True only when this really is an interactive terminal on BOTH ends. Both matter: reading
    # keys needs stdin to be a terminal, and a full-screen redraw needs stdout to be one.
    def self.interactive?(input: $stdin, out: $stdout)
      input.respond_to?(:tty?) && input.tty? && out.respond_to?(:tty?) && out.tty?
    end

    # One logical keypress. Assumes the caller already holds raw mode.
    def read_key
      char = input.getc
      return "ctrl-c" if char.nil? # stdin closed under us: treat as cancel, never as a loop
      return char unless char == "\e"

      escape_sequence
    end

    # Pure keypress decision, extracted so it can be proven without a terminal. Returns
    # [:move, index] | [:select, value] | [:cancel, nil] | [:ignore, nil].
    #
    # A shortcut selects IMMEDIATELY and does not move the highlight: an operator who knows
    # the key should not have to watch the screen to be sure it took effect.
    def self.resolve_key(key, entries, index)
      return [ :ignore, nil ] if entries.empty?
      return [ :move, (index - 1) % entries.length ] if key == "up"
      return [ :move, (index + 1) % entries.length ] if key == "down"
      return [ :select, entries[index].value ] if [ "\r", "\n" ].include?(key)
      return [ :cancel, nil ] if [ "", "ctrl-c", "esc" ].include?(key)
      return [ :ignore, nil ] if [ "left", "right" ].include?(key)

      shortcut_for(key, entries)
    end

    def self.shortcut_for(key, entries)
      pressed = key.to_s.upcase
      match = entries.find { |entry| entry.shortcut.to_s.upcase == pressed }
      match ? [ :select, match.value ] : [ :ignore, nil ]
    end

    # Draw and drive one menu until the operator selects or cancels. Raw mode is held for the
    # WHOLE loop rather than toggled per keypress, so every frame renders under one
    # deterministic mode.
    def select(title:, entries:, footer:, header: [])
      index = 0
      with_raw do
        loop do
          render(title: title, entries: entries, index: index, footer: footer, header: header)
          action, payload = self.class.resolve_key(read_key, entries, index)
          case action
          when :move then index = payload
          when :select then return payload
          when :cancel then return CANCEL
          end
        end
      end
    end

    # A destructive-action confirmation. Deliberately NOT part of `select`: a confirmation is
    # a different question from a choice, and rendering it as one more menu row is how an
    # operator selects "yes" by muscle memory. It defaults to no, and only `y` is yes.
    #
    # Phrased by the caller in the future tense; this method only asks.
    def confirm(prompt)
      out.print "\n#{prompt} [y/N]: "
      out.flush if out.respond_to?(:flush)
      key = with_raw { read_key }
      out.puts key.to_s.match?(/\A[a-zA-Z]\z/) ? key : ""
      key.to_s.downcase == "y"
    end

    def pause(message = "Press any key to return…")
      out.puts ""
      out.print message
      out.flush if out.respond_to?(:flush)
      with_raw { read_key }
      out.puts ""
    end

    def clear = out.print(CLEAR)

    # Re-assert cooked line discipline before output that is not this menu's. Defence in
    # depth: `with_raw` already restores on every exit path, but a dispatched command must be
    # unable to inherit a raw mode however the host terminal behaved.
    def restore
      input.cooked! if input.respond_to?(:cooked!)
    rescue IOError, SystemCallError
      # Not a real terminal any more (closed or redirected): there is nothing to normalise.
      nil
    end

    # The usable width, bounded so a very narrow or unreported terminal still renders
    # predictably instead of collapsing to one character per line.
    def width
      reported = out.respond_to?(:winsize) ? out.winsize[1].to_i : 0
      reported = DEFAULT_WIDTH unless reported.positive?
      [ reported, MINIMUM_WIDTH ].max
    rescue IOError, SystemCallError, NoMethodError
      DEFAULT_WIDTH
    end

    private

    attr_reader :input, :out

    # Every entry into raw mode goes through here, so there is exactly one place the
    # restoration can be reasoned about. A terminal that refuses raw mode (already closed, or
    # not a tty after all) still runs the block: the caller gets degraded input rather than a
    # crash, and `interactive?` has already been checked before any dashboard is opened.
    def with_raw(&block)
      return block.call unless input.respond_to?(:raw)

      input.raw(&block)
    rescue IOError, SystemCallError
      block.call
    end

    def escape_sequence
      return "esc" unless input.respond_to?(:wait_readable) && input.wait_readable(ESCAPE_SEQUENCE_TIMEOUT)

      bracket = input.getc
      return "esc" unless bracket == "["

      { "A" => "up", "B" => "down", "C" => "right", "D" => "left" }.fetch(input.getc, "esc")
    end

    # Raw mode disables ONLCR, so lines are joined with an explicit CR+LF and the frame ends
    # with one. Written as ONE `print` so a redraw cannot be seen half-finished.
    def render(title:, entries:, index:, footer:, header:)
      lines = [ paint(title, :bold), rule ]
      lines.concat(header)
      lines << rule unless header.empty?
      entries.each_with_index { |entry, position| lines << row(entry, position == index) }
      lines << rule
      lines << dim(footer)
      out.print(CLEAR + lines.join("\r\n") + "\r\n")
      out.flush if out.respond_to?(:flush)
    end

    def row(entry, highlighted)
      text = " #{highlighted ? '›' : ' '} #{entry.shortcut.to_s.ljust(2)} #{entry.label}"
      highlighted ? paint(clip(text), :cyan) : clip(text)
    end

    def rule = dim("─" * width)
    def clip(text) = text.length > width ? "#{text[0, width - 1]}…" : text

    # Colour is applied only to a terminal, and never carries information on its own: the
    # highlight is also marked with `›`, so the menu is usable with colour disabled, on a
    # monochrome terminal, and in a captured transcript.
    def paint(text, style)
      code = { bold: "1", cyan: "36", dim: "2" }.fetch(style)
      out.tty? ? "\e[#{code}m#{text}\e[0m" : text
    rescue NoMethodError
      text
    end

    def dim(text) = paint(text, :dim)
  end
end
