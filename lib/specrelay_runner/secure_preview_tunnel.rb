# frozen_string_literal: true

require "digest"
require "fileutils"
require "net/http"
require "socket"
require "yaml"

module SpecrelayRunner
  # The one outbound connection that makes an already-running local preview reachable
  # from outside this machine's network, and nothing else.
  #
  # It is a SUBORDINATE CHILD of the claim that started it, in the strict sense: it opens no
  # listener, calls no provider API, discovers nothing about the project, and is derived entirely
  # from two things the claim already holds — the namespace Platform put in the assignment and the
  # service snapshot the project's own status command already reported and Platform already
  # validated. Nothing here reads a hostname, a port or a URL from anywhere else.
  #
  # The ingress it renders is EXACT. One rule per already-validated service, matched on the whole
  # hostname, and a final rule that answers everything else with 404. There is no wildcard, no
  # catch-all origin and no path rule, so a request for a service this preview does not publish
  # reaches nothing rather than reaching the first rule that happens to match.
  #
  # Its output goes nowhere. `cloudflared` logs the hostnames it is serving, and those are the
  # hidden names the whole design keeps out of pages, results and logs — so the child's streams are
  # discarded rather than captured, and every reason this class reports is one of its own bounded
  # sentences.
  #
  # It performs no retry. One start, one honest outcome, and the local preview is untouched either
  # way: a machine that cannot publish remotely is still a machine a person standing at it can use.
  class SecurePreviewTunnel
    # The three local deployment facts. They are provisioned once per eligible Runner and never
    # travel: Platform learns none of them, and the assignment carries none of them.
    TUNNEL_ENV = "SPECRELAY_PREVIEW_TUNNEL"
    CREDENTIALS_ENV = "SPECRELAY_PREVIEW_TUNNEL_CREDENTIALS"
    HIDDEN_ZONE_ENV = "SPECRELAY_PREVIEW_HIDDEN_ZONE"

    EXECUTABLE = "cloudflared"
    # The terminal ingress rule. Cloudflare requires a last rule with no hostname; making it a 404
    # rather than an origin is what stops an unmatched request reaching an application.
    TERMINAL_RULE = "http_status:404"

    # The exact arguments this class spawns, and therefore the exact identity it will adopt.
    TUNNEL_VERB = "tunnel"
    CONFIG_FLAG = "--config"
    RUN_VERB = "run"

    # The only durable state this class keeps, and the only reason it keeps any: the child runs in
    # its OWN process group, so a runner process that dies leaves it publishing an environment
    # nobody is holding. The release Platform hands back on reconnect is the first thing in a
    # position to end it, and by then the child exists only on disk. One private directory per
    # attempt under the runner's existing local state root, holding the configuration the child was
    # started with and the pid it was given, and removed only once that child is accounted for.
    STATE_RELATIVE_PATH = ".specrelay/runner/preview-tunnels"
    CONFIGURATION_FILE = "config.yml"
    PID_FILE = "pid"
    STATE_DIRECTORY_MODE = 0o700
    STATE_FILE_MODE = 0o600

    # The local process table. It is a collaborator for the same reason `executable` is: this
    # class's own test has to be able to make the probe fail and to make it answer ambiguously,
    # and neither of those can be provoked from a passing operating system on demand.
    PROCESS_PROBE = "ps"

    # The three fields this class reads, each asked for on its own. `comm` is the one that says
    # what a process IS: the kernel fills it in from the file that was executed, so no argument any
    # program was handed can reach it. `args` and `pid` are only ever asked what a process was
    # given and which number it has.
    COMM_FIELD = "comm="
    ARGUMENTS_FIELD = "args="
    PID_FIELD = "pid="
    # One supported system reports `comm` truncated to this width. `cloudflared` fits; a longer
    # executable name would not, and a name that cannot survive the field cannot be compared.
    COMM_MAX_LENGTH = 15

    # The hidden hostname is ONE label below the zone, packed exactly as Platform packs it: 64 bits
    # of service digest, the full 128-bit attempt token, then the full 128-bit namespace, written
    # as one zero-padded base36 number. A second label could not be covered by an ordinary
    # first-level wildcard certificate, and truncating any field would make the two ends disagree
    # about a name that must be identical.
    SERVICE_DIGEST_LENGTH = 16
    ATTEMPT_TOKEN_LENGTH = 32
    NAMESPACE_LENGTH = 32
    PACKED_LENGTH = SERVICE_DIGEST_LENGTH + ATTEMPT_TOKEN_LENGTH + NAMESPACE_LENGTH
    PACKED = /\A[0-9a-f]{#{PACKED_LENGTH}}\z/
    LABEL_PREFIX = "v"
    LABEL_BASE = 36
    LABEL_DIGITS = 62
    READY_TIMEOUT_SECONDS = 60
    READY_POLL_SECONDS = 0.25
    PROBE_TIMEOUT_SECONDS = 1
    STOP_GRACE_SECONDS = 10

    # The exceptions a LOCAL readiness probe may see while the child is still coming up. Named
    # rather than rescued broadly: a connection that is not there yet is weather, and anything else
    # must surface.
    PROBE_FAILURES = [ SystemCallError, Timeout::Error, EOFError, SocketError, IOError,
                       Net::HTTPBadResponse, Net::ProtocolError ].freeze

    Result = Struct.new(:ok, :reason, keyword_init: true) do
      def ok? = ok
    end

    # `executable` is the collaborator this class launches, `process_probe` the one it asks about
    # processes, and `ready_timeout_seconds` the one wait it performs. All three are constructor
    # arguments so this class's own test can hand it a stub child, a probe that fails or answers
    # ambiguously, and a short bound; nothing configures them, and no assignment can name them.
    def initialize(preview_id:, namespace:, services:, env: ENV, executable: EXECUTABLE,
                   ready_timeout_seconds: READY_TIMEOUT_SECONDS, process_probe: PROCESS_PROBE)
      @preview_id = preview_id.to_s
      @namespace = namespace.to_s
      @services = Array(services)
      @env = env
      @executable = executable
      @ready_timeout_seconds = ready_timeout_seconds
      @process_probe = process_probe
      @pid = nil
      @own_child = false
    end

    # One attempt. Ready means this machine's own tunnel client says it has registered a
    # connection — a local fact, read from the child's own metrics endpoint, never a provider API.
    def start
      refusal = provisioning_refusal
      return failure(refusal) if refusal

      port = free_port
      launch(port)
      return Result.new(ok: true) if ready?(port)

      stop
      failure("the secure preview tunnel did not become ready")
    rescue SystemCallError => e
      stop
      failure("the secure preview tunnel could not be started: #{safe(e.message)}")
    end

    # Is the tunnel process still there? A child this object spawned is answered by a non-blocking
    # reap, which is remembered because a reaped child cannot be waited on twice. One adopted from
    # a record was spawned by a process that no longer exists, so signal 0 is the only honest
    # question to ask about it.
    def running?
      return false if @pid.nil?

      @own_child ? unreaped_child? : signalable?
    end

    # Is this attempt's tunnel accounted for? The answer decides whether the project-owned release
    # may run, so it is PROVED, never assumed. Exactly three things count as proof:
    #
    #   * no attempt state was ever established, so no child was ever spawned;
    #   * the exact recorded child was stopped and then confirmed gone; or
    #   * the recorded number is positively running something else, which proves the child exited
    #     and its pid was reused.
    #
    # Everything else is NOT accounted: a pid file that will not parse or was half written, a probe
    # that would not answer, a command line that matches more than one process, a shutdown whose
    # disappearance could not be confirmed. Those return false and leave every file exactly where
    # it is — for the retry, and for a person to look at — and the caller keeps its existing
    # release obligation rather than releasing an environment a process may still be publishing.
    def stop
      accounted = account
      discard_state if accounted
      accounted
    end

    # The exact document handed to the child. Public because it IS the boundary this class is
    # judged on: one rule per validated service, matched whole, and a final 404.
    def configuration(metrics_port)
      { "tunnel" => setting(TUNNEL_ENV), "credentials-file" => setting(CREDENTIALS_ENV),
        "metrics" => "127.0.0.1:#{metrics_port}", "no-autoupdate" => true, "ingress" => ingress }
    end

    # The one directory this attempt owns on this machine. Public for the same reason
    # `configuration` is: it is what the class leaves behind, and it is the only path it removes.
    #
    # The name is a DIGEST of the preview id rather than the id itself. The id arrives over the
    # wire as free text, and this is the one place it would otherwise choose a path — a value
    # containing a separator would name a directory outside the runner's own state root, which
    # this class then writes into and deletes.
    def state_directory
      File.join(home, STATE_RELATIVE_PATH,
                Digest::SHA256.hexdigest(@preview_id)[0, ATTEMPT_TOKEN_LENGTH])
    end

    private

    attr_reader :services, :env, :executable, :process_probe

    def configuration_path = File.join(state_directory, CONFIGURATION_FILE)
    def pid_path = File.join(state_directory, PID_FILE)

    # Every service the project reported and Platform accepted, and nothing else. The hostname is
    # derived from the stored service key exactly as Platform derives it, so a name either side
    # computes differently simply never resolves.
    def ingress
      services.map do |service|
        { "hostname" => hidden_host(service["service"].to_s),
          "service" => service["url"].to_s.chomp("/") }
      end + [ { "service" => TERMINAL_RULE } ]
    end

    def hidden_host(service_key)
      "#{label(service_key)}.#{setting(HIDDEN_ZONE_ENV)}"
    end

    # Nil for anything that is not exactly the three fixed-width fields, which is what
    # `provisioning_refusal` turns into one bounded refusal before a child is ever started.
    def label(service_key)
      packed = "#{Digest::SHA256.hexdigest(service_key)[0, SERVICE_DIGEST_LENGTH]}" \
               "#{attempt_token}#{@namespace}"
      return nil unless PACKED.match?(packed)

      "#{LABEL_PREFIX}#{packed.to_i(16).to_s(LABEL_BASE).rjust(LABEL_DIGITS, '0')}"
    end

    # The attempt label is the tail of the preview's own public id, which is what Platform
    # addresses this attempt by. Nothing new is invented for the hostname.
    def attempt_token = @preview_id[-ATTEMPT_TOKEN_LENGTH..].to_s

    # A machine that was never provisioned for remote access fails closed and says so once. It is
    # not an error state and not a retry: the local preview is running and stays running.
    def provisioning_refusal
      missing = [ TUNNEL_ENV, CREDENTIALS_ENV, HIDDEN_ZONE_ENV ].find { |key| setting(key).empty? }
      return "this runner is not provisioned for secure preview access" if missing
      return "this runner's secure preview credential file is missing" unless
        File.file?(setting(CREDENTIALS_ENV))
      return "this preview reports no service to publish" if services.empty?
      # The attempt token is the tail of an id that arrives over the wire, and the namespace is
      # the assignment's. Either being the wrong width would publish a name Platform never built.
      return "this preview's secure route inputs are malformed" if
        services.any? { |service| label(service["service"].to_s).nil? }

      nil
    end

    def setting(key) = env[key].to_s.strip

    # The configuration is written BEFORE the child exists, and the pid the moment after. That
    # order is what makes a crash survivable: a runner that dies between the two leaves a
    # configuration and no pid, which is the evidence reconnect needs to go looking for a child
    # rather than conclude there was never one.
    def launch(port)
      FileUtils.mkdir_p(state_directory, mode: STATE_DIRECTORY_MODE)
      write_atomically(configuration_path, YAML.dump(configuration(port)))
      # Its own process group, so this claim can end the whole child tree rather than one process.
      # Both streams are discarded: they name the hidden hostnames this design keeps private.
      @pid = Process.spawn({}, *spawn_argv, out: File::NULL, err: File::NULL, pgroup: true)
      @own_child = true
      write_atomically(pid_path, "#{@pid}\n")
    end

    # Written to a sibling name and renamed, because rename is the one filesystem operation that
    # either happens or does not. A runner killed mid-write leaves the previous content or the new
    # content — never half of either, which a later process would have to guess about.
    def write_atomically(path, content)
      pending = "#{path}.writing"
      File.write(pending, content)
      File.chmod(STATE_FILE_MODE, pending)
      File.rename(pending, path)
    end

    def spawn_argv = [ executable, TUNNEL_VERB, CONFIG_FLAG, configuration_path, RUN_VERB ]

    # ---- accounting ----------------------------------------------------------------------

    def account
      return terminate if @pid
      # Nothing was ever established here, so nothing was ever spawned.
      return true unless File.exist?(configuration_path)

      pid = recorded_pid
      return false if pid == :unusable
      return recover_unrecorded_child if pid == :absent

      account_recorded(pid)
    end

    # The pid a previous runner persisted. A file that is not there is a different fact from one
    # that will not parse: the first means the child may never have been recorded, the second
    # means this runner knows nothing and must not guess. Zero and one are refused outright —
    # `kill` reads a non-positive pid as "this process group", which is the runner itself.
    def recorded_pid
      return :absent unless File.exist?(pid_path)

      text = File.read(pid_path)
      return :unusable unless text.match?(/\A[0-9]+\s*\z/)

      value = Integer(text.strip, 10)
      value > 1 ? value : :unusable
    rescue SystemCallError, IOError
      :unusable
    end

    # A recorded number is a CANDIDATE, never a child. Nothing is signalled until the process it
    # names is proved to be this attempt's tunnel; a probe that will not answer proves nothing and
    # is not an accounted child.
    def account_recorded(pid)
      case identity(pid)
      when :absent then true    # the process is gone: the child has exited
      when :unknown then false  # this runner cannot tell what it is: signal nothing, release nothing
      # Running, and positively something else: the child exited and its number was handed out
      # again. That is proof the child is gone, and the process now holding the number is left
      # entirely alone.
      when :other then true
      else adopt_and_terminate(pid)
      end
    end

    # A runner that died between spawning the child and persisting its pid. The configuration file
    # is both the evidence that a child may exist and the exact identity that finds it: the process
    # table is searched for the one command line this class would have spawned, never for a program
    # by name. More than one match is ambiguity, and a search that will not answer is ignorance —
    # neither is an accounted child, and neither signals anything.
    def recover_unrecorded_child
      candidates = matching_processes
      return false if candidates.nil? || candidates.length > 1
      return true if candidates.empty?

      adopt_and_terminate(candidates.first)
    end

    def adopt_and_terminate(pid)
      @pid = pid
      @own_child = false
      terminate
    end

    # ---- process identity ----------------------------------------------------------------

    # WHAT A CANDIDATE IS, as two independent facts, both required before anything is signalled.
    #
    # The first fact is the PROGRAM, read from the process table's own `comm` field. That field is
    # filled in by the kernel from the file that was executed; it is asked for on its own, so the
    # whole answer is the field and nothing is carved out of flattened text. This is the fact
    # round 003 did not have: a process's argument list can end with any string at all — including
    # this class's argument shape and the name of its executable — while the program running it is
    # something else entirely. An argument cannot reach `comm`.
    #
    # The second fact is the ARGUMENTS: this attempt's own configuration path, as the value
    # following `--config`, with `run` last. It narrows the right program to the right attempt. It
    # is never asked to say what the program is.
    #
    # Four answers, and only one of them may lead to a signal.
    def identity(pid)
      return :unknown unless comparable_executable?

      program, presence = field(pid, COMM_FIELD)
      return presence unless presence == :ok
      return :other unless same_executable?(program)

      arguments, presence = field(pid, ARGUMENTS_FIELD)
      return presence unless presence == :ok

      arguments.end_with?(argument_tail) ? :mine : :other
    end

    # The attempt's own arguments. `ps` reports argv joined by spaces and there is no portable way
    # to take the fields back apart — a home directory may contain one — so this is an anchored
    # suffix rather than a field walk. It says the configuration path is what follows `--config`
    # and that `run` is last; it deliberately says nothing about which program was handed them.
    def argument_tail = " #{TUNNEL_VERB} #{CONFIG_FLAG} #{configuration_path} #{RUN_VERB}"

    # The comparison rule, stated once. `comm` is a full executable path on one supported system
    # and a bare file name on the other, so the two are compared on the file name: the name of the
    # program that was executed.
    def same_executable?(program) = File.basename(program.to_s) == File.basename(executable)

    # One supported system reports `comm` truncated to a fixed width. An executable whose file name
    # could not survive that truncation cannot be compared honestly, so no candidate is ever proved
    # and nothing is ever signalled — the release stays fenced instead of resting on a prefix.
    def comparable_executable? = File.basename(executable).length <= COMM_MAX_LENGTH

    # ONE process-table field, asked for on its own so that the whole line is the value. A reply
    # that is not exactly one line is not a field this class can read, and unreadable is unknown.
    def field(pid, specifier)
      output, status = probe("-o", specifier, "-p", pid.to_s)
      return [ nil, :absent ] if status == :none
      return [ nil, :unknown ] unless status == :ok

      lines = output.lines.map(&:strip).reject(&:empty?)
      lines.length == 1 ? [ lines.first, :ok ] : [ nil, :unknown ]
    end

    # Candidates for the crash window, found by the attempt's own configuration path in the
    # argument text — never by program name — and then put through the SAME complete proof a
    # recorded pid gets, one `comm` probe each. The argument scan narrows; it never decides. A
    # candidate this runner cannot identify makes the whole search unknown rather than being
    # quietly dropped from it.
    def matching_processes
      listing, status = probe("-A", "-o", "#{PID_FIELD},#{ARGUMENTS_FIELD}")
      return nil unless status == :ok

      proved = listing.lines.filter_map { |line| candidate_pid(line) }
                      .map { |pid| [ pid, identity(pid) ] }
      return nil if proved.any? { |_, answer| answer == :unknown }

      proved.select { |_, answer| answer == :mine }.map(&:first)
    end

    # Only the pid is taken from this line, and `ps` delimits it for us as the leading run of
    # digits. What the process IS is asked separately, per candidate, through `comm`.
    def candidate_pid(line)
      pid, arguments = line.strip.split(" ", 2)
      return nil unless pid&.match?(/\A[0-9]+\z/) && arguments.to_s.end_with?(argument_tail)

      Integer(pid, 10)
    end

    # `-ww` because a truncated command line is an identity this class cannot check, and `ps`
    # narrows to the terminal width without it. A status of 1 with nothing written is how `ps`
    # says the process is not there; anything else it does is an answer this class will not use.
    def probe(*arguments)
      output = IO.popen([ process_probe, "-ww", *arguments ], err: File::NULL, &:read).to_s
      status = $?
      return [ output, :unknown ] if status.nil?
      return [ output, :ok ] if status.success?

      status.exitstatus == 1 && output.strip.empty? ? [ output, :none ] : [ output, :unknown ]
    rescue SystemCallError, IOError
      [ "", :unknown ]
    end

    def unreaped_child?
      return false if @exited

      @exited = !Process.waitpid(@pid, Process::WNOHANG).nil?
      !@exited
    rescue Errno::ECHILD
      @exited = true
      false
    end

    # A process this runner did not spawn cannot be waited on. Signal 0 asks the kernel whether it
    # is still there; a process that exists but belongs to another user answers by refusing, which
    # is still an answer that it exists.
    def signalable?
      Process.kill(0, @pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # Removes ONLY this attempt's own directory, and only once the child named in it is accounted
    # for. The configuration a previous runner process wrote goes with it, which is what stops an
    # adopted cleanup leaving behind the document naming the hidden hostnames.
    def discard_state
      FileUtils.remove_entry(state_directory) if File.directory?(state_directory)
    rescue SystemCallError
      nil
    end

    def home = [ env["HOME"], Dir.home ].map(&:to_s).find { |value| !value.strip.empty? }

    def ready?(port)
      deadline = monotonic + @ready_timeout_seconds
      loop do
        return false unless running?
        return true if registered?(port)
        return false if monotonic >= deadline

        sleep(READY_POLL_SECONDS)
      end
    end

    # The child's own local readiness answer. It is on loopback and it is the tunnel client's
    # statement about its own connections, so nothing about this asks a provider anything.
    def registered?(port)
      Net::HTTP.start("127.0.0.1", port, open_timeout: PROBE_TIMEOUT_SECONDS,
                                         read_timeout: PROBE_TIMEOUT_SECONDS) do |http|
        http.get("/ready").code == "200"
      end
    rescue *PROBE_FAILURES
      false
    end

    # TERM the group, wait out the grace, then KILL it. Returns whether the child is really gone,
    # because that answer is what the release ordering depends on.
    def terminate
      signal("TERM")
      deadline = monotonic + STOP_GRACE_SECONDS
      sleep(READY_POLL_SECONDS) while running? && monotonic < deadline
      return true unless running?

      signal("KILL")
      sleep(READY_POLL_SECONDS) while running? && monotonic < deadline + STOP_GRACE_SECONDS
      !running?
    end

    def signal(name)
      Process.kill(name, -Process.getpgid(@pid))
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    # An ephemeral loopback port for the child's metrics server, chosen by the operating system and
    # handed straight over.
    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    def failure(reason) = Result.new(ok: false, reason: reason)
    def safe(text) = PrivatePaths.sanitize(Redaction.redact(text.to_s))
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
