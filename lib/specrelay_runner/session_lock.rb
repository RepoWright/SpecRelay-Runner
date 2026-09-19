# frozen_string_literal: true

require "fileutils"

module SpecrelayRunner
  # ONE work-running session per local OS user.
  #
  # A machine that holds a separate registration per project has a separate server-side work
  # queue per project, and Platform serializes work per registration. Nothing on the server
  # therefore prevents one laptop from running two projects' sessions at once — each of them
  # driving provider processes, task environments and checkouts on the same host, in the belief
  # that it is the only one doing so. The resource being protected is local, so the guard is too.
  #
  # It is a `flock` on one file under the operator's own home:
  #
  #   ~/.specrelay/runner/session.lock
  #
  # The location follows the USER and nothing else. Deriving it from the project, the working
  # directory, the checkout, the config path or the state-file override would let a second session
  # slip past simply by pointing somewhere else — which is precisely what an operator switching
  # projects does. The file holds no content and is never read; only the lock on it means anything.
  #
  # NON-BLOCKING on purpose. A queued second session looks identical to a hung one from the
  # terminal, and the honest answer to "can I start this now?" is no, said immediately.
  #
  # The lock is released by closing the descriptor, through the ordinary ensure boundary, so every
  # ending releases it: a normal return, a startup failure, an exception, and an interrupt. The
  # FILE is deliberately left behind — unlinking it would let a later session create a second file
  # at the same name and lock that instead, while this one still held the first. Close-on-exec is
  # set so a provider or connector this session launches cannot inherit the descriptor and keep
  # the session claimed after the runner itself has gone.
  #
  # SCOPE. This is a same-OS-user local guard, not a distributed claim: another user, another
  # host, or a runner installation that predates it does not participate. A process killed by the
  # OS releases the lock the way the kernel releases every descriptor, and any external work it
  # left behind remains subject to the existing recovery behaviour.
  class SessionLock
    # Raised when another session on this machine already holds the lock. The message is the
    # operator's whole remedy: there is exactly one thing to do about it.
    Busy = Class.new(StandardError)

    Error = Class.new(StandardError)

    RELATIVE_PATH = ".specrelay/runner/session.lock"

    BUSY_MESSAGE = "another SpecRelay runner session is already running on this machine. " \
                   "Stop it first (Ctrl-C in its terminal), then start this one."

    # The operator's own home, from the environment the OS sets, so a test can point one
    # invocation at an isolated home without this becoming a runner setting anybody configures.
    def self.path(env: ENV)
      home = env["HOME"].to_s.strip
      File.join(home.empty? ? Dir.home : home, RELATIVE_PATH)
    end

    def self.hold(env: ENV, &block) = new(path(env: env)).hold(&block)

    def initialize(path)
      @path = path.to_s
    end

    attr_reader :path

    # Run the block while holding the session, or raise Busy without running it at all. Raising
    # rather than returning a value keeps the caller from mistaking a refusal for a result the
    # block produced.
    def hold
      file = acquire
      begin
        yield
      ensure
        # Closing releases the lock. The file stays.
        file.close unless file.closed?
      end
    end

    private

    def acquire
      file = open_lock_file
      return file if file.flock(File::LOCK_EX | File::LOCK_NB)

      file.close
      raise Busy, BUSY_MESSAGE
    end

    def open_lock_file
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
