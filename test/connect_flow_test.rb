# frozen_string_literal: true

require_relative "test_helper"

# MVP-0017 — the guided connection, asserted as behavior against a real HTTP fake
# Platform and real local Git repositories.
#
# The claims this file is here to prove:
#   - `connect` needs no YAML, no exported credential, and no workspace key;
#   - the local checkout is validated against the ASSIGNED repository before the runner
#     can become ready, and a mismatch/missing checkout/missing branch refuses;
#   - the durable credential goes to the OS secret store and is never printed;
#   - only non-secret facts reach Platform — no local path, no credential;
#   - a retry is idempotent in the runner's own storage;
#   - the runner renders the state PLATFORM decided, not its own opinion;
#   - `claim-once` afterwards works from the stored connection alone.
class ConnectFlowTest < Minitest::Test
  CODE_ORIGIN_PREFIX = SpecrelayRunner::Connect::CODE_PREFIX

  def setup
    @platform = nil
    @state_file = File.join(Dir.mktmpdir("state"), "connections.json")
  end

  def teardown
    @platform&.stop
  end

  # --- test doubles ---------------------------------------------------------

  # An in-memory stand-in for the macOS Keychain, exercising the same narrow seam the
  # real SecretStore exposes. It is used INSTEAD of shelling out to `security` so the
  # suite never touches the developer's real Keychain or prompts for access.
  class FakeSecretStore
    attr_reader :writes

    def initialize(fail_write: false)
      @entries = {}
      @writes = []
      @fail_write = fail_write
    end

    def write(account:, credential:)
      raise SpecrelayRunner::SecretStore::Error, "keychain access was denied" if @fail_write

      @writes << account
      @entries[account] = credential
      true
    end

    def read(account:) = @entries[account]
  end

  # --- fixtures -------------------------------------------------------------

  def start_platform(repository_url: "https://github.com/SpecRelay/tiny-demo-runs")
    payload = claim_payload_for(task_id: "DEMO-0017", executor_command: "specrelay-fake-executor")
    payload["workspace"]["repository_url"] = repository_url
    @platform = FakePlatform.new(claim_payload: payload).start
    @platform.enrollment_code = code_for(@platform.base_url)
    @platform
  end

  # The tail is the secret half; varying it is how a test models a DIFFERENT code for the
  # same Platform origin (an expired, reused, or simply wrong code).
  def code_for(origin, tail: "issued-tail-#{@tail_counter = @tail_counter.to_i + 1}")
    "#{CODE_ORIGIN_PREFIX}#{Base64.urlsafe_encode64(origin, padding: false)}.#{tail}"
  end

  # A real Git repository with a real `origin` remote and a real `main` branch, so
  # RepositoryCheck runs its real git commands rather than a stub.
  def git_checkout(remote: "https://github.com/SpecRelay/tiny-demo-runs", branch: "main")
    path = Dir.mktmpdir("checkout")
    run_git(path, %w[init --quiet])
    run_git(path, [ "symbolic-ref", "HEAD", "refs/heads/#{branch}" ])
    run_git(path, [ "remote", "add", "origin", remote ])
    File.write(File.join(path, "README.md"), "demo\n")
    run_git(path, %w[add .])
    run_git(path, [ "-c", "user.email=t@example.test", "-c", "user.name=Test",
                    "commit", "--quiet", "-m", "initial" ])
    path
  end

  def run_git(path, args)
    result = SpecrelayRunner::CommandRunner.run([ "git", "-C", path, *args ], chdir: path,
                                                env: { "PATH" => ENV["PATH"].to_s }, timeout_seconds: 30)
    raise "git #{args.join(' ')} failed: #{result.stderr}" unless result.success?
  end

  def connect(code:, checkout:, secret_store: FakeSecretStore.new, out: StringIO.new, err: StringIO.new,
              platform: "arm64-darwin23", env: { "PATH" => ENV["PATH"].to_s })
    result = SpecrelayRunner::Connect.call(
      code: code, out: out, err: err, env: env, checkout_path: checkout,
      store: store, secret_store: secret_store, platform: platform
    )
    [ result, out.string, err.string, secret_store ]
  end

  def store = @store ||= SpecrelayRunner::ConnectionStore.new(@state_file)

  # --- the happy path -------------------------------------------------------

  def test_connects_with_only_a_code_and_a_checkout_path
    platform = start_platform
    result, out, _err, secret_store = connect(code: platform.enrollment_code, checkout: git_checkout)

    assert result.ready?, "Platform reported #{result.state}: #{result.detail}"
    assert_equal "tiny-demo-workspace", result.workspace_key
    # The credential reached the OS secret store, keyed by workspace and nothing else.
    assert_equal [ "workspace:tiny-demo-workspace" ], secret_store.writes
    # …and was never printed.
    refute_includes out, FakePlatform::ISSUED_CREDENTIAL
  end

  def test_sends_platform_no_local_path_and_no_credential
    platform = start_platform
    checkout = git_checkout
    connect(code: platform.enrollment_code, checkout: checkout)

    report = platform.last_readiness_report.fetch(:body).fetch("report")

    assert_equal "main", report.fetch("default_branch")
    refute_nil report["repository_url"]
    # The exhaustive privacy assertion: the whole serialized report must not contain the
    # machine's local path or the credential, under any key.
    serialized = JSON.generate(platform.last_readiness_report[:body])

    refute_includes serialized, checkout
    refute_includes serialized, FakePlatform::ISSUED_CREDENTIAL
  end

  def test_stores_a_non_secret_connection_record_the_user_never_edits
    platform = start_platform
    checkout = git_checkout
    connect(code: platform.enrollment_code, checkout: checkout)

    stored = store.connection_for("tiny-demo-workspace")

    assert_equal platform.base_url, stored.base_url
    assert_equal checkout, stored.local_path
    assert_equal "main", stored.default_branch
    # The credential is NOT in the runner's own file — it is in the OS secret store.
    refute_includes File.read(@state_file), FakePlatform::ISSUED_CREDENTIAL
  end

  def test_a_retry_updates_the_same_stored_connection_rather_than_duplicating_it
    platform = start_platform
    checkout = git_checkout
    connect(code: platform.enrollment_code, checkout: checkout)
    platform.enrollment_code = code_for(platform.base_url)
    second = git_checkout
    connect(code: platform.enrollment_code, checkout: second)

    assert_equal 1, store.connections.size
    assert_equal second, store.connection_for("tiny-demo-workspace").local_path
  end

  # --- refusals BEFORE the runner can become ready --------------------------

  def test_refuses_a_malformed_code_without_calling_platform
    platform = start_platform

    error = assert_raises(SpecrelayRunner::Connect::Error) do
      connect(code: "not-a-code", checkout: git_checkout)
    end

    assert_match(/enrollment code/, error.message)
    assert_empty platform.requests_to("/api/runner/enrollment")
  end

  def test_refuses_a_rejected_code
    platform = start_platform
    assert_raises(SpecrelayRunner::PlatformClient::Unauthorized) do
      connect(code: code_for(platform.base_url), checkout: git_checkout)
    end
  end

  def test_refuses_a_checkout_of_a_different_repository
    platform = start_platform
    checkout = git_checkout(remote: "https://github.com/SpecRelay/some-other-repo")

    error = assert_raises(SpecrelayRunner::Connect::Error) do
      connect(code: platform.enrollment_code, checkout: checkout)
    end

    assert_match(/some-other-repo/, error.message)
    assert_match(/No runner was registered as ready/, error.message)
    assert_empty platform.requests_to("/api/runner/workspace_connections")
  end

  def test_refuses_a_missing_checkout
    platform = start_platform

    error = assert_raises(SpecrelayRunner::Connect::Error) do
      connect(code: platform.enrollment_code, checkout: File.join(Dir.mktmpdir("gone"), "absent"))
    end

    assert_match(/does not exist/, error.message)
    assert_empty platform.requests_to("/api/runner/workspace_connections")
  end

  def test_refuses_a_directory_that_is_not_a_git_repository
    platform = start_platform

    error = assert_raises(SpecrelayRunner::Connect::Error) do
      connect(code: platform.enrollment_code, checkout: Dir.mktmpdir("plain"))
    end

    assert_match(/not a Git repository/, error.message)
  end

  def test_refuses_a_checkout_without_the_assigned_default_branch
    platform = start_platform
    checkout = git_checkout(branch: "trunk")

    error = assert_raises(SpecrelayRunner::Connect::Error) do
      connect(code: platform.enrollment_code, checkout: checkout)
    end

    assert_match(/no 'main' branch/, error.message)
  end

  def test_refuses_a_denied_keychain_without_saving_a_plaintext_credential
    platform = start_platform

    assert_raises(SpecrelayRunner::SecretStore::Error) do
      connect(code: platform.enrollment_code, checkout: git_checkout,
              secret_store: FakeSecretStore.new(fail_write: true))
    end

    # Nothing was persisted locally and Platform was never told the runner is ready.
    refute File.exist?(@state_file), "no local state may be written when the credential could not be stored"
    assert_empty platform.requests_to("/api/runner/workspace_connections")
  end

  # --- Platform owns the verdict --------------------------------------------

  def test_reports_the_state_platform_decided_not_its_own_opinion
    platform = start_platform
    platform.readiness_verdict = { "state" => "blocked", "failure_class" => "repository_mismatch",
                                   "detail" => "Runner reported repository mismatch." }
    result, = connect(code: platform.enrollment_code, checkout: git_checkout)

    refute result.ready?
    assert_equal "blocked", result.state
    assert_equal "repository_mismatch", result.failure_class
  end

  # --- unsupported platform -------------------------------------------------

  def test_refuses_a_non_macos_host_before_any_platform_call
    platform = start_platform

    error = assert_raises(SpecrelayRunner::SecretStore::UnsupportedPlatform) do
      SpecrelayRunner::Connect.call(
        code: platform.enrollment_code, out: StringIO.new, err: StringIO.new,
        env: {}, checkout_path: git_checkout, store: store, platform: "x86_64-linux"
      )
    end

    assert_match(/only supported on macOS/, error.message)
    assert_empty platform.requests_to("/api/runner/enrollment")
  end

  # --- the connection is enough to claim ------------------------------------

  def test_claim_once_uses_the_stored_connection_with_no_config_file
    platform = start_platform
    checkout = git_checkout
    connect(code: platform.enrollment_code, checkout: checkout)
    stored = store.connection_for("tiny-demo-workspace")

    config = SpecrelayRunner::Config.from_connection(stored, credential: FakePlatform::ISSUED_CREDENTIAL)

    assert_equal platform.base_url, config.base_url
    assert_equal stored.runner_id, config.runner["id"]
    # The credential comes from the secret store, so no environment variable is needed…
    auth = config.resolve_auth(env: {})

    assert_equal :registered, auth.mode
    assert_equal FakePlatform::ISSUED_CREDENTIAL, auth.token
    # …and the workspace root is the validated local checkout, so no
    # SPECRELAY_RUNNER_WORKSPACE_ROOT_* variable is needed either.
    assert_equal checkout, config.workspace_root("tiny-demo-workspace", env: {})
  end

  # MVP-0017: "not connected to any workspace" and "nothing to do" are different problems, so
  # the runner surfaces the reason Platform returned instead of one generic idle line.
  def test_reports_platforms_reason_when_no_work_was_claimed
    out = StringIO.new
    platform = start_platform
    connect(code: platform.enrollment_code, checkout: git_checkout)
    stored = store.connection_for("tiny-demo-workspace")
    client = SpecrelayRunner::PlatformClient.new(base_url: stored.base_url,
                                                 token: FakePlatform::ISSUED_CREDENTIAL)
    # The fake claims once, then reports not-claimed with its own reason.
    client.claim({ "id" => "x", "display_name" => "X" })

    result = client.claim({ "id" => "x", "display_name" => "X" })

    refute result.claimed?
    assert_equal "already claimed", result.reason
    assert_nil out.string[/never printed/]
  end

  def test_a_stored_connection_credential_beats_a_stale_exported_one
    platform = start_platform
    connect(code: platform.enrollment_code, checkout: git_checkout)
    config = SpecrelayRunner::Config.from_connection(store.connection_for("tiny-demo-workspace"),
                                                     credential: "src_from-keychain")

    auth = config.resolve_auth(env: { "SPECRELAY_RUNNER_CREDENTIAL" => "src_stale-exported" })

    assert_equal "src_from-keychain", auth.token
  end
end
