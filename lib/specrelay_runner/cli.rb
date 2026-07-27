# frozen_string_literal: true

module SpecrelayRunner
  # The `specrelay-runner` command-line entry point for the standalone runner
  # (MVP-0010). It is a thin adapter: parse argv, load local configuration, build the
  # Platform API client, claim at most one run, and — if claimed — execute it and
  # report back. It never reaches Platform except through PlatformClient.
  #
  # The NORMAL path is two commands and no files (MVP-0017):
  #
  #   specrelay-runner connect <enrollment-code>
  #   specrelay-runner claim-once
  #
  # `connect` obtains everything from Platform, asks only for the local checkout, and
  # stores the credential in the OS secret store; `claim-once` then reads that stored
  # connection, so there is no YAML to author and no credential to export.
  #
  # `register --config <path>` and `claim-once --config <path>` remain as the
  # ADVANCED/LEGACY path for an operator who already runs a hand-written config. They
  # are supported, not recommended, and are not the documented setup route.
  #
  # Exit codes mirror the in-process runner: 0 = completed or nothing eligible,
  # 1 = a claimed execution did not complete successfully, 2 = config/usage error.
  class CLI
    SUCCESS = 0
    RUN_FAILED = 1
    USAGE_ERROR = 2

    def self.run(argv, out: $stdout, err: $stderr, env: ENV) = new(out:, err:, env:).run(argv)

    def initialize(out: $stdout, err: $stderr, env: ENV)
      @out = out
      @err = err
      @env = env
    end

    def run(argv)
      command, *rest = argv
      case command
      when "connect" then connect(rest)
      when "register" then register(rest)
      when "claim-once" then claim_once(rest)
      when "loop" then loop_mode(rest)
      when nil, "help", "-h", "--help" then print_help
      when "version", "--version" then print_version
      else usage("unknown command: #{command}")
      end
    end

    private

    attr_reader :out, :err, :env

    # The guided connection (MVP-0017). Every failure mode reports ONE focused, redacted
    # remedy and leaves this runner not-ready rather than half-connected: an unsupported
    # platform, a malformed/expired code, a checkout that is not the assigned repository,
    # an unavailable or unauthenticated Claude, or a refused Keychain write.
    def connect(args)
      code = args.find { |arg| !arg.start_with?("-") }
      return usage("usage: specrelay-runner connect <enrollment-code>") if code.nil?

      result = Connect.call(code: code, out: out, err: err, env: env,
                            checkout_path: option(args, "--checkout"))
      print_connection(result)
      result.ready? ? SUCCESS : RUN_FAILED
    rescue SecretStore::UnsupportedPlatform => e
      connect_failed("Cannot connect: #{e.message}", USAGE_ERROR)
    rescue Connect::Error, SecretStore::Error, ConnectionStore::Error, PlatformClient::Error => e
      connect_failed("Connection failed: #{Redaction.redact(e.message)}", RUN_FAILED)
    end

    # stdout is block-buffered when redirected while stderr is not, so without this flush the
    # failure line appears BEFORE the assignment lines it refers to in a merged operator log —
    # the same ordering problem `executor_ready?` already guards against.
    def connect_failed(message, status)
      out.flush if out.respond_to?(:flush)
      err.puts message
      status
    end

    # Prints the state PLATFORM decided, never the runner's own opinion, and never the
    # credential (which is already in the Keychain by this point).
    def print_connection(result)
      out.puts ""
      if result.ready?
        out.puts "Connected. This machine is ready to execute #{result.workspace_key} work."
        # `loop` is named first because it is the normal mode for a connected machine
        # (MVP-0018); `claim-once` is the controlled single shot for a manual test.
        out.puts "Next: leave `specrelay-runner loop` running here to pick up work as it becomes ready,"
        out.puts "      or run `specrelay-runner claim-once` for a single controlled test."
        return
      end

      out.flush if out.respond_to?(:flush)
      err.puts "Platform recorded this connection as #{result.state}" \
               "#{" (#{result.failure_class})" if result.failure_class}."
      err.puts "Remedy: #{Redaction.redact(result.detail.to_s)}" if result.detail.to_s.strip != ""
    end

    # ADVANCED / LEGACY (MVP-0011). Enroll with a one-time registration token read from
    # the environment and receive the durable credential, printed EXACTLY ONCE for the
    # operator to export. Superseded by `connect`, which needs no file and no exported
    # credential — and, unlike this command, grants access to a specific workspace. A
    # runner enrolled here holds no workspace grant and can claim nothing until it
    # completes `connect`.
    def register(args)
      config = load_config(args)
      return USAGE_ERROR if config.nil?

      token = config.registration_token(env: env)
      client = PlatformClient.new(base_url: config.base_url, token: token)
      out.puts "Registering runner #{config.runner['display_name']} (#{config.runner['id']}) with #{config.base_url}…"
      print_registration(config, client.register(config.registration_identity))
      SUCCESS
    rescue Config::Error => e
      err.puts "Invalid runner config: #{e.message}"
      USAGE_ERROR
    rescue PlatformClient::Error => e
      err.puts "Registration failed: #{e.message}"
      RUN_FAILED
    end

    # Show the returned credential a single time with clear, secret-safe guidance.
    # This is the ONE place the runner prints a raw secret (never via the redacting
    # logger) because the operator must capture it now — Platform cannot re-show it.
    def print_registration(config, result)
      runner = result.fetch("runner")
      out.puts "Registered. Runner identity: #{runner['public_id']} (#{runner['id']})."
      out.puts ""
      out.puts "Per-runner credential (shown once — store it, do not commit it):"
      out.puts "  #{result.fetch('credential')}"
      out.puts ""
      out.puts "Export it before claiming work:"
      out.puts "  export #{config.credential_env}=<the value above>"
      out.puts ""
      out.puts "This runner has NO workspace access yet. Registration alone authorizes nothing:"
      out.puts "run `specrelay-runner connect <enrollment-code>` for the workspace it should execute."
    end

    def claim_once(args)
      config = resolve_claim_config(args)
      return USAGE_ERROR if config.nil?

      auth = config.resolve_auth(env: env)
      announce(config, auth)
      # MVP-0016: when this runner selected the real Claude Code profile, prove the
      # local dependency is ready BEFORE asking Platform for work. Claiming first
      # and discovering a missing CLI afterwards burns a real run and leaves it
      # stuck; this exits non-zero having sent no claim request at all.
      return RUN_FAILED unless executor_ready?(config)

      client = PlatformClient.new(base_url: config.base_url, token: auth.token)
      result = client.claim(config.claim_runner_params)
      unless result.claimed?
        out.puts not_claimed_message(result)
        return SUCCESS
      end

      execute(config, client, result.payload)
    rescue ClaudeProfile::Error => e
      err.puts "Invalid executor profile: #{e.message}"
      USAGE_ERROR
    rescue Config::Error => e
      err.puts "Invalid runner config: #{e.message}"
      USAGE_ERROR
    rescue PlatformClient::Error => e
      err.puts "Runner failed: #{e.message}"
      RUN_FAILED
    end

    # MVP-0018 — the normal operator mode for a connected personal runner: poll,
    # claim, execute, repeat, until interrupted.
    #
    # It reuses `claim-once`'s resolution and readiness gates verbatim — the same
    # stored connection, the same Keychain credential, the same executor readiness
    # check — and adds only repetition. The readiness gate runs ONCE here rather
    # than per poll: it probes the provider CLI, and doing that every minute would
    # be a cost with no new information.
    def loop_mode(args)
      interval = PollInterval.resolve(option(args, "--poll-interval"))
      return usage(interval.error) unless interval.valid?

      policy = option(args, "--on-failure").to_s.strip
      policy = LoopRunner::ON_FAILURE_CONTINUE if policy.empty?
      return usage("--on-failure must be one of: #{LoopRunner::FAILURE_POLICIES.join(', ')}") unless
        LoopRunner::FAILURE_POLICIES.include?(policy)

      start_loop(args, interval, policy)
    end

    def start_loop(args, interval, policy)
      config = resolve_claim_config(args)
      return USAGE_ERROR if config.nil?

      auth = config.resolve_auth(env: env)
      announce(config, auth)
      out.puts "Poll interval: #{interval.notice || "#{interval.seconds}s"}"
      return RUN_FAILED unless executor_ready?(config)

      run_loop(config, auth, interval, policy)
    rescue ClaudeProfile::Error => e
      err.puts "Invalid executor profile: #{e.message}"
      USAGE_ERROR
    rescue Config::Error => e
      err.puts "Invalid runner config: #{e.message}"
      USAGE_ERROR
    end

    def run_loop(config, auth, interval, policy)
      client = PlatformClient.new(base_url: config.base_url, token: auth.token)
      result = LoopRunner.call(
        out: out, err: err, poll_seconds: interval.seconds, on_failure: policy,
        claim: -> { client.claim(config.claim_runner_params) },
        execute: ->(payload) { execute(config, client, payload) == SUCCESS }
      )
      result == LoopRunner::OK ? SUCCESS : RUN_FAILED
    end

    # Print PLATFORM's reason for a not-claimed poll, so an unconnected runner is told to run
    # `connect` rather than being left to read "nothing eligible" as a healthy idle.
    def not_claimed_message(result)
      reason = Redaction.redact(result.reason)
      reason.strip.empty? ? "no eligible work (Platform authorized no run for this runner)." : "no work claimed: #{reason}"
    end

    # The local, no-edit readiness gate for the real provider profile. Returns true
    # immediately when no real profile is selected, so the deterministic
    # fake-executor regression path never requires Claude Code to be installed or
    # authenticated. Only classifications are printed — never probe output, which
    # carries the operator's account identity.
    def executor_ready?(config)
      profile = config.selected_claude_profile
      return true if profile.nil?

      out.puts "Executor: #{profile.describe}"
      readiness = profile.readiness(env: env)
      out.puts "Readiness: #{readiness.summary}"
      return true if readiness.ready?

      # stdout is block-buffered when redirected while stderr is not, so the
      # classification would otherwise appear AFTER the remedy in a merged
      # operator log — exactly the ordering that makes such a log hard to read.
      out.flush if out.respond_to?(:flush)
      err.puts "Claude Code is not ready on this host — no run was claimed and nothing was executed."
      err.puts "Remedy: #{readiness.remedy}"
      false
    end

    def execute(config, client, payload)
      announce_claim(payload)
      result = Execution.new(config: config, client: client, payload: payload, env: env, io: out).call
      out.puts result.message
      result.success? ? SUCCESS : RUN_FAILED
    end

    # Prefer the guided connection (MVP-0017); fall back to the advanced/legacy config
    # file. An explicit `--config` (or SPECRELAY_RUNNER_CONFIG) always wins, so an
    # operator who deliberately runs a hand-written config is never silently overridden by
    # a stored connection.
    def resolve_claim_config(args)
      explicit = path_from(args) || Config.resolve_path(nil, env)
      return load_config(args) if explicit.to_s.strip != ""

      store = ConnectionStore.load(env: env)
      return not_connected if store.connections.empty?

      connection_config(store, args)
    end

    def not_connected
      err.puts "this machine is not connected to a workspace."
      err.puts "Run `specrelay-runner connect <enrollment-code>` — get the code from your " \
               "project's setup page in Platform."
      err.puts "(Advanced/legacy: point at a hand-written config with --config <path>.)"
      nil
    end

    # Build a config from a stored connection, reading its credential from the OS secret
    # store. Returns nil after printing ONE specific remedy when the connection cannot be
    # used, so a normal user is never shown a config-file error they did not cause.
    def connection_config(store, args)
      connection = select_connection(store, option(args, "--workspace"))
      return nil if connection.nil?

      credential = stored_credential(connection)
      return missing_credential(connection) if credential.nil?

      Config.from_connection(connection, credential: credential)
    rescue SecretStore::UnsupportedPlatform, SecretStore::Error => e
      err.puts "Cannot read the stored runner credential: #{Redaction.redact(e.message)}"
      nil
    end

    # The credential for this connection's RUNNER identity, falling back to the pre-round-003
    # per-workspace account so a machine that connected under the old scheme keeps working
    # (review-002, F3 residual). The credential is per runner, so keying it per workspace is what
    # let a second workspace's connection orphan the first's stored copy.
    def stored_credential(connection)
      store = SecretStore.for(platform: RUBY_PLATFORM)
      runner_public_id = connection.runner_public_id.to_s.strip
      unless runner_public_id.empty?
        value = store.read(account: SecretStore.account_for_runner(runner_public_id))
        return value if value
      end
      store.read(account: SecretStore.legacy_account_for(connection.workspace_key))
    end

    # A named workspace, or the sole stored connection. Several connections with no
    # `--workspace` is ambiguous, and guessing which workspace to claim for is exactly the
    # inference this MVP removed — so it asks.
    def select_connection(store, workspace_key)
      requested = workspace_key.to_s.strip
      unless requested.empty?
        found = store.connection_for(requested)
        return found if found

        return unknown_workspace(store, requested)
      end

      store.sole_connection || ambiguous_workspace(store)
    end

    def unknown_workspace(store, requested)
      err.puts "no connection for workspace '#{requested}'. Connected: " \
               "#{store.connections.map(&:workspace_key).join(', ')}"
      nil
    end

    def ambiguous_workspace(store)
      err.puts "several workspaces are connected " \
               "(#{store.connections.map(&:workspace_key).join(', ')}); " \
               "choose one with --workspace <workspace-key>"
      nil
    end

    def missing_credential(connection)
      err.puts "no stored credential for workspace #{connection.workspace_key}. " \
               "Reconnect it: specrelay-runner connect <enrollment-code>"
      nil
    end

    def load_config(args)
      Config.load(path_from(args), env: env)
    rescue Config::Error => e
      err.puts "Invalid runner config: #{e.message}"
      nil
    end

    def option(args, flag)
      index = args.index(flag)
      return args[index + 1] if index

      args.find { |arg| arg.start_with?("#{flag}=") }&.split("=", 2)&.last
    end

    def announce(config, auth)
      out.puts "SpecRelay standalone runner #{VERSION} (contract #{CONTRACT_VERSION})"
      out.puts "Platform: #{config.base_url}"
      out.puts "Runner:   #{config.runner['display_name']} (#{config.runner['id']})"
      out.puts "Source:   #{config.connection ? "connected workspace #{config.connection.workspace_key}" : "config file #{config.source_path}"}"
      out.puts "Auth:     #{auth.mode == :registered ? 'registered runner credential' : 'development token (fallback)'}"
    end

    def announce_claim(payload)
      claim = payload.fetch("claim")
      out.puts "Claimed run #{payload.dig('run', 'task_id')} (#{payload.dig('run', 'id')}); " \
               "execution #{claim['runner_execution_id']} via #{claim['claim_policy_mode']}."
    end

    def path_from(args)
      index = args.index("--config")
      return args[index + 1] if index

      flag = args.find { |a| a.start_with?("--config=") }
      flag&.split("=", 2)&.last
    end

    def usage(message)
      err.puts message if message
      err.puts "Usage: specrelay-runner connect <enrollment-code>"
      err.puts "       specrelay-runner claim-once [--workspace <workspace-key>]"
      err.puts "       specrelay-runner loop [--workspace <workspace-key>] " \
               "[--poll-interval <#{PollInterval::MINIMUM}-#{PollInterval::MAXIMUM}>] [--on-failure continue|stop]"
      USAGE_ERROR
    end

    def print_version
      out.puts VERSION
      SUCCESS
    end

    def print_help
      out.puts <<~HELP
        specrelay-runner — the SpecRelay execution plane

        A developer-installed runner that talks to Platform ONLY over the runner
        API (HTTP). It claims approved runs, runs the configured executor and
        tests locally, and uploads events/heartbeat/report through the API.

        This is the one supported way to execute SpecRelay work. Platform's
        `bin/platform runner once|loop` no longer executes anything.

        Normal setup — two commands, no files to edit:

          specrelay-runner connect <enrollment-code>
              Connect this machine to one workspace. Get the code from your
              project's setup page in Platform ("Connect a Runner"); it is shown
              once, works once, and expires shortly.

              The command obtains the Platform endpoint and the project/workspace
              assignment from the code exchange, asks you for ONE thing — the local
              checkout directory for the assigned repository — validates that
              checkout's remote and default branch against the assignment, checks
              the assigned executor is ready, and stores this runner's durable
              credential in the macOS Keychain. The credential is never printed,
              never written to a file, and never exported.

              macOS only in this release. On another system it stops before
              registering rather than saving a plaintext credential. Exits 0 when
              Platform records the runner ready, 1 otherwise, 2 on usage/platform.

          specrelay-runner claim-once [--workspace <workspace-key>]
              Claim at most one eligible run (Platform decides), execute it, and
              upload the report. With no arguments it uses the connection created
              by `connect`, reading the credential from the Keychain — no config
              file, no exported credential, and no workspace-root variable.
              --workspace picks one when several are connected. Exits 0 on
              completion or no eligible work, 1 on a failed execution, 2 on a
              config/usage error.

              Use this for a controlled, single-shot manual test. For day-to-day
              operation, leave `loop` running instead.

          specrelay-runner loop [--workspace <workspace-key>]
                                [--poll-interval <seconds>]
                                [--on-failure continue|stop]
              The normal mode for a connected machine: poll Platform for eligible
              work, claim ONE run at a time, execute it, and keep going. Uses the
              same stored connection and Keychain credential as `claim-once`.

              While the executor runs, safe redacted executor output is streamed to
              this terminal between [core.started] and [verification.started], and
              submitted to Platform as ordered live log events. When the provider is
              quiet, a periodic heartbeat line proves forward progress. Output is
              redacted, per-line clipped, and budget-capped; truncation is printed.

              --poll-interval defaults to #{PollInterval::DEFAULT}s; the supported
              range is #{PollInterval::MINIMUM}-#{PollInterval::MAXIMUM}s. A value
              outside it is clamped and the clamp is printed; a non-numeric value is
              refused.
              --on-failure continue (default) reports a failed run through the normal
              terminal-result contract and resumes polling; stop ends the session.

              Ctrl-C (or SIGTERM) stops it cleanly and says whether it was idle or an
              execution was in progress. Foreground only — installing it as a service
              is deliberately out of scope.

              Exits 0 when every executed run succeeded, 1 if any failed or the
              credential was rejected, 2 on a config/usage error.

        Advanced / legacy — supported for an existing hand-written setup, and NOT the
        documented way to set a machine up:

          specrelay-runner register --config <path>
              Enroll with a one-time registration token (read from the env var named
              by runner.registration_token_env, default
              SPECRELAY_RUNNER_REGISTRATION_TOKEN) and PRINT the durable credential
              once for you to export as SPECRELAY_RUNNER_CREDENTIAL. Unlike
              `connect`, it grants no workspace access on its own: a runner enrolled
              this way shows as `legacy setup` in Platform and can claim nothing
              until it completes `connect` for a workspace.

          specrelay-runner claim-once --config <path>
              Claim using a hand-written config file and a credential from the
              environment. An explicit --config always wins over a stored connection.

          specrelay-runner version
          specrelay-runner help
      HELP
      SUCCESS
    end
  end
end
