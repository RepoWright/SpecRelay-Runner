# frozen_string_literal: true

module SpecrelayRunner
  # The `specrelay-runner` command-line entry point for the standalone runner
  # (MVP-0010). It is a thin adapter: parse argv, load local config, build the
  # Platform API client, claim at most one run, and — if claimed — execute it and
  # report back. It never reaches Platform except through PlatformClient.
  #
  #   specrelay-runner claim-once --config <path>
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
      when "register" then register(rest)
      when "claim-once" then claim_once(rest)
      when nil, "help", "-h", "--help" then print_help
      when "version", "--version" then print_version
      else usage("unknown command: #{command}")
      end
    end

    private

    attr_reader :out, :err, :env

    # Enroll this runner with Platform using a one-time registration token (read
    # from the environment, never the config file) and receive its durable
    # per-runner credential. The credential is printed EXACTLY ONCE; the operator
    # must store it in the credential env var. It is never written to disk here.
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
    end

    def claim_once(args)
      config = load_config(args)
      return USAGE_ERROR if config.nil?

      auth = config.resolve_auth(env: env)
      client = PlatformClient.new(base_url: config.base_url, token: auth.token)
      announce(config, auth)
      result = client.claim(config.claim_runner_params)
      unless result.claimed?
        out.puts "no eligible work (Platform authorized no run under this runner's policy)."
        return SUCCESS
      end

      execute(config, client, result.payload)
    rescue Config::Error => e
      err.puts "Invalid runner config: #{e.message}"
      USAGE_ERROR
    rescue PlatformClient::Error => e
      err.puts "Runner failed: #{e.message}"
      RUN_FAILED
    end

    def execute(config, client, payload)
      announce_claim(payload)
      result = Execution.new(config: config, client: client, payload: payload, env: env, io: out).call
      out.puts result.message
      result.success? ? SUCCESS : RUN_FAILED
    end

    def load_config(args)
      Config.load(path_from(args), env: env)
    rescue Config::Error => e
      err.puts "Invalid runner config: #{e.message}"
      nil
    end

    def announce(config, auth)
      out.puts "SpecRelay standalone runner #{VERSION} (contract #{CONTRACT_VERSION})"
      out.puts "Platform: #{config.base_url}"
      out.puts "Runner:   #{config.runner['display_name']} (#{config.runner['id']})"
      out.puts "Policy:   #{config.runner.dig('claim_policy', 'mode')}"
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
      err.puts "Usage: specrelay-runner claim-once --config <path>"
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
        API (HTTP). It claims one approved run, runs the configured executor and
        tests locally, and uploads events/heartbeat/report through the API.

        This is the one supported way to execute SpecRelay work. Platform's
        `bin/platform runner once|loop` no longer executes anything.

        Usage:
          specrelay-runner register --config <path>
              Enroll this runner with Platform using a one-time registration
              token (read from the env var named by runner.registration_token_env,
              default SPECRELAY_RUNNER_REGISTRATION_TOKEN). Platform returns a
              durable per-runner credential exactly once; export it into the
              credential env var (default SPECRELAY_RUNNER_CREDENTIAL). Exits 0 on
              success, 1 on a rejected token, 2 on a config/usage error.

          specrelay-runner claim-once --config <path>
              Claim at most one eligible run (Platform decides), execute it, and
              upload the report. Reads the Platform base URL + runner identity
              from the config. Authenticates with the per-runner credential when
              present (registered mode), otherwise the shared development token
              (fallback) — both from the environment, never the file. Exits 0 on
              completion or no eligible work, 1 on a failed execution, 2 on a
              config/usage error.

          specrelay-runner version
          specrelay-runner help
      HELP
      SUCCESS
    end
  end
end
