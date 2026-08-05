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
