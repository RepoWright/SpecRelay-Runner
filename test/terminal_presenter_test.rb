# frozen_string_literal: true

require_relative "test_helper"

# RUNNER-0001 scope 2 and 3 — the terminal write boundary, proved without a terminal.
#
# Capability, width, and the sink are all injected, so every property here is asserted
# deterministically: no pty, no wall-clock delay, and no dependence on the developer's
# terminal. The REAL terminal behaviour it enables — one row across many idle polls, and
# `echo`/`icanon`/`isig` after every exit path — is proved separately and for real in
# `loop_tty_test.rb`, because that is the one thing a StringIO cannot reproduce.
#
# The claims:
#   - a transient row REPLACES itself and leaves no history;
#   - a shorter message leaves no tail of the longer one it replaced;
#   - a durable line always clears the row first, so history is never corrupted;
#   - with no terminal to redraw there is no cursor control at all — ephemeral status is
#     dropped and status that MATTERS falls back to a plain line;
#   - one row stays one row at any width; and
#   - redaction runs before every write, transient included.
class TerminalPresenterTest < Minitest::Test
  Presenter = SpecrelayRunner::TerminalPresenter

  # A sink that is a terminal as far as the presenter can tell, and records every write
  # separately so a test can see the FRAMES rather than only the final text.
  class FakeTerminal
    attr_reader :writes

    def initialize
      @writes = []
    end

    def tty? = true
    def print(bytes) = @writes << bytes
    def flush = nil
    def string = @writes.join
  end

  def terminal_presenter(columns: 100)
    sink = FakeTerminal.new
    [ Presenter.new(out: sink, transient: true, columns: columns), sink ]
  end

  # ---- capability, not class ----------------------------------------------

  def test_transient_rendering_needs_an_output_terminal_and_nothing_else
    refute_predicate Presenter.for(out: StringIO.new, err: StringIO.new), :transient?
    assert_predicate Presenter.for(out: FakeTerminal.new, err: StringIO.new), :transient?
  end

  def test_wrapping_a_presenter_returns_it_so_there_is_only_ever_one_boundary
    presenter, = terminal_presenter
    assert_same presenter, Presenter.wrap(presenter)
  end

  def test_wrapping_a_plain_io_gives_a_line_oriented_presenter
    wrapped = Presenter.wrap(StringIO.new)
    assert_kind_of Presenter, wrapped
    refute_predicate wrapped, :transient?
  end

  # ---- the transient row --------------------------------------------------

  def test_the_row_is_replaced_in_place_and_adds_no_terminal_history
    presenter, sink = terminal_presenter
    presenter.status("checking for eligible work")
    presenter.status("no eligible work; next check in 4s")

    refute_includes sink.string, "\n", "a transient row must never terminate a line"
    assert_equal 2, sink.writes.length
    assert_includes sink.writes.last, "no eligible work; next check in 4s"
    assert(sink.writes.all? { |frame| frame.start_with?("\r") }, "each frame returns to column 0")
  end

  # Scenario 7. Overwriting a long message with a short one leaves the tail of the long
  # one on screen unless the remainder is erased.
  def test_a_shorter_message_leaves_no_trailing_characters_from_the_longer_one
    presenter, sink = terminal_presenter
    long = "no eligible work under this runner's claim policy; next check in 60s"
    presenter.status(long)
    presenter.status("claimed")

    frame = sink.writes.last
    assert_includes frame, "claimed"
    covered = frame.delete("\r").length
    assert_operator covered, :>=, long.length,
                    "the new frame must cover at least as many columns as the message it replaced"
    assert_match(/claimed\s+\z/, frame.delete("\r"), "the remainder is erased with spaces")
  end

  def test_the_row_carries_a_rotating_marker_so_it_visibly_changes
    presenter, sink = terminal_presenter
    4.times { presenter.status("no eligible work") }

    markers = sink.writes.map { |frame| frame[1] }
    assert_operator markers.uniq.length, :>, 1, "an unchanging row cannot show liveness"
    assert(markers.all? { |marker| Presenter::GLYPHS.include?(marker) })
  end

  # Scenario 9 / criterion 5: one row stays one row. A row that exactly fills the terminal
  # wraps on some of them, so the text is clipped one column short.
  def test_a_narrow_terminal_still_renders_exactly_one_row
    presenter, sink = terminal_presenter(columns: 40)
    presenter.status("a project name that is far too long to fit in forty columns")

    frame = sink.writes.last.delete("\r")
    refute_includes frame, "\n"
    assert_operator frame.length, :<=, 39
    assert_includes frame, "…", "truncation is visible rather than silent"
  end

  def test_an_unreported_width_falls_back_to_a_readable_default
    presenter = Presenter.new(out: FakeTerminal.new, transient: true)
    assert_equal Presenter::DEFAULT_COLUMNS, presenter.columns
  end

  # ---- the boundary between transient and durable -------------------------

  def test_a_durable_line_erases_the_row_before_it_is_written
    presenter, sink = terminal_presenter
    presenter.status("no eligible work; next check in 4s")
    presenter.line("[loop] executing — claimed DEMO-1")

    erase, durable = sink.writes.last(2)
    assert_match(/\A\r +\r\z/, erase, "the row is erased with spaces, not left under the new line")
    assert_equal "[loop] executing — claimed DEMO-1\n", durable
    refute_includes durable, "\r", "no spinner or cursor byte may reach a durable line"
  end

  def test_a_durable_line_with_no_row_on_screen_erases_nothing
    presenter, sink = terminal_presenter
    presenter.line("[loop] started")

    assert_equal [ "[loop] started\n" ], sink.writes
  end

  def test_finishing_erases_the_row_and_refuses_to_draw_another
    presenter, sink = terminal_presenter
    presenter.status("no eligible work")
    presenter.finish
    presenter.status("this must not appear")

    assert_match(/\A\r +\r\z/, sink.writes.last)
    refute_includes sink.string, "this must not appear"
  end

  def test_clearing_twice_writes_nothing_the_second_time
    presenter, sink = terminal_presenter
    presenter.status("no eligible work")
    presenter.clear_status
    before = sink.writes.length
    presenter.clear_status

    assert_equal before, sink.writes.length
  end

  # ---- no terminal: line-oriented, and no cursor control at all -----------

  def test_without_a_terminal_ephemeral_status_is_dropped_entirely
    io = StringIO.new
    presenter = Presenter.new(out: io, transient: false)
    presenter.status("no eligible work; next check in 59s")
    presenter.line("[loop] started")

    assert_equal "[loop] started\n", io.string
    refute_includes io.string, "\r", "a log file must receive no carriage-return animation"
  end

  # Scope 5: progress that still matters with nowhere to redraw stays a plain bounded line.
  def test_without_a_terminal_status_that_matters_falls_back_to_a_line
    io = StringIO.new
    presenter = Presenter.new(out: io, transient: false)
    presenter.status("claude executor running for 45s (no new output yet)", fallback: :line)

    assert_equal "claude executor running for 45s (no new output yet)\n", io.string
  end

  def test_stderr_is_a_separate_sink
    out = StringIO.new
    err = StringIO.new
    presenter = Presenter.new(out: out, err: err, transient: false)
    presenter.error("[loop] stopping — the credential was rejected")

    assert_empty out.string
    assert_includes err.string, "credential was rejected"
  end

  # ---- redaction before EVERY write --------------------------------------

  def test_redaction_runs_before_the_transient_write_not_only_before_upload
    presenter, sink = terminal_presenter
    presenter.status("polling failed for token sk-live-DO-NOT-LEAK-0123456789")

    refute_includes sink.string, "sk-live-DO-NOT-LEAK-0123456789"
    assert_includes sink.string, "[REDACTED]"
  end

  def test_redaction_runs_before_a_durable_line_and_before_stderr
    out = StringIO.new
    err = StringIO.new
    presenter = Presenter.new(out: out, err: err, transient: false)
    presenter.line("stdout sk-live-DO-NOT-LEAK-0123456789")
    presenter.error("stderr sk-live-DO-NOT-LEAK-0123456789")

    refute_includes out.string, "sk-live-DO-NOT-LEAK-0123456789"
    refute_includes err.string, "sk-live-DO-NOT-LEAK-0123456789"
  end

  # ---- the active run's ticket key ---------------------------------------
  #
  # One terminal, one scrollback, many runs. The claims:
  #   - a durable line and the transient row name the run that produced them, in front of
  #     the source tag they already carried;
  #   - a message carrying embedded newlines is named on each LOGICAL line;
  #   - with no key the output is byte-identical to what it was before;
  #   - colour names the key on a terminal and nothing anywhere else, and a pipe still
  #     carries the bracketed key as plain text; and
  #   - a key belongs to one run: it is gone the moment it is cleared, and the next one
  #     replaces it.

  def test_a_durable_line_names_the_active_run_before_the_existing_source_tag
    io = StringIO.new
    presenter = Presenter.new(out: io, transient: false)
    presenter.ticket_key = "DEMO-260"
    presenter.line("  [claude:stdout] Run launcher test suite")

    assert_equal "[DEMO-260]   [claude:stdout] Run launcher test suite\n", io.string
  end

  def test_an_embedded_newline_is_named_on_each_logical_line_and_adds_no_row
    io = StringIO.new
    presenter = Presenter.new(out: io, transient: false)
    presenter.ticket_key = "DEMO-260"
    presenter.line("[loop] first\nsecond\nthird")

    assert_equal "[DEMO-260] [loop] first\n[DEMO-260] second\n[DEMO-260] third\n", io.string
  end

  # One write, so a status frame or another thread's line cannot land between the rows of
  # one multiline message.
  def test_a_multiline_message_is_still_a_single_write
    presenter, sink = terminal_presenter
    presenter.ticket_key = "DEMO-260"
    presenter.line("first\nsecond")

    assert_equal 1, sink.writes.length
  end

  def test_stderr_is_named_too
    out = StringIO.new
    err = StringIO.new
    presenter = Presenter.new(out: out, err: err, transient: false)
    presenter.ticket_key = "DEMO-260"
    presenter.error("the credential was rejected")

    assert_equal "[DEMO-260] the credential was rejected\n", err.string
  end

  # The regression guard for every surface outside a claimed assignment — and the proof that
  # a runner claiming from a Platform that states no key degrades cleanly rather than
  # printing empty brackets.
  def test_without_an_active_key_the_output_is_what_it_always_was
    %w[unset empty blank].each do |state|
      io = StringIO.new
      presenter = Presenter.new(out: io, transient: false)
      presenter.ticket_key = { "empty" => "", "blank" => "   " }[state]
      presenter.line("[loop] started")

      assert_equal "[loop] started\n", io.string, "a #{state} key must prefix nothing"
    end
  end

  def test_the_transient_row_names_the_active_run
    presenter, sink = terminal_presenter
    presenter.ticket_key = "DEMO-260"
    presenter.status("claude running for 15s (no new output yet)")

    assert_match(/\A\r\e\[36m\[DEMO-260\]\e\[0m [|\/\-\\] claude running/, sink.writes.last)
  end

  # Criterion 3 on a terminal: the key is painted, and no other text gains or loses colour.
  def test_colour_names_the_key_and_nothing_else
    presenter, sink = terminal_presenter
    presenter.ticket_key = "DEMO-260"
    presenter.line("  [claude:stdout] Run launcher test suite")

    written = sink.writes.last
    assert_equal "\e[36m[DEMO-260]\e[0m   [claude:stdout] Run launcher test suite\n", written
    assert_equal 1, written.scan("\e[").length - written.scan("\e[0m").length,
                 "exactly one span is opened, and it closes before the existing text"
  end

  # Criterion 3 with no terminal: a pipe, a redirect, or a CI log still names the ticket.
  def test_without_a_terminal_the_key_is_plain_text_and_still_there
    io = StringIO.new
    presenter = Presenter.new(out: io, transient: false)
    presenter.ticket_key = "DEMO-260"
    presenter.line("  [claude:stdout] Run launcher test suite")
    presenter.status("claude running for 15s (no new output yet)", fallback: :line)

    refute_includes io.string, "\e[", "a captured transcript must carry no escape sequences"
    assert_equal 2, io.string.lines.count { |line| line.start_with?("[DEMO-260] ") }
  end

  # Criterion 5, the half a StringIO can prove: colour has length but occupies no columns, so
  # a row measured on the painted string would overflow into a second one.
  def test_a_named_row_is_still_exactly_one_row_on_a_narrow_terminal
    presenter, sink = terminal_presenter(columns: 40)
    presenter.ticket_key = "DEMO-260"
    presenter.status("a project name that is far too long to fit in forty columns")

    frame = sink.writes.last.delete("\r")
    refute_includes frame, "\n"
    assert_operator visible_length(frame), :<=, 39
    assert_includes frame, "…", "truncation is visible rather than silent"
  end

  # The same arithmetic seen from the other side: the erase padding is counted in columns, so
  # a shorter replacement leaves no tail of the longer named row it replaced.
  def test_a_shorter_named_row_leaves_no_tail_of_the_longer_one
    presenter, sink = terminal_presenter
    long = "no eligible work under this runner's claim policy; next check in 60s"
    presenter.ticket_key = "DEMO-260"
    presenter.status(long)
    presenter.status("claimed")

    frame = sink.writes.last.delete("\r")
    assert_operator visible_length(frame), :>=, long.length + "[DEMO-260] ".length
    assert_match(/claimed\s+\z/, frame, "the remainder is erased with spaces")
  end

  # Criterion 4. A machine left in `loop` mode executes one run after another into one
  # scrollback, and the key is the only thing telling them apart.
  def test_a_key_belongs_to_one_run_and_the_next_run_states_its_own
    io = StringIO.new
    presenter = Presenter.new(out: io, transient: false)
    presenter.ticket_key = "DEMO-260"
    presenter.line("[loop] executing")
    presenter.ticket_key = nil
    presenter.line("[loop] no eligible work")
    presenter.ticket_key = "DEMO-261"
    presenter.line("[loop] executing")

    assert_equal [ "[DEMO-260] [loop] executing",
                   "[loop] no eligible work",
                   "[DEMO-261] [loop] executing" ], io.string.lines.map(&:chomp)
  end

  def test_redaction_still_runs_before_a_named_line
    io = StringIO.new
    presenter = Presenter.new(out: io, transient: false)
    presenter.ticket_key = "DEMO-260"
    presenter.line("stdout sk-live-DO-NOT-LEAK-0123456789")

    refute_includes io.string, "sk-live-DO-NOT-LEAK-0123456789"
    assert io.string.start_with?("[DEMO-260] "), "the key is applied after redaction, not through it"
  end

  # Columns occupied, which is what a terminal counts — an escape sequence has length and
  # occupies none.
  def visible_length(text) = text.gsub(/\e\[[0-9;]*m/, "").length

  # ---- IO compatibility --------------------------------------------------

  # Heartbeater, Execution, Publication, and the specification lanes write with `io.puts`.
  # Answering it is what lets them clear the transient row without knowing it exists.
  def test_it_can_stand_in_for_the_io_every_other_writer_already_uses
    presenter, sink = terminal_presenter
    presenter.status("claude executor running for 45s (no new output yet)")
    presenter.puts("[heartbeat] Platform signalled the claim is no longer live")
    presenter.flush

    assert_match(/\A\r +\r\z/, sink.writes[-2])
    assert_equal "[heartbeat] Platform signalled the claim is no longer live\n", sink.writes[-1]
  end

  # A blank separator line is a line. Splitting a message into its logical rows must not answer
  # the EMPTY message with no rows at all: `puts` and `line("")` have always written one blank
  # line, and every spacer an existing writer emits depends on it.
  def test_an_empty_message_is_still_one_blank_line
    presenter, sink = terminal_presenter

    presenter.line("alpha")
    presenter.puts
    presenter.line("")
    presenter.line("beta")

    assert_equal "alpha\n\n\nbeta\n", sink.string,
                 "with no key the output is byte-identical to the unprefixed presenter's"
  end

  # The blank line belongs to the run too, and carries the key on the same terms as the blank
  # row inside a multiline message.
  def test_an_empty_message_carries_the_key_like_any_other_logical_line
    sink = StringIO.new
    presenter = Presenter.new(out: sink)
    presenter.ticket_key = "DEMO-260"

    presenter.line("alpha")
    presenter.puts
    presenter.line("beta")

    assert_equal "[DEMO-260] alpha\n[DEMO-260] \n[DEMO-260] beta\n", sink.string
  end

  # ---- concurrency: criterion 16 -----------------------------------------

  # An executor reader thread, a heartbeat timer, and the loop's own status all write here.
  # A durable line that got split, or had a status frame inserted into the middle of it, is
  # the corruption this boundary exists to make impossible.
  def test_concurrent_status_and_durable_writes_never_split_a_durable_line
    presenter, sink = terminal_presenter
    writers = 4.times.map do |worker|
      Thread.new { 25.times { |i| presenter.line("DURABLE #{worker}-#{i} #{'.' * 40}") } }
    end
    spinner = Thread.new { 200.times { presenter.status("no eligible work; next check in 7s") } }
    (writers + [ spinner ]).each(&:join)

    lines = sink.string.split("\n")
    assert_equal 100, lines.count { |line| line.include?("DURABLE") }
    lines.each do |line|
      assert_operator line.scan("DURABLE").length, :<=, 1, "two durable lines landed on one row: #{line.inspect}"
      next unless line.include?("DURABLE")

      assert_match(/DURABLE \d+-\d+ \.{40}\z/, line, "a durable line was truncated or interleaved: #{line.inspect}")
    end
  end

  # ---- a failing terminal must not fail the run --------------------------

  def test_a_sink_that_refuses_a_transient_write_disables_rendering_instead_of_raising
    presenter = Presenter.new(out: RefusingTerminal.new, transient: true, columns: 100)
    presenter.status("no eligible work")

    refute_predicate presenter, :transient?, "rendering switches itself off rather than retrying"
    presenter.clear_status
    presenter.finish
  end

  class RefusingTerminal
    def tty? = true
    def print(_bytes) = raise(IOError, "device not configured")
    def flush = nil
  end
end
