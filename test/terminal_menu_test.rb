# frozen_string_literal: true

require_relative "test_helper"

# MVP-0021 scope 1 — the terminal menu's key semantics and its width behaviour.
#
# `resolve_key` is deliberately a pure function so that every binding the operator's fingers
# depend on — including the two that are hardest to test any other way, Ctrl-C and Escape — is
# proved without a terminal, a pty, or a timing assumption. Raw mode and restoration are proved
# for real in `dashboard_tty_test.rb`; this file is about the decisions.
class TerminalMenuTest < Minitest::Test
  Entry = SpecrelayRunner::TerminalMenu::Entry
  CANCEL = SpecrelayRunner::TerminalMenu::CANCEL

  def entries
    [ Entry.new(shortcut: "1", label: "first", value: :first),
      Entry.new(shortcut: "2", label: "second", value: :second),
      Entry.new(shortcut: "Q", label: "Quit", value: :quit) ]
  end

  def resolve(key, index: 0) = SpecrelayRunner::TerminalMenu.resolve_key(key, entries, index)

  # --- movement -------------------------------------------------------------

  def test_arrows_move_the_highlight_and_wrap_around
    assert_equal [ :move, 1 ], resolve("down", index: 0)
    assert_equal [ :move, 0 ], resolve("down", index: 2), "down from the last row wraps to the first"
    assert_equal [ :move, 2 ], resolve("up", index: 0), "up from the first row wraps to the last"
  end

  def test_enter_selects_whatever_is_highlighted
    assert_equal [ :select, :second ], resolve("\r", index: 1)
    assert_equal [ :select, :second ], resolve("\n", index: 1)
  end

  def test_horizontal_arrows_are_ignored_rather_than_treated_as_anything
    assert_equal [ :ignore, nil ], resolve("left")
    assert_equal [ :ignore, nil ], resolve("right")
  end

  def test_an_unbound_key_is_ignored_and_never_selects
    assert_equal [ :ignore, nil ], resolve("z")
    assert_equal [ :ignore, nil ], resolve("\t")
  end

  # --- shortcuts ------------------------------------------------------------

  # The property that makes shortcuts trustworthy: pressing one acts on THAT entry, not on
  # whatever happens to be highlighted.
  def test_a_shortcut_selects_its_own_entry_regardless_of_the_highlight
    assert_equal [ :select, :first ], resolve("1", index: 2)
    assert_equal [ :select, :quit ], resolve("Q", index: 0)
  end

  def test_shortcuts_are_case_insensitive
    assert_equal [ :select, :quit ], resolve("q")
    assert_equal [ :select, :quit ], resolve("Q")
  end

  # --- getting out ----------------------------------------------------------

  # Raw mode disables ISIG, so Ctrl-C arrives as a byte rather than as SIGINT. If it were not
  # bound, Ctrl-C would do nothing at all and the menu would look hung — which is worse than
  # either quitting or raising.
  def test_ctrl_c_cancels
    assert_equal [ :cancel, nil ], resolve("")
    assert_equal [ :cancel, nil ], resolve("ctrl-c")
  end

  def test_escape_cancels
    assert_equal [ :cancel, nil ], resolve("esc")
  end

  def test_an_empty_menu_ignores_every_key_instead_of_indexing_into_nothing
    %w[up down \r 1 Q z].each do |key|
      assert_equal [ :ignore, nil ], SpecrelayRunner::TerminalMenu.resolve_key(key, [], 0)
    end
  end

  # --- width ----------------------------------------------------------------

  def test_an_unreported_width_falls_back_to_a_readable_default
    menu = SpecrelayRunner::TerminalMenu.new(input: StringIO.new, out: StringIO.new)

    assert_equal SpecrelayRunner::TerminalMenu::DEFAULT_WIDTH, menu.width
  end

  # A terminal narrower than the minimum still renders predictably instead of collapsing to one
  # character per line — content is truncated, never wrapped, so no row can shift another one.
  def test_a_very_narrow_terminal_is_floored_at_the_minimum
    menu = SpecrelayRunner::TerminalMenu.new(input: StringIO.new, out: narrow_terminal(12))

    assert_equal SpecrelayRunner::TerminalMenu::MINIMUM_WIDTH, menu.width
  end

  def test_a_reported_width_is_used
    menu = SpecrelayRunner::TerminalMenu.new(input: StringIO.new, out: narrow_terminal(120))

    assert_equal 120, menu.width
  end

  def narrow_terminal(columns, rows = 24)
    StringIO.new.tap do |io|
      io.define_singleton_method(:winsize) { [ rows, columns ] }
      io.define_singleton_method(:tty?) { true }
    end
  end

  # --- long lists -----------------------------------------------------------
  #
  # A machine may hold more projects than the terminal has lines. Rendering every row pushed the
  # top of the frame — and with it the highlighted row and the footer — off the screen, so the
  # arrow keys moved a highlight nobody could see. The frame is windowed instead.

  def many_entries(count)
    (1..count).map { |n| Entry.new(shortcut: (n.to_s if n < 10), label: "project #{n}", value: :"p#{n}") }
  end

  def frame_for(entries, index, rows: 24, columns: 100)
    terminal = narrow_terminal(columns, rows)
    SpecrelayRunner::TerminalMenu.new(input: StringIO.new, out: terminal)
                                .send(:render, title: "T", entries: entries, index: index,
                                      footer: "F", header: [ "H" ])
    terminal.string.sub(SpecrelayRunner::TerminalMenu::CLEAR, "").split("\r\n")
  end

  def test_a_frame_never_renders_more_lines_than_the_terminal_has
    lines = frame_for(many_entries(40), 0, rows: 24)

    assert_operator lines.reject(&:empty?).length, :<=, 24
  end

  def test_the_highlighted_row_stays_on_screen_at_the_start_middle_and_end
    entries = many_entries(40)

    [ 0, 19, 39 ].each do |index|
      frame = frame_for(entries, index, rows: 24).join("\n")

      assert_includes frame, entries[index].label,
                      "row #{index} was scrolled out of the frame that highlights it"
      assert_match(/› .*#{Regexp.escape(entries[index].label)}/, frame,
                   "row #{index} is not the highlighted one on its own frame")
    end
  end

  def test_the_footer_survives_a_list_longer_than_the_terminal
    lines = frame_for(many_entries(40), 39, rows: 24)

    assert_includes lines.last.gsub(/\e\[[\d;]*m/, ""), "F"
  end

  # The operator has to be able to tell that ↑/↓ will reach more than they can see.
  def test_a_windowed_frame_says_how_many_rows_are_out_of_sight
    frame = frame_for(many_entries(40), 20, rows: 24).join("\n")

    assert_match(/of 40/, frame)
    assert_match(/above/, frame)
    assert_match(/below/, frame)
  end

  def test_a_list_that_fits_is_rendered_whole_with_no_notice
    frame = frame_for(many_entries(4), 0, rows: 40).join("\n")

    (1..4).each { |n| assert_includes frame, "project #{n}" }
    refute_match(/of 4/, frame, "a list that fits needs no scrolling notice")
  end

  # A very short terminal must still show the highlight rather than collapsing to nothing.
  def test_a_tiny_terminal_still_shows_at_least_the_minimum_rows
    frame = frame_for(many_entries(40), 0, rows: 6).join("\n")

    shown = (1..40).count { |n| frame.include?("project #{n}") }

    assert_operator shown, :>=, SpecrelayRunner::TerminalMenu::MINIMUM_VISIBLE_ENTRIES
  end

  # --- rendering posture ----------------------------------------------------

  # Colour must never be the only signal: the highlight also carries `›`, so the menu is usable
  # with colour off, on a monochrome terminal, and in a captured transcript.
  def test_the_highlight_is_marked_with_a_pointer_and_not_only_with_colour
    plain = StringIO.new
    menu = SpecrelayRunner::TerminalMenu.new(input: StringIO.new, out: plain)
    menu.send(:render, title: "T", entries: entries, index: 1, footer: "F", header: [ "H" ])

    frame = plain.string

    refute_match(/\e\[3\dm/, frame, "a non-terminal must receive no colour codes at all")
    rows = frame.split("\r\n").grep(/first|second|Quit/)
    assert_equal [ "   1  first", " › 2  second", "   Q  Quit" ], rows
  end

  # CR-001 / review-001 F4. A wrapped title, header, or footer pushes every row below it down, so
  # the highlighted line and the line the operator is reading stop being the same line. The entry
  # rows were clipped from the start; these three were not.
  def test_every_line_in_a_frame_is_clipped_to_the_terminal_width
    narrow = narrow_terminal(48)
    menu = SpecrelayRunner::TerminalMenu.new(input: StringIO.new, out: narrow)
    long = "x" * 200

    menu.send(:render, title: long, entries: entries, index: 0, footer: long, header: [ long, long ])

    frame = narrow.string.sub(SpecrelayRunner::TerminalMenu::CLEAR, "")
    frame.split("\r\n").reject(&:empty?).each do |line|
      assert_operator line.gsub(/\e\[[\d;]*m/, "").length, :<=, 48,
                      "a line wider than the terminal wraps and shifts every row below it"
    end
  end

  # Raw mode disables ONLCR, so a bare "\n" would render as a right-drifting staircase.
  def test_every_rendered_line_ends_with_an_explicit_carriage_return
    plain = StringIO.new
    SpecrelayRunner::TerminalMenu.new(input: StringIO.new, out: plain)
                                .send(:render, title: "T", entries: entries, index: 0, footer: "F", header: [])

    body = plain.string.sub(SpecrelayRunner::TerminalMenu::CLEAR, "")

    assert body.end_with?("\r\n")
    refute_match(/[^\r]\n/, body, "a newline with no carriage return would staircase in raw mode")
  end
end
