# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "uri"

module SpecrelayRunner
  # Which work-running sessions may run together on one OS account.
  #
  # Platform keeps one presence session and one active execution per registration, and a machine
  # holds a separate registration per project. Sessions of two SAVED connections with different
  # registrations share nothing on the server and each keeps its own project, credential and root,
  # so they may run at the same time. Two sessions of the SAME registration would overwrite each
  # other's presence, so they may not — and nothing on the server stops them, so the guard is local.
  #
  # A saved connection names its registration by the public id Platform issued for it, which
  # survives reconnect and credential rotation. A hand-written config has nothing like it — its
  # `runner.id` is the client's own claim and its credential changes on rotation — so a session
  # started from one runs alone. Two `flock`s under the operator's own home express both rules:
  #
  #   ~/.specrelay/runner/session.lock              the gate: shared by saved sessions,
  #                                                 exclusive for a hand-written one
  #   ~/.specrelay/runner/sessions/<digest>.lock    one per registration, exclusive
  #
  # The digest covers the Platform origin and the stored public id and nothing else. Deriving it
  # from the project, the working directory, the checkout, the config path, the state-file
  # override, a declared id or the credential would let a second session of one registration slip
  # past simply by pointing somewhere else. Neither file holds content or is ever read; only the
  # locks on them mean anything.
  #
  # NON-BLOCKING on purpose. A queued second session looks identical to a hung one from the
  # terminal, and the honest answer to "can I start this now?" is no, said immediately.
  #
  # The gate is taken first and the registration second. Every descriptor taken is closed through
  # the ordinary ensure boundary, so every ending releases exactly what was acquired: a normal
  # return, a startup failure, an exception, an interrupt, and a refusal after the gate was already
  # taken. The FILES are deliberately left behind — unlinking one would let a later session create
  # a second file at the same name and lock that instead, while this one still held the first.
  # Close-on-exec is set so a provider or connector this session launches cannot inherit a
  # descriptor and keep the session claimed after the runner itself has gone.
  #
  # SCOPE. This is a same-OS-user local guard, not a distributed claim: another user, another
  # host, or a runner installation that predates it does not participate. A process killed by the
  # OS releases its locks the way the kernel releases every descriptor, and any external work it
  # left behind remains subject to the existing recovery behaviour.
  class SessionLock
    # Raised when another session on this machine already holds a lock this one needs. The message
    # is the operator's whole remedy: there is exactly one thing to do about it.
    Busy = Class.new(StandardError)

    Error = Class.new(StandardError)

    RELATIVE_PATH = ".specrelay/runner/session.lock"
    REGISTRATION_DIRECTORY = ".specrelay/runner/sessions"

    REGISTRATION_BUSY = "another SpecRelay runner session for this Runner registration is already running on this machine"
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

    def self.registration_path(base_url:, runner_public_id:, env: ENV)
      registration = Digest::SHA256.hexdigest(JSON.generate([ platform_origin(base_url), runner_public_id.to_s ]))
      File.join(home(env), REGISTRATION_DIRECTORY, "#{registration}.lock")
    end

    # Requests go to the Platform's origin, so a path or trailing slash does not name another one.
    def self.platform_origin(base_url)
      uri = URI.parse(base_url.to_s)
      uri.is_a?(URI::HTTP) ? uri.origin : base_url.to_s
    rescue URI::InvalidURIError
      base_url.to_s
    end

    # A saved connection's session: the gate shared, then its own registration exclusive.
    def self.saved(base_url:, runner_public_id:, env: ENV)
      new([ path(env: env), File::LOCK_SH, EXCLUSIVE_BUSY ],
          [ registration_path(base_url: base_url, runner_public_id: runner_public_id, env: env),
            File::LOCK_EX, REGISTRATION_BUSY ])
    end

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
