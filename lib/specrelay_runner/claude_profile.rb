# frozen_string_literal: true

module SpecrelayRunner
  # The ONE supported real provider profile (MVP-0016): Claude Code, launched
  # non-interactively by the runner in the task worktree Platform assigned.
  #
  # This is deliberately a single named profile and NOT a provider registry. It is
  # the narrow Runner-owned boundary where everything Claude-specific lives —
  # which argv is safe, whether the local CLI is ready, whether a claimed payload
  # really resolved to this profile, and how a failure is classified. Executor and
  # CommandRunner stay provider-agnostic: they only launch an argv array.
  #
  #   executor:
  #     provider: claude
  #     command: claude
  #     args: [--print, --dangerously-skip-permissions]
  #     prompt_delivery: argument
  #     timeout_seconds: 900
  #     env: {}
  #
  # Secret posture: this class NEVER reads, stores, returns, logs, or uploads a
  # provider credential, login token, or account identity. Claude authenticates
  # from the runner operator's own inherited environment on this host. The
  # readiness probe runs `claude auth status`, extracts a single boolean, and
  # DISCARDS the raw output — which carries the operator's email, org id, and org
  # name and must never reach a console, report, event, or Platform.
  class ClaudeProfile
    Error = Class.new(StandardError)

    PROVIDER = "claude"
    EXECUTABLE = "claude"
    PROMPT_DELIVERY = "argument"

    # The readiness/auth classifications this profile is allowed to record. They
    # are the ONLY thing the probes produce — never the underlying output.
    AVAILABLE = "available"
    UNAVAILABLE = "unavailable"
    AUTHENTICATED = "authenticated"
    NOT_AUTHENTICATED = "not_authenticated"
    CHECK_FAILED = "check_failed"

    # Terminal-result error classifications for a Claude execution that failed
    # after the claim (MVP-0016 scope 2). They are distinct so an operator can
    # tell a missing CLI from an expired login from a real execution failure.
    EXECUTOR_UNAVAILABLE = "executor_unavailable"
    EXECUTOR_NOT_AUTHENTICATED = "executor_not_authenticated"
    EXECUTOR_TIMEOUT = "executor_timeout"
    EXECUTOR_FAILED = "executor_failed"

    # Non-interactive output. `--print` (or `-p`) is what makes Claude Code answer
    # once and exit instead of opening a session, so it is mandatory.
    PRINT_FLAGS = %w[--print -p].freeze

    # Bounded so a hung CLI can never stall the runner before it claims. These are
    # metadata calls (no inference), so a few seconds is generous.
    PROBE_TIMEOUT_SECONDS = 20

    # Flags refused because each one breaks a boundary this MVP proves. Refusing
    # them here — rather than trusting the operator's YAML — is what makes
    # "non-interactive, text output, no session reuse, no MCP, no remote control"
    # an enforced property instead of a documented hope.
    FORBIDDEN_FLAGS = {
      "--output-format" => "text output is the supported evidence format; streamed/JSON output is not",
      "--input-format" => "streamed provider input is not part of this profile",
      "--mcp-config" => "a custom MCP configuration is out of scope for this profile",
      "--strict-mcp-config" => "a custom MCP configuration is out of scope for this profile",
      "--bg" => "an automated run must not start a background agent",
      "--background" => "an automated run must not start a background agent",
      "--chrome" => "an automated run must not enable Chrome control",
      "--remote-control" => "an automated run must not enable remote control",
      "--tmux" => "an interactive tmux session contradicts non-interactive execution",
      "-c" => "an implicit resumed conversation must not influence an automated run",
      "--continue" => "an implicit resumed conversation must not influence an automated run",
      "-r" => "an implicit resumed conversation must not influence an automated run",
      "--resume" => "an implicit resumed conversation must not influence an automated run",
      "--fork-session" => "session forking implies a resumed conversation",
      "--session-id" => "a pinned session id implies a reused conversation"
    }.freeze

    # Environment keys refused in the profile's `env:` block. That block is
    # non-secret logical config and it TRAVELS TO PLATFORM in the claim request,
    # so a credential smuggled in here would leave the operator's machine. Fail
    # closed rather than redact after the fact.
    CREDENTIAL_ENV = /(?:token|secret|password|passwd|credential|api[_-]?key|access[_-]?key|_key)\z/i

    # Local evidence that a non-zero Claude exit was an authentication problem
    # rather than a task failure. Matched against the executor's own captured
    # output, which the report already stores redacted.
    AUTH_FAILURE_HINT = /
      (?:not\s+logged\s+in) | (?:please\s+run\s+.?claude\s+auth) | (?:authentication\s+(?:required|failed)) |
      (?:invalid\s+api\s+key) | (?:unauthorized) | (?:401)
    /ix

    # The outcome of the local, no-edit readiness check. It carries ONLY the two
    # classifications — never the probe output.
    Readiness = Struct.new(:version, :auth, keyword_init: true) do
      def ready? = version == AVAILABLE && auth == AUTHENTICATED
      def summary = "claude=#{version}, auth=#{auth}"

      # A redacted, actionable remedy for the operator, or nil when ready.
      def remedy
        return nil if ready?
        return "install Claude Code so `claude` resolves on this runner's PATH" if version == UNAVAILABLE
        return "`claude --version` did not complete; check the local Claude Code installation" unless version == AVAILABLE
        return "run `claude auth login` as this runner's operator on this host" if auth == NOT_AUTHENTICATED

        "`claude auth status` did not complete; check the local Claude Code installation"
      end
    end

    # True when an executor config selects this real provider. Non-raising, so the
    # deterministic fake-executor path can ask without risking an exception.
    def self.selected?(executor_config)
      return false unless executor_config.is_a?(Hash)

      executor_config.transform_keys(&:to_s)["provider"].to_s.strip.downcase == PROVIDER
    end

    # Launches one bounded metadata probe. Returns a CommandRunner::Result, or nil
    # when the executable could not be launched at all (an absent CLI).
    #
    # `env` is the runner's EFFECTIVE process environment, threaded in explicitly
    # rather than read from the global ENV: Process.spawn resolves the executable
    # through the PATH it is handed, so the probe must look up `claude` on exactly
    # the PATH the executor will later launch it from. Reading a global here would
    # let readiness pass against one CLI and execution run another.
    def self.default_probe(env: ENV)
      path = env["PATH"].to_s
      lambda do |argv|
        CommandRunner.run(argv, chdir: Dir.pwd, env: { "PATH" => path }, timeout_seconds: PROBE_TIMEOUT_SECONDS)
      rescue SystemCallError
        nil
      end
    end

    attr_reader :command, :args, :prompt_delivery

    def initialize(executor_config)
      config = (executor_config || {}).to_h.transform_keys(&:to_s)
      raise Error, "executor.provider must be '#{PROVIDER}'" unless self.class.selected?(config)

      @command = presence(config["command"]) || EXECUTABLE
      @args = Array(config["args"]).map(&:to_s)
      @prompt_delivery = presence(config["prompt_delivery"]) || PROMPT_DELIVERY
      validate!(config)
    end

    # A stable, secret-free identity for the fields this profile owns. Two configs
    # with the same fingerprint launch the same process the same way.
    def fingerprint = [ PROVIDER, File.basename(command), args, prompt_delivery ]

    # A one-line, redacted description safe for a console line or a report field.
    def describe = Redaction.redact("#{PROVIDER} #{command} #{args.join(' ')} (prompt via #{prompt_delivery})")

    # The local, no-edit readiness check the runner performs BEFORE it asks
    # Platform for work: is the CLI installed, and is the operator logged in? It
    # sends no prompt, runs no inference, touches no repository, and consumes no
    # claim. `probe` is the injected command-execution seam (no ENV mutation, no
    # live CLI, no global process state in tests).
    def readiness(env: ENV, probe: nil)
      probe ||= self.class.default_probe(env: env)
      version = classify_version(probe.call([ command, "--version" ]))
      # Auth cannot be established when the CLI itself is not runnable. Reported as
      # check_failed (the "could not determine" classification) rather than as a
      # login problem the operator would then chase in the wrong place.
      return Readiness.new(version: version, auth: CHECK_FAILED) unless version == AVAILABLE

      Readiness.new(version: version, auth: classify_auth(probe.call([ command, "auth", "status" ])))
    end

    # Why the executor Platform actually resolved is not this profile, or nil when
    # it is. This is the fail-closed gate: the runner refuses to launch a command
    # it did not select, instead of silently executing another CLI or the fake.
    def mismatch_reason(payload_executor)
      claimed = self.class.new(payload_executor)
      return nil if claimed.fingerprint == fingerprint

      "claimed executor #{claimed.describe} is not the selected profile #{describe}"
    rescue Error => e
      "claimed executor is not a usable Claude Code profile (#{Redaction.redact(e.message)}); selected #{describe}"
    end

    # Classify a Claude execution that failed AFTER the claim, so the terminal
    # report says which local condition actually happened.
    def classify_failure(result)
      return EXECUTOR_UNAVAILABLE if result.respond_to?(:launch_error) && result.launch_error
      return EXECUTOR_TIMEOUT if result.timed_out
      return EXECUTOR_NOT_AUTHENTICATED if authentication_failure?(result)

      EXECUTOR_FAILED
    end

    private

    def authentication_failure?(result)
      [ result.stderr, result.stdout ].any? { |text| text.to_s.match?(AUTH_FAILURE_HINT) }
    end

    def validate!(config)
      raise Error, "executor.command must be the Claude Code CLI ('#{EXECUTABLE}')" unless claude_executable?
      raise Error, "executor.prompt_delivery must be '#{PROMPT_DELIVERY}' so the prompt stays a distinct argv element" unless prompt_delivery == PROMPT_DELIVERY
      raise Error, "executor.args must request non-interactive output (#{PRINT_FLAGS.join(' or ')})" unless non_interactive?

      forbidden = args.find { |arg| FORBIDDEN_FLAGS.key?(flag_name(arg)) }
      raise Error, "executor.args must not pass #{flag_name(forbidden)}: #{FORBIDDEN_FLAGS.fetch(flag_name(forbidden))}" if forbidden

      credential = (config["env"] || {}).to_h.keys.map(&:to_s).find { |key| key.match?(CREDENTIAL_ENV) }
      raise Error, "executor.env must carry no credential (remove #{credential}); Claude authenticates from the operator environment" if credential
    end

    # An operator may point at an absolute path, but the executable itself must be
    # the Claude CLI — this is what refuses a silent substitution of another CLI.
    def claude_executable? = File.basename(command) == EXECUTABLE
    def non_interactive? = args.any? { |arg| PRINT_FLAGS.include?(flag_name(arg)) }

    # `--output-format=text` and `--output-format text` are the same flag.
    def flag_name(arg) = arg.to_s.split("=", 2).first.to_s

    def classify_version(result)
      return UNAVAILABLE if result.nil?
      return CHECK_FAILED if result.timed_out?

      result.exit_code.to_i.zero? ? AVAILABLE : UNAVAILABLE
    end

    def classify_auth(result)
      return CHECK_FAILED if result.nil? || result.timed_out?
      return NOT_AUTHENTICATED unless result.exit_code.to_i.zero?

      logged_in?(result.stdout) ? AUTHENTICATED : NOT_AUTHENTICATED
    end

    # Reads ONE boolean out of the auth probe and discards everything else. The
    # raw output carries the operator's account email, org id, and org name; it is
    # never returned, logged, stored, or uploaded. When no recognizable field is
    # present the exit status is the contract, so a future CLI whose output shape
    # changed still reports "authenticated" rather than a false failure.
    def logged_in?(output)
      match = output.to_s.match(/"loggedIn"\s*:\s*(true|false)/i)
      match.nil? || match[1].casecmp("true").zero?
    end

    def presence(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end
  end
end
