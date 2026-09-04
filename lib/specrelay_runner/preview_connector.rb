# frozen_string_literal: true

require "fileutils"
require "net/http"
require "socket"
require "tmpdir"

module SpecrelayRunner
  # The ONE outbound connector a connected machine runs for as long as its loop is active.
  #
  # The guided connection already provisioned this machine its own connector and put the token in
  # the operating system's secret store. This is what runs it: the operator installs the program
  # and supplies nothing else — no account credential, no credential file, no certificate, no
  # tunnel name, no zone, no environment setting. There is deliberately no other way to start it,
  # so a machine that has not connected cannot run one at all.
  #
  # IT BELONGS TO THE LOOP SESSION, not to a task or a preview. {LoopRunner} starts it before its
  # first claim, asks it once per poll whether the child is still there, and stops it on every exit
  # path it has. That is the whole supervision: no daemon, no second process to watch this one, and
  # no retry framework — an unexpected exit is answered on the loop's own bounded cadence, which is
  # already the interval at which this session does everything else.
  #
  # THE TOKEN'S ONLY APPEARANCE OUTSIDE THE SECRET STORE is a file this process creates for it
  # under the machine's private temporary root — outside every repository and outside the runner's
  # own state — read `0600` from a `0700` directory, named in argv and nowhere else, and removed as
  # soon as the child has acquired it. Readiness is what proves acquisition: a connector that has
  # registered a connection has already read the token it registered with. `--token` is never used:
  # an argv element is visible in the process table to every process running as this user.
  #
  # Its output goes nowhere. The child logs the connector identity it is serving, which is the
  # machine-scoped fact this design keeps out of pages, results and logs — so its streams are
  # discarded rather than captured, and every reason this class reports is one of its own bounded
  # sentences naming only the one thing the operator has to do.
  #
  # IT KEEPS NO DURABLE STATE. The per-preview tunnel persists a configuration and a pid because
  # its child outlives the runner process and a later reconnect has to account for it. This child
  # is bounded by a loop that is running right now, so there is nothing for a later process to
  # adopt and nothing a reconnect has to fence.
  class PreviewConnector
    EXECUTABLE = "cloudflared"

    # The exact command this class spawns. `--no-autoupdate` is not a preference: a child that
    # replaced itself would break the one thing this class guarantees, which is that the process it
    # is holding is the process it started.
    TUNNEL_VERB = "tunnel"
    RUN_VERB = "run"
    NO_AUTOUPDATE_FLAG = "--no-autoupdate"
    METRICS_FLAG = "--metrics"
    TOKEN_FILE_FLAG = "--token-file"

    # The private file the token is delivered in, and the directory made for it. Both are created
    # with their final mode rather than chmod-ed afterwards, so there is no instant at which the
    # token is readable by anything else.
    TOKEN_DIRECTORY_PREFIX = "specrelay-preview-connector"
    TOKEN_FILE = "connector"
    TOKEN_FILE_MODE = 0o600

    READY_TIMEOUT_SECONDS = 60
    READY_POLL_SECONDS = 0.25
    PROBE_TIMEOUT_SECONDS = 1
    STOP_GRACE_SECONDS = 10

    # The exceptions a LOCAL readiness probe may see while the child is still coming up. Named
    # rather than rescued broadly: a connection that is not there yet is weather, and anything else
    # must surface.
    PROBE_FAILURES = [ SystemCallError, Timeout::Error, EOFError, SocketError, IOError,
                       Net::HTTPBadResponse, Net::ProtocolError ].freeze

    # The three refusals, and the one action each names. None of them mentions the local secret
    # store, the account it looked in, or anything the operator cannot act on.
    NO_STORED_CONNECTOR = "this machine has no stored preview connector"
    NOT_INSTALLED = "the preview connector program (#{EXECUTABLE}) is not installed on this machine"
    NOT_READY = "this machine's preview connector did not become ready"
    RECONNECT = "Reconnect this machine: specrelay-runner connect <enrollment-code>"
    INSTALL = "Install #{EXECUTABLE}, then start this runner again."

    EXITED_NOTICE = "preview connector stopped unexpectedly — starting it again"

    # What the loop must do next, in the same two states {Presence} reports: carry on, or stop and
    # tell the operator why. A refusal is PERMANENT by construction — a machine with no stored
    # connector and a machine with no program to run are both states no wait would fix.
    Outcome = Struct.new(:message, :remedy, keyword_init: true) do
      def ok? = message.nil?
      def stop? = !ok?
    end

    OK = Outcome.new.freeze

    # A loop with no connection record — an advanced `--config` invocation — has no machine
    # identity to read a connector for and manages none. A null object rather than a nil check at
    # three call sites in {LoopRunner}.
    class Disabled
      def started = OK
      def restart_if_exited = OK
      def stopped = nil
    end

    NONE = Disabled.new

    # `executable` is the collaborator this class launches and `ready_timeout_seconds` the one wait
    # it performs. Both are constructor arguments so this class's own test can hand it a stand-in
    # child and a short bound; nothing configures them, and no assignment can name them.
    def initialize(runner_public_id:, secret_store:, executable: EXECUTABLE,
                   ready_timeout_seconds: READY_TIMEOUT_SECONDS, on_notice: nil)
      @runner_public_id = runner_public_id.to_s
      @secret_store = secret_store
      @executable = executable
      @ready_timeout_seconds = ready_timeout_seconds
      @on_notice = on_notice || ->(_message) { }
      @pid = nil
      @exited = false
    end

    # Started before the loop's first claim, so a machine that cannot run its connector refuses
    # before it holds any work rather than after. A session that already owns a healthy child gets
    # that one back: there is exactly one connector per loop, and starting twice is not a reason
    # for a second process.
    def started
      running? ? OK : launch
    end

    # Asked once per poll, which makes the loop's own interval the cadence. A child that is still
    # there is not touched; one that has gone is reported once and started again on this tick
    # rather than immediately, so an exit can never become a spin.
    def restart_if_exited
      return OK if @pid.nil? || running?

      forget_child
      @on_notice.call(EXITED_NOTICE)
      launch
    end

    # Best effort, on every exit path the loop has — an ordinary end, a refusal, Ctrl-C, SIGTERM,
    # or an exception on its way past. It cannot change the session's result, which the work has
    # already decided, and it must never be the reason a session fails; what it must do is leave no
    # child and no file, which is why both removals happen whatever the shutdown answered.
    def stopped
      terminate if @pid
      nil
    rescue StandardError
      nil
    ensure
      forget_child
      discard_token_directory
    end

    private

    attr_reader :runner_public_id, :secret_store, :executable

    # ONE attempt: the stored token, one child, one bounded wait for that child's own readiness.
    # The token file is removed on the way out of every one of those outcomes.
    def launch
      token = stored_token
      return refusal(NO_STORED_CONNECTOR, RECONNECT) if token.nil?

      outcome = start_child(token)
      stopped if outcome.stop?
      outcome
    ensure
      discard_token_directory
    end

    # The token is materialized as late as possible and `spawn` is the authority on whether the
    # program exists: resolving the executable against PATH here would be a second copy of the
    # rule the operating system already applies, and the two disagreeing is the defect that copy
    # would introduce. So a missing program is `ENOENT` from the spawn itself, and the token file
    # that was written a moment earlier is removed by the caller's `ensure`.
    def start_child(token)
      port = free_port
      # Its own process group, so a stop ends the whole child tree rather than one process. Both
      # streams are discarded: they name this machine's connector identity.
      @pid = Process.spawn({}, *spawn_argv(write_token(token), port),
                           out: File::NULL, err: File::NULL, pgroup: true)
      @exited = false
      ready?(port) ? OK : refusal(NOT_READY, RECONNECT)
    rescue Errno::ENOENT, Errno::EACCES
      refusal(NOT_INSTALLED, INSTALL)
    rescue SystemCallError
      refusal(NOT_READY, RECONNECT)
    end

    # The connector token stored under THIS machine's identity, and nothing else: no Cloudflare
    # account authority, no operator-authored setting, and no other account. A missing item is a
    # normal state — a machine that has not connected since its connector was provisioned — and it
    # is reported as the one action that fixes it.
    def stored_token
      secret_store.read(account: SecretStore.preview_connector_account_for(runner_public_id))
    end

    def spawn_argv(token_path, port)
      [ executable, TUNNEL_VERB, NO_AUTOUPDATE_FLAG, METRICS_FLAG, "127.0.0.1:#{port}",
        RUN_VERB, TOKEN_FILE_FLAG, token_path ]
    end

    # `EXCL` and the mode at creation, so the file is private from the instant it exists rather
    # than from the chmod after it. `mktmpdir` creates its directory `0700`.
    def write_token(token)
      @token_directory = Dir.mktmpdir(TOKEN_DIRECTORY_PREFIX)
      path = File.join(@token_directory, TOKEN_FILE)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, TOKEN_FILE_MODE) do |file|
        file.write(token)
      end
      path
    end

    # The whole directory, so the file cannot be left behind by a path this class computed twice.
    def discard_token_directory
      directory = @token_directory
      @token_directory = nil
      FileUtils.remove_entry(directory) if directory && File.directory?(directory)
    rescue SystemCallError
      nil
    end

    # A child this object spawned is answered by a non-blocking reap, which is remembered because
    # a reaped child cannot be waited on twice. This class only ever holds its own children, so
    # there is no adopted case to ask the process table about.
    def running?
      return false if @pid.nil? || @exited

      @exited = !Process.waitpid(@pid, Process::WNOHANG).nil?
      !@exited
    rescue Errno::ECHILD
      @exited = true
      false
    end

    def forget_child
      @pid = nil
      @exited = false
    end

    def ready?(port)
      deadline = monotonic + @ready_timeout_seconds
      loop do
        return false unless running?
        return true if registered?(port)
        return false if monotonic >= deadline

        sleep(READY_POLL_SECONDS)
      end
    end

    # The child's own local readiness answer, on loopback: the connector client's statement about
    # its own connections, so nothing about this asks a provider anything.
    def registered?(port)
      Net::HTTP.start("127.0.0.1", port, open_timeout: PROBE_TIMEOUT_SECONDS,
                                         read_timeout: PROBE_TIMEOUT_SECONDS) do |http|
        http.get("/ready").code == "200"
      end
    rescue *PROBE_FAILURES
      false
    end

    # TERM the group, wait out the grace, then KILL it.
    def terminate
      signal("TERM")
      deadline = monotonic + STOP_GRACE_SECONDS
      sleep(READY_POLL_SECONDS) while running? && monotonic < deadline
      return unless running?

      signal("KILL")
      sleep(READY_POLL_SECONDS) while running? && monotonic < deadline + STOP_GRACE_SECONDS
    end

    def signal(name)
      Process.kill(name, -Process.getpgid(@pid))
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    # An ephemeral loopback port for the child's readiness endpoint, chosen by the operating
    # system and handed straight over.
    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    def refusal(message, remedy) = Outcome.new(message: message, remedy: remedy)
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
