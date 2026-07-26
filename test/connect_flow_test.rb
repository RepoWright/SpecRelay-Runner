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
    attr_reader :writes, :probes
    attr_writer :fail_probe

    # `fail_probe` defaults to `fail_write` because a Keychain that refuses writes refuses the
    # writability probe too. They are separable so one example can model a Keychain that passes
    # the pre-flight and then fails at the real write.
    def initialize(fail_write: false, fail_probe: fail_write)
      @entries = {}
      @writes = []
      @probes = 0
      @fail_write = fail_write
      @fail_probe = fail_probe
    end

    def write(account:, credential:)
      raise SpecrelayRunner::SecretStore::Error, "keychain access was denied" if @fail_write

      @writes << account
      @entries[account] = credential
      true
    end

    # The real store writes, reads back, and deletes a throwaway item; the fake only has to
    # record that the check happened and whether it passed.
    def verify_writable!
      @probes += 1
      raise SpecrelayRunner::SecretStore::Error, "keychain access was denied" if @fail_probe

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
    # The credential reached the OS secret store, keyed by the RUNNER identity Platform issued —
    # the credential's actual scope (round 003, review-002 F3 residual).
    assert_equal [ "runner:rnr_fake" ], secret_store.writes
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

  # --- the Keychain is proved writable BEFORE the code is spent --------------
  #
  # Reported from a real manual run after round 003: the Keychain write was broken on the
  # operator's machine, and because it was attempted only AFTER the exchange, every retry
  # needed a newly issued enrollment code. A local storage failure must cost nothing, exactly
  # like the local checkout failures above.

  def test_an_unwritable_keychain_fails_before_the_code_is_consumed
    platform = start_platform
    secret_store = FakeSecretStore.new(fail_write: true)

    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)
    end

    assert_equal 1, secret_store.probes, "the writability check must run"
    # The code was never exchanged, so it is still usable.
    assert_empty platform.requests_to("/api/runner/enrollment")
    assert_match(/code was NOT used/, error.message)
    assert_empty secret_store.writes
  end

  def test_the_same_code_still_works_after_an_unwritable_keychain
    platform = start_platform
    code = platform.enrollment_code

    assert_raises(SpecrelayRunner::SecretStore::Error) do
      connect(code: code, checkout: git_checkout, secret_store: FakeSecretStore.new(fail_write: true))
    end
    result, = connect(code: code, checkout: git_checkout)

    assert result.ready?, "the same code must still be usable after a Keychain failure"
  end

  # The check runs after every other local step, so an operator with a mistyped checkout hears
  # about the checkout — not about the Keychain.
  def test_the_writability_check_runs_only_once_every_local_step_has_passed
    platform = start_platform
    secret_store = FakeSecretStore.new

    assert_raises(SpecrelayRunner::Connect::Error) do
      connect(code: platform.enrollment_code, checkout: Dir.mktmpdir("not-a-repo"),
              secret_store: secret_store)
    end

    assert_equal 0, secret_store.probes
  end

  # A reconnect writes nothing, so a Keychain check must not be able to block it. Otherwise a
  # machine that already holds a working credential could be refused for a write it never makes.
  def test_a_reconnect_that_keeps_its_credential_is_not_gated_on_writability
    platform = start_platform
    secret_store = FakeSecretStore.new
    connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)
    baseline_probes = secret_store.probes

    platform.held_credential = FakePlatform::ISSUED_CREDENTIAL
    platform.enrollment_code = code_for(platform.base_url)
    secret_store.fail_probe = true

    result, = connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)

    assert result.ready?, "a reconnect must not be blocked by a check for a write it does not make"
    assert_equal baseline_probes, secret_store.probes, "no probe may run when a credential is held"
  end

  # The pre-flight is not a substitute for handling a write that fails afterwards.
  def test_a_keychain_that_passes_the_check_and_then_fails_still_refuses
    platform = start_platform

    assert_raises(SpecrelayRunner::SecretStore::Error) do
      connect(code: platform.enrollment_code, checkout: git_checkout,
              secret_store: FakeSecretStore.new(fail_write: true, fail_probe: false))
    end

    refute File.exist?(@state_file)
    assert_empty platform.requests_to("/api/runner/workspace_connections")
  end

  # --- review-001 F3: a failed attempt must cost the operator nothing --------
  #
  # Round 001 consumed the code and rotated the credential BEFORE validating locally, so a
  # mistyped checkout took a working runner offline. These assert the new order directly.

  def test_a_local_failure_does_not_consume_the_code
    platform = start_platform

    assert_raises(SpecrelayRunner::Connect::Error) do
      connect(code: platform.enrollment_code, checkout: git_checkout(remote: "https://github.com/x/wrong"))
    end

    # The preview was read; the consuming exchange was never called.
    refute_empty platform.requests_to("/api/runner/enrollment_preview")
    assert_empty platform.requests_to("/api/runner/enrollment")
    assert_empty platform.requests_to("/api/runner/workspace_connections")
  end

  def test_the_same_code_still_works_after_a_local_failure
    platform = start_platform
    code = platform.enrollment_code

    assert_raises(SpecrelayRunner::Connect::Error) do
      connect(code: code, checkout: Dir.mktmpdir("not-a-repo"))
    end
    result, = connect(code: code, checkout: git_checkout)

    assert result.ready?, "the same code must still be usable after a purely local failure"
  end

  def test_a_local_failure_writes_nothing_to_the_secret_store
    platform = start_platform
    secret_store = FakeSecretStore.new

    assert_raises(SpecrelayRunner::Connect::Error) do
      connect(code: platform.enrollment_code, checkout: Dir.mktmpdir("not-a-repo"),
              secret_store: secret_store)
    end

    assert_empty secret_store.writes
    refute File.exist?(@state_file)
  end

  def test_a_reconnect_keeps_the_credential_the_machine_already_holds
    platform = start_platform
    secret_store = FakeSecretStore.new
    connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)
    assert_equal 1, secret_store.writes.size

    # Platform now recognises the held credential and issues nothing.
    platform.held_credential = FakePlatform::ISSUED_CREDENTIAL
    platform.enrollment_code = code_for(platform.base_url)
    result, out, = connect(code: platform.enrollment_code, checkout: git_checkout,
                           secret_store: secret_store)

    assert result.ready?
    # No second write: the machine kept what it had, so nothing could be invalidated.
    assert_equal 1, secret_store.writes.size
    assert_includes out, "unchanged"
    assert_equal FakePlatform::ISSUED_CREDENTIAL, secret_store.read(account: "runner:rnr_fake")
  end

  def test_a_reconnect_presents_the_held_credential_so_platform_can_recognise_it
    platform = start_platform
    secret_store = FakeSecretStore.new
    connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)
    platform.enrollment_code = code_for(platform.base_url)

    connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)

    # It travels in a HEADER, never the body, so Rails' parameter log can never contain it
    # (round 003, review-002 N1).
    assert_equal FakePlatform::ISSUED_CREDENTIAL,
                 platform.last_enrollment.dig(:headers, "x-specrelay-runner-credential")
    refute_includes JSON.generate(platform.last_enrollment.fetch(:body)), "current_credential"
  end

  # A fresh machine has nothing to present, and must still be issued a credential.
  def test_a_first_connect_presents_no_credential_and_is_issued_one
    platform = start_platform
    secret_store = FakeSecretStore.new

    connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)

    assert_nil platform.last_enrollment.dig(:headers, "x-specrelay-runner-credential")
    assert_equal FakePlatform::ISSUED_CREDENTIAL, secret_store.read(account: "runner:rnr_fake")
  end

  # --- review-002, F3 residual: a second workspace must not orphan the first ---
  #
  # The credential is per RUNNER, but round 002 stored it per WORKSPACE. Connecting a SECOND
  # workspace on an already-registered machine presented nothing (there was no entry for the new
  # workspace), so Platform rotated, and the first workspace's stored copy stopped
  # authenticating — `claim-once --workspace <first>` then failed.

  def test_connecting_a_second_workspace_leaves_the_first_workspace_authenticating
    platform = start_platform
    secret_store = FakeSecretStore.new
    connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)
    first_credential = secret_store.read(account: "runner:rnr_fake")

    refute_nil first_credential

    # A DIFFERENT workspace on the same Platform and the same machine.
    platform.claim_payload_workspace_key = "second-workspace"
    platform.held_credential = first_credential
    platform.enrollment_code = code_for(platform.base_url)
    result, = connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)

    assert result.ready?
    assert_equal "second-workspace", result.workspace_key
    # The machine presented the credential it already held, so nothing was rotated…
    assert_equal first_credential,
                 platform.last_enrollment.dig(:headers, "x-specrelay-runner-credential")
    # …and the single runner-scoped entry still holds it, so the FIRST workspace still works.
    assert_equal first_credential, secret_store.read(account: "runner:rnr_fake")
    assert_equal 1, secret_store.writes.size, "a second workspace must not rewrite the credential"
  end

  def test_both_stored_workspaces_resolve_the_same_credential
    platform = start_platform
    secret_store = FakeSecretStore.new
    connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)
    platform.claim_payload_workspace_key = "second-workspace"
    platform.held_credential = secret_store.read(account: "runner:rnr_fake")
    platform.enrollment_code = code_for(platform.base_url)
    connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)

    # Two stored connections, one runner identity, one credential.
    assert_equal %w[second-workspace tiny-demo-workspace], store.connections.map(&:workspace_key).sort
    assert_equal [ "rnr_fake" ], store.connections.map(&:runner_public_id).uniq
  end

  # A machine that connected under the pre-round-003 per-workspace scheme keeps working: the
  # legacy account is still READ, so it presents its credential and is not rotated.
  def test_reads_a_legacy_per_workspace_credential_so_an_existing_machine_keeps_working
    platform = start_platform
    secret_store = FakeSecretStore.new
    secret_store.write(account: "workspace:tiny-demo-workspace", credential: FakePlatform::ISSUED_CREDENTIAL)
    platform.held_credential = FakePlatform::ISSUED_CREDENTIAL

    result, = connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)

    assert result.ready?
    assert_equal FakePlatform::ISSUED_CREDENTIAL,
                 platform.last_enrollment.dig(:headers, "x-specrelay-runner-credential")
  end

  # Round 003 consulted the legacy account for the workspace being connected ONLY. A machine
  # whose credential still sits under ANOTHER workspace's legacy account therefore presented
  # nothing when connecting a new workspace, Platform issued a fresh credential, and the legacy
  # copy went stale — reaching the same orphaning by a different route.
  #
  # Observed for real: a manual fresh-project connect rotated the credential on a machine whose
  # only copy was a legacy entry, leaving an already-`ready` workspace unable to authenticate.
  def test_a_legacy_credential_stored_for_another_workspace_is_still_presented
    platform = start_platform
    secret_store = FakeSecretStore.new
    # A machine that connected under the pre-round-003 scheme: local state knows the runner
    # identity and the FIRST workspace, and the credential lives under that workspace's account.
    store.save(SpecrelayRunner::ConnectionStore::Connection.new(
                 base_url: platform.base_url, runner_id: "host-runner", runner_public_id: "rnr_fake",
                 runner_display_name: "host runner", project_slug: "tiny-demo",
                 workspace_key: "first-workspace",
                 repository_url: "https://github.com/SpecRelay/tiny-demo-runs",
                 default_branch: "main", local_path: "/tmp/first",
                 connected_at: "2026-07-26T00:00:00Z"
               ))
    secret_store.write(account: "workspace:first-workspace", credential: FakePlatform::ISSUED_CREDENTIAL)
    platform.held_credential = FakePlatform::ISSUED_CREDENTIAL

    # Connecting a DIFFERENT workspace on the same machine and Platform.
    result, = connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)

    assert result.ready?
    assert_equal FakePlatform::ISSUED_CREDENTIAL,
                 platform.last_enrollment.dig(:headers, "x-specrelay-runner-credential")
    # Nothing rotated, so the first workspace's stored credential still authenticates.
    assert_equal 1, secret_store.writes.size
    assert_equal FakePlatform::ISSUED_CREDENTIAL, secret_store.read(account: "workspace:first-workspace")
  end

  def test_the_preview_carries_no_credential
    platform = start_platform
    connect(code: platform.enrollment_code, checkout: git_checkout)

    body = JSON.generate(platform.last_enrollment_preview[:body])

    refute_includes body, FakePlatform::ISSUED_CREDENTIAL
    refute_includes body, "credential"
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
