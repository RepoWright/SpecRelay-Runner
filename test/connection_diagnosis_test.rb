# frozen_string_literal: true

require_relative "test_helper"

# MVP-0021 scope 3 — the non-claiming readiness test, asserted against a real HTTP fake
# Platform, a real local Git checkout, and the real ClaudeProfile probe seam.
#
# The claims this file is here to prove:
#   - each failure condition produces its OWN outcome and its OWN remedy, so an operator is
#     never sent to fix the wrong thing;
#   - the walk STOPS at the first failure, in claim order, because a later precondition's
#     verdict is meaningless once an earlier one is broken;
#   - it claims nothing: no /api/runner/claim request is ever made, and Platform's own state is
#     not changed, so running the test cannot demote the connection being tested;
#   - no credential, provider auth output, or account identity appears in any result.
class ConnectionDiagnosisTest < Minitest::Test
  RUNNER_ACCOUNT = "runner:rnr_fake"
  CREDENTIAL = FakePlatform::ISSUED_CREDENTIAL
  REPOSITORY = "https://github.com/SpecRelay/tiny-demo-workspace"

  def setup
    @dir = Dir.mktmpdir("diagnosis")
    @checkout = git_checkout(REPOSITORY)
    @platform = FakePlatform.new(
      claim_payload: claim_payload_for(task_id: "DEMO-0021", executor_command: "specrelay-fake-executor")
    ).start
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # --- the happy path -------------------------------------------------------

  def test_a_healthy_connection_reports_ok_and_claims_nothing
    result = diagnose

    assert_equal SpecrelayRunner::ConnectionDiagnosis::OK, result.outcome, result.summary
    assert result.ok?
    assert_nil result.remedy, "there is nothing to remedy"
    assert_empty @platform.requests_to("/api/runner/claim"), "the test must never claim work"
  end

  def test_the_check_trail_records_every_precondition_in_claim_order
    labels = diagnose.checks.map(&:label)

    assert_equal [ "Local connection entry", "Runner credential in the OS secret store",
                  "Platform accepted the credential", "Platform workspace grant is ready",
                  "Workspace repository matches this connection",
                  "Local checkout is this workspace's repository", "Executor readiness" ],
                 labels
  end

  # The fixture executor must never require Claude Code to be installed or signed in, so the
  # provider check is explicitly SKIPPED rather than silently reported as passing.
  def test_a_fixture_executor_workspace_skips_the_provider_check_explicitly
    executor = diagnose.checks.last

    assert_equal :skipped, executor.state
    assert_match(/deterministic fixture executor/, executor.detail)
  end

  def test_platform_is_asked_with_a_read_and_only_for_this_workspace
    diagnose

    request = @platform.requests.find { |r| r[:path].start_with?("/api/runner/workspace_connections/") }

    assert_equal "GET", request[:method], "a diagnosis must not be able to change anything"
    assert_equal "/api/runner/workspace_connections/tiny-demo-workspace", request[:path]
  end

  # --- local state ----------------------------------------------------------

  def test_an_incomplete_local_entry_is_reported_before_anything_else_is_attempted
    result = diagnose(connection: connection(local_path: ""))

    assert_equal SpecrelayRunner::ConnectionDiagnosis::LOCAL_STATE_INVALID, result.outcome
    assert_match(/missing local_path/, result.summary)
    assert_match(/disconnect-local/, result.remedy)
    assert_equal 1, result.checks.length, "the walk must stop at the first failure"
    assert_empty @platform.requests, "a damaged local entry must not reach Platform at all"
  end

  # --- the credential -------------------------------------------------------

  def test_a_missing_credential_names_reconnecting_and_never_reaches_platform
    result = diagnose(secret_store: FakeSecretStore.new)

    assert_equal SpecrelayRunner::ConnectionDiagnosis::CREDENTIAL_MISSING, result.outcome
    assert_match(/no credential is stored for runner rnr_fake/, result.summary)
    assert_match(/specrelay-runner connect/, result.remedy)
    assert_empty @platform.requests
  end

  # A machine that connected before the credential became runner-scoped still authenticates
  # from its per-workspace item, so the test must find it there too — otherwise it would report
  # a healthy machine as broken.
  def test_a_legacy_per_workspace_credential_is_still_found
    legacy = FakeSecretStore.new(entries: { "workspace:tiny-demo-workspace" => CREDENTIAL })

    assert_equal SpecrelayRunner::ConnectionDiagnosis::OK, diagnose(secret_store: legacy).outcome
  end

  def test_a_credential_platform_rejects_is_distinguished_from_a_missing_one
    result = diagnose(secret_store: FakeSecretStore.new(entries: { RUNNER_ACCOUNT => "src_wrong-credential" }))

    assert_equal SpecrelayRunner::ConnectionDiagnosis::CREDENTIAL_REJECTED, result.outcome
    assert_match(/rotated or the runner revoked/, result.remedy)
  end

  def test_no_result_field_ever_contains_the_credential
    result = diagnose

    serialized = [ result.summary, result.remedy, result.checks.map { |c| [ c.label, c.detail ] } ].to_s

    refute_includes serialized, CREDENTIAL
    refute_match(/src_/, serialized)
  end

  # --- Platform's answer ----------------------------------------------------

  def test_an_unreachable_platform_is_its_own_outcome
    # The connection is built while the port is still knowable, then Platform goes away — which
    # is the real shape of this failure: valid local state pointing at an endpoint that is down.
    entry = connection
    @platform.stop
    result = diagnose(connection: entry)

    assert_equal SpecrelayRunner::ConnectionDiagnosis::PLATFORM_UNREACHABLE, result.outcome
    assert_match(/is running and reachable/, result.remedy)
  end

  def test_a_grant_platform_no_longer_holds_names_a_new_enrollment_code
    @platform.grants.clear
    result = diagnose

    assert_equal SpecrelayRunner::ConnectionDiagnosis::WORKSPACE_GRANT_MISSING, result.outcome
    assert_match(/new enrollment code/, result.remedy)
  end

  def test_a_blocked_grant_follows_platforms_own_failure_classification
    @platform.grant_state = "blocked"
    @platform.grant_failure_class = "executor_not_authenticated"
    result = diagnose

    assert_equal SpecrelayRunner::ConnectionDiagnosis::WORKSPACE_GRANT_NOT_READY, result.outcome
    assert_match(/claude auth login/, result.remedy)
  end

  def test_a_pending_grant_asks_for_a_reconnect_so_readiness_is_reported_again
    @platform.grant_state = "pending"
    result = diagnose

    assert_equal SpecrelayRunner::ConnectionDiagnosis::WORKSPACE_GRANT_NOT_READY, result.outcome
    assert_match(/reports\s+readiness again/, result.remedy)
  end

  # A deactivated workspace is offered to no runner however healthy the grant looks, so a test
  # that ignored it would report a connection that can never claim as ready.
  def test_a_deactivated_workspace_is_called_out_as_its_own_condition
    @platform.workspace_active = false
    result = diagnose

    assert_equal SpecrelayRunner::ConnectionDiagnosis::WORKSPACE_GRANT_NOT_READY, result.outcome
    assert_match(/deactivated in Platform/, result.summary)
    assert_match(/reactivate the workspace/, result.remedy)
  end

  # --- the repository -------------------------------------------------------

  # An operator editing the workspace's repository in Platform breaks the connection without
  # touching the machine. The remedy has to name the NEW repository, or the operator reconnects
  # to the same wrong checkout.
  def test_a_workspace_whose_repository_moved_in_platform_is_reported_with_both_identities
    result = diagnose(connection: connection(repository_url: "https://github.com/SpecRelay/old-repo"))

    assert_equal SpecrelayRunner::ConnectionDiagnosis::REPOSITORY_MISMATCH, result.outcome
    assert_match(%r{Platform now defines this workspace as https://github.com/SpecRelay/tiny-demo-workspace}, result.summary)
    assert_match(%r{old-repo}, result.summary)
    assert_match(%r{point it at a checkout of https://github.com/SpecRelay/tiny-demo-workspace}, result.remedy)
  end

  def test_a_checkout_repointed_at_another_repository_is_reported_against_the_checkout
    other = git_checkout("https://github.com/SpecRelay/somewhere-else", name: "other")
    result = diagnose(connection: connection(local_path: other))

    assert_equal SpecrelayRunner::ConnectionDiagnosis::REPOSITORY_MISMATCH, result.outcome
    assert_match(/somewhere-else/, result.summary)
    assert_match(/correct local checkout directory/, result.remedy)
  end

  def test_a_checkout_that_no_longer_exists_is_reported_as_a_repository_problem
    result = diagnose(connection: connection(local_path: File.join(@dir, "deleted")))

    assert_equal SpecrelayRunner::ConnectionDiagnosis::REPOSITORY_MISMATCH, result.outcome
    assert_match(/does not exist/, result.summary)
  end

  # --- the executor ---------------------------------------------------------

  def test_a_missing_provider_cli_reports_executor_unavailable_with_an_install_remedy
    use_claude_executor
    result = diagnose(env: { "PATH" => File.join(@dir, "empty-bin") })

    assert_equal SpecrelayRunner::ConnectionDiagnosis::EXECUTOR_UNAVAILABLE, result.outcome
    assert_match(/install Claude Code/, result.remedy)
  end

  def test_an_unauthenticated_provider_cli_reports_a_login_remedy_and_no_probe_output
    use_claude_executor
    result = diagnose(env: { "PATH" => fake_claude(logged_in: false) })

    assert_equal SpecrelayRunner::ConnectionDiagnosis::EXECUTOR_NOT_AUTHENTICATED, result.outcome
    assert_match(/claude auth login/, result.remedy)
    # The auth probe's raw output carries the operator's email and organization. Only the
    # classification may survive.
    refute_match(/operator@example.com|Example Org/, [ result.summary, result.remedy ].join(" "))
  end

  def test_an_authenticated_provider_cli_passes_the_executor_check
    use_claude_executor
    result = diagnose(env: { "PATH" => fake_claude(logged_in: true) })

    assert_equal SpecrelayRunner::ConnectionDiagnosis::OK, result.outcome, result.summary
    assert_match(/claude=available, auth=authenticated/, result.checks.last.label)
  end

  # An executor profile this runner refuses to launch would fail the claim too, so it is
  # reported here as an executor problem rather than raised at the operator.
  def test_an_executor_profile_this_runner_refuses_is_reported_not_raised
    @platform.claim_payload_executor = { "provider" => "claude", "command" => "claude",
                                        "args" => [], "prompt_delivery" => "argument" }
    result = diagnose

    assert_equal SpecrelayRunner::ConnectionDiagnosis::EXECUTOR_CHECK_FAILED, result.outcome
    assert_match(/non-interactive output/, result.summary)
    assert_match(/correct the workspace's executor configuration/, result.remedy)
  end

  private

  def diagnose(connection: connection(), env: { "PATH" => ENV.fetch("PATH", "") },
               secret_store: FakeSecretStore.new(entries: { RUNNER_ACCOUNT => CREDENTIAL }))
    SpecrelayRunner::ConnectionDiagnosis.call(connection: connection, env: env,
                                             secret_store: secret_store, platform: "arm64-darwin25")
  end

  def connection(local_path: @checkout, repository_url: REPOSITORY, **overrides)
    SpecrelayRunner::ConnectionStore::Connection.new(
      { base_url: @platform.base_url, runner_id: "host-runner", runner_public_id: "rnr_fake",
        runner_display_name: "host runner", project_slug: "tiny-demo",
        workspace_key: "tiny-demo-workspace", project_key: "tiny-demo",
        workspace_display_name: "Tiny Demo Workspace", repository_url: repository_url,
        default_branch: "main", local_path: local_path,
        connected_at: "2026-07-20T10:00:00Z" }.merge(overrides)
    )
  end

  def use_claude_executor
    @platform.claim_payload_executor = {
      "provider" => "claude", "command" => "claude", "args" => [ "--print" ],
      "prompt_delivery" => "argument", "timeout_seconds" => 900, "env" => {}
    }
    FileUtils.mkdir_p(File.join(@dir, "empty-bin"))
  end

  # A real Git repository with the given remote and a `main` branch, so RepositoryCheck runs
  # against real local git configuration rather than a stub.
  def git_checkout(remote, name: "checkout")
    path = File.join(@dir, name)
    FileUtils.mkdir_p(path)
    run_git(path, %w[init --initial-branch main])
    run_git(path, [ "remote", "add", "origin", remote ])
    File.write(File.join(path, "README.md"), "demo\n")
    run_git(path, %w[add .])
    run_git(path, [ "-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-m", "init" ])
    path
  end

  def run_git(path, args)
    system("git", "-C", path, *args, out: File::NULL, err: File::NULL) ||
      raise("git #{args.join(' ')} failed in #{path}")
  end

  # A stub `claude` on PATH whose auth output carries the operator identity the real CLI emits,
  # so "the probe output never reaches a result" is proven against output that would matter.
  def fake_claude(logged_in:)
    bin = File.join(@dir, "claude-bin-#{logged_in}")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "claude"), <<~SH)
      #!/bin/sh
      case "$1" in
        --version) echo "1.2.3 (Claude Code)"; exit 0 ;;
        auth) echo '{"loggedIn": #{logged_in}, "email": "operator@example.com", "org": "Example Org"}'
              exit 0 ;;
      esac
      exit 1
    SH
    File.chmod(0o755, File.join(bin, "claude"))
    bin
  end
end
