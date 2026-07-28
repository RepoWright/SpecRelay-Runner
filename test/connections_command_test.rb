# frozen_string_literal: true

require_relative "test_helper"

# MVP-0021 scope 4, 5, 6, 7 — the scriptable `connections` commands, driven through the real
# CLI entry point with no terminal anywhere.
#
# Everything here runs against StringIO, which is exactly the point: these commands must work
# in a script, in CI, and over `ssh host specrelay-runner …`, so not one of them may prompt,
# open a menu, or require a tty. The dashboard's own behaviour is covered by
# `dashboard_test.rb` and `dashboard_tty_test.rb`.
#
# The claims this file is here to prove:
#   - list/show/test/default/clear-default/disconnect-local/disconnect-platform all work
#     headless, and the exit codes are the documented contract (0 / 1 / 2);
#   - an explicit default lets bare `loop`/`claim-once` run with several connections and SAYS
#     it used the default;
#   - a broken default fails closed and never falls through to another workspace;
#   - local disconnect removes one entry, keeps a still-needed runner credential, and only ever
#     removes an orphaned one when explicitly asked;
#   - a failed Platform disconnect changes no local state;
#   - no output contains a credential.
class ConnectionsCommandTest < Minitest::Test
  RUNNER_ACCOUNT = "runner:rnr_fake"
  SECOND_RUNNER_ACCOUNT = "runner:rnr_second"
  CREDENTIAL = FakePlatform::ISSUED_CREDENTIAL
  REPOSITORY = "https://github.com/SpecRelay/tiny-demo-runs"

  def setup
    @dir = Dir.mktmpdir("connections-command")
    @state_file = File.join(@dir, "connections.json")
    @checkout = git_checkout(REPOSITORY)
    @platform = FakePlatform.new(
      claim_payload: claim_payload_for(task_id: "DEMO-0021", executor_command: "specrelay-fake-executor")
    ).start
    @secret_store = FakeSecretStore.new(entries: { RUNNER_ACCOUNT => CREDENTIAL })
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # --- list -----------------------------------------------------------------

  def test_list_on_a_machine_with_no_connections_explains_how_to_connect
    status, out, = run_cli(%w[connections list])

    assert_equal 0, status, "having no connections is not an error"
    assert_match(/not connected to any workspace/, out)
    assert_match(/specrelay-runner connect <enrollment-code>/, out)
  end

  def test_list_shows_every_connection_newest_first_with_the_default_marked
    store_connection("tiny-demo-workspace", connected_at: "2026-07-20T10:00:00Z")
    store_connection("development-workspace", connected_at: "2026-07-27T10:00:00Z")
    run_cli(%w[connections default tiny-demo-workspace])

    status, out, = run_cli(%w[connections list])

    assert_equal 0, status
    listed = out.lines.grep(/^ [ *] /).map { |line| line.strip.sub(/\A\*\s*/, "").split(" ").first }
    assert_equal %w[development-workspace tiny-demo-workspace], listed
    assert_match(/^ \* tiny-demo-workspace/, out, "the default is marked in the list itself")
    assert_match(/^   development-workspace/, out, "and non-defaults are not")
    assert_match(/Default workspace: tiny-demo-workspace \(marked \*\)/, out)
  end

  # The top-level listing is the screen most likely to end up in a screenshot or a pasted
  # transcript, so it must not name the operator's filesystem layout.
  def test_list_shows_no_absolute_local_paths
    store_connection("tiny-demo-workspace")

    _status, out, = run_cli(%w[connections list])

    refute_includes out, @checkout
  end

  def test_list_reports_a_default_that_no_longer_resolves_instead_of_hiding_it
    store_connection("tiny-demo-workspace")
    run_cli(%w[connections default tiny-demo-workspace])
    rewrite_state { |doc| doc["connections"] = [] }

    _status, out, = run_cli(%w[connections list])

    assert_match(/SET BUT NOT CONNECTED/, out)
  end

  def test_a_damaged_state_file_is_a_usage_error_rather_than_an_empty_list
    File.write(@state_file, "{ not json")

    status, _out, err = run_cli(%w[connections list])

    assert_equal 2, status
    assert_match(/could not be read as SpecRelay connection state/, err)
  end

  # --- show -----------------------------------------------------------------

  def test_show_names_the_local_checkout_and_no_credential
    store_connection("tiny-demo-workspace")

    status, out, = run_cli(%w[connections show tiny-demo-workspace])

    assert_equal 0, status
    assert_match(/Local checkout\s+#{Regexp.escape(@checkout)}/, out)
    assert_match(/Runner\s+host runner — host-runner \(rnr_fake\)/, out)
    refute_includes out, CREDENTIAL
  end

  def test_show_without_a_workspace_key_is_a_usage_error
    status, _out, err = run_cli(%w[connections show])

    assert_equal 2, status
    assert_match(/usage: specrelay-runner connections show/, err)
  end

  def test_show_for_an_unknown_workspace_is_a_usage_error_naming_the_listing_command
    store_connection("tiny-demo-workspace")

    status, _out, err = run_cli(%w[connections show nope])

    assert_equal 2, status
    assert_match(/connections list/, err)
  end

  # --- test -----------------------------------------------------------------

  def test_test_succeeds_with_exit_zero_and_claims_nothing
    store_connection("tiny-demo-workspace")

    status, out, = run_cli(%w[connections test tiny-demo-workspace])

    assert_equal 0, status, out
    assert_match(/is ready/, out)
    assert_empty @platform.requests_to("/api/runner/claim")
  end

  # Exit 1, not 2: the question was well-formed and the answer is no. A wrapper script must be
  # able to tell that from "you called me wrong".
  def test_a_failed_readiness_test_exits_one_with_one_remedy
    store_connection("tiny-demo-workspace")
    @platform.grants.clear

    status, _out, err = run_cli(%w[connections test tiny-demo-workspace])

    assert_equal 1, status
    assert_match(/workspace_grant_missing/, err)
    assert_match(/Remedy: .*new enrollment code/, err)
  end

  def test_an_unusable_local_entry_makes_the_test_a_usage_error
    store_connection("tiny-demo-workspace")
    rewrite_state { |doc| doc["connections"].first["local_path"] = "" }

    status, _out, err = run_cli(%w[connections test tiny-demo-workspace])

    assert_equal 2, status
    assert_match(/local_state_invalid/, err)
  end

  # --- default / clear-default ----------------------------------------------

  # Proven on the REAL claim path: the runner authenticates with the stored credential and polls
  # Platform. Platform authorizes no work, which is a normal exit-0 poll, so what is asserted is
  # exactly the workspace resolution and what it printed — not a whole simulated execution.
  def test_setting_a_default_lets_bare_claim_once_run_with_several_connections
    store_connection("tiny-demo-workspace")
    store_connection("development-workspace", connected_at: "2026-07-27T10:00:00Z")
    @platform.offer_no_work!

    status, out, = run_cli(%w[connections default tiny-demo-workspace])

    assert_equal 0, status
    assert_match(/Default workspace set to tiny-demo-workspace/, out)

    status, out, err = run_cli(%w[claim-once])

    assert_equal 0, status, err
    assert_match(/connected workspace tiny-demo-workspace \(your explicit default workspace\)/, out)
    refute_match(/several workspaces are connected/, err)
    assert_equal 1, @platform.requests_to("/api/runner/claim").length, "it must really have claimed for one"
  end

  def test_the_sole_connection_is_still_used_without_a_default_and_says_so
    store_connection("tiny-demo-workspace")
    @platform.offer_no_work!

    status, out, err = run_cli(%w[claim-once])

    assert_equal 0, status, err
    assert_match(/connected workspace tiny-demo-workspace \(the only one connected here\)/, out)
  end

  def test_setting_a_default_for_an_unconnected_workspace_is_refused_as_a_usage_error
    store_connection("tiny-demo-workspace")

    status, _out, err = run_cli(%w[connections default nope])

    assert_equal 2, status
    assert_match(/no local connection for workspace 'nope'/, err)
    assert_match(/connected workspaces: tiny-demo-workspace/, err)
  end

  def test_clearing_a_default_restores_the_explicit_choice_requirement
    store_connection("tiny-demo-workspace")
    store_connection("development-workspace", connected_at: "2026-07-27T10:00:00Z")
    run_cli(%w[connections default tiny-demo-workspace])

    status, out, = run_cli(%w[connections clear-default])

    assert_equal 0, status
    assert_match(/Default workspace cleared \(was tiny-demo-workspace\)/, out)

    status, _out, err = run_cli(%w[loop])

    assert_equal 2, status
    assert_match(/several workspaces are connected/, err)
  end

  def test_clearing_a_default_that_was_never_set_is_a_harmless_success
    store_connection("tiny-demo-workspace")

    status, out, = run_cli(%w[connections clear-default])

    assert_equal 0, status
    assert_match(/No default workspace was set/, out)
  end

  # THE fail-closed rule. Executing another project's work because a default went stale is
  # exactly the routing mistake MVP-0017 fixed, so this must never resolve to anything else.
  def test_a_default_naming_a_disconnected_workspace_fails_closed_and_claims_nothing
    store_connection("tiny-demo-workspace")
    store_connection("development-workspace", connected_at: "2026-07-27T10:00:00Z")
    run_cli(%w[connections default tiny-demo-workspace])
    run_cli(%w[connections disconnect-local development-workspace])
    rewrite_state { |doc| doc["default_workspace_key"] = "development-workspace" }

    status, _out, err = run_cli(%w[claim-once])

    assert_equal 2, status
    assert_match(/default workspace 'development-workspace' is no longer connected/, err)
    assert_match(/nothing was claimed/, err)
    assert_empty @platform.requests_to("/api/runner/claim")
  end

  # The dangerous variant: exactly ONE other connection exists, so a fall-through would look
  # like it worked. It must still refuse.
  def test_a_broken_default_does_not_fall_through_even_to_a_sole_remaining_connection
    store_connection("tiny-demo-workspace")
    rewrite_state { |doc| doc["default_workspace_key"] = "gone-workspace" }

    status, _out, err = run_cli(%w[claim-once])

    assert_equal 2, status
    assert_match(/default workspace 'gone-workspace' is no longer connected/, err)
    assert_empty @platform.requests_to("/api/runner/claim")
  end

  def test_the_ambiguity_message_now_points_at_the_default_and_the_dashboard
    store_connection("tiny-demo-workspace")
    store_connection("development-workspace", connected_at: "2026-07-27T10:00:00Z")

    status, _out, err = run_cli(%w[claim-once])

    assert_equal 2, status
    assert_match(/connections default <workspace-key>/, err)
    assert_match(/run `specrelay-runner` in a terminal for the dashboard/, err)
  end

  # --- disconnect-local -----------------------------------------------------

  def test_local_disconnect_removes_one_entry_and_says_platform_is_unchanged
    store_connection("tiny-demo-workspace")
    store_connection("development-workspace", connected_at: "2026-07-27T10:00:00Z")

    status, out, = run_cli(%w[connections disconnect-local development-workspace])

    assert_equal 0, status
    assert_match(/Removed the local connection for development-workspace/, out)
    assert_match(/Platform-side authorization is unchanged/, out)
    assert_equal [ "tiny-demo-workspace" ], stored_keys
  end

  # The credential is scoped to the RUNNER, so removing one workspace must not break the other
  # workspace that authenticates from the same item.
  def test_local_disconnect_keeps_a_credential_another_connection_still_needs
    store_connection("tiny-demo-workspace")
    store_connection("development-workspace", connected_at: "2026-07-27T10:00:00Z")

    _status, out, = run_cli(%w[connections disconnect-local development-workspace --remove-credential])

    assert_match(/runner credential was kept: tiny-demo-workspace still uses it/, out)
    assert_empty @secret_store.deletes
    assert @secret_store.stored?(RUNNER_ACCOUNT)
  end

  def test_local_disconnect_of_the_last_connection_keeps_the_credential_unless_asked
    store_connection("tiny-demo-workspace")

    _status, out, err = run_cli(%w[connections disconnect-local tiny-demo-workspace])

    assert_match(/runner credential was kept/, out)
    assert_empty @secret_store.deletes
    assert_match(/--remove-credential/, "#{out}#{err}", "it must say how to remove it")
  end

  def test_local_disconnect_removes_an_orphaned_credential_only_when_explicitly_asked
    store_connection("tiny-demo-workspace")

    _status, out, = run_cli(%w[connections disconnect-local tiny-demo-workspace --remove-credential])

    assert_equal [ RUNNER_ACCOUNT ], @secret_store.deletes
    assert_match(/Keychain credential \(runner:rnr_fake\) was removed/, out)
  end

  # Two runner identities on one machine: removing one must not touch the other's credential.
  def test_local_disconnect_never_removes_another_runner_identitys_credential
    store_connection("tiny-demo-workspace")
    store_connection("other-workspace", runner_public_id: "rnr_second", connected_at: "2026-07-27T10:00:00Z")
    @secret_store.write(account: SECOND_RUNNER_ACCOUNT, credential: "src_second-runner")

    run_cli(%w[connections disconnect-local tiny-demo-workspace --remove-credential])

    assert_equal [ RUNNER_ACCOUNT ], @secret_store.deletes
    assert @secret_store.stored?(SECOND_RUNNER_ACCOUNT)
  end

  def test_local_disconnect_of_the_default_workspace_clears_the_default
    store_connection("tiny-demo-workspace")
    store_connection("development-workspace", connected_at: "2026-07-27T10:00:00Z")
    run_cli(%w[connections default development-workspace])

    run_cli(%w[connections disconnect-local development-workspace])

    assert_nil document["default_workspace_key"]
  end

  def test_an_unknown_option_to_disconnect_local_is_a_usage_error
    store_connection("tiny-demo-workspace")

    status, _out, err = run_cli(%w[connections disconnect-local tiny-demo-workspace --force])

    assert_equal 2, status
    assert_match(/unknown option for disconnect-local: --force/, err)
    assert_equal [ "tiny-demo-workspace" ], stored_keys, "a rejected invocation must change nothing"
  end

  # A legacy item is removed only through its own named action, and the action names the exact
  # account, so an operator can see which item is going.
  def test_the_legacy_per_workspace_credential_has_its_own_explicit_cleanup_action
    store_connection("tiny-demo-workspace")
    @secret_store.write(account: "workspace:tiny-demo-workspace", credential: "src_legacy")

    status, out, = run_cli(%w[connections forget-legacy-credential tiny-demo-workspace])

    assert_equal 0, status
    assert_match(/Removed the legacy per-workspace Keychain item workspace:tiny-demo-workspace/, out)
    assert_equal [ "workspace:tiny-demo-workspace" ], @secret_store.deletes
  end

  def test_a_plain_local_disconnect_never_touches_a_legacy_item
    store_connection("tiny-demo-workspace")
    @secret_store.write(account: "workspace:tiny-demo-workspace", credential: "src_legacy")

    run_cli(%w[connections disconnect-local tiny-demo-workspace --remove-credential])

    refute_includes @secret_store.deletes, "workspace:tiny-demo-workspace"
  end

  # --- disconnect-platform --------------------------------------------------

  def test_platform_disconnect_removes_the_grant_and_leaves_local_state_alone
    store_connection("tiny-demo-workspace")

    status, out, = run_cli(%w[connections disconnect-platform tiny-demo-workspace])

    assert_equal 0, status
    assert_match(/removed this runner's grant/, out)
    assert_match(/Next: .*disconnect-local/, out)
    assert_equal [ "tiny-demo-workspace" ], stored_keys, "the local entry is removed separately"
    assert_empty @platform.grants
  end

  def test_platform_disconnect_is_idempotent
    store_connection("tiny-demo-workspace")
    run_cli(%w[connections disconnect-platform tiny-demo-workspace])

    status, out, = run_cli(%w[connections disconnect-platform tiny-demo-workspace])

    assert_equal 0, status, "a retry after a dropped response must succeed"
    assert_match(/holds no grant for this runner/, out)
  end

  def test_a_platform_disconnect_platform_rejects_changes_no_local_state
    store_connection("tiny-demo-workspace")
    @secret_store.write(account: RUNNER_ACCOUNT, credential: "src_no-longer-valid")

    status, _out, err = run_cli(%w[connections disconnect-platform tiny-demo-workspace])

    assert_equal 1, status
    assert_match(/did not accept this runner's credential/, err)
    assert_match(/nothing was disconnected and no local state changed/, err)
    assert_equal [ "tiny-demo-workspace" ], stored_keys
    assert_equal [ "tiny-demo-workspace" ], @platform.grants
  end

  def test_a_platform_disconnect_that_cannot_reach_platform_changes_no_local_state
    store_connection("tiny-demo-workspace")
    @platform.stop

    status, _out, err = run_cli(%w[connections disconnect-platform tiny-demo-workspace])

    assert_equal 1, status
    assert_match(/could not reach Platform/, err)
    assert_equal [ "tiny-demo-workspace" ], stored_keys
  end

  def test_a_platform_disconnect_with_no_stored_credential_is_a_usage_error_naming_the_local_option
    store_connection("tiny-demo-workspace")
    @secret_store = FakeSecretStore.new

    status, _out, err = run_cli(%w[connections disconnect-platform tiny-demo-workspace])

    assert_equal 2, status
    assert_match(/no stored credential for runner rnr_fake/, err)
    assert_match(/disconnect-local/, err)
  end

  # --- usage ----------------------------------------------------------------

  def test_an_unknown_subcommand_lists_the_real_ones
    status, _out, err = run_cli(%w[connections frobnicate])

    assert_equal 2, status
    assert_match(/unknown connections subcommand: frobnicate/, err)
    SpecrelayRunner::ConnectionsCommand::SUBCOMMANDS.each { |name| assert_match(/#{name}/, err) }
  end

  def test_connections_with_no_subcommand_is_a_usage_error
    status, _out, err = run_cli(%w[connections])

    assert_equal 2, status
    assert_match(/needs a subcommand/, err)
  end

  def test_no_command_output_anywhere_contains_a_credential
    store_connection("tiny-demo-workspace")
    transcript = [ %w[connections list], %w[connections show tiny-demo-workspace],
                  %w[connections test tiny-demo-workspace], %w[connections default tiny-demo-workspace],
                  %w[connections disconnect-platform tiny-demo-workspace] ].map do |argv|
      _status, out, err = run_cli(argv)
      "#{out}#{err}"
    end.join

    refute_includes transcript, CREDENTIAL
    refute_match(/src_|srt_|sre_/, transcript)
  end

  private

  # Drives the REAL CLI entry point, with StringIO everywhere so nothing is a terminal and the
  # in-memory Keychain stand-in is injected through the CLI's own seam — the developer's real
  # Keychain is never read or written by this suite.
  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    status = SpecrelayRunner::CLI.new(out: out, err: err, env: env, input: StringIO.new,
                                     secret_store: @secret_store).run(argv)
    [ status, out.string, err.string ]
  end

  def env
    { "SPECRELAY_RUNNER_STATE_FILE" => @state_file, "PATH" => ENV.fetch("PATH", "") }
  end

  def store_connection(workspace_key, runner_public_id: "rnr_fake", connected_at: "2026-07-20T10:00:00Z")
    SpecrelayRunner::ConnectionStore.new(@state_file).save(
      SpecrelayRunner::ConnectionStore::Connection.new(
        base_url: @platform.base_url, runner_id: "host-runner", runner_public_id: runner_public_id,
        runner_display_name: "host runner", project_slug: "tiny-demo", workspace_key: workspace_key,
        project_key: "tiny-demo", workspace_display_name: "Tiny Demo Workspace",
        repository_url: REPOSITORY, default_branch: "main", local_path: @checkout,
        connected_at: connected_at
      )
    )
  end

  def stored_keys = SpecrelayRunner::ConnectionStore.new(@state_file).connections.map(&:workspace_key)
  def document = JSON.parse(File.read(@state_file))

  def rewrite_state
    doc = document
    yield doc
    File.write(@state_file, "#{JSON.pretty_generate(doc)}\n")
  end

  def git_checkout(remote)
    path = File.join(@dir, "checkout")
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
end
