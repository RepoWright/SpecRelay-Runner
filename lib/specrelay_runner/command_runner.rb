# frozen_string_literal: true

require "open3"

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
    # How often the parent notices that the child exited, the timeout passed, or a stop was
    # requested. Short enough that a released provider session ends promptly, long enough that
    # waiting on a half-hour executor costs nothing measurable.
    WAIT_POLL_SECONDS = 0.05

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

    # `stop_check` (MVP-0036) is an OPTIONAL predicate polled while the child runs. When it
    # answers truthfully, the process group is ended through the same bounded TERM-then-KILL
    # grace a timeout uses — one shutdown implementation, so a released provider session and an
    # overrunning one cannot be stopped by two different rules. Nil restores the ordinary
    # behaviour exactly: wait for the child, or kill it at the timeout.
    #
    # `on_start` (MVP-0036 CR-004 F3) is an OPTIONAL callback fired once the child exists AND its
    # input has been handed over. See {#notify_started}.
    def initialize(chdir:, env: {}, timeout_seconds: 1800, stdin_data: nil, on_output: nil,
                   stop_check: nil, on_start: nil)
      @chdir = chdir.to_s
      @env = env.to_h.transform_keys(&:to_s).transform_values(&:to_s)
      @timeout_seconds = timeout_seconds
      @stdin_data = stdin_data
      @on_output = on_output
      @stop_check = stop_check
      @on_start = on_start
    end

    def run(argv)
      argv = Array(argv).map(&:to_s)
      raise ArgumentError, "argv must not be empty" if argv.empty?

      started = monotonic
      out_r, err_r, pid = spawn_process(argv)
      timed_out, status = deliver_and_wait(pid)
      Result.new(exit_code: status&.exitstatus, stdout: out_r.value, stderr: err_r.value,
                 duration_seconds: (monotonic - started).round(3), timed_out: timed_out)
    end

    private

    attr_reader :chdir, :env, :timeout_seconds, :stdin_data, :on_output, :stop_check, :on_start

    # THE provider-start boundary (MVP-0036 CR-004 F3, corrected by CR-005 F2): the child exists
    # and its input REALLY reached it — by argv at spawn, or by a stdin write that completed. It
    # is the one honest instant at which a caller may record "this process received what we gave
    # it": before it, nothing was started; after it, the child may already have acted.
    #
    # A child that was gone before it read a byte received nothing, so nothing may be told it
    # did. That case is an ordinary early exit when no callback was requested — which is what it
    # has always been, and F2.4 keeps it that way — but a caller that asked to be told the input
    # arrived needs the LAUNCH to fail, not an exit code that looks like the task's own. Raising
    # here reaches `Executor#run`'s existing SystemCallError rescue, so it becomes the same
    # `launch_error` every other "no provider ran this" already produces.
    def deliver_and_wait(pid)
      return wait_or_kill(pid) if on_start.nil?

      unless @input_delivered
        terminate_group(pid)
        raise Errno::EPIPE, "the child closed its input before the prompt was delivered"
      end

      notify_started(pid)
      wait_or_kill(pid)
    end

    # Deliberately NOT swallowed the way `on_output` is. That one is a progress display and must
    # never fail the execution it reports on; this one is a decision about whether the run may
    # continue at all, and a caller that cannot record the handoff has to be able to stop it. The
    # process group is ended first so a raising callback can never leave an orphaned child and a
    # run stuck CLAIMED (the QUALITY-0002 failure class).
    def notify_started(pid)
      on_start&.call
    rescue StandardError
      terminate_group(pid)
      raise
    end

    def spawn_process(argv)
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      in_r, in_w = IO.pipe
      pid = Process.spawn(env, *argv, chdir: chdir, out: out_w, err: err_w, in: in_r, pgroup: true)
      [ out_w, err_w, in_r ].each(&:close)
      @input_delivered = write_stdin(in_w)
      [ reader_thread(out_r, STDOUT), reader_thread(err_r, STDERR), pid ]
    end

    # True when the child really has its input: there was none to give, or all of it was written.
    def write_stdin(io)
      io.write(stdin_data) if stdin_data
      true
    rescue Errno::EPIPE
      # The child exited before reading stdin. Not an error in itself — see {#deliver_and_wait}
      # for why it stops mattering only when nobody asked to be told the input arrived.
      false
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

    # One wait loop for both reasons a child stops early. It replaces the old
    # `Timeout.timeout(...) { waitpid }` because a blocking wait cannot also observe a stop
    # signal, and giving the two reasons separate implementations would mean two shutdown
    # graces that could drift apart.
    def wait_or_kill(pid)
      deadline = monotonic + timeout_seconds
      loop do
        return [ false, $? ] if reaped?(pid)
        return [ true, terminate_group(pid) ] if monotonic >= deadline
        return [ false, terminate_group(pid) ] if stop_requested?

        sleep WAIT_POLL_SECONDS
      end
    rescue Errno::ECHILD
      [ false, nil ]
    end

    # A stop predicate must never be able to fail the execution it is watching, for the same
    # reason the live-output consumer cannot: it is an observer, not a decision.
    def stop_requested?
      stop_check&.call ? true : false
    rescue StandardError
      false
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
