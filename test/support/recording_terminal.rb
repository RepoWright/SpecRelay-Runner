# frozen_string_literal: true

# A sink that is a terminal as far as TerminalPresenter can tell, and records every write
# SEPARATELY (RUNNER-0001).
#
# Recording frames rather than one concatenated string is what makes the transient row
# testable: the property under test is that a frame replaces the previous one in place and
# that a durable line is preceded by an erase, and both are invisible once the writes have
# been joined into a single buffer.
#
# The waiting region is several rows drawn in one write and never newline-terminated, so it is
# told apart from durable output the same way the one-row status always was. `screen` replays
# every write through a minimal terminal, which is what proves that redraws leave no history.
class RecordingTerminal
  CONTROL = /\e\[[\d;]*[A-Za-z]/
  attr_reader :writes
  attr_accessor :columns, :lines

  def initialize(columns: 100, lines: 40)
    @columns = columns
    @lines = lines
    @writes = []
  end

  def tty? = true
  def winsize = [ @lines, @columns ]
  def print(bytes) = @writes << bytes
  def flush = nil

  def string = @writes.join

  # Every write that ended a line: the terminal HISTORY an operator can scroll back to.
  def durable_lines
    @writes.reject { |write| region?(write) }.join.gsub(/\e\[\d*[AJ]/, "")
           .split("\n").map { |line| line.rpartition("\r").last }.reject(&:empty?)
  end

  # The successive contents of the one reusable row, marker stripped.
  def transient_rows
    @writes.select { |frame| frame.start_with?("\r") && !frame.include?("\n") }
           .map { |frame| frame.gsub(CONTROL, "").delete("\r").strip.sub(/\A[|\/\-\\] /, "") }
           .reject(&:empty?)
  end

  # Each drawing of the waiting region, as the plain rows it put on screen.
  def regions = @writes.select { |write| region?(write) }.map { |write| plain(write).split("\n").drop(1) }

  # What is on screen once every write has been applied: carriage return, newline (a pty's
  # `onlcr` makes it a CR LF), cursor up, erase-to-end-of-screen and colour.
  def screen
    rows = [ +"" ]
    row = col = 0
    string.scan(/\e\[([\d;]*)([A-Za-z])|(\r)|(\n)|([^\e\r\n])/) do |count, command, cr, lf, char|
      case
      when command == "A"
        row = [ row - [ count.to_i, 1 ].max, 0 ].max
      when command == "J"
        rows[row] = rows[row][0, col].to_s
        rows.slice!((row + 1)..)
      when command, cr
        col = 0 if cr
      when lf
        row += 1
        col = 0
        rows[row] ||= +""
      else
        rows[row] = rows[row].ljust(col)
        rows[row][col] = char
        col += 1
      end
    end
    rows.map(&:rstrip)
  end

  private

  def region?(write) = write.include?("\n") && !write.end_with?("\n")
  def plain(write) = write.gsub(CONTROL, "").delete("\r")
end
