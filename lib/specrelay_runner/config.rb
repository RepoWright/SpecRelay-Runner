# frozen_string_literal: true

require "yaml"

module SpecrelayRunner
  # The standalone runner's local, operator-owned configuration (MVP-0010). It is
  # parsed from a YAML file the operator points the runner at
  # (`--config <path>` or SPECRELAY_RUNNER_CONFIG). It carries NO secret:
  # the Platform API token is read from an environment variable named by the
  # config, never stored in the file, so the config is safe to keep in a repo or
  # dotfiles while the token stays out of version control.
  #
  #   platform:
  #     base_url: http://127.0.0.1:3100
  #     token_env: SPECRELAY_RUNNER_API_TOKEN   # dev-token FALLBACK env var
  #   runner:
  #     id: local-dev-runner-1
  #     display_name: Local Developer Runner
  #     credential_env: SPECRELAY_RUNNER_CREDENTIAL          # registered-mode credential
  #     registration_token_env: SPECRELAY_RUNNER_REGISTRATION_TOKEN  # for `register`
  #     operator_email: hrmohseni@example.com   # optional (assigned_to_me)
  #     operator_account_id: 5b10ac...          # optional (assigned_to_me)
  #     claim_policy:
  #       mode: all_eligible                     # all_eligible | assigned_to_me
  #     executor:                                # optional non-secret override
  #       provider: fake
  #       command: ./bin/fake-executor
  #   workspace_roots:                           # optional; else env resolution
  #     tiny-demo-workspace: /abs/path/to/tiny-demo-runs
  #
  # Two authentication modes, clearly separated (MVP-0011):
  #   - registered mode (primary): the per-runner credential is read from the env
  #     var named by `runner.credential_env`. The credential is issued once by
  #     Platform (`specrelay-runner register`) and NEVER stored in this file.
  #   - development-token mode (fallback): the single shared token from
  #     `platform.token_env`, used only when no registered credential is present.
  #
  # Validation is intentionally minimal and thin: the runner does NOT re-validate
  # claim policy semantics (that is Platform's job). It only checks the fields it
  # needs to make an API call. NO secret is ever stored in the file.
  class Config
    Error = Class.new(StandardError)

    TOKEN_ENV_DEFAULT = "SPECRELAY_RUNNER_API_TOKEN"
    CREDENTIAL_ENV_DEFAULT = "SPECRELAY_RUNNER_CREDENTIAL"
    REGISTRATION_TOKEN_ENV_DEFAULT = "SPECRELAY_RUNNER_REGISTRATION_TOKEN"
    # The canonical config-path env var. `SPECRELAY_RUNNER_SPIKE_CONFIG` is the
    # name the spike shipped with (MVP-0010); MVP-0015 made the runner a real
    # product component, so the "spike" name is kept working as a deprecated
    # alias rather than broken out from under an operator who already exported it.
    CONFIG_PATH_ENV = "SPECRELAY_RUNNER_CONFIG"
    LEGACY_CONFIG_PATH_ENV = "SPECRELAY_RUNNER_SPIKE_CONFIG"
    WORKSPACE_ROOT_ENV = "SPECRELAY_RUNNER_WORKSPACE_ROOT"

    # The resolved runner API bearer: a per-runner registered credential
    # (mode: :registered) or the shared development token (mode: :development).
    Auth = Struct.new(:mode, :token, keyword_init: true)

    attr_reader :base_url, :token_env, :credential_env, :registration_token_env,
                :runner, :workspace_roots, :source_path

    def self.load(path, env: ENV)
      resolved = resolve_path(path, env)
      raise Error, "a runner config path is required (--config <path> or #{CONFIG_PATH_ENV})" if resolved.to_s.strip.empty?
      raise Error, "runner config file not found: #{resolved}" unless File.file?(resolved)

      new(parse(resolved), source_path: resolved)
    end

    # An explicit `--config <path>` always wins; otherwise the canonical env var,
    # then the deprecated spike-era alias.
    def self.resolve_path(explicit, env)
      return explicit unless explicit.to_s.strip.empty?

      candidate = env[CONFIG_PATH_ENV]
      candidate.to_s.strip.empty? ? env[LEGACY_CONFIG_PATH_ENV] : candidate
    end

    def self.parse(path)
      YAML.safe_load_file(path) || {}
    rescue Psych::SyntaxError => e
      raise Error, "runner config is not valid YAML: #{e.message.split("\n").first}"
    end

    def initialize(document, source_path: nil)
      raise Error, "runner config must be a YAML mapping" unless document.is_a?(Hash)

      @source_path = source_path
      platform = fetch_hash(document, "platform")
      @base_url = presence(platform["base_url"]) or raise Error, "platform.base_url is required"
      @token_env = presence(platform["token_env"]) || TOKEN_ENV_DEFAULT
      @runner = fetch_hash(document, "runner")
      raise Error, "runner.id is required" if presence(@runner["id"]).nil?
      raise Error, "runner.display_name is required" if presence(@runner["display_name"]).nil?
      @credential_env = presence(@runner["credential_env"]) || CREDENTIAL_ENV_DEFAULT
      @registration_token_env = presence(@runner["registration_token_env"]) || REGISTRATION_TOKEN_ENV_DEFAULT
      @workspace_roots = fetch_hash(document, "workspace_roots")
    end

    # The runner identity block posted to POST /api/runner/claim, exactly as the
    # Platform Runner::Config expects it. The runner does not interpret policy.
    def claim_runner_params = runner

    # Resolve the Platform API token from the environment (never the file). A
    # blank token is a clear operator error surfaced before any HTTP call. This is
    # the development-token fallback resolver; see #resolve_auth for the primary
    # registered-credential path.
    def api_token(env: ENV)
      token = env[token_env].to_s.strip
      raise Error, "no Platform API token in $#{token_env} (set it in your environment; never commit it)" if token.empty?

      token
    end

    # The identity block a runner posts to register itself. Only non-secret fields;
    # the credential is issued by Platform, never sent by the runner.
    def registration_identity
      identity = { "id" => runner["id"], "display_name" => runner["display_name"] }
      identity["operator_email"] = presence(runner["operator_email"]) if presence(runner["operator_email"])
      identity["operator_account_id"] = presence(runner["operator_account_id"]) if presence(runner["operator_account_id"])
      identity
    end

    # The one-time registration token, read from the environment (never the file),
    # used only by `specrelay-runner register`.
    def registration_token(env: ENV)
      value = env[registration_token_env].to_s.strip
      if value.empty?
        raise Error, "no registration token in $#{registration_token_env} " \
                     "(get a one-time token from `bin/platform runners issue-registration-token`)"
      end

      value
    end

    # Resolve the runner API bearer credential and its mode. Registered mode is
    # PRIMARY: when the per-runner credential env var is set, use it. Otherwise
    # fall back to the shared development token (explicit local/demo path). Neither
    # value ever comes from the config file.
    def resolve_auth(env: ENV)
      credential = env[credential_env].to_s.strip
      return Auth.new(mode: :registered, token: credential) unless credential.empty?

      token = env[token_env].to_s.strip
      return Auth.new(mode: :development, token: token) unless token.empty?

      raise Error, "no runner credential in $#{credential_env} and no development token in $#{token_env} " \
                   "(register the runner, or set the development token; never commit either)"
    end

    # Resolve the physical local workspace root the runner runs project commands
    # in, for a given workspace key. Precedence: per-workspace env, global env,
    # then the config's workspace_roots map. This mirrors the Platform-side
    # WorkspaceLocation precedence so the two behave identically.
    def workspace_root(workspace_key, env: ENV)
      key_env = "#{WORKSPACE_ROOT_ENV}_#{workspace_key.to_s.upcase.gsub(/[^A-Z0-9]+/, '_')}"
      root = presence(env[key_env]) || presence(env[WORKSPACE_ROOT_ENV]) || presence(workspace_roots[workspace_key.to_s])
      raise Error, "no local workspace root for '#{workspace_key}' (set #{key_env}, #{WORKSPACE_ROOT_ENV}, or workspace_roots)" if root.nil?
      raise Error, "configured local workspace root does not exist: #{root}" unless File.directory?(root)

      root
    end

    private

    def fetch_hash(document, key)
      value = document[key] || document[key.to_sym]
      value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
    end

    def presence(value)
      s = value.to_s.strip
      s.empty? ? nil : s
    end
  end
end
