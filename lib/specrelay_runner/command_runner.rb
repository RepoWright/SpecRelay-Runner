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
  class CommandRunner
    MAX_CAPTURE_BYTES = 1_000_000
    TERM_GRACE_SECONDS = 5

    Result = Struct.new(:exit_code, :stdout, :stderr, :duration_seconds, :timed_out, keyword_init: true) do
      def success? = !timed_out && exit_code == 0
      def timed_out? = timed_out ? true : false
    end

    def self.run(argv, **kwargs) = new(**kwargs).run(argv)

    def initialize(chdir:, env: {}, timeout_seconds: 1800, stdin_data: nil)
      @chdir = chdir.to_s
      @env = env.to_h.transform_keys(&:to_s).transform_values(&:to_s)
      @timeout_seconds = timeout_seconds
      @stdin_data = stdin_data
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

    attr_reader :chdir, :env, :timeout_seconds, :stdin_data

    def spawn_process(argv)
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      in_r, in_w = IO.pipe
      pid = Process.spawn(env, *argv, chdir: chdir, out: out_w, err: err_w, in: in_r, pgroup: true)
      [ out_w, err_w, in_r ].each(&:close)
      write_stdin(in_w)
      [ reader_thread(out_r), reader_thread(err_r), pid ]
    end

    def write_stdin(io)
      io.write(stdin_data) if stdin_data
    rescue Errno::EPIPE
      # child exited before reading stdin; not an error
    ensure
      io.close
    end

    def reader_thread(io)
      Thread.new do
        data = +""
        while (chunk = io.read(64 * 1024))
          data << chunk if data.bytesize < MAX_CAPTURE_BYTES
        end
        io.close
        bounded(data).dup.force_encoding(Encoding::UTF_8).scrub("")
      end
    end

    def bounded(data)
      return data if data.bytesize <= MAX_CAPTURE_BYTES

      "#{data.byteslice(0, MAX_CAPTURE_BYTES)}\n[output truncated at #{MAX_CAPTURE_BYTES} bytes]\n"
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
