# frozen_string_literal: true

require "fileutils"

module SpecrelayRunner
  # Which work-running sessions may run together on one OS account.
  #
  # How many terminals of one registration may work at once is Platform's decision: each session is
  # admitted against the registration's stored maximum before it does anything else. Sessions of
  # SAVED connections therefore need nothing from each other locally, whichever registration they
  # belong to. A hand-written config has no stored registration identity on this machine — its
  # `runner.id` is the client's own claim — so a session started from one runs alone. One `flock`
  # under the operator's own home expresses that:
  #
  #   ~/.specrelay/runner/session.lock    shared by saved sessions, exclusive for a hand-written one
  #
  # The file holds no content and is never read; only the lock on it means anything.
  #
  # NON-BLOCKING on purpose. A queued second session looks identical to a hung one from the
  # terminal, and the honest answer to "can I start this now?" is no, said immediately.
  #
  # The descriptor is closed through the ordinary ensure boundary, so every ending releases it: a
  # normal return, a startup failure, an exception and an interrupt. The FILE is deliberately left
  # behind — unlinking it would let a later session create a second file at the same name and lock
  # that instead, while this one still held the first. Close-on-exec is set so a provider or
  # connector this session launches cannot inherit the descriptor and keep the session claimed after
  # the runner itself has gone.
  #
  # SCOPE. This is a same-OS-user local guard, not a distributed claim: another user, another
  # host, or a runner installation that predates it does not participate. A process killed by the
  # OS releases its lock the way the kernel releases every descriptor, and any external work it
  # left behind remains subject to the existing recovery behaviour.
  class SessionLock
    # Raised when another session on this machine already holds a lock this one needs. The message
    # is the operator's whole remedy: there is exactly one thing to do about it.
    Busy = Class.new(StandardError)

    Error = Class.new(StandardError)

    RELATIVE_PATH = ".specrelay/runner/session.lock"

    EXCLUSIVE_BUSY = "a SpecRelay runner session using a hand-written config is already running on this machine " \
                     "and runs only alone"
    GATE_BUSY = "another SpecRelay runner session is already running on this machine, and a session using a " \
                "hand-written config runs only alone"

    # The operator's own home, from the environment the OS sets, so a test can point one
    # invocation at an isolated home without this becoming a runner setting anybody configures.
    def self.home(env)
      home = env["HOME"].to_s.strip
      home.empty? ? Dir.home : home
    end

    def self.path(env: ENV) = File.join(home(env), RELATIVE_PATH)

    # A saved connection's session: the gate shared. Platform admits it against its registration.
    def self.saved(env: ENV) = new([ path(env: env), File::LOCK_SH, EXCLUSIVE_BUSY ])

    # A hand-written config's session: the gate exclusive, so it runs alone.
    def self.exclusive(env: ENV) = new([ path(env: env), File::LOCK_EX, GATE_BUSY ])

    # Each lock is [path, flock mode, what a refusal of it means], in acquisition order.
    def initialize(*locks)
      @locks = locks
    end

    # Run the block while holding every lock, or raise Busy without running it at all. Raising
    # rather than returning a value keeps the caller from mistaking a refusal for a result the
    # block produced.
    def hold
      files = []
      @locks.each { |path, mode, running| files << acquire(path, mode, running) }
      yield
    ensure
      # Closing releases a lock. The files stay.
      files.each { |file| file.close unless file.closed? }
    end

    private

    def acquire(path, mode, running)
      file = open_lock_file(path)
      return file if file.flock(mode | File::LOCK_NB)

      file.close
      raise Busy, busy_message(path, running)
    end

    def busy_message(path, running)
      pid = lock_holder_pid(path)
      return "#{running}. Stop it first (Ctrl-C in its terminal), then start this one." unless pid

      "#{running} (PID #{pid}). To stop it, run:\n  kill -CONT #{pid}\n  kill -TERM #{pid}\nThen start this one."
    end

    # The lock files stay empty, so this identifies the holder without any recorded state. An
    # ambiguous or unavailable OS lookup keeps the refusal without guessing a PID.
    def lock_holder_pid(path)
      output = IO.popen([ "lsof", "-nP", "-t", "--", path ], err: File::NULL, &:read)
      pids = output.lines.map(&:strip).uniq
      pids.first if pids.length == 1 && pids.first.match?(/\A[1-9]\d*\z/)
    rescue Errno::ENOENT, IOError, SystemCallError
      nil
    end

    def open_lock_file(path)
      FileUtils.mkdir_p(File.dirname(path))
      file = File.open(path, File::RDWR | File::CREAT, 0o600)
      file.close_on_exec = true
      file
    rescue SystemCallError, IOError => e
      raise Error, "could not open the runner session lock #{path} (#{e.class}). Make sure that " \
                   "path's directory exists and this user can write to it, then try again."
    end
  end
end
