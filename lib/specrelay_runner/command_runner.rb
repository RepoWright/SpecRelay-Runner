# frozen_string_literal: true

require "open3"
require "timeout"

module SpecrelayRunner
  # Launches one child process from an explicit argv array under a hard timeout,
  # capturing stdout/stderr/exit status/duration (MVP-0010). It mirrors the
  # safety posture of the Platform-side runner CommandRunner but is a standalone,
  # dependency-free reimplementation (the runner shares no code with Platform):
  #
  #   - the command is ALWAYS an argv array via Process.spawn, so no shell is
  #     involved and no argument (including executor prompt text) is interpolated
  #     into a shell line;
  #   - the child runs in its own process group so a timeout kills the whole tree;
  #   - output is bounded so a runaway process cannot exhaust runner memory.
  #
  # MVP-0018 adds an OPTIONAL `on_output` consumer that receives each complete
  # output line as it arrives, so a caller can show live progress instead of
  # waiting for process exit. The consumer is strictly additive: the buffered
  # `Result` remains the authoritative capture, the child's exit status is
  # observed independently of it, and a consumer that raises is swallowed — a
  # progress display must never be able to fail the execution it reports on.
  class CommandRunner
    MAX_CAPTURE_BYTES = 1_000_000
    TERM_GRACE_SECONDS = 5
    READ_CHUNK_BYTES = 64 * 1024

    # A provider that emits a very long line with no newline must not be able to
    # grow the pending-line buffer without bound; at this size the partial line is
    # handed to the consumer as-is.
    MAX_PENDING_LINE_BYTES = 8_192

    # Stream names passed to `on_output`. They are the runner's own vocabulary,
    # never provider-supplied.
    STDOUT = "stdout"
    STDERR = "stderr"

    Result = Struct.new(:exit_code, :stdout, :stderr, :duration_seconds, :timed_out, keyword_init: true) do
      def success? = !timed_out && exit_code == 0
      def timed_out? = timed_out ? true : false
    end

    def self.run(argv, **kwargs) = new(**kwargs).run(argv)

    def initialize(chdir:, env: {}, timeout_seconds: 1800, stdin_data: nil, on_output: nil)
      @chdir = chdir.to_s
      @env = env.to_h.transform_keys(&:to_s).transform_values(&:to_s)
      @timeout_seconds = timeout_seconds
      @stdin_data = stdin_data
      @on_output = on_output
    end

    def run(argv)
      argv = Array(argv).map(&:to_s)
      raise ArgumentError, "argv must not be empty" if argv.empty?

      started = monotonic
      out_r, err_r, pid = spawn_process(argv)
      timed_out, status = wait_or_kill(pid)
      Result.new(exit_code: status&.exitstatus, stdout: out_r.value, stderr: err_r.value,
                 duration_seconds: (monotonic - started).round(3), timed_out: timed_out)
    end

    private

    attr_reader :chdir, :env, :timeout_seconds, :stdin_data, :on_output

    def spawn_process(argv)
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      in_r, in_w = IO.pipe
      pid = Process.spawn(env, *argv, chdir: chdir, out: out_w, err: err_w, in: in_r, pgroup: true)
      [ out_w, err_w, in_r ].each(&:close)
      write_stdin(in_w)
      [ reader_thread(out_r, STDOUT), reader_thread(err_r, STDERR), pid ]
    end

    def write_stdin(io)
      io.write(stdin_data) if stdin_data
    rescue Errno::EPIPE
      # child exited before reading stdin; not an error
    ensure
      io.close
    end

    # `readpartial` rather than `read(n)`: `read(n)` blocks until it has n bytes or
    # the pipe closes, which is precisely why output used to appear only at exit.
    # `readpartial` returns whatever has arrived, so a live consumer sees each line
    # as the provider writes it while the buffered capture stays byte-identical.
    def reader_thread(io, source)
      Thread.new do
        data = +"".b
        pending = +"".b
        while (chunk = read_available(io))
          data << chunk if data.bytesize < MAX_CAPTURE_BYTES
          pending = stream_lines(source, pending << chunk)
        end
        emit_line(source, pending)
        io.close
        bounded(data).dup.force_encoding(Encoding::UTF_8).scrub("")
      end
    end

    def read_available(io)
      io.readpartial(READ_CHUNK_BYTES)
    rescue EOFError
      nil
    end

    # Hands every COMPLETE line to the consumer and returns the unterminated
    # remainder. Splitting on the newline BYTE is UTF-8 safe, so a multi-byte
    # character split across two reads is reassembled before it is decoded.
    def stream_lines(source, buffer)
      return buffer if on_output.nil?
      return flush_pending(source, buffer) unless buffer.include?("\n")

      *lines, remainder = buffer.split("\n", -1)
      lines.each { |line| emit_line(source, line) }
      remainder.to_s.b
    end

    # A single line longer than the buffer cap is delivered as-is rather than
    # accumulated forever.
    def flush_pending(source, buffer)
      return buffer if buffer.bytesize < MAX_PENDING_LINE_BYTES

      emit_line(source, buffer)
      +"".b
    end

    def emit_line(source, line)
      return if on_output.nil? || line.nil? || line.empty?

      on_output.call(source, line.dup.force_encoding(Encoding::UTF_8).scrub(""))
    rescue StandardError
      # A live progress consumer must never be able to fail the execution it is
      # reporting on. The buffered Result is the authoritative capture.
      nil
    end

    # The capture buffer is byte-oriented (a multi-byte character can straddle two
    # reads), so it is decoded before the marker is appended: interpolating raw
    # bytes into a UTF-8 literal would raise on non-ASCII provider output.
    def bounded(data)
      text = data.dup.force_encoding(Encoding::UTF_8).scrub("")
      return text if text.bytesize <= MAX_CAPTURE_BYTES

      "#{text.byteslice(0, MAX_CAPTURE_BYTES).force_encoding(Encoding::UTF_8).scrub('')}\n" \
        "[output truncated at #{MAX_CAPTURE_BYTES} bytes]\n"
    end

    def wait_or_kill(pid)
      Timeout.timeout(timeout_seconds) { Process.waitpid(pid, 0) }
      [ false, $? ]
    rescue Timeout::Error
      [ true, terminate_group(pid) ]
    rescue Errno::ECHILD
      [ false, nil ]
    end

    def terminate_group(pid)
      signal_group(pid, "TERM")
      deadline = monotonic + TERM_GRACE_SECONDS
      until monotonic >= deadline
        return $? if reaped?(pid)

        sleep 0.05
      end
      signal_group(pid, "KILL")
      reaped?(pid) ? $? : nil
    end

    def signal_group(pid, signal)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def reaped?(pid)
      !Process.waitpid(pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      true
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
