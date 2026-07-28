# frozen_string_literal: true

module SpecrelayRunner
  # The ONE implementation of every connection-management action (MVP-0021).
  #
  # The interactive dashboard and the `specrelay-runner connections …` commands are two
  # presentations of this object and nothing more. That is a requirement, not a preference:
  # a menu that re-implemented "remove the local entry" or "ask Platform to disconnect"
  # would be a second place for those rules to drift, and the destructive ones are exactly
  # the rules that must not. So both surfaces call these methods, and the difference between
  # them is only how the operator is asked and how the outcome is printed.
  #
  # Every method returns an Outcome carrying a finished, non-secret operator sentence. The
  # callers do not compose messages, decide exit codes from internals, or interpret state —
  # they print `message`, print `remedy` when there is one, and map `ok?` to an exit code.
  #
  # Nothing here reads the terminal or prompts. Confirmation belongs to the surface that has
  # the operator's attention; the operator's DECISION arrives as an argument
  # (`remove_credential:`), so a scripted `connections disconnect-local --remove-credential`
  # and a confirmed menu action travel the same path.
  class ConnectionOperations
    # The two outcomes Platform's disconnect endpoint is contracted to state
    # (`Runner::Connections::Disconnect::REVOKED` / `ALREADY_ABSENT`). They are consumed here as
    # constants because Platform's own comment says "the runner branches on them" — round 001
    # never looked at the field at all, which made that statement aspirational rather than true
    # (review-001 F2).
    PLATFORM_REVOKED = "revoked"
    PLATFORM_ALREADY_ABSENT = "already_absent"
    PLATFORM_OUTCOMES = [ PLATFORM_REVOKED, PLATFORM_ALREADY_ABSENT ].freeze

    # A finished operator-facing result. `ok` is the exit-code decision: false means the
    # operation was understood and did not succeed (exit 1), and `invalid` means the local
    # state or request was unusable (exit 2). `remedy` is the ONE next action.
    Outcome = Struct.new(:ok, :invalid, :message, :remedy, :payload, keyword_init: true) do
      def ok? = ok ? true : false
      def invalid? = invalid ? true : false
    end

    # The dashboard's top-level view model. `default_missing` is deliberately separate from
    # `default_workspace_key`: a default naming a workspace that is no longer connected is a
    # condition the operator must see and fix, not silently nothing.
    Listing = Struct.new(:connections, :default_workspace_key, :default_missing, :readable, :path,
                         keyword_init: true) do
      def empty? = connections.empty?
      def readable? = readable ? true : false
      def default_missing? = default_missing ? true : false
      def default?(connection) = !default_workspace_key.nil? && default_workspace_key == connection.workspace_key
    end

    def self.call(**kwargs) = new(**kwargs)

    def initialize(env: ENV, store: nil, secret_store: nil, platform: RUBY_PLATFORM,
                   client_factory: nil, diagnosis: ConnectionDiagnosis)
      @env = env
      @store = store || ConnectionStore.load(env: env)
      @injected_secret_store = secret_store
      @platform = platform
      @client_factory = client_factory || ->(base_url, token) { PlatformClient.new(base_url: base_url, token: token) }
      @diagnosis = diagnosis
    end

    attr_reader :store

    def listing
      Listing.new(connections: store.connections, default_workspace_key: store.default_workspace_key,
                  default_missing: store.default_set_but_missing?, readable: store.readable?,
                  path: store.path)
    end

    def connection_for(workspace_key) = store.connection_for(workspace_key)

    # Would removing this workspace leave the runner-scoped Keychain credential with nothing
    # depending on it? Asked BEFORE the removal so a surface can put both questions to the
    # operator up front and then perform exactly one atomic operation, instead of removing the
    # entry and only then discovering it has a second question to ask.
    def credential_orphaned_by?(workspace_key)
      connection = store.connection_for(workspace_key)
      return false if connection.nil? || connection.runner_public_id.to_s.strip.empty?

      store.connections.none? do |other|
        other.workspace_key != connection.workspace_key &&
          other.runner_public_id == connection.runner_public_id
      end
    end

    def credential_account_for(workspace_key)
      connection = store.connection_for(workspace_key)
      connection && SecretStore.account_for_runner(connection.runner_public_id.to_s)
    end

    # --- readiness test ------------------------------------------------------

    def test(workspace_key)
      connection = require_connection(workspace_key) { |outcome| return outcome }
      result = @diagnosis.call(connection: connection, env: env, secret_store: @injected_secret_store,
                               platform: platform, client_factory: @client_factory)
      Outcome.new(ok: result.ok?, invalid: result.outcome == ConnectionDiagnosis::LOCAL_STATE_INVALID,
                  message: result.ok? ? result.summary : "#{result.outcome}: #{result.summary}",
                  remedy: result.remedy, payload: result)
    end

    # --- explicit default ----------------------------------------------------

    def set_default(workspace_key)
      connection = require_connection(workspace_key) { |outcome| return outcome }
      store.set_default(connection.workspace_key)
      Outcome.new(ok: true, message: "Default workspace set to #{connection.workspace_key}. " \
                                     "`specrelay-runner loop` and `claim-once` will use it when no " \
                                     "--workspace is given, and will say so.")
    rescue ConnectionStore::Error => e
      write_failed(e)
    end

    def clear_default
      previous = store.default_workspace_key
      store.clear_default
      Outcome.new(ok: true, message: default_cleared_message(previous))
    rescue ConnectionStore::Error => e
      write_failed(e)
    end

    def default_cleared_message(previous)
      return "No default workspace was set; nothing changed." if previous.nil?

      "Default workspace cleared (was #{previous}). With several workspaces connected, `loop` and " \
        "`claim-once` will ask for --workspace again."
    end

    # --- local disconnect ----------------------------------------------------

    # Removes THIS MACHINE's memory of one workspace, and nothing else. Presented honestly
    # because the honest version is surprising: it does not remove Platform-side
    # authorization, so Platform still lists this machine as connected and would still offer
    # it work if it reconnected. `disconnect_platform` is the operation that changes that.
    #
    # The credential is runner-scoped, so removing a workspace must NOT remove it while
    # another local connection for the same runner identity still depends on it — that would
    # break a working connection as a side effect of tidying up an unrelated one. When
    # nothing depends on it any more, the operator is told so and decides separately; that
    # decision arrives here as `remove_credential`.
    def disconnect_local(workspace_key, remove_credential: false)
      connection = require_connection(workspace_key) { |outcome| return outcome }
      removed = store.delete(connection.workspace_key)
      return already_absent_locally(connection) if removed.nil?

      credential = credential_disposition(removed, remove_credential: remove_credential)
      # The local entry really was removed, so the message says so — but a Keychain that REFUSED
      # the credential deletion makes this a failed operation, not a successful one with a note.
      # An operator who asked for the credential to be gone must not be told it is (review-001 F1),
      # and a script must be able to see it in the exit code.
      Outcome.new(ok: credential[:state] != :remove_failed,
                  message: local_disconnect_message(removed, credential),
                  remedy: credential[:remedy], payload: credential)
    rescue ConnectionStore::Error => e
      write_failed(e)
    end

    # Whether the runner-scoped Keychain credential is still needed, and what was done about
    # it. `shared_with` is computed AFTER the removal, so it reflects what actually remains.
    def credential_disposition(removed, remove_credential:)
      account = SecretStore.account_for_runner(removed.runner_public_id.to_s)
      shared_with = store.connections.select { |c| c.runner_public_id == removed.runner_public_id }
                         .map(&:workspace_key)
      return { state: :kept_shared, account: account, shared_with: shared_with } if shared_with.any?
      return { state: :orphaned, account: account, shared_with: [], remedy: orphaned_remedy(removed) } unless remove_credential

      delete_credential(account)
    end

    def orphaned_remedy(removed)
      "no local connection uses runner #{removed.runner_public_id} any more. Its Keychain " \
        "credential was KEPT. Remove it too with `specrelay-runner connections " \
        "disconnect-local #{removed.workspace_key} --remove-credential` (already done for the " \
        "local entry), or leave it — reconnecting reuses it."
    end

    def delete_credential(account)
      secret_store.delete_credential(account: account)
      { state: :removed, account: account, shared_with: [] }
    rescue SecretStore::UnsupportedPlatform, SecretStore::Error => e
      { state: :remove_failed, account: account, shared_with: [], remedy: Redaction.redact(e.message) }
    end

    def local_disconnect_message(removed, credential)
      "Removed the local connection for #{removed.workspace_key} " \
        "(#{Redaction.redact(removed.repository_url.to_s)}). #{credential_sentence(credential)} " \
        "This removed only this machine's local memory — Platform-side authorization is " \
        "unchanged; use `connections disconnect-platform #{removed.workspace_key}` for that."
    end

    def credential_sentence(credential)
      case credential[:state]
      when :kept_shared
        "The runner credential was kept: #{credential[:shared_with].join(', ')} still uses it."
      when :removed then "The runner-scoped Keychain credential (#{credential[:account]}) was removed."
      when :remove_failed
        "The runner-scoped Keychain credential (#{credential[:account]}) could NOT be removed and " \
          "is still stored."
      else "The runner credential was kept."
      end
    end

    def already_absent_locally(connection)
      Outcome.new(ok: true, message: "No local connection for #{connection.workspace_key}; " \
                                     "nothing to remove.")
    end

    # The pre-round-003 per-workspace Keychain item, removed ONLY through this explicit
    # action and only after naming the exact account. Nothing else in the runner deletes a
    # legacy item, because a machine that connected under the old scheme still authenticates
    # from it and a silent cleanup would take it offline.
    def forget_legacy_credential(workspace_key)
      key = workspace_key.to_s.strip
      return usage("a workspace key is required") if key.empty?

      account = SecretStore.legacy_account_for(key)
      secret_store.delete_credential(account: account)
      Outcome.new(ok: true, message: "Removed the legacy per-workspace Keychain item #{account}. " \
                                     "Runner-scoped credentials (runner:<public-id>) are untouched.")
    rescue SecretStore::UnsupportedPlatform, SecretStore::Error => e
      Outcome.new(ok: false, message: Redaction.redact(e.message),
                  remedy: "unlock your login keychain (Keychain Access ▸ login) and try again")
    end

    # --- Platform disconnect -------------------------------------------------

    # Asks Platform to remove this runner's grant for one workspace. Local state is left
    # alone on purpose: deleting it after a FAILED Platform call would leave a machine that
    # still has authorization it can no longer see, which is the worst of both states. The
    # caller offers local removal only after this returns ok.
    def disconnect_platform(workspace_key)
      connection = require_connection(workspace_key) { |outcome| return outcome }
      credential = stored_credential(connection)
      return missing_credential(connection) if credential.nil?

      response = client(connection, credential).disconnect_workspace_connection(
        workspace_key: connection.workspace_key
      )
      platform_disconnected(connection, response)
    rescue PlatformClient::Unauthorized => e
      platform_refused(connection, e)
    rescue PlatformClient::Error => e
      Outcome.new(ok: false, message: Redaction.redact(e.message),
                  remedy: "check that #{connection.base_url} is reachable and try again; nothing " \
                          "local was changed")
    rescue SecretStore::UnsupportedPlatform, SecretStore::Error => e
      Outcome.new(ok: false, message: Redaction.redact(e.message),
                  remedy: "unlock your login keychain (Keychain Access ▸ login) and try again")
    end

    # A 200 is not a confirmation. Platform must SAY what it did.
    #
    # Round 001 returned `ok: true` for any 200 (review-001 F2). `PlatformClient#parse` yields
    # `{}` for a body that is not JSON, so an HTML page from a proxy, a captive portal, or a
    # different service now listening on that port arrived here as a success — and the dashboard
    # went on to print "Platform confirmed." and offer to delete local state. That is the exact
    # "worst of both states" this operation exists to prevent: local memory gone, Platform-side
    # authorization possibly still there, and nothing left on the machine pointing at it.
    #
    # So the outcome is validated against the two contract values. Anything else is an operation
    # failure (exit 1), not invalid local state (exit 2) — the request was well-formed and the
    # machine's own state is fine; it is the answer that could not be trusted.
    def platform_disconnected(connection, response)
      disconnected = response.is_a?(Hash) ? response["disconnected"] : nil
      outcome = disconnected.is_a?(Hash) ? disconnected["outcome"].to_s : ""
      return platform_unconfirmed(connection, outcome) unless PLATFORM_OUTCOMES.include?(outcome)

      Outcome.new(ok: true, payload: disconnected,
                  message: platform_disconnect_message(connection, disconnected, outcome),
                  remedy: "the local entry for #{connection.workspace_key} is still stored on this " \
                          "machine. Remove it with `specrelay-runner connections disconnect-local " \
                          "#{connection.workspace_key}`.")
    end

    # Platform's own sentence when it sent one, and the runner's own when it did not. A blank
    # `detail` used to render as an empty line, so the operator's next screen line was
    # "Platform confirmed." with nothing behind it (review-001 F2).
    def platform_disconnect_message(connection, disconnected, outcome)
      supplied = Redaction.redact(disconnected["detail"].to_s).strip
      return supplied unless supplied.empty?

      case outcome
      when PLATFORM_REVOKED
        "Platform removed this runner's grant for #{connection.workspace_key}. The runner " \
          "identity and its other workspace connections are unchanged."
      else
        "Platform holds no grant for this runner on '#{connection.workspace_key}', so there was " \
          "nothing to remove."
      end
    end

    def platform_unconfirmed(connection, outcome)
      Outcome.new(ok: false, payload: nil,
                  message: "Platform answered, but did not confirm the disconnect for " \
                           "#{connection.workspace_key}#{" (it reported '#{Redaction.redact(outcome)}')" unless outcome.empty?}.",
                  remedy: "nothing local was changed. Check that #{connection.base_url} is really " \
                          "Platform and not a proxy or another service, then try again; or remove " \
                          "only this machine's copy with `specrelay-runner connections " \
                          "disconnect-local #{connection.workspace_key}`.")
    end

    def platform_refused(connection, error)
      Outcome.new(ok: false, message: Redaction.redact(error.message),
                  remedy: "Platform did not accept this runner's credential, so nothing was " \
                          "disconnected and no local state changed. Reconnect with " \
                          "`specrelay-runner connect <enrollment-code>`, or remove only this " \
                          "machine's copy with `specrelay-runner connections disconnect-local " \
                          "#{connection.workspace_key}`.")
    end

    private

    attr_reader :env, :platform, :client_factory

    # Resolves a workspace key or yields the Outcome the caller must return. Written as a
    # yielding guard rather than a nil return so that no caller can forget the check: there
    # is no way to get a connection out of it without handling the failure.
    def require_connection(workspace_key)
      key = workspace_key.to_s.strip
      yield usage("a workspace key is required (one of: #{known_keys})") if key.empty?

      found = store.connection_for(key)
      yield unknown_workspace(key) if found.nil?

      found
    end

    def known_keys
      keys = store.connections.map(&:workspace_key)
      keys.empty? ? "none connected" : keys.join(", ")
    end

    def unknown_workspace(key)
      return unreadable_state unless store.readable?

      Outcome.new(ok: false, invalid: true, message: "no local connection for workspace '#{key}'.",
                  remedy: unknown_workspace_remedy)
    end

    def unknown_workspace_remedy
      return "connect this machine first: `specrelay-runner connect <enrollment-code>`" if store.connections.empty?

      "connected workspaces: #{known_keys}"
    end

    def unreadable_state
      Outcome.new(ok: false, invalid: true,
                  message: "the local runner state file #{store.path} exists but could not be read " \
                           "as SpecRelay connection state.",
                  remedy: "move it aside and reconnect: `specrelay-runner connect <enrollment-code>`")
    end

    def missing_credential(connection)
      Outcome.new(ok: false, invalid: true,
                  message: "no stored credential for runner #{connection.runner_public_id}, so this " \
                           "machine cannot authenticate to Platform.",
                  remedy: "remove only this machine's copy with `specrelay-runner connections " \
                          "disconnect-local #{connection.workspace_key}`, or reconnect with " \
                          "`specrelay-runner connect <enrollment-code>`")
    end

    def usage(message) = Outcome.new(ok: false, invalid: true, message: message)

    def write_failed(error)
      Outcome.new(ok: false, invalid: true, message: Redaction.redact(error.message),
                  remedy: "check that #{store.path} is writable by this user")
    end

    # The same runner-scoped-then-legacy resolution order the claim path uses.
    def stored_credential(connection)
      secrets = secret_store
      runner_public_id = connection.runner_public_id.to_s.strip
      unless runner_public_id.empty?
        value = secrets.read(account: SecretStore.account_for_runner(runner_public_id))
        return value if value
      end
      secrets.read(account: SecretStore.legacy_account_for(connection.workspace_key))
    end

    def secret_store = @injected_secret_store || SecretStore.for(platform: platform)
    def client(connection, credential) = client_factory.call(connection.base_url, credential)
  end
end
