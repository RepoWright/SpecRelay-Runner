# frozen_string_literal: true

require_relative "test_helper"

# The guided connection, asserted as behavior against a real HTTP fake Platform and real local
# Git repositories.
#
# The claims this file is here to prove:
#   - `connect` needs no YAML, no exported credential, and no workspace key;
#   - the local checkout is validated against the ASSIGNED repository before the runner
#     can become ready, and a mismatch/missing checkout/missing branch refuses;
#   - the durable credential and the machine's own preview connector token go to the OS secret
#     store, under separate accounts, and neither is ever printed;
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

  # The in-memory Keychain stand-in lives in `support/fake_secret_store.rb` — it is shared with
  # the connection-management tests, so "what the Keychain seam does" has exactly one
  # definition rather than one per test file.
  FakeSecretStore = ::FakeSecretStore

  # --- fixtures -------------------------------------------------------------

  def start_platform(repository_url: "https://github.com/SpecRelay/tiny-demo-workspace")
    payload = claim_payload_for(task_id: "DEMO-0017")
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
  def git_checkout(remote: "https://github.com/SpecRelay/tiny-demo-workspace", branch: "main")
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
    # the credential's actual scope.
    assert_equal [ "runner:rnr_fake", "preview-connector:rnr_fake" ], secret_store.writes
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

    stored = store.resolve("tiny-demo-workspace").connection

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
    assert_equal second, store.resolve("tiny-demo-workspace").connection.local_path
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
  # Reported from a real manual run: the Keychain write was broken on the
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

  # A reconnect writes too. Every successful exchange returns a connector token this machine must
  # store, so the pre-flight covers a reconnect as well: a machine whose store is locked must be
  # refused BEFORE it spends a code it could not have finished using.
  def test_a_reconnect_with_a_locked_store_is_refused_before_the_code_is_consumed
    platform = start_platform
    secret_store = FakeSecretStore.new
    connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)
    stored_writes = secret_store.writes.dup
    stored_state = File.read(@state_file)
    exchanges = platform.requests_to("/api/runner/enrollment").size

    platform.held_credential = FakePlatform::ISSUED_CREDENTIAL
    platform.enrollment_code = code_for(platform.base_url)
    secret_store.fail_probe = true

    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)
    end

    # Refused before the exchange was POSTed, so the reissued code is still usable…
    assert_equal exchanges, platform.requests_to("/api/runner/enrollment").size
    assert_match(/code was NOT used/, error.message)
    # …and neither stored secret nor the local connection record moved.
    assert_equal stored_writes, secret_store.writes
    assert_equal FakePlatform::ISSUED_CREDENTIAL, secret_store.read(account: "runner:rnr_fake")
    assert_equal FakePlatform::ISSUED_CONNECTOR_TOKEN,
                 secret_store.read(account: "preview-connector:rnr_fake")
    assert_equal stored_state, File.read(@state_file)
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

  # --- a failed attempt must cost the operator nothing ----------------------
  #
  # Consuming the code and rotating the credential BEFORE validating locally meant a
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
    assert_equal 1, secret_store.writes.count("runner:rnr_fake")

    # Platform now recognises the held credential and issues nothing.
    platform.held_credential = FakePlatform::ISSUED_CREDENTIAL
    platform.enrollment_code = code_for(platform.base_url)
    result, out, = connect(code: platform.enrollment_code, checkout: git_checkout,
                           secret_store: secret_store)

    assert result.ready?
    # No second CREDENTIAL write: the machine kept what it had, so nothing could be invalidated.
    assert_equal 1, secret_store.writes.count("runner:rnr_fake")
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

  # --- a second workspace must not orphan the first -------------------------
  #
  # The credential is per RUNNER, but storing it per WORKSPACE meant connecting a SECOND
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
    assert_equal 1, secret_store.writes.count("runner:rnr_fake"),
                 "a second workspace must not rewrite the credential"
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

  # A workspace-keyed secret is not this registration's credential. A machine now holds one
  # registration per project, so an item keyed by a workspace key does not say which project it
  # belongs to — two projects may use the same key. It is not presented; Platform issues this
  # registration its own credential instead, which is the safe default and the only path a
  # genuinely new registration can take.
  def test_a_workspace_keyed_secret_is_not_presented_as_this_registrations_credential
    platform = start_platform
    secret_store = FakeSecretStore.new
    secret_store.write(account: "workspace:tiny-demo-workspace", credential: FakePlatform::ISSUED_CREDENTIAL)
    platform.held_credential = FakePlatform::ISSUED_CREDENTIAL

    result, = connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)

    assert result.ready?
    assert_nil platform.last_enrollment.dig(:headers, "x-specrelay-runner-credential")
    # The connection is usable afterwards because the issued credential was stored under this
    # registration's own account.
    assert_equal FakePlatform::ISSUED_CREDENTIAL, secret_store.read(account: "runner:rnr_fake")
  end

  # A SECOND workspace in a project this machine already knows joins that project's existing
  # registration, so it presents that registration's credential and Platform recognises a
  # reconnect rather than issuing a second identity.
  def test_a_second_workspace_in_a_known_project_presents_that_registrations_credential
    platform = start_platform
    secret_store = FakeSecretStore.new
    # A machine already connected to this project: local state knows the registration, and the
    # credential lives under that registration's own account.
    store.save(SpecrelayRunner::ConnectionStore::Connection.new(
                 base_url: platform.base_url, runner_id: "host-runner", runner_public_id: "rnr_fake",
                 runner_display_name: "host runner", project_slug: "tiny-demo",
                 workspace_key: "first-workspace",
                 repository_url: "https://github.com/SpecRelay/tiny-demo-workspace",
                 default_branch: "main", local_path: "/tmp/first",
                 connected_at: "2026-07-26T00:00:00Z"
               ))
    secret_store.write(account: "runner:rnr_fake", credential: FakePlatform::ISSUED_CREDENTIAL)
    platform.held_credential = FakePlatform::ISSUED_CREDENTIAL

    # Connecting a DIFFERENT workspace of the same project on the same machine.
    result, = connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)

    assert result.ready?
    assert_equal FakePlatform::ISSUED_CREDENTIAL,
                 platform.last_enrollment.dig(:headers, "x-specrelay-runner-credential")
    # It was recognised, so nothing rotated and the first workspace keeps working.
    assert_equal 1, secret_store.writes.count("runner:rnr_fake"), "only the initial write"
    assert_equal 2, store.connections.length
  end

  # A secret keyed by a workspace key is never reached for, even when the key matches: it cannot
  # say which project it belongs to, and presenting it could authenticate one project's
  # enrollment with another's credential.
  def test_a_workspace_keyed_secret_from_another_workspace_is_never_presented
    platform = start_platform
    secret_store = FakeSecretStore.new
    secret_store.write(account: "workspace:first-workspace", credential: FakePlatform::ISSUED_CREDENTIAL)
    platform.held_credential = FakePlatform::ISSUED_CREDENTIAL

    connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)

    assert_nil platform.last_enrollment.dig(:headers, "x-specrelay-runner-credential")
    assert_equal FakePlatform::ISSUED_CREDENTIAL, secret_store.read(account: "workspace:first-workspace"),
                 "the old item is left alone rather than deleted"
  end

  def test_the_preview_carries_no_credential
    platform = start_platform
    connect(code: platform.enrollment_code, checkout: git_checkout)

    body = JSON.generate(platform.last_enrollment_preview[:body])

    refute_includes body, FakePlatform::ISSUED_CREDENTIAL
    refute_includes body, "credential"
  end

  # --- the machine's own isolated preview connector -------------------------
  #
  # The operator supplies no connector configuration at all: Platform provisions the machine its
  # own connector during the exchange and returns only that connector's token, which is stored
  # beside — never instead of — the durable Platform credential.

  def test_stores_the_preview_connector_beside_the_credential_under_its_own_account
    platform = start_platform
    result, out, _err, secret_store = connect(code: platform.enrollment_code, checkout: git_checkout)

    assert result.ready?
    assert_equal FakePlatform::ISSUED_CONNECTOR_TOKEN,
                 secret_store.read(account: "preview-connector:rnr_fake")
    # Beside, not instead of: the durable credential is untouched under its own account.
    assert_equal FakePlatform::ISSUED_CREDENTIAL, secret_store.read(account: "runner:rnr_fake")
    # And the operator is told it happened without being asked to configure anything.
    assert_match(/Preview connector:\s+stored in the macOS Keychain/, out)
  end

  def test_never_prints_files_or_reports_the_preview_connector_token
    platform = start_platform
    _result, out, err = connect(code: platform.enrollment_code, checkout: git_checkout)

    refute_includes out, FakePlatform::ISSUED_CONNECTOR_TOKEN
    refute_includes err, FakePlatform::ISSUED_CONNECTOR_TOKEN
    refute_includes File.read(@state_file), FakePlatform::ISSUED_CONNECTOR_TOKEN
    refute_includes JSON.generate(platform.last_readiness_report[:body]),
                    FakePlatform::ISSUED_CONNECTOR_TOKEN
  end

  # A reconnect keeps the credential it holds and replaces only the connector token, so a machine
  # that reconnects can still publish a preview without its Platform authentication being touched.
  def test_a_reconnect_replaces_only_the_preview_connector_token
    platform = start_platform
    secret_store = FakeSecretStore.new
    connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)
    platform.held_credential = FakePlatform::ISSUED_CREDENTIAL
    platform.enrollment_code = code_for(platform.base_url)
    platform.preview_connector = { token: "cft_fake-replacement-connector-token" }

    connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)

    assert_equal 1, secret_store.writes.count("runner:rnr_fake")
    assert_equal 2, secret_store.writes.count("preview-connector:rnr_fake")
    assert_equal "cft_fake-replacement-connector-token",
                 secret_store.read(account: "preview-connector:rnr_fake")
    assert_equal FakePlatform::ISSUED_CREDENTIAL, secret_store.read(account: "runner:rnr_fake")
  end

  def test_two_machine_identities_store_two_separate_preview_connectors
    platform = start_platform
    secret_store = FakeSecretStore.new
    connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)

    platform.runner_public_id = "rnr_second"
    platform.preview_connector = { token: "cft_fake-second-machine-connector-token" }
    platform.enrollment_code = code_for(platform.base_url)
    connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)

    assert_equal FakePlatform::ISSUED_CONNECTOR_TOKEN,
                 secret_store.read(account: "preview-connector:rnr_fake")
    assert_equal "cft_fake-second-machine-connector-token",
                 secret_store.read(account: "preview-connector:rnr_second")
  end

  # An otherwise successful exchange that carries no usable connector is refused BEFORE anything
  # is stored: a machine Platform believes can publish a preview but which holds no connector
  # would fail later and somewhere else.
  def test_refuses_an_enrollment_that_carries_no_usable_preview_connector
    [ nil, {}, { token: "  " }, "not-an-object" ].each do |connector|
      platform = start_platform
      platform.preview_connector = connector
      secret_store = FakeSecretStore.new

      error = assert_raises(SpecrelayRunner::Connect::Error) do
        connect(code: platform.enrollment_code, checkout: git_checkout, secret_store: secret_store)
      end

      assert_match(/preview connector/, error.message)
      assert_empty secret_store.writes, "nothing may be stored for #{connector.inspect}"
      refute File.exist?(@state_file)
      assert_nil platform.last_readiness_report
      platform.stop
    end
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
    stored = store.resolve("tiny-demo-workspace").connection

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

  # "Not connected to any workspace" and "nothing to do" are different problems, so
  # the runner surfaces the reason Platform returned instead of one generic idle line.
  def test_reports_platforms_reason_when_no_work_was_claimed
    out = StringIO.new
    platform = start_platform
    connect(code: platform.enrollment_code, checkout: git_checkout)
    stored = store.resolve("tiny-demo-workspace").connection
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
    config = SpecrelayRunner::Config.from_connection(store.resolve("tiny-demo-workspace").connection,
                                                     credential: "src_from-keychain")

    auth = config.resolve_auth(env: { "SPECRELAY_RUNNER_CREDENTIAL" => "src_stale-exported" })

    assert_equal "src_from-keychain", auth.token
  end

  # --- the connection is enough to REVIEW -----------------------------------

  # The reproduced defect: `connect` advertised a ready reviewer to Platform and then
  # stored a record that said nothing about which provider that was, so the next `claim-once`
  # reported no reviewer provider on a machine Platform had just been told could review.
  def test_the_reviewer_provider_reported_as_ready_is_the_one_the_connection_stores
    platform = start_platform
    connect(code: platform.enrollment_code, checkout: git_checkout, env: reviewer_env)

    report = platform.last_readiness_report.fetch(:body).fetch("report")

    assert_equal "ready", report.fetch("reviewer_readiness")
    assert_equal "fake", report.dig("reviewer_profile", "provider")
    stored = store.resolve("tiny-demo-workspace").connection

    assert_equal "fake", stored.reviewer_provider
    config = SpecrelayRunner::Config.from_connection(stored, credential: FakePlatform::ISSUED_CREDENTIAL)

    assert_equal "fake", SpecrelayRunner::Review::Settings.from(config, env: {}).provider
  end

  # A machine that advertised no reviewer stores no selection. Nothing may be invented for it
  # later, and its executor connection is unaffected.
  def test_a_connection_that_advertised_no_reviewer_stores_no_selection
    platform = start_platform
    connect(code: platform.enrollment_code, checkout: git_checkout)

    assert_equal "not_configured",
                 platform.last_readiness_report.fetch(:body).fetch("report").fetch("reviewer_readiness")
    assert_nil store.resolve("tiny-demo-workspace").connection.reviewer_provider
  end

  # The whole point of the ticket: after ONE guided connection, the ordinary claim command
  # completes a review of the connected checkout itself with no reviewer-provider and no
  # workspace-root environment override. The live run that found this needed both.
  def test_claim_once_completes_a_review_of_the_connected_checkout_without_any_override
    platform = start_platform
    checkout = git_checkout
    secret_store = FakeSecretStore.new
    connect(code: platform.enrollment_code, checkout: checkout, secret_store: secret_store,
            env: reviewer_env)
    platform.claim_payload = review_claim_payload(checkout)
    platform.offer_again!
    out = StringIO.new

    status = SpecrelayRunner::CLI.new(out: out, err: StringIO.new, env: claim_env(checkout),
                                     secret_store: secret_store)
                                 .run([ "claim-once", "--workspace", "tiny-demo-workspace" ])

    assert_equal 0, status, out.string
    assert_equal "ACCEPT", platform.last_review["outcome"]
  end

  private

  # The guided connection's own environment: the operator's selection travels here, and only
  # here. Every claim assertion above runs against `claim_env`, which carries neither.
  def reviewer_env
    { "PATH" => ENV["PATH"].to_s, SpecrelayRunner::Review::Settings::PROVIDER_ENV => "fake" }
  end

  # The claiming environment, asserted to contain NO provider and NO workspace-root override. The
  # reviewer COMMAND is present because the deterministic stand-in has no default executable; the
  # supported provider resolves its own, which is why only the provider is ever persisted.
  def claim_env(checkout)
    env = { "SPECRELAY_RUNNER_STATE_FILE" => @state_file, "PATH" => ENV["PATH"].to_s,
            "HOME" => checkout,
            SpecrelayRunner::Review::Settings::COMMAND_ENV => reviewer_script(checkout) }
    refute env.key?(SpecrelayRunner::Review::Settings::PROVIDER_ENV)
    refute env.keys.any? { |key| key.start_with?(SpecrelayRunner::Config::WORKSPACE_ROOT_ENV) }
    env
  end

  # A real executable that prints one supported outcome and exits, so the runner's argv, timeout
  # and capture behaviour are exercised by a real child process.
  def reviewer_script(directory)
    path = File.join(Dir.mktmpdir("reviewer"), "reviewer.rb")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      print '{"outcome":"ACCEPT","summary":"Read the pinned diff in #{File.basename(directory)}."}'
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end

  # A REVIEW assignment for the connected checkout itself — the single-repository shape a guided
  # connection produces, where the workspace root IS the reviewed repository.
  def review_claim_payload(checkout)
    head = `git -C #{checkout} rev-parse HEAD`.strip
    { "contract_version" => "mvp-0033", "assignment_type" => "review",
      "claim" => { "runner_execution_id" => "rex_review123" },
      # `rvt_fake` is the attempt identity the fake Platform answers with, and the client checks
      # the answer against the attempt it sent.
      "review" => { "attempt_id" => "rvt_fake", "attempt_ordinal" => 1,
                    "input_manifest_digest" => "digest" },
      "ticket" => { "external_id" => "DEMO-0091", "task_id" => "DEMO-0091" },
      "workspace" => { "key" => "tiny-demo-workspace" },
      "specification" => { "digest" => "specdigest", "documents" => [
        { "role" => "approved_specification_source", "digest" => "abc123", "byte_size" => 10,
          "content" => "# Approved" }
      ] },
      "implementation" => { "run_url" => "#{@platform.base_url}/runs/run_review123" },
      "repositories" => [ { "repository_key" => "tiny-demo-workspace",
                            "slug" => "SpecRelay/tiny-demo-workspace",
                            "clone_url" => "https://github.com/SpecRelay/tiny-demo-workspace",
                            "base_commit" => "1" * 40, "head_commit" => head,
                            "pull_request_url" => "https://github.com/SpecRelay/tiny-demo-workspace/pull/1" } ],
      "execution_evidence" => { "executor_summary" => "Did the work.", "files" => [] },
      "execution_policy" => { "attempt_timeout_seconds" => 30, "lease_renewal_seconds" => 0 },
      "result_contract" => { "outcomes" => %w[ACCEPT CHANGES_REQUESTED NEEDS_INPUT] } }
  end
end
