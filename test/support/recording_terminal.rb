# frozen_string_literal: true

# A sink that is a terminal as far as TerminalPresenter can tell, and records every write
# SEPARATELY (RUNNER-0001).
#
# Recording frames rather than one concatenated string is what makes the transient row
# testable: the property under test is that a frame replaces the previous one in place and
# that a durable line is preceded by an erase, and both are invisible once the writes have
# been joined into a single buffer.
class RecordingTerminal
  attr_reader :writes

  def initialize(columns: 100)
    @columns = columns
    @writes = []
  end

  def tty? = true
  def winsize = [ 40, @columns ]
  def print(bytes) = @writes << bytes
  def flush = nil

  def string = @writes.join

  # Every write that ended a line: the terminal HISTORY an operator can scroll back to.
  def durable_lines = string.split("\n").map { |line| line.rpartition("\r").last }.reject(&:empty?)

  # The successive contents of the one reusable row, marker stripped.
  def transient_rows
    @writes.select { |frame| frame.start_with?("\r") && !frame.include?("\n") }
           .map { |frame| frame.delete("\r").strip.sub(/\A[|\/\-\\] /, "") }
           .reject(&:empty?)
  end
end
