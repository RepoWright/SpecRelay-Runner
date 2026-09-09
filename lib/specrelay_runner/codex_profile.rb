# frozen_string_literal: true

module SpecrelayRunner
  # The SECOND approved real implementation profile: Codex, launched non-interactively by the
  # runner in the task worktree Platform assigned.
  #
  # It is deliberately a second NAMED profile beside {ClaudeProfile} and NOT a step towards a
  # provider registry. It is the narrow Runner-owned boundary where everything Codex-specific
  # lives — the one approved argv, whether the local CLI is ready, whether a claimed payload really
  # resolved to this profile, and how a failure is classified. {Executor} and {CommandRunner} stay
  # provider-agnostic: they only launch an argv array.
  #
  # It does NOT judge whether a claimed payload is tolerable. {ImplementationProfile} compares the
  # claim with CANONICAL below, byte for byte, before anything here is constructed; a second,
  # weaker opinion about which arguments are acceptable would be a copy of that rule that could
  # only ever disagree with it.
  #
  #   executor:
  #     provider: codex
  #     command: codex
  #     mode: exec
  #     args: [exec, --json, --ephemeral, --dangerously-bypass-approvals-and-sandbox]
  #     prompt_delivery: stdin
  #     timeout_seconds: 1800
  #     env: {}
  #
  # `stdin` keeps the assignment prompt out of process arguments. `--ephemeral` prevents session
  # reuse. The bypass flag is the unattended equivalent of the Claude profile's permission bypass;
  # the assigned task worktree remains the execution boundary. No model is pinned, because the
  # operator's own local account and configuration own model availability — and a model that is
  # unavailable is an execution failure, never a switch to another provider.
  #
  # Secret posture: this class NEVER reads, stores, returns, logs, or uploads a provider
  # credential, login token, or account identity. Codex authenticates from the runner operator's
  # own inherited environment on this host. The readiness probe runs `codex login status`, extracts
  # a single classification, and DISCARDS the raw output — which names the operator's account and
  # must never reach a console, report, event, or Platform.
  class CodexProfile
    Error = Class.new(StandardError)

    PROVIDER = "codex"
    EXECUTABLE = "codex"
    PROMPT_DELIVERY = "stdin"
    # The non-interactive entry point, and the first argument because it is a SUBCOMMAND rather
    # than a flag: `codex exec` is a different program surface from `codex`.
    MODE = "exec"

    # The readiness/auth classifications this profile is allowed to record. They are the ONLY
    # thing the probes produce — never the underlying output.
    AVAILABLE = "available"
    UNAVAILABLE = "unavailable"
    AUTHENTICATED = "authenticated"
    NOT_AUTHENTICATED = "not_authenticated"
    CHECK_FAILED = "check_failed"

    # Terminal-result error classifications for a Codex execution that failed after the claim.
    # They are the SAME vocabulary the Claude profile records, because Platform's terminal
    # contract is provider-neutral and an operator reads one set of outcomes, not one per CLI.
    EXECUTOR_UNAVAILABLE = "executor_unavailable"
    EXECUTOR_NOT_AUTHENTICATED = "executor_not_authenticated"
    EXECUTOR_TIMEOUT = "executor_timeout"
    EXECUTOR_FAILED = "executor_failed"

    # `--json` is what makes `codex exec` report each event as a JSON line while it works, and
    # {CodexStream} is the only reader of that stream. `--ephemeral` is what stops a previous
    # session from influencing this run. The bypass flag is what makes an unattended run possible
    # at all — without it the CLI waits for an approval nobody is there to give.
    #
    # They are part of the approved argv rather than flags this class appends, because the launch
    # is built from the claimed payload's own `args`. A flag the runner added silently would not be
    # part of the profile identity, so the fail-closed comparison would pass while the effective
    # invocation differed — the precise failure `identity` exists to prevent.
    REQUIRED_FLAGS = %w[--json --ephemeral --dangerously-bypass-approvals-and-sandbox].freeze

    # Bounded so a hung CLI can never stall the runner before it claims. These are metadata calls
    # (no inference), so a few seconds is generous.
    PROBE_TIMEOUT_SECONDS = 20

    # Local evidence that a non-zero Codex exit was an authentication problem rather than a task
    # failure. Matched against the executor's own captured output, which the report already stores
    # redacted.
    AUTH_FAILURE_HINT = /
      (?:not\s+logged\s+in) | (?:please\s+run\s+.?codex\s+login) | (?:run\s+.?codex\s+login) |
      (?:authentication\s+(?:required|failed)) | (?:invalid\s+api\s+key) | (?:unauthorized) | (?:401)
    /ix

    # The ONE form of `codex --version` this runner will read, and the only fact it keeps from the
    # probe. Anchored and bounded: unexpected text is a failed check, not a longer version.
    VERSION_LINE = /\A(codex-cli \d+(?:\.\d+){0,3}(?:-[A-Za-z0-9.]{1,16})?)\z/
    MAX_VERSION_CHARS = 40

    # The outcome of the local, no-edit readiness check. It carries ONLY the classifications and
    # the one strictly parsed public version fact — never the probe output.
    Readiness = Struct.new(:version, :auth, :cli_version, keyword_init: true) do
      def ready? = version == AVAILABLE && auth == AUTHENTICATED

      def summary
        [ "codex=#{version}", "auth=#{auth}", cli_version ].compact.join(", ")
      end

      # What the EXISTING readiness `detail` field carries: the safe version fact once this host is
      # ready, and otherwise the actionable remedy. One accessor, so a caller never has to know
      # which of the two a given state produces.
      def detail = ready? ? cli_version : remedy

      # A redacted, actionable remedy for the operator, or nil when ready.
      def remedy
        return nil if ready?
        return "install Codex so `codex` resolves on this runner's PATH" if version == UNAVAILABLE
        return "`codex --version` did not report a version this runner recognizes; check the local Codex installation" unless version == AVAILABLE
        return "run `codex login` as this runner's operator on this host" if auth == NOT_AUTHENTICATED

        "`codex login status` did not complete; check the local Codex installation"
      end
    end

    # True when an executor config selects this real provider. Non-raising, so the deterministic
    # fixture path can ask without risking an exception.
    def self.selected?(executor_config)
      return false unless executor_config.is_a?(Hash)

      executor_config.transform_keys(&:to_s)["provider"].to_s.strip.downcase == PROVIDER
    end

    # Launches one bounded metadata probe. Returns a CommandRunner::Result, or nil when the
    # executable could not be launched at all (an absent CLI).
    #
    # `env` is the runner's EFFECTIVE process environment, threaded in explicitly rather than read
    # from the global ENV: Process.spawn resolves the executable through the PATH it is handed, so
    # the probe must look `codex` up on exactly the PATH the executor will later launch it from.
    # Reading a global here would let readiness pass against one CLI and execution run another.
    def self.default_probe(env: ENV)
      path = env["PATH"].to_s
      lambda do |argv|
        CommandRunner.run(argv, chdir: Dir.pwd, env: { "PATH" => path }, timeout_seconds: PROBE_TIMEOUT_SECONDS)
      rescue SystemCallError
        nil
      end
    end

    # Mirrors Executor's fallback so `identity` compares effective values.
    DEFAULT_TIMEOUT_SECONDS = 1800

    # The ONE approved Codex invocation, assembled from this profile's own constants. It is the
    # exact hash Platform stores and serves; {ImplementationProfile} compares a claimed payload
    # against it before a worktree exists.
    CANONICAL_ARGS = [ MODE, *REQUIRED_FLAGS ].freeze
    CANONICAL = {
      "provider" => PROVIDER, "command" => EXECUTABLE, "mode" => MODE, "args" => CANONICAL_ARGS,
      "prompt_delivery" => PROMPT_DELIVERY, "timeout_seconds" => DEFAULT_TIMEOUT_SECONDS, "env" => {}
    }.freeze

    # Labels for the identity tuple, so a mismatch names the dimension that differed instead of
    # dumping two opaque arrays at the operator.
    IDENTITY_FIELDS = %w[provider command args prompt_delivery timeout_seconds env].freeze

    attr_reader :command, :args, :prompt_delivery, :timeout_seconds, :extra_env

    # {ImplementationProfile} compares a claimed payload with CANONICAL before it constructs one of
    # these, so this is not a second validator: the provider check is what makes a cross-provider
    # payload a usable-profile refusal in `mismatch_reason` rather than a silent Codex object.
    def initialize(executor_config)
      config = (executor_config || {}).to_h.transform_keys(&:to_s)
      raise Error, "executor.provider must be '#{PROVIDER}'" unless self.class.selected?(config)

      @command = presence(config["command"]) || EXECUTABLE
      @args = Array(config["args"]).map(&:to_s)
      @prompt_delivery = presence(config["prompt_delivery"]) || PROMPT_DELIVERY
      # Effective values, mirroring Executor's own defaults, so the fail-closed comparison reflects
      # what would REALLY happen rather than what was written.
      @timeout_seconds = config["timeout_seconds"].to_i.positive? ? config["timeout_seconds"].to_i : DEFAULT_TIMEOUT_SECONDS
      @extra_env = (config["env"] || {}).to_h.transform_keys(&:to_s).transform_values(&:to_s)
    end

    # Every dimension that decides WHAT runs and HOW. Two configs with the same identity launch the
    # same executable, the same way, under the same limit, with the same child environment.
    #
    # `command` is compared as the RESOLVED executable, not as a basename: any file named `codex`
    # anywhere on the host would otherwise pass as a match and then be spawned. When a command
    # cannot be resolved to a real file the literal string is used instead, so unresolvable never
    # silently equals resolvable.
    def identity(env: ENV)
      [ PROVIDER, Executor.resolve_command(command, env: env) || command,
        args, prompt_delivery, timeout_seconds, extra_env ]
    end

    # A one-line, redacted description safe for a console line or a report field.
    def describe = Redaction.redact("#{PROVIDER} #{command} #{args.join(' ')} (prompt via #{prompt_delivery})")

    # The local, no-edit readiness check the runner performs BEFORE it asks Platform for work: is
    # the CLI installed, and is the operator logged in? It sends no prompt, runs no inference,
    # touches no repository, and consumes no claim. `probe` is the injected command-execution seam
    # (no ENV mutation, no live CLI, no global process state in tests).
    def readiness(env: ENV, probe: nil)
      probe ||= self.class.default_probe(env: env)
      # Probe the file the LAUNCH will resolve to, not merely the configured name, so readiness
      # cannot pass against a different `codex` than the one that will run. Falls back to the raw
      # name when nothing resolves, so the probe still runs and reports `unavailable` itself.
      target = Executor.resolve_command(command, env: env) || command
      version, fact = classify_version(probe.call([ target, "--version" ]))
      # Login cannot be established when the CLI itself is not usable. Reported as check_failed
      # (the "could not determine" classification) rather than as a login problem the operator
      # would then chase in the wrong place.
      return Readiness.new(version: version, auth: CHECK_FAILED, cli_version: fact) unless version == AVAILABLE

      Readiness.new(version: version, auth: classify_login(probe.call([ target, "login", "status" ])),
                    cli_version: fact)
    end

    # Why the executor Platform actually resolved is not this profile, or nil when it is. This is
    # the fail-closed gate: the runner refuses to launch a command it did not select, instead of
    # silently executing another CLI or the fixture.
    def mismatch_reason(payload_executor, env: ENV)
      claimed = self.class.new(payload_executor)
      differing = differing_fields(claimed, env: env)
      return nil if differing.empty?

      "claimed executor differs from the selected profile in #{differing.join(', ')} " \
        "(claimed #{claimed.describe}; selected #{describe})"
    rescue Error => e
      "claimed executor is not a usable Codex profile (#{Redaction.redact(e.message)}); selected #{describe}"
    end

    # Classify a Codex execution that failed AFTER the claim, so the terminal report says which
    # local condition actually happened.
    def classify_failure(result)
      return EXECUTOR_UNAVAILABLE if result.respond_to?(:launch_error) && result.launch_error
      return EXECUTOR_TIMEOUT if result.timed_out
      return EXECUTOR_NOT_AUTHENTICATED if authentication_failure?(result)

      EXECUTOR_FAILED
    end

    private

    # Which identity dimensions disagree, by name. `env` is reported without its values: an
    # operator does not need them echoed, and they are not this method's to print.
    def differing_fields(claimed, env:)
      mine = identity(env: env)
      theirs = claimed.identity(env: env)
      IDENTITY_FIELDS.each_with_index.filter_map { |field, index| field if mine[index] != theirs[index] }
    end

    def authentication_failure?(result)
      [ result.stderr, result.stdout ].any? { |text| text.to_s.match?(AUTH_FAILURE_HINT) }
    end

    # Returns [classification, safe_version_fact]. The fact is the ONE thing kept from the probe
    # and is strictly parsed: output that is not exactly the proven form is a failed check, and
    # none of it is returned. That is what stops a future CLI — or a stub on the PATH — from
    # publishing arbitrary text through a field an operator reads.
    def classify_version(result)
      return [ UNAVAILABLE, nil ] if result.nil?
      return [ CHECK_FAILED, nil ] if result.timed_out?
      return [ UNAVAILABLE, nil ] unless result.exit_code.to_i.zero?

      fact = safe_version(result.stdout)
      fact ? [ AVAILABLE, fact ] : [ CHECK_FAILED, nil ]
    end

    def safe_version(output)
      line = output.to_s.lines.first.to_s.strip
      return nil if line.empty? || line.length > MAX_VERSION_CHARS

      match = line.match(VERSION_LINE)
      match && Redaction.redact(match[1])
    end

    # Reads ONE classification out of the login probe and discards everything else. The raw output
    # names the operator's account; it is never returned, logged, stored, or uploaded. When no
    # recognizable signed-out marker is present the exit status is the contract, so a future CLI
    # whose output shape changed still reports "authenticated" rather than a false failure.
    def classify_login(result)
      return CHECK_FAILED if result.nil? || result.timed_out?
      return NOT_AUTHENTICATED unless result.exit_code.to_i.zero?

      result.stdout.to_s.match?(/not\s+logged\s+in/i) ? NOT_AUTHENTICATED : AUTHENTICATED
    end

    def presence(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end
  end
end
