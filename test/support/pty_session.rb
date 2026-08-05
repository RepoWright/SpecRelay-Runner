# frozen_string_literal: true

require "pty"

# Driving the real `specrelay-runner` inside a real controlling terminal.
#
# Extracted from `dashboard_tty_test.rb` (MVP-0021) so RUNNER-0001's loop-in-a-pty proof uses
# the SAME harness rather than a second, subtly different one. The two things it gets right are
# the two that are easy to get wrong:
#
#   1. It reads the frame BEFORE sending the next key. A key written before the program has
#      entered raw mode is handled by the terminal's line discipline instead of by the program —
#      and for Ctrl-C that means SIGINT to the whole process group, killing the harness rather
#      than exercising the program's own handling.
#   2. It asks the PTY ITSELF what state it was left in, from a separate process, after the
#      program exited. "The program thinks it restored the terminal" is precisely the claim
#      under test, so its own opinion is not evidence.
#
# A pty delivers bytes, so every chunk is forced to UTF-8 before being joined: the frames
# legitimately contain `·`, `›`, and `─`, and comparing those against a UTF-8 literal would
# otherwise raise instead of matching.
module PtySession
  # Generous enough for a cold Ruby boot on a loaded machine, bounded so a hang fails the test
  # instead of the suite.
  READ_TIMEOUT_SECONDS = 20

  # A long-running program is driven by what it has actually DONE (`wait_until`), not by a
  # sleep. Bounded generously so a condition that never holds fails the test instead of
  # hanging the suite.
  WAIT_TIMEOUT_SECONDS = 90

  # Separates the program's own frames from the `stty` report that follows it.
  MARKER = "STTY-REPORT-BEGIN"

  # `keys` is a script of keystrokes to send. An entry may also be a PROC, which means "keep
  # reading until this is true before sending the next key" — that is how a long-running
  # command is driven by what it has actually DONE (five real polls) rather than by a sleep.
  # `columns` resizes the pty ITSELF, which is the only thing a program can actually observe:
  # `COLUMNS` in the environment is a shell convention, and `IO#winsize` — what the runner reads —
  # answers from the terminal driver regardless of it.
  def pty_session(argv, keys, env: {}, columns: nil, rows: 40)
    output = utf8
    PTY.spawn(env, *argv) do |reader, writer, pid|
      resize(reader, rows, columns) if columns
      output << read_available(reader)
      keys.each do |key|
        next output << read_while(reader, key) if key.is_a?(Proc)
        break unless write_key(writer, key)

        output << read_available(reader)
      end
      output << drain(reader)
      wait(pid)
    end
    output
  rescue PTY::ChildExited
    output
  end

  # Keep reading while waiting, so a chatty child can never block on a full pty buffer while
  # the test is waiting for it to reach the state under test.
  def read_while(reader, condition, timeout: WAIT_TIMEOUT_SECONDS)
    chunk = utf8
    deadline = monotonic + timeout
    chunk << read_available(reader, first: 0.5) until condition.call || monotonic > deadline
    chunk
  end

  # Run `argv`, then ask the terminal what state it is in. `stty -a` runs in the SAME pty
  # session, after the program has exited, from a shell that inherits the same controlling
  # terminal.
  #
  # The program's output is deliberately NOT redirected away: with stdout on /dev/null a
  # dashboard would correctly refuse to open at all (no terminal on both ends) and the
  # assertion would pass while proving nothing.
  def resize(pty, rows, columns)
    pty.winsize = [ rows, columns ]
  rescue IOError, SystemCallError, NotImplementedError
    nil
  end

  def probe_terminal(name, argv, keys, env: {}, directory: @dir, repeat: 1)
    script = File.join(directory, "#{name}.sh")
    command = argv.map { |part| shell_quote(part) }.join(" ")
    File.write(script, <<~SH)
      #!/bin/sh
      #{Array.new(repeat, command).join("\n")}
      printf '\\n#{MARKER}\\n'
      stty -a
    SH
    File.chmod(0o755, script)
    output = pty_session([ "/bin/sh", script ], keys, env: env)
    report = output.split(MARKER, 2)[1]
    refute_nil report, "the stty report never arrived; the pty session was:\n#{output}"
    report
  end

  # The three attributes whose loss outlives the program: no echo, no line editing, no working
  # Ctrl-C in the operator's shell afterwards.
  def assert_terminal_restored(report, context)
    assert_includes report, "echo", "raw mode leaked after #{context}: the shell would not echo"
    assert_includes report, "icanon", "raw mode leaked after #{context}: line editing would be dead"
    assert_includes report, "isig", "raw mode leaked after #{context}: Ctrl-C would no longer work"
  end

  # A pty whose child has already exited raises EIO on write. That is a legitimate end of the
  # session (the program quit on an earlier key), not a test failure.
  def write_key(writer, key)
    writer.write(key)
    writer.flush
    true
  rescue Errno::EIO, IOError
    false
  end

  # Read whatever the child has produced, waiting only until it goes quiet. A frame is written
  # in one `print`, so a short quiet period means the frame is complete.
  def read_available(reader, quiet: 0.2, first: 2.0)
    chunk = utf8
    deadline = monotonic + READ_TIMEOUT_SECONDS
    while monotonic < deadline
      break unless reader.wait_readable(chunk.empty? ? first : quiet)

      begin
        chunk << reader.read_nonblock(8192).force_encoding(Encoding::UTF_8)
      rescue IO::WaitReadable
        next
      rescue Errno::EIO, EOFError
        break
      end
    end
    chunk
  end

  # Read to the end of the session. BOUNDED: a program that is still waiting for a key when the
  # script has run out of them would otherwise block here forever, which reads as a hung suite
  # rather than as the test-script mistake it is.
  def drain(reader, timeout: READ_TIMEOUT_SECONDS)
    rest = utf8
    deadline = monotonic + timeout
    while monotonic < deadline
      break unless reader.wait_readable(0.2)

      rest << reader.readpartial(4096).force_encoding(Encoding::UTF_8)
    end
    rest
  rescue Errno::EIO, EOFError, IOError
    rest
  end

  def utf8 = String.new("", encoding: Encoding::UTF_8)

  # The child is expected to have exited by the time the key script ran out. One that has not —
  # a menu still waiting for a key that was never sent — is terminated instead of being left to
  # block the suite indefinitely.
  def wait(pid, timeout: 5)
    deadline = monotonic + timeout
    while monotonic < deadline
      return if Process.waitpid(pid, Process::WNOHANG)

      sleep 0.05
    end
    Process.kill("KILL", pid)
    Process.waitpid(pid)
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  def shell_quote(value) = "'#{value.gsub("'", "'\\\\''")}'"
end
