# frozen_string_literal: true

require "base64"
require "socket"
require "time"

module SpecrelayRunner
  # The guided runner connection (MVP-0017 scope 2): `specrelay-runner connect <code>`.
  #
  # This is the ONLY local action a normal user performs. The whole command asks for
  # exactly one thing — the local checkout directory — and derives everything else:
  #
  #   1. the Platform endpoint, read from the enrollment code itself (the origin is not a
  #      secret, so it travels inside the code and the displayed command needs no flag);
  #   2. the runner identity, derived from this machine's hostname, so it is stable and a
  #      retry updates the same runner instead of creating a second one;
  #   3. the project/workspace assignment, the repository identity to validate against,
  #      and the executor profile, all returned by the enrollment exchange.
  #
  # Order is load-bearing and fails closed at each step:
  #
  #   platform support check -> exchange the code -> ask for the checkout ->
  #   validate the checkout -> provider readiness (only for the real Claude profile) ->
  #   store the credential in the OS secret store -> save non-secret local state ->
  #   report readiness to Platform
  #
  # The unsupported-platform check runs FIRST, before any Platform call, so a
  # non-macOS host never consumes a code it cannot finish using. The credential is
  # stored BEFORE readiness is reported, so a runner Platform believes is ready can
  # always authenticate. If a later step fails, Platform holds the connection in
  # `pending`/`blocked` — never `ready` — and the operator reissues a code and retries.
  #
  # Secret posture: the durable credential is never printed, never written to YAML, a
  # shell profile, Git, or a log, and never appears in an error message. The local
  # checkout path is stored locally and never sent to Platform. Provider probe output is
  # reduced to one classification and discarded.
  class Connect
    Error = Class.new(StandardError)

    CONTRACT_VERSION = "mvp-0017"

    # Matches Platform's Runner::Enrollment::Code shape.
    CODE_PREFIX = "sre_"
    CODE_SEPARATOR = "."

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

      # Everything local happens against a PREVIEW, which does not consume the code (round 002,
      # review-001 F3). Round 001 exchanged first, so a mistyped checkout or an unauthenticated
      # provider spent the code and — for an already-connected machine — rotated its credential
      # and demoted its grant. One typo took a working runner offline. Now a failure here costs
      # nothing at all: the same code still works.
      assignment = preview(origin)
      workspace = assignment.fetch("workspace")
      checkout = validated_checkout!(workspace)
      readiness = executor_readiness(assignment.fetch("executor", {}))

      # Only now is anything consumed or changed.
      enrolled = exchange(origin, workspace, secret_store)
      persist(secret_store, enrolled, workspace, checkout)
      report(enrolled, workspace, checkout, readiness)
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
      out.puts "Connecting to #{origin} as #{runner_display_name} (#{runner_id})…"
      assignment = client(origin, code).preview_enrollment
      announce_assignment(assignment)
      assignment
    end

    # Consume the code. The machine's EXISTING credential for this workspace is presented so
    # Platform can recognise a reconnect and leave that credential alone; when it does,
    # `credential_unchanged` comes back true and nothing in the secret store is touched.
    def exchange(origin, workspace, secret_store)
      held = held_credential(secret_store, workspace)
      enrolled = client(origin, code).enroll(identity, current_credential: held)
      @credential = presence(enrolled["credential"]) || held
      raise Error, "Platform returned no usable credential for this machine" if @credential.nil?

      @credential_unchanged = enrolled["credential_unchanged"] ? true : false
      @base_url = presence(enrolled.dig("platform", "base_url")) || origin
      enrolled
    end

    # The credential this machine already holds for the assigned workspace, or nil. A store that
    # cannot be read is treated as "none held", so a fresh credential is issued rather than the
    # connection failing.
    def held_credential(secret_store, workspace)
      secret_store.read(account: SecretStore.account_for(workspace.fetch("workspace_key")))
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

    # The existing bounded Claude readiness checks, run ONLY when the assigned executor is
    # the supported real profile. The deterministic fixture path must never require Claude
    # Code to be installed or authenticated. Raw probe output — which carries the
    # operator's account email and organization — is never printed or returned.
    def executor_readiness(executor)
      return { classification: READY, provider: executor["provider"].to_s, detail: nil } unless ClaudeProfile.selected?(executor)

      profile = ClaudeProfile.new(executor)
      out.puts "Executor:           #{profile.describe}"
      readiness = profile.readiness(env: env)
      out.puts "Readiness:          #{readiness.summary}"
      return { classification: READY, provider: ClaudeProfile::PROVIDER, detail: nil } if readiness.ready?

      { classification: classify(readiness), provider: ClaudeProfile::PROVIDER, detail: readiness.remedy }
    rescue ClaudeProfile::Error => e
      raise Error, "the assigned executor profile is not usable on this host: #{Redaction.redact(e.message)}"
    end

    def classify(readiness)
      return "executor_unavailable" if readiness.version == ClaudeProfile::UNAVAILABLE
      return "executor_not_authenticated" if readiness.auth == ClaudeProfile::NOT_AUTHENTICATED

      "executor_check_failed"
    end

    # Credential first, then local state. A credential stored without local state leaves a
    # recoverable runner; local state pointing at a credential that was never stored would
    # not authenticate. A reconnect that kept its existing credential writes nothing to the
    # secret store, so it cannot fail on a Keychain prompt it does not need.
    def persist(secret_store, assignment, workspace, checkout)
      unless @credential_unchanged
        secret_store.write(account: SecretStore.account_for(workspace.fetch("workspace_key")),
                           credential: @credential)
      end
      store.save(ConnectionStore::Connection.new(
                   base_url: @base_url, runner_id: identity.fetch("id"),
                   runner_public_id: assignment.dig("runner", "public_id"),
                   runner_display_name: identity.fetch("display_name"),
                   project_slug: assignment.dig("project", "slug"),
                   workspace_key: workspace.fetch("workspace_key"),
                   project_key: workspace["project_key"],
                   workspace_display_name: workspace["display_name"],
                   repository_url: workspace.fetch("repository_url"),
                   default_branch: workspace.fetch("default_branch"),
                   local_path: checkout.fetch(:path), connected_at: Time.now.utc.iso8601
                 ))
      out.puts "Credential:         #{credential_line}"
    end

    # Report facts, not a verdict. Platform re-checks the repository identity against its
    # own workspace definition and decides the state; the runner renders whatever came
    # back. Note the payload: no local path, no credential, no provider account.
    def report(assignment, workspace, checkout, readiness)
      response = client(@base_url, @credential).report_workspace_readiness(
        workspace_key: workspace.fetch("workspace_key"),
        report: {
          contract_version: CONTRACT_VERSION,
          repository_url: checkout.fetch(:remote_url),
          default_branch: checkout.fetch(:default_branch),
          executor_provider: readiness[:provider],
          executor_readiness: readiness[:classification],
          detail: readiness[:detail]
        }
      )
      build_result(assignment, response)
    end

    def build_result(_assignment, response)
      connection = response.fetch("connection", {})
      Result.new(workspace_key: connection["workspace_key"], state: connection["state"],
                 failure_class: connection["failure_class"], detail: connection["detail"])
    end

    def client(base_url, token) = client_factory.call(base_url, token)

    # Non-secret, machine-derived identity. The user types neither field, and both are
    # deterministic, so a retried connect updates the same runner.
    def identity
      @identity ||= { "id" => runner_id, "display_name" => runner_display_name }
    end

    def runner_id
      @runner_id ||= "#{hostname_slug}-runner"
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
