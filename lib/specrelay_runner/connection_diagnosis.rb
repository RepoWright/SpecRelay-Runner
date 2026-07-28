# frozen_string_literal: true

module SpecrelayRunner
  # The non-claiming readiness test for ONE stored connection (MVP-0021 scope 3).
  #
  # Before this existed, the only way to find out whether a connected machine could still
  # execute was to run `loop` and watch what happened. That is a bad diagnostic for two
  # reasons: it consumes a real run when it works, and when it fails the message describes
  # the step that broke rather than the condition that caused it — a rejected credential, a
  # grant an operator removed in Platform, a checkout switched to another repository, and an
  # expired Claude login all surfaced as some variant of "could not claim".
  #
  # So this walks the SAME preconditions a claim depends on, in the order a claim would hit
  # them, and stops at the first one that fails — reporting ONE outcome and ONE remedy:
  #
  #   local_state_invalid       the stored entry is damaged or incomplete
  #   credential_missing        nothing in the OS secret store for this runner identity
  #   platform_unreachable     the Platform endpoint did not answer
  #   credential_rejected      Platform refused the credential (401)
  #   workspace_grant_missing  Platform holds no grant for this runner on this workspace
  #   workspace_grant_not_ready the grant exists but Platform will not offer work to it
  #   repository_mismatch      the workspace's repository moved, or this checkout is not it
  #   executor_unavailable      the provider CLI is not installed on this host
  #   executor_not_authenticated the provider CLI is installed but not signed in
  #   ok                        every precondition a claim needs is satisfied
  #
  # ORDER IS THE DESIGN. Each step is a precondition of the next, so the first failure is
  # the one worth fixing: reporting "executor not authenticated" to an operator whose grant
  # was removed would send them to fix the wrong thing. It stops at the first failure for
  # the same reason.
  #
  # It claims NOTHING. No run is requested, no lease is taken, no readiness report is
  # submitted, and Platform's side is a pure GET — so an operator can run this as often as
  # they like and it can never demote the connection being tested. That property is what
  # makes it usable as a first move when something looks wrong.
  #
  # Secret posture: the credential is read to be USED as a bearer and is never returned,
  # printed, or included in a result. Provider probe output — which carries the operator's
  # account email and organization — is reduced to a classification by ClaudeProfile and
  # discarded. Repository URLs are passed through Redaction, which strips userinfo.
  class ConnectionDiagnosis
    OK = "ok"
    LOCAL_STATE_INVALID = "local_state_invalid"
    CREDENTIAL_MISSING = "credential_missing"
    CREDENTIAL_REJECTED = "credential_rejected"
    WORKSPACE_GRANT_MISSING = "workspace_grant_missing"
    WORKSPACE_GRANT_NOT_READY = "workspace_grant_not_ready"
    REPOSITORY_MISMATCH = "repository_mismatch"
    EXECUTOR_UNAVAILABLE = "executor_unavailable"
    EXECUTOR_NOT_AUTHENTICATED = "executor_not_authenticated"
    EXECUTOR_CHECK_FAILED = "executor_check_failed"
    PLATFORM_UNREACHABLE = "platform_unreachable"

    # The result of one test. `checks` is the ordered trail of what passed before the
    # outcome was decided, so a terminal can show progress rather than a single verdict.
    Result = Struct.new(:outcome, :summary, :remedy, :checks, :platform, keyword_init: true) do
      def ok? = outcome == OK
    end

    # One precondition and how it went. `state` is :ok, :failed, or :skipped — skipped
    # because the run stopped earlier, which is information, not absence of it.
    Check = Struct.new(:label, :state, :detail, keyword_init: true)

    def self.call(**kwargs) = new(**kwargs).call

    # `secret_store` and `client_factory` are the deterministic seams: a test exercises the
    # real ordering without touching the developer's Keychain or a live Platform.
    def initialize(connection:, env: ENV, store: nil, secret_store: nil, platform: RUBY_PLATFORM,
                   client_factory: nil, repository_check: RepositoryCheck)
      @connection = connection
      @env = env
      @store = store
      @injected_secret_store = secret_store
      @platform = platform
      @client_factory = client_factory || ->(base_url, token) { PlatformClient.new(base_url: base_url, token: token) }
      @repository_check = repository_check
      @checks = []
    end

    def call
      local_state or return result
      credential = stored_credential or return result
      described = describe(credential) or return result
      grant(described) or return result
      repository(described) or return result
      executor(described) or return result

      succeed(described)
    end

    private

    attr_reader :connection, :env, :platform, :client_factory, :repository_check, :checks

    # --- the preconditions, in claim order -----------------------------------

    # A hand-edited or partially written entry is caught here rather than surfacing later as
    # a confusing config error the operator did not cause.
    def local_state
      missing = connection.missing_fields
      return pass("Local connection entry") if missing.empty?

      fail_with(LOCAL_STATE_INVALID, "Local connection entry",
                "the stored entry for #{connection.workspace_key} is incomplete " \
                "(missing #{missing.join(', ')})",
                "remove this stale local entry with `specrelay-runner connections disconnect-local " \
                "#{connection.workspace_key}`, then reconnect it with " \
                "`specrelay-runner connect <enrollment-code>`")
    end

    # The credential belongs to the RUNNER identity, not the workspace, with the
    # pre-MVP-0017-round-003 per-workspace account read as a fallback — the same resolution
    # order the claim path uses, because testing a different lookup than the one that runs
    # would prove nothing.
    def stored_credential
      value = read_credential
      return pass_value("Runner credential in the OS secret store", value) if value

      fail_with(CREDENTIAL_MISSING, "Runner credential in the OS secret store",
                "no credential is stored for runner #{connection.runner_public_id}",
                "reconnect this workspace with `specrelay-runner connect <enrollment-code>`; " \
                "the credential is re-issued and stored without being printed")
    rescue SecretStore::UnsupportedPlatform, SecretStore::Error => e
      fail_with(CREDENTIAL_MISSING, "Runner credential in the OS secret store",
                Redaction.redact(e.message),
                "unlock your login keychain (Keychain Access ▸ login) and run the test again")
    end

    # One request answers three questions at once — is Platform reachable, is the credential
    # accepted, and does the grant exist — because they are the same round trip. The
    # exception class, not a parsed body, is what distinguishes them.
    def describe(credential)
      described = client(credential).describe_workspace_connection(workspace_key: connection.workspace_key)
      pass_value("Platform accepted the credential", described)
    rescue PlatformClient::Unauthorized => e
      fail_with(CREDENTIAL_REJECTED, "Platform accepted the credential", Redaction.redact(e.message),
                "reconnect this workspace with `specrelay-runner connect <enrollment-code>`; the " \
                "stored credential is no longer valid for this runner (it may have been rotated " \
                "or the runner revoked)")
    rescue PlatformClient::NotFound
      fail_with(WORKSPACE_GRANT_MISSING, "Platform workspace grant",
                "Platform holds no grant for this runner on #{connection.workspace_key}",
                "ask your project owner for a new enrollment code for this workspace and run " \
                "`specrelay-runner connect <code>`; or drop the local entry with " \
                "`specrelay-runner connections disconnect-local #{connection.workspace_key}`")
    rescue PlatformClient::Error => e
      fail_with(PLATFORM_UNREACHABLE, "Platform reachable", Redaction.redact(e.message),
                "check that #{connection.base_url} is running and reachable from this machine, " \
                "then run the test again")
    end

    # `ready` is Platform's own composite predicate, so the runner does not re-derive the
    # eligibility rule and cannot drift from it. A deactivated workspace is called out
    # separately because it grants no capacity however healthy the grant looks.
    def grant(described)
      connection_state = described.fetch("connection", {})
      return grant_workspace_inactive(described) if described.dig("workspace", "active") == false
      return pass("Platform workspace grant is ready") if connection_state["ready"]

      fail_with(WORKSPACE_GRANT_NOT_READY, "Platform workspace grant is ready",
                grant_detail(connection_state), grant_remedy(connection_state))
    end

    def grant_workspace_inactive(described)
      fail_with(WORKSPACE_GRANT_NOT_READY, "Platform workspace grant is ready",
                "the workspace #{described.dig('workspace', 'workspace_key')} is deactivated in Platform",
                "ask your project owner to reactivate the workspace in Platform project setup; " \
                "a deactivated workspace is offered to no runner")
    end

    def grant_detail(connection_state)
      [ "Platform reports state #{connection_state['state']}",
        connection_state["failure_class"] && "(#{connection_state['failure_class']})",
        Redaction.redact(connection_state["detail"].to_s) ].compact.reject(&:empty?).join(" ")
    end

    # The remedy follows Platform's OWN failure classification where it has one, because
    # Platform already decided which of the local conditions caused the block.
    def grant_remedy(connection_state)
      case connection_state["failure_class"]
      when "repository_mismatch", "repository_missing"
        "point this connection at the correct checkout by reconnecting: " \
          "`specrelay-runner connect <enrollment-code>`"
      when "executor_not_authenticated"
        "sign in to Claude Code on this host (`claude auth login`), then reconnect this workspace"
      when "executor_unavailable", "executor_check_failed"
        "install Claude Code so `claude` resolves on this runner's PATH, then reconnect this workspace"
      else
        "reconnect this workspace with `specrelay-runner connect <enrollment-code>` so it reports " \
          "readiness again; Platform marks a connection ready only after a successful report"
      end
    end

    # Two comparisons, both of which a claim depends on: the workspace's repository identity
    # as Platform defines it TODAY against what this connection stored, and that same
    # identity against the checkout actually on disk. An operator can break either one
    # without touching the other — by editing the workspace in Platform, or by repointing
    # the local directory — and they need different fixes.
    def repository(described)
      expected = described.fetch("workspace", {})
      return platform_repository_drift(expected) unless workspace_repository_matches?(expected)

      pass("Workspace repository matches this connection")
      checkout(expected)
    end

    def workspace_repository_matches?(expected)
      repository_identity(expected["repository_url"]) == repository_identity(connection.repository_url) &&
        expected["default_branch"].to_s == connection.default_branch.to_s
    end

    def platform_repository_drift(expected)
      fail_with(REPOSITORY_MISMATCH, "Workspace repository matches this connection",
                "Platform now defines this workspace as " \
                "#{Redaction.redact(expected['repository_url'].to_s)} (#{expected['default_branch']}), " \
                "but this connection was validated against " \
                "#{Redaction.redact(connection.repository_url.to_s)} (#{connection.default_branch})",
                "reconnect this workspace with `specrelay-runner connect <enrollment-code>` and point " \
                "it at a checkout of #{Redaction.redact(expected['repository_url'].to_s)}")
    end

    # Reuses the same validator `connect` used, so the test cannot accept a checkout the
    # guided connection would have refused. It reads local git configuration only — no
    # network, so this stays fast and offline-safe.
    def checkout(expected)
      result = repository_check.call(path: connection.local_path,
                                    repository_url: expected["repository_url"].to_s,
                                    default_branch: expected["default_branch"].to_s)
      return pass("Local checkout is this workspace's repository") if result.ok?

      fail_with(REPOSITORY_MISMATCH, "Local checkout is this workspace's repository",
                Redaction.redact(result.message.to_s),
                "reconnect this workspace with `specrelay-runner connect <enrollment-code>` and give " \
                "it the correct local checkout directory")
    end

    # Only for the supported real Claude profile. The deterministic fixture executor must
    # never require Claude Code to be installed or signed in, so a fake-executor workspace
    # skips this check explicitly rather than silently passing it.
    def executor(described)
      executor_config = described.fetch("executor", {})
      unless ClaudeProfile.selected?(executor_config)
        return skip("Executor readiness", "this workspace uses the deterministic fixture executor, " \
                                          "which needs no provider CLI")
      end

      readiness = ClaudeProfile.new(executor_config).readiness(env: env)
      return pass("Executor readiness (#{readiness.summary})") if readiness.ready?

      fail_with(executor_outcome(readiness), "Executor readiness", readiness.summary, readiness.remedy)
    rescue ClaudeProfile::Error => e
      # A profile this runner REFUSES to launch is an executor problem, reported as one rather
      # than raised: the operator needs the remedy, and the claim path would have failed here too.
      fail_with(EXECUTOR_CHECK_FAILED, "Executor readiness", Redaction.redact(e.message),
                "this runner will not launch the executor this workspace resolves to; ask your " \
                "project owner to correct the workspace's executor configuration in Platform")
    end

    def executor_outcome(readiness)
      return EXECUTOR_UNAVAILABLE if readiness.version == ClaudeProfile::UNAVAILABLE
      return EXECUTOR_NOT_AUTHENTICATED if readiness.auth == ClaudeProfile::NOT_AUTHENTICATED

      EXECUTOR_CHECK_FAILED
    end

    # --- result construction -------------------------------------------------

    def succeed(described)
      @outcome = OK
      @summary = "#{connection.workspace_key} is ready: Platform accepts this runner, the grant is " \
                 "ready, the checkout matches, and the executor is available."
      @platform = described
      result
    end

    def result
      Result.new(outcome: @outcome || OK, summary: @summary, remedy: @remedy,
                 checks: checks, platform: @platform)
    end

    def pass(label)
      checks << Check.new(label: label, state: :ok, detail: nil)
      true
    end

    # `true` is not usable as a carrier for the value a later step needs, and a bare value
    # could legitimately be falsey, so passing steps that produce something return it and
    # the caller's `or return` handles nil.
    def pass_value(label, value)
      checks << Check.new(label: label, state: :ok, detail: nil)
      value
    end

    def skip(label, detail)
      checks << Check.new(label: label, state: :skipped, detail: detail)
      true
    end

    # Records the failure and returns nil, which is what stops the walk at the first
    # problem — every caller is `x or return result`.
    def fail_with(outcome, label, detail, remedy)
      checks << Check.new(label: label, state: :failed, detail: detail)
      @outcome = outcome
      @summary = detail
      @remedy = remedy
      nil
    end

    # --- collaborators -------------------------------------------------------

    def read_credential
      store = secret_store
      runner_public_id = connection.runner_public_id.to_s.strip
      unless runner_public_id.empty?
        value = store.read(account: SecretStore.account_for_runner(runner_public_id))
        return value if value
      end
      store.read(account: SecretStore.legacy_account_for(connection.workspace_key))
    end

    def secret_store = @injected_secret_store || SecretStore.for(platform: platform)
    def client(credential) = client_factory.call(connection.base_url, credential)
    def repository_identity(url) = RepositoryCheck.repository_identity(url)
  end
end
