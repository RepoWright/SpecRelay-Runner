# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "socket"
require "time"

module SpecrelayRunner
  # The guided runner connection: `specrelay-runner connect <code>`.
  #
  # This is the ONLY local action a normal user performs. The whole command asks for
  # exactly one thing — the local checkout directory — and derives everything else:
  #
  #   1. the Platform endpoint, read from the enrollment code itself (the origin is not a
  #      secret, so it travels inside the code and the displayed command needs no flag);
  #   2. the runner identity, derived from this machine's hostname, so it is stable and a
  #      retry updates the same runner instead of creating a second one;
  #   3. the project/workspace assignment, the repository identity to validate against, the
  #      executor profile, and this machine's own preview connector, all returned by the
  #      enrollment exchange.
  #
  # Order is load-bearing and fails closed at each step:
  #
  #   platform support check -> preview the code (does NOT consume it) ->
  #   ask for the checkout -> validate the checkout ->
  #   provider readiness (only for the real Claude profile) ->
  #   prove the OS secret store is writable -> EXCHANGE the code ->
  #   store the credential and the preview connector token ->
  #   save non-secret local state -> report readiness to Platform
  #
  # Every step that can fail for a purely local reason runs BEFORE the exchange, so a failed
  # attempt costs nothing — not even the one-time code — on a first connection and on a
  # reconnect alike. The unsupported-platform check runs first, before any Platform call; the
  # Keychain writability check runs last among the local steps, immediately before the code is
  # spent. The credential is stored BEFORE readiness is reported, so a runner Platform believes
  # is ready can always authenticate. If a step after
  # the exchange fails, Platform holds the connection in `pending`/`blocked` — never `ready` —
  # and the operator reissues a code and retries.
  #
  # Secret posture: neither the durable credential nor the preview connector token is ever
  # printed, written to YAML, a shell profile, Git, or a log, and neither appears in an error
  # message. The local checkout path is stored locally and never sent to Platform. Provider probe
  # output is reduced to one classification and discarded.
  class Connect
    Error = Class.new(StandardError)

    CONTRACT_VERSION = "mvp-0017"

    # Matches Platform's Runner::Enrollment::Code shape.
    CODE_PREFIX = "sre_"
    CODE_SEPARATOR = "."

    # This machine advertises no reviewer capability. A normal state, not a failure: it stays a
    # fully usable executor.
    NO_REVIEWER = "not_configured"

    # The readiness classification Platform accepts as ready.
    READY = "ready"

    Result = Struct.new(:workspace_key, :state, :failure_class, :detail, keyword_init: true) do
      def ready? = state == "ready"
    end

    def self.call(**kwargs) = new(**kwargs).call

    # `secret_store`, `store`, and `client_factory` are the deterministic injection seams
    # the engineering constraints require: a test exercises the real flow without touching
    # the developer's Keychain, home directory, or a live Platform, and production code
    # keeps ONE resolution point for each collaborator.
    def initialize(code:, out:, err:, env: ENV, input: $stdin, checkout_path: nil,
                   store: nil, secret_store: nil, platform: RUBY_PLATFORM, client_factory: nil)
      @code = code.to_s.strip
      @out = out
      @err = err
      @env = env
      @input = input
      @checkout_path = checkout_path
      @store = store
      @injected_secret_store = secret_store
      @platform = platform
      @client_factory = client_factory || ->(base_url, token) { PlatformClient.new(base_url: base_url, token: token) }
    end

    def call
      secret_store = resolve_secret_store
      origin = origin_from_code!

      # Everything local happens against a PREVIEW, which does not consume the code. Exchanging
      # first meant a mistyped checkout or an unauthenticated provider spent the code and — for an
      # already-connected machine — rotated its credential and demoted its grant. One typo took a
      # working runner offline. Now a failure here costs nothing at all: the same code still works.
      assignment = preview(origin)
      workspace = assignment.fetch("workspace")
      # Which machine identity this PROJECT is registered under, resolved from the previewed
      # assignment and announced before anything is consumed — so what the operator reads is the
      # identity that will really be enrolled.
      registration = resolve_registration!(origin, assignment, workspace)
      checkout = validated_checkout!(workspace)
      readiness = executor_readiness(assignment.fetch("executor", {}))
      # Resolved ONCE, before anything is stored or reported. Deriving it separately for the
      # readiness report and for later local execution is what let this machine advertise a
      # reviewer it could not then launch.
      reviewer = reviewer_settings(readiness)

      # What this machine already holds for THIS registration decides what the exchange presents,
      # so it is resolved before anything is consumed.
      held = held_credential(secret_store, registration)
      # The local connection file has to be able to accept a new record without disturbing the
      # existing selection. Asked here, among the other local checks, so a damaged file or a
      # default the operator must fix costs no enrollment code.
      verify_connection_store!
      verify_secret_storage!(secret_store)

      # Only now is anything consumed or changed.
      enrolled = exchange(origin, registration, held)
      persist(secret_store, enrolled, workspace, checkout, reviewer)
      report(enrolled, workspace, checkout, readiness, reviewer)
    end

    private

    attr_reader :code, :out, :err, :env, :input, :platform, :client_factory

    def store = @store ||= ConnectionStore.load(env: env)

    # Resolved before anything else in #call, so an unsupported host refuses BEFORE it can
    # consume an enrollment code it could never finish using.
    def resolve_secret_store = @injected_secret_store || SecretStore.for(platform: platform)

    # The enrollment code carries the Platform origin so the operator copies one command.
    # A code that is not this shape is refused locally, before any network call, so a
    # mistyped or truncated paste gets an immediate, specific message.
    def origin_from_code!
      body = code.delete_prefix(CODE_PREFIX)
      encoded, separator, random = body.partition(CODE_SEPARATOR)
      raise Error, malformed_message if separator.empty? || encoded.empty? || random.empty?

      origin = decode(encoded)
      raise Error, malformed_message if origin.nil?

      origin
    end

    def decode(encoded)
      value = Base64.urlsafe_decode64(encoded)
      value.match?(%r{\Ahttps?://\S+\z}) ? value : nil
    rescue ArgumentError
      nil
    end

    def malformed_message
      "that does not look like a SpecRelay enrollment code. Copy the whole " \
        "`specrelay-runner connect …` command from Platform project setup."
    end

    # Read the assignment without consuming the code.
    def preview(origin)
      out.puts "Connecting to #{origin}…"
      assignment = client(origin, code).preview_enrollment
      announce_assignment(assignment)
      assignment
    end

    # WHICH machine identity Platform knows this project by, and which stored credential belongs
    # to it. One registration per project, because that is what Platform enforces: a registration
    # belongs to the project of the code that created it and cannot be repointed at another.
    #
    # Three cases, in order of how much this machine already knows:
    #
    #   1. this exact connection exists — reuse its saved identity, so a reconnect updates the
    #      registration it already has rather than creating a second one;
    #   2. a DIFFERENT workspace of a project this machine already knows — reuse that project's
    #      single registration, because a project's workspaces share one machine there;
    #   3. a project with nothing saved — derive a new identity for it.
    #
    # Two saved registrations for one project is a state this machine cannot choose between, and
    # guessing would mean presenting one project's credential under another's identity. It is
    # reported with both identities named instead.
    Registration = Struct.new(:runner_id, :display_name, :runner_public_id, keyword_init: true)

    def resolve_registration!(origin, assignment, workspace)
      project_slug = assignment.dig("project", "slug").to_s
      saved = store.project_connections(origin, project_slug)
      exact = saved.find { |connection| connection.workspace_key == workspace["workspace_key"] }
      registration = exact ? from_saved(exact) : registration_for_project(saved, origin, project_slug)
      announce_registration(registration)
      @registration = registration
    end

    def registration_for_project(saved, origin, project_slug)
      known = saved.uniq { |connection| connection.runner_id.to_s }
      raise Error, conflicting_registrations(project_slug, known) if known.length > 1
      return from_saved(known.first) if known.length == 1

      Registration.new(runner_id: project_runner_id(origin, project_slug),
                       display_name: runner_display_name, runner_public_id: nil)
    end

    def from_saved(connection)
      Registration.new(runner_id: connection.runner_id, display_name: runner_display_name,
                       runner_public_id: presence(connection.runner_public_id))
    end

    def conflicting_registrations(project_slug, known)
      identities = known.map { |connection| "#{connection.runner_id} (#{connection.workspace_key})" }
      "this machine has more than one saved registration for project '#{project_slug}': " \
        "#{identities.join(', ')}. Disconnect the one you no longer use with " \
        "`specrelay-runner connections disconnect-local <selector>`, then connect again."
    end

    # A machine identity for ONE project on ONE Platform. Hostname-derived, so it still names this
    # machine and a retry updates the same registration, plus a short digest of the Platform
    # origin and project slug so a second project gets its own registration instead of being
    # refused as a machine that already belongs somewhere else.
    #
    # A standard SHA-256 over a standard JSON serialization of the two values: deterministic
    # across retries, different between projects, and no new wire format to keep in step with
    # anything. The digest is an identifier, not a secret, and neither value in it is one.
    def project_runner_id(origin, project_slug)
      digest = Digest::SHA256.hexdigest(JSON.generate([ origin, project_slug ]))
      "#{hostname_slug}-runner-#{digest[0, 12]}"
    end

    def announce_registration(registration)
      out.puts "Runner identity:    #{registration.display_name} (#{registration.runner_id})"
    end

    # The local connection file must be able to take a new record without disturbing the existing
    # selection. `pinned_default` raises when the stored default no longer names exactly one
    # connection — the state in which adding a record could let a stale default attach to it.
    def verify_connection_store!
      raise ConnectionStore::Error, unreadable_store_message unless store.readable?

      store.pinned_default
    rescue ConnectionStore::Error => e
      raise ConnectionStore::Error,
            "#{e.message} The enrollment code was NOT used, so the same command still works."
    end

    def unreadable_store_message
      "the local runner connection file #{store.path} exists but could not be read as SpecRelay " \
        "connection state. Move it aside and connect again."
    end

    # Prove local secret storage works BEFORE the one-time code is spent.
    #
    # Unconditionally, because every successful exchange returns a connector token this machine
    # must store — a reconnect included. Probing only a machine that holds no credential yet was
    # right while the credential was the only stored secret; it would now let a reconnect spend a
    # code it could never have finished using.
    #
    # This ordering is the difference between a failed connection costing nothing and costing a
    # freshly issued code every retry — the state a real operator hit when the Keychain write
    # itself was broken. It runs last among the local steps, so an operator with a mistyped
    # checkout still hears about the checkout.
    def verify_secret_storage!(secret_store)
      secret_store.verify_writable!
      out.puts "Keychain:           writable (checked before the enrollment code was used)"
    rescue SecretStore::Error => e
      raise SecretStore::Error,
            "#{e.message} The enrollment code was NOT used, so the same command still works."
    end

    # Consume the code. The machine's EXISTING credential is presented so Platform can recognise
    # a reconnect and leave that credential alone; when it does, `credential_unchanged` comes
    # back true and nothing in the secret store is touched.
    def exchange(origin, registration, held)
      enrolled = client(origin, code).enroll(identity(registration), current_credential: held)
      @credential = presence(enrolled["credential"]) || held
      raise Error, "Platform returned no usable credential for this machine" if @credential.nil?

      @credential_unchanged = enrolled["credential_unchanged"] ? true : false
      @preview_connector = preview_connector!(enrolled["preview_connector"])
      @base_url = presence(enrolled.dig("platform", "base_url")) || origin
      enrolled
    end

    # The token for this machine's own preview connector, which Platform provisioned during the
    # exchange. REQUIRED: a machine that Platform believes can publish a preview but which holds
    # no connector would fail much later and somewhere else, so a nominally successful response
    # without one is refused here — before anything is stored or reported.
    #
    # Only the token is read. Platform sends nothing else about the connector, and this machine
    # deliberately learns nothing about the account it lives in.
    def preview_connector!(connector)
      token = presence(connector.is_a?(Hash) ? connector["token"] : nil)
      raise Error, "Platform returned no preview connector for this machine" if token.nil?

      token
    end

    # The credential this machine already holds for THIS REGISTRATION, or nil.
    #
    # Read through the selected registration's public id and nothing else. A machine now holds one
    # registration per project, each with its own credential, so any wider search — another
    # project's runner account, or a workspace-keyed account from the pre-registration scheme —
    # could present project A's credential while enrolling project B. Platform would then either
    # reject it or, worse, accept a reconnect this machine cannot actually authenticate as.
    #
    # A registration this machine has never enrolled holds nothing, which is exactly right: a new
    # project is issued its own credential.
    #
    # A secret store that cannot be read is treated as "none held", so a fresh credential is
    # issued rather than the connection failing.
    def held_credential(secret_store, registration)
      public_id = presence(registration.runner_public_id)
      return nil if public_id.nil?

      secret_store.read(account: SecretStore.account_for_runner(public_id))
    rescue SecretStore::Error
      nil
    end

    # A reconnect that kept its existing credential says so, because "stored in the Keychain"
    # would imply a write that did not happen.
    def credential_line
      return "unchanged — this machine keeps the credential it already had" if @credential_unchanged

      "stored in the macOS Keychain (never printed or written to a file)"
    end

    def announce_assignment(assignment)
      workspace = assignment.fetch("workspace")
      out.puts "Assigned project:   #{assignment.dig('project', 'name')} (#{assignment.dig('project', 'slug')})"
      out.puts "Assigned workspace: #{workspace['display_name']} (#{workspace['workspace_key']})"
      out.puts "Repository:         #{workspace['repository_url']} (#{workspace['default_branch']})"
    end

    # The ONE human input. Prompted only after the assignment is known, so the operator is
    # asked for the checkout of a named repository rather than for an abstract directory.
    def validated_checkout!(workspace)
      path = expand(presence(@checkout_path) || prompt_for_checkout(workspace))
      result = RepositoryCheck.call(path: path, repository_url: workspace.fetch("repository_url"),
                                    default_branch: workspace.fetch("default_branch"))
      raise Error, "#{result.message}. No runner was registered as ready." unless result.ok?

      out.puts "Checkout:           #{path} (validated against #{workspace['repository_url']})"
      { path: path, remote_url: result.remote_url, default_branch: result.default_branch }
    end

    def prompt_for_checkout(workspace)
      out.puts ""
      out.print "Local checkout of #{workspace['repository_url']}: "
      out.flush if out.respond_to?(:flush)
      answer = input.gets.to_s.strip
      raise Error, "a local checkout directory is required to connect this workspace" if answer.empty?

      answer
    end

    def expand(path) = File.expand_path(path.to_s.strip)

    # The bounded readiness checks for whichever real profile the assigned executor resolves to.
    # The deterministic fixture path must never require a provider CLI to be installed or
    # authenticated, so it resolves to no profile and is reported ready as it stands. Raw probe
    # output — which carries the operator's account identity — is never printed or returned.
    #
    # `detail` is the profile's own: the safe, bounded CLI-version fact once this host is ready,
    # and the actionable remedy when it is not. It travels in the EXISTING readiness field; no new
    # wire key is introduced for it.
    def executor_readiness(executor)
      profile = ImplementationProfile.for(executor)
      return { classification: READY, provider: executor["provider"].to_s, detail: nil } if profile.nil?

      out.puts "Executor:           #{profile.describe}"
      readiness = profile.readiness(env: env)
      out.puts "Readiness:          #{readiness.summary}"
      provider = ImplementationProfile.provider_of(executor)
      return { classification: READY, provider: provider, detail: readiness.detail } if readiness.ready?

      { classification: classify(readiness, profile.class), provider: provider, detail: readiness.detail }
    rescue ImplementationProfile::Error, ClaudeProfile::Error, CodexProfile::Error => e
      raise Error, "the assigned executor profile is not usable on this host: #{Redaction.redact(e.message)}"
    end

    # The classifications are provider-neutral Platform vocabulary; which constants say
    # "unavailable" and "not authenticated" belongs to the profile that produced the readiness.
    def classify(readiness, owner)
      return "executor_unavailable" if readiness.version == owner::UNAVAILABLE
      return "executor_not_authenticated" if readiness.auth == owner::NOT_AUTHENTICATED

      "executor_check_failed"
    end

    # Secrets first, then local state. A credential stored without local state leaves a
    # recoverable runner; local state pointing at a credential that was never stored would
    # not authenticate. A reconnect that kept its existing credential writes no CREDENTIAL, so
    # nothing it already relies on is replaced.
    #
    # The connector token IS upserted on every connection, because Platform issues one every
    # time and a reconnect must end holding the token for the connector it was just given. That
    # is why `#verify_secret_storage!` now runs before every exchange rather than only before a
    # first one: every path through here writes.
    def persist(secret_store, assignment, workspace, checkout, reviewer)
      public_id = runner_public_id!(assignment)
      unless @credential_unchanged
        secret_store.write(account: SecretStore.account_for_runner(public_id), credential: @credential)
      end
      secret_store.write(account: SecretStore.preview_connector_account_for(public_id),
                         credential: @preview_connector, label: "preview connector token")
      store.save(ConnectionStore::Connection.new(
                   base_url: @base_url, runner_id: @registration.runner_id,
                   runner_public_id: assignment.dig("runner", "public_id"),
                   runner_display_name: @registration.display_name,
                   project_slug: assignment.dig("project", "slug"),
                   workspace_key: workspace.fetch("workspace_key"),
                   project_key: workspace["project_key"],
                   workspace_display_name: workspace["display_name"],
                   repository_url: workspace.fetch("repository_url"),
                   default_branch: workspace.fetch("default_branch"),
                   local_path: checkout.fetch(:path),
                   # The provider identifier only, and only when a reviewer was really advertised.
                   # Non-secret, and the least that reconstructs the same reviewer.
                   reviewer_provider: (reviewer.provider if reviewer&.configured?),
                   connected_at: Time.now.utc.iso8601
                 ))
      out.puts "Credential:         #{credential_line}"
      out.puts "Preview connector:  stored in the macOS Keychain (never printed or written to a file)"
    end

    # The runner identity Platform issued. Required, because it is the Keychain account name the
    # credential is stored under — a missing one would silently store nothing findable.
    def runner_public_id!(assignment)
      assignment.dig("runner", "public_id").to_s.strip.tap do |public_id|
        raise Error, "Platform returned no runner identity for this machine" if public_id.empty?
      end
    end

    # Report facts, not a verdict. Platform re-checks the repository identity against its
    # own workspace definition and decides the state; the runner renders whatever came
    # back. Note the payload: no local path, no credential, no provider account.
    def report(assignment, workspace, checkout, readiness, reviewer)
      response = client(@base_url, @credential).report_workspace_readiness(
        workspace_key: workspace.fetch("workspace_key"),
        report: {
          contract_version: CONTRACT_VERSION,
          repository_url: checkout.fetch(:remote_url),
          default_branch: checkout.fetch(:default_branch),
          executor_provider: readiness[:provider],
          executor_readiness: readiness[:classification],
          detail: readiness[:detail],
          **reviewer_report(reviewer)
        }
      )
      build_result(assignment, response)
    end

    # The REVIEWER capability, advertised alongside the executor one.
    #
    # Bounded public facts only: role, name, provider, version and a one-way digest of the
    # local configuration. The command, its arguments, the timeout and the operator's paths
    # stay on this machine — Platform is never given a local command to store or to run.
    #
    # A machine with no `runner.reviewer:` block reports `not_configured` and nothing else.
    # That leaves review waiting for another machine and does not affect this one's executor
    # readiness in any way.
    def reviewer_report(reviewer)
      return { reviewer_readiness: NO_REVIEWER } unless reviewer&.configured?

      { reviewer_readiness: READY,
        reviewer_profile: reviewer.public_identity(version: SpecrelayRunner::VERSION) }
    end

    # The guided path writes no YAML, so the reviewer is resolved the way the specification
    # lane's provider is: an explicit environment override wins, and otherwise the machine
    # reviews with the SAME provider installation its executor already proved ready.
    #
    # That default is the "ordinary solo setup may select the same provider installation for both
    # roles" case — the independence this product requires comes from a separate role profile, a
    # separate process and separate fixed instructions, not from a second installation. A machine
    # whose executor is NOT ready advertises no reviewer: an unauthenticated CLI cannot review any
    # more than it can implement.
    def reviewer_settings(readiness)
      return Review::Settings.new({}, env: env) if env[Review::Settings::PROVIDER_ENV].to_s.strip != ""
      # Still Claude-only: reviewing through the second provider is its own delivery, so a machine
      # whose EXECUTOR is Codex advertises no reviewer rather than one it cannot launch.
      return nil unless readiness[:classification] == READY && readiness[:provider] == ClaudeProfile::PROVIDER

      Review::Settings.new({ "provider" => Review::Settings::PROVIDER_CLAUDE }, env: env)
    end

    def build_result(_assignment, response)
      connection = response.fetch("connection", {})
      Result.new(workspace_key: connection["workspace_key"], state: connection["state"],
                 failure_class: connection["failure_class"], detail: connection["detail"])
    end

    def client(base_url, token) = client_factory.call(base_url, token)

    # Non-secret, machine-derived identity. The user types neither field, and both are
    # deterministic for a given project, so a retried connect updates the same runner.
    def identity(registration)
      { "id" => registration.runner_id, "display_name" => registration.display_name }
    end

    def runner_display_name
      @runner_display_name ||= "#{short_hostname} runner"
    end

    def short_hostname = @short_hostname ||= Socket.gethostname.to_s.split(".").first.to_s

    # A conservative slug: the hostname may contain characters Platform would have to
    # escape, and a stable id matters more than a pretty one.
    def hostname_slug
      slug = short_hostname.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      slug.empty? ? "local" : slug
    end

    # The runner is Rails-free, so it carries its own blank check rather than relying on
    # ActiveSupport's String#presence.
    def presence(value)
      stripped = value.to_s.strip
      stripped.empty? ? nil : stripped
    end
  end
end
