# frozen_string_literal: true

require_relative "test_helper"
require "pty"

# LOGICAL lines, not visual ones — proved on a real terminal, because a StringIO cannot wrap.
#
# The presenter names the run when it WRITES a line. A durable line wider than the window is
# then wrapped by the terminal itself, and the continuation rows are the same line: a second
# name on them would be the terminal telling the operator about a run boundary that did not
# happen.
#
# Deliberately its own file rather than an addition to `loop_tty_test.rb`: this needs one short
# child that exits on its own, and that suite drives a long-running runner whose child can get
# stuck — a hazard this bounded case has no reason to inherit.
class TerminalWrappingTtyTest < Minitest::Test
  COLUMNS = 40
  KEY = "DEMO-260"
  # Several times the window, so the row count cannot be an accident of rounding.
  MESSAGE = "  [claude:stdout] #{'wrapped ' * 25}"

  def test_a_line_wider_than_the_window_is_named_once_and_wraps_without_a_second_name
    output = run_on_a_pty

    assert_includes output, "columns=#{COLUMNS}",
                    "the child must really have seen a window narrower than the line"
    assert_equal 1, output.scan("[#{KEY}]").length,
                 "a wrapped continuation must carry no second name: #{output.inspect}"
    assert_includes output.gsub(/\e\[[0-9;]*m/, ""), "[#{KEY}] #{MESSAGE}",
                    "the whole line is written once, unbroken"
    assert_equal 1, output.scan("\n").length - 1,
                 "the presenter terminates the line exactly once; the rest is the terminal's wrap"
  end

  private

  # One child, on a real pty resized to a narrow window, writing through the real presenter.
  def run_on_a_pty
    script = File.join(@dir, "write_one_wide_line.rb")
    File.write(script, <<~RUBY)
      $LOAD_PATH.unshift(#{File.expand_path('../lib', __dir__).inspect})
      require "specrelay_runner"
      presenter = SpecrelayRunner::TerminalPresenter.for(out: $stdout, err: $stderr)
      presenter.ticket_key = #{KEY.inspect}
      puts "columns=\#{presenter.columns}"
      presenter.line(#{MESSAGE.inspect})
    RUBY
    read_child([ RbConfig.ruby, script ])
  end

  def read_child(argv)
    output = String.new("", encoding: Encoding::UTF_8)
    PTY.spawn(*argv) do |reader, _writer, pid|
      reader.winsize = [ 24, COLUMNS ]
      output << drain(reader)
      Process.waitpid(pid)
    rescue Errno::ECHILD
      nil
    end
    output
  rescue PTY::ChildExited
    output
  end

  # Bounded, so a child that never exits fails this test instead of hanging the suite. The
  # FIRST wait is the generous one: a cold Ruby boot takes about a second, and a short wait
  # there reads as a child that printed nothing.
  def drain(reader, timeout: 20, first: 10)
    text = String.new("", encoding: Encoding::UTF_8)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      break unless reader.wait_readable(text.empty? ? first : 0.2)

      text << reader.readpartial(4096).force_encoding(Encoding::UTF_8)
    end
    text
  rescue Errno::EIO, EOFError, IOError
    text
  end

  def setup = @dir = Dir.mktmpdir("terminal-wrapping")
  def teardown = FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
end
