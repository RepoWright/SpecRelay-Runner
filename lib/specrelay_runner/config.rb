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
  #     executor:                                # optional non-secret provider SELECTION
  #       provider: fake                         # claude | codex | fake, and nothing else
  #   workspace_roots:                           # optional; else env resolution
  #     tiny-demo-workspace: /abs/path/to/tiny-demo-workspace
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
    # The policy value a guided connection uses; see .from_connection.
    ALL_ELIGIBLE_MODE = "all_eligible"
    # The only key `runner.executor:` may carry.
    PROVIDER_KEY = "provider"

    # The resolved runner API bearer: a per-runner registered credential
    # (mode: :registered) or the shared development token (mode: :development).
    Auth = Struct.new(:mode, :token, keyword_init: true)

    attr_reader :base_url, :token_env, :credential_env, :registration_token_env,
                :runner, :workspace_roots, :source_path, :connection, :selection_source

    def self.load(path, env: ENV)
      resolved = resolve_path(path, env)
      raise Error, "a runner config path is required (--config <path> or #{CONFIG_PATH_ENV})" if resolved.to_s.strip.empty?
      raise Error, "runner config file not found: #{resolved}" unless File.file?(resolved)

      new(parse(resolved), source_path: resolved)
    end

    # Build a config from a guided connection (MVP-0017) instead of a YAML file. This is
    # what makes the normal path complete: after `specrelay-runner connect`, `claim-once`
    # needs no file, no exported credential, and no workspace-root environment variable.
    #
    # The credential is passed in, having been read from the OS secret store, and never
    # touches disk or the environment. The workspace root comes from the connection's own
    # validated local path — the runner's to keep, which Platform never learns.
    #
    # `all_eligible` is the honest policy value here: since MVP-0017, workspace access is
    # an explicit Platform-side grant on this runner's identity, so the routing policy is
    # no longer what bounds what it may execute.
    # `selection_source` records HOW this connection was chosen (:requested, :default, :sole)
    # so the announce line can say so. It is presentation metadata, deliberately not a
    # decision input: nothing in this class behaves differently because of it (MVP-0021).
    def self.from_connection(connection, credential:, selection_source: nil)
      runner = { "id" => connection.runner_id, "display_name" => connection.runner_display_name,
                 "claim_policy" => { "mode" => ALL_ELIGIBLE_MODE } }
      # MAPIAI-91 — the reviewer the guided connection selected, restored into the ORDINARY
      # `runner.reviewer:` shape so {Review::Settings} remains the single owner of provider
      # precedence and launch defaults. The key is absent when nothing was selected: a machine
      # that advertised no reviewer must not acquire one here by inference.
      provider = connection.reviewer_provider.to_s.strip
      runner["reviewer"] = { "provider" => provider } unless provider.empty?
      document = {
        "platform" => { "base_url" => connection.base_url }, "runner" => runner,
        "workspace_roots" => { connection.workspace_key.to_s => connection.local_path }
      }
      new(document, source_path: nil, credential: credential, connection: connection,
          selection_source: selection_source)
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

    def initialize(document, source_path: nil, credential: nil, connection: nil, selection_source: nil)
      raise Error, "runner config must be a YAML mapping" unless document.is_a?(Hash)

      @source_path = source_path
      # MVP-0017: a credential resolved from the OS secret store by the guided path. It is
      # held in memory only — never written to the config file, the environment, or a log.
      @resolved_credential = presence(credential)
      @connection = connection
      @selection_source = selection_source
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

    # The operator's optional, NON-SECRET `runner.specification:` block (MVP-0026): where
    # this machine keeps its specification-repository checkouts, which generation provider it
    # may run, and which lane capabilities are available or explicitly substituted. Parsed by
    # {Specification::Settings}, which also applies the environment overrides — so a guided
    # connection, which writes no YAML at all, still resolves a complete configuration.
    #
    # Returns {} when absent. That is a usable configuration, not a broken one: it selects
    # the deterministic built-in provider and no repository roots, and Preflight then refuses
    # with the exact variable to set rather than raising from here.
    def specification_settings
      value = runner["specification"]
      value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
    end

    # The operator's optional, NON-SECRET `runner.reviewer:` block (MVP-0033). It configures
    # the REVIEWER role, independently of the executor: a machine may have one, both or
    # neither. Returns {} when absent, which is a usable state meaning "this machine does not
    # review" — never an error, because a missing reviewer must not affect implementation
    # claiming.
    def reviewer_settings
      value = runner["reviewer"]
      value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
    end

    # The operator's optional, NON-SECRET `runner.executor:` SELECTION block. It names one of the
    # supported providers and NOTHING else, and it is sent to Platform, which expands it from its
    # own fixed profile map to produce the effective claim payload. It is not a way to compose a
    # profile: a command, argv, prompt delivery, timeout or environment written here is refused by
    # {#selected_implementation_profile} before any Platform request, and Platform refuses it too.
    def executor_override
      value = runner["executor"]
      value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
    end

    # The real provider profile this runner selected locally, or nil when it selected the
    # deterministic fixture or nothing at all — the offline regression path, which must never
    # require either provider CLI to be installed. BOTH lanes read it: a machine has one selected
    # AI provider, and the specification lane asking a narrower question of its own is how it came
    # to launch a provider the operator had not chosen.
    #
    # A caller that must distinguish an EXPLICIT fixture selection from no selection at all reads
    # {#executor_override} alongside it — nil answers "no real profile", which is true of both.
    #
    # `runner.executor:` is a PROVIDER-ONLY selection, the same shape Platform accepts and expands
    # from its own fixed map. It used to be a full profile here and a provider-only key there, so
    # neither representation worked across both halves of the ordinary local-selection path. A
    # machine names a provider; it does not describe one, and any additional key is refused here —
    # before a claim request is made.
    def selected_implementation_profile
      selection = executor_override
      return nil if selection.empty?

      extra = selection.keys - [ PROVIDER_KEY ]
      raise Error, "runner.executor selects only a provider (remove #{extra.join(', ')}); " \
                   "the approved command, arguments, prompt delivery, timeout and environment " \
                   "belong to the profile, not to this file" unless extra.empty?

      ImplementationProfile.for(ImplementationProfile.canonical(selection[PROVIDER_KEY]))
    end

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
      # A guided connection's credential wins: it came from the OS secret store, which is
      # the supported storage, and it must not be overridable by a stale exported value.
      return Auth.new(mode: :registered, token: @resolved_credential) if @resolved_credential

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
