# frozen_string_literal: true

require_relative "test_helper"

# MVP-0021 scope 1 and 2 — the dashboard's behaviour, driven by scripted keystrokes.
#
# The menu's own terminal handling is proved separately and for real: `terminal_menu_test.rb`
# covers the key decisions as a pure function, and `dashboard_tty_test.rb` runs the whole thing
# under an actual pty and asserts the terminal is left cooked afterwards. This file covers what
# the dashboard DOES once a key has been pressed, which is where the acceptance criteria live.
#
# The claims this file is here to prove:
#   - a no-argument invocation opens the dashboard ONLY with a terminal on both ends, and prints
#     usage with exit 2 otherwise;
#   - `Start loop` and `Claim once` dispatch the EXACT argv of the direct commands, and dispatch
#     it through the CLI's own dispatcher rather than reimplementing anything;
#   - the empty state tells the operator to connect and does not crash;
#   - the detail view shows every required field and every required action;
#   - destructive actions do nothing when the confirmation is declined; the Keychain question is
#     asked separately and only when the credential would be orphaned; and a failed Platform
#     disconnect leaves local state alone;
#   - no screen prints a credential, and the top-level list prints no absolute path.
class DashboardTest < Minitest::Test
  RUNNER_ACCOUNT = "runner:rnr_fake"
  CREDENTIAL = FakePlatform::ISSUED_CREDENTIAL
  REPOSITORY = "https://github.com/SpecRelay/tiny-demo-workspace"

  def setup
    @dir = Dir.mktmpdir("dashboard")
    @state_file = File.join(@dir, "connections.json")
    @checkout = git_checkout(REPOSITORY)
    @platform = FakePlatform.new(
      claim_payload: claim_payload_for(task_id: "DEMO-0021")
    ).start
    @secret_store = FakeSecretStore.new(entries: { RUNNER_ACCOUNT => CREDENTIAL })
    @dispatched = []
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # --- a scripted menu -----------------------------------------------------

  # Stands in for TerminalMenu, answering with scripted selections and confirmations. It exists
  # so the ACTIONS can be tested exhaustively without a terminal; the real menu's rendering and
  # raw-mode handling are covered by the two dedicated files named above.
  class ScriptedMenu
    attr_reader :frames, :confirmations, :restores

    def initialize(selections, confirmations: [])
      @selections = selections
      @confirmations = []
      @answers = confirmations
      @frames = []
      @restores = 0
    end

    def select(title:, entries:, footer:, header: [])
      @frames << { title: title, header: header, footer: footer,
                   entries: entries.map { |e| [ e.shortcut, e.label, e.value ] } }
      raise "the dashboard asked for more input than the script provides" if @selections.empty?

      @selections.shift
    end

    def confirm(prompt)
      @confirmations << prompt
      @answers.empty? ? false : @answers.shift
    end

    def pause(_message = nil) = nil
    def clear = nil
    def restore = @restores += 1
    def width = 100
  end

  # --- no-argument routing --------------------------------------------------

  def test_without_a_terminal_a_no_argument_invocation_prints_usage_and_exits_two
    store_connection("tiny-demo-workspace")
    out = StringIO.new
    err = StringIO.new

    status = SpecrelayRunner::CLI.new(out: out, err: err, env: env, input: StringIO.new,
                                     secret_store: @secret_store).run([])

    assert_equal 2, status, "a mis-scripted invocation must not pass as a successful run"
    assert_match(/needs a command when there is no terminal/, err.string)
    assert_match(/in a terminal: opens the dashboard/, err.string)
    refute_match(/\e\[/, out.string, "no escape sequences may be written to a non-terminal")
  end

  def test_explicit_help_still_exits_zero_without_a_terminal
    out = StringIO.new

    status = SpecrelayRunner::CLI.new(out: out, err: StringIO.new, env: env, input: StringIO.new).run([ "help" ])

    assert_equal 0, status, "asking for help and getting it is a success"
    assert_match(/opens the local control center/, out.string)
  end

  def test_interactive_requires_a_terminal_on_both_ends
    refute SpecrelayRunner::TerminalMenu.interactive?(input: StringIO.new, out: StringIO.new)
    refute SpecrelayRunner::TerminalMenu.interactive?(input: FakeTty.new, out: StringIO.new)
    refute SpecrelayRunner::TerminalMenu.interactive?(input: StringIO.new, out: FakeTty.new)
    assert SpecrelayRunner::TerminalMenu.interactive?(input: FakeTty.new, out: FakeTty.new)
  end

  class FakeTty < StringIO
    def tty? = true
  end

  # --- top level ------------------------------------------------------------

  def test_the_empty_state_names_the_connect_command_and_does_not_crash
    menu = ScriptedMenu.new([ :quit ])

    assert_equal 0, run_dashboard(menu)
    header = menu.frames.first[:header].join("\n")
    assert_match(/not connected to any project yet/, header)
    assert_match(/specrelay-runner connect <enrollment-code>/, header)
    assert_equal [ %w[H], %w[Q] ], menu.frames.first[:entries].map { |shortcut, _, _| [ shortcut ] }
  end

  def test_a_damaged_state_file_is_reported_on_the_dashboard_rather_than_read_as_empty
    File.write(@state_file, "{ not json")
    menu = ScriptedMenu.new([ :quit ])

    run_dashboard(menu)

    assert_match(/could not be read as SpecRelay connection state/, menu.frames.first[:header].join("\n"))
  end

  def test_every_connection_is_listed_with_a_numeric_shortcut_newest_first
    store_connection("tiny-demo-workspace", connected_at: "2026-07-20T10:00:00Z")
    store_connection("development-workspace", connected_at: "2026-07-27T10:00:00Z")
    menu = ScriptedMenu.new([ :quit ])

    run_dashboard(menu)

    workspaces = menu.frames.first[:entries].select { |shortcut, _, _| shortcut.match?(/\d/) }
    assert_equal [ [ "1", "development-workspace" ], [ "2", "tiny-demo-workspace" ] ],
                 workspaces.map { |shortcut, label, _| [ shortcut, label.split("·")[1].strip ] }
    assert_equal %w[tiny-demo tiny-demo],
                 workspaces.map { |_, label, _| label.split("·").first.strip },
                 "the project leads every row"
  end

  # RUNNER-0001 acceptance criterion 1: the PROJECT is the primary identity an operator reads,
  # and the workspace key stays on the row because it is what `--workspace` routes on.
  def test_the_list_leads_with_the_project_and_keeps_the_workspace_key_visible
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ :quit ])

    run_dashboard(menu)

    label = menu.frames.first[:entries].first[1]
    assert_match(/\Atiny-demo · tiny-demo-workspace ·/, label, "project first, workspace key second")
    assert_match(%r{specrelay/tiny-demo-workspace@main}, label, "the repository and its default branch")
    assert_match(/\dd ago/, label, "how old this connection is")
    # Every field survives an 80-column terminal, which is the whole reason the row is short.
    assert_operator label.length, :<=, 80
    refute_includes label, @checkout, "the top-level list must not name the operator's filesystem"
  end

  # Scenario 3: two connections to the same project must still be distinguishable. The project
  # name alone cannot do it, so the row carries the workspace key and the repository.
  def test_two_connections_to_the_same_project_are_still_told_apart
    store_connection("tiny-demo-workspace", connected_at: "2026-07-20T10:00:00Z")
    store_connection("tiny-demo-staging", connected_at: "2026-07-27T10:00:00Z")
    menu = ScriptedMenu.new([ :quit ])

    run_dashboard(menu)

    rows = menu.frames.first[:entries].select { |shortcut, _, _| shortcut.match?(/\d/) }.map { |_, label, _| label }
    assert_equal rows.uniq, rows, "two rows an operator cannot tell apart is an unsafe choice"
    assert(rows.all? { |row| row.start_with?("tiny-demo ·") }, "both are the same project")
    assert_includes rows.join("\n"), "tiny-demo-staging"
    assert_includes rows.join("\n"), "tiny-demo-workspace"
  end

  # Scenario 4: a connection stored before project metadata existed must still be usable, and
  # must fall back VISIBLY to the workspace key rather than to a dash or an invented name.
  def test_a_legacy_record_without_project_metadata_falls_back_to_the_workspace_key
    store_connection("tiny-demo-workspace")
    rewrite_state do |doc|
      doc["connections"].each { |entry| entry["project_slug"] = entry["project_key"] = nil }
    end
    # A record with no project still has ONE identity: the project segment falls back visibly
    # rather than leaving the row unaddressable.
    unknown = selector("tiny-demo-workspace",
                       project_slug: SpecrelayRunner::ConnectionStore::UNKNOWN_PROJECT)
    menu = ScriptedMenu.new([ unknown, :show, :back, :quit ])

    printed = capture_dashboard(menu)

    assert_equal unknown, menu.frames.first[:entries].first[2]
    assert_match(/\Atiny-demo-workspace · specrelay/, menu.frames.first[:entries].first[1])
    assert_equal "#{SpecrelayRunner::Dashboard::TITLE} — tiny-demo-workspace", menu.frames[1][:title]
    assert_match(/Project +—/, printed, "the missing fact is shown as missing, not guessed")
    assert_match(/Workspace +tiny-demo-workspace/, printed)
  end

  def test_the_default_workspace_is_visible_on_the_top_level
    store_connection("tiny-demo-workspace")
    operations.set_default("tiny-demo-workspace")
    menu = ScriptedMenu.new([ :quit ])

    run_dashboard(menu)

    assert_match(/Default workspace: #{Regexp.escape(selector('tiny-demo-workspace'))}/,
                 menu.frames.first[:header].join("\n"))
    assert_match(/\(default\)/, menu.frames.first[:entries].first[1])
    assert_includes menu.frames.first[:entries].map(&:first), "C"
  end

  # CR-001 round 002: with one connection there is no ambiguity to resolve, so the "you need
  # --workspace" advice describes a situation the operator is not in.
  def test_the_no_default_header_matches_how_many_workspaces_are_actually_connected
    store_connection("tiny-demo-workspace")
    sole = ScriptedMenu.new([ :quit ])
    run_dashboard(sole)

    assert_match(/none set \(not needed — only one project is connected\)/,
                 sole.frames.first[:header].join("\n"))

    store_connection("development-workspace", connected_at: "2026-07-27T10:00:00Z")
    several = ScriptedMenu.new([ :quit ])
    run_dashboard(several)

    assert_match(/none set — `loop` needs --workspace while several are connected/,
                 several.frames.first[:header].join("\n"))
  end

  def test_a_dangling_default_is_flagged_on_the_top_level
    store_connection("tiny-demo-workspace")
    operations.set_default("tiny-demo-workspace")
    rewrite_state { |doc| doc["default_workspace_key"] = "gone" }
    menu = ScriptedMenu.new([ :quit ])

    run_dashboard(menu)

    assert_match(/NOT RESOLVABLE/, menu.frames.first[:header].join("\n"))
  end

  def test_quitting_restores_the_terminal
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ :quit ])

    run_dashboard(menu)

    assert_operator menu.restores, :>=, 1
  end

  # Esc and Ctrl-C both arrive as CANCEL from the menu; at the top level that means quit.
  def test_cancelling_at_the_top_level_exits_cleanly
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ SpecrelayRunner::TerminalMenu::CANCEL ])

    assert_equal 0, run_dashboard(menu)
  end

  # --- the detail view ------------------------------------------------------

  def test_opening_a_workspace_shows_every_required_field
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :back, :quit ])

    run_dashboard(menu)

    header = menu.frames[1][:header].join("\n")
    [ "Workspace", "Project", "Platform", "Repository", "Default branch", "Local checkout",
      "Runner", "Connected", "Default workspace", "Last local readiness" ].each do |label|
      assert_match(/#{label}/, header, "the detail view must show #{label}")
    end
    assert_match(/#{Regexp.escape(@checkout)}/, header, "the detail view is where the path belongs")
    assert_match(/rnr_fake/, header)
  end

  def test_the_detail_view_offers_every_required_action
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :back, :quit ])

    run_dashboard(menu)

    values = menu.frames[1][:entries].map { |_, _, value| value }
    assert_equal %i[loop claim_once test show default disconnect_local disconnect_platform back], values
    shortcuts = menu.frames[1][:entries].map(&:first)
    assert_equal shortcuts.uniq, shortcuts, "two actions sharing a shortcut would hide one of them"
  end

  def test_the_default_action_label_reflects_the_current_state
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :default, :back, :quit ])

    run_dashboard(menu)

    assert_match(/Set as the default workspace/, menu.frames[1][:entries][4][1])
    assert_match(/Clear the default workspace/, menu.frames[2][:entries][4][1])
    assert_equal selector("tiny-demo-workspace"), document["default_workspace_key"]
  end

  def test_going_back_returns_to_the_top_level_rather_than_exiting
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :back, :quit ])

    run_dashboard(menu)

    assert_equal [ SpecrelayRunner::Dashboard::TITLE,
                  "#{SpecrelayRunner::Dashboard::TITLE} — tiny-demo  ·  tiny-demo-workspace",
                  SpecrelayRunner::Dashboard::TITLE ],
                 menu.frames.map { |frame| frame[:title] }
  end

  # --- acceptance criterion 5: the same code path as the direct commands ----

  def test_start_loop_dispatches_exactly_the_direct_loop_command
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :loop, :back, :quit ])

    run_dashboard(menu)

    assert_equal [ [ "loop", "--workspace", selector("tiny-demo-workspace") ] ], @dispatched
  end

  def test_claim_once_dispatches_exactly_the_direct_claim_once_command
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :claim_once, :back, :quit ])

    run_dashboard(menu)

    assert_equal [ [ "claim-once", "--workspace", selector("tiny-demo-workspace") ] ], @dispatched
  end

  # The dispatcher handed to the dashboard must be the CLI's OWN one, or "the menu reuses the
  # direct command path" is a claim about a lambda rather than about the product. This drives the
  # real CLI and asserts the real command ran: Platform received the claim poll.
  def test_the_dispatcher_the_cli_injects_really_runs_the_command
    store_connection("tiny-demo-workspace")
    @platform.offer_no_work!
    out = FakeTty.new
    cli = SpecrelayRunner::CLI.new(out: out, err: StringIO.new, env: env, input: FakeTty.new,
                                  secret_store: @secret_store)
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :claim_once, :back, :quit ])
    stub_dashboard_menu(menu) { cli.run([]) }

    assert_equal 1, @platform.requests_to("/api/runner/claim").length
    assert_match(/\$ specrelay-runner claim-once --workspace #{Regexp.escape(selector('tiny-demo-workspace'))}/,
                 out.string)
    assert_match(/connected workspace #{Regexp.escape(selector('tiny-demo-workspace'))}/, out.string)
  end

  def test_a_dispatched_command_runs_in_cooked_mode
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :loop, :back, :quit ])

    run_dashboard(menu)

    assert_operator menu.restores, :>=, 2, "the terminal must be restored before command output"
  end

  # --- the readiness test ---------------------------------------------------

  def test_the_test_action_shows_the_ordered_check_trail_and_the_verdict
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :test, :back, :quit ])

    printed = capture_dashboard(menu)

    assert_match(/claims no work/, printed)
    assert_match(/✓ Local connection entry/, printed)
    assert_match(/✓ Platform workspace grant is ready/, printed)
    assert_match(/is ready/, printed)
    assert_empty @platform.requests_to("/api/runner/claim")
  end

  def test_a_failed_test_shows_one_remedy_and_records_it_in_the_detail_view
    store_connection("tiny-demo-workspace")
    @platform.grants.clear
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :test, :back, :quit ])

    printed = capture_dashboard(menu)

    assert_match(/✗ Platform workspace grant/, printed)
    assert_match(/Remedy: .*new enrollment code/, printed)
    assert_match(/workspace_grant_missing \(tested just now\)/, menu.frames[2][:header].join("\n"))
  end

  # --- local disconnect -----------------------------------------------------

  def test_declining_the_local_disconnect_confirmation_changes_nothing
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :disconnect_local, :back, :quit ],
                            confirmations: [ false ])

    run_dashboard(menu)

    assert_equal [ "tiny-demo-workspace" ], stored_keys
    assert_equal 1, menu.confirmations.length
  end

  # The confirmation must name the repository, not only the key: with several workspaces
  # connected a key alone is easy to misread, and this action is irreversible without a new
  # enrollment code.
  def test_the_local_disconnect_confirmation_names_the_workspace_and_the_repository
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :disconnect_local, :back, :quit ], confirmations: [ false ])

    printed = capture_dashboard(menu)

    assert_match(/tiny-demo-workspace/, menu.confirmations.first)
    assert_match(%r{github.com/SpecRelay/tiny-demo-workspace}, menu.confirmations.first)
    assert_match(/will remove only THIS MACHINE's memory/, printed)
    assert_match(/will NOT remove Platform-side authorization/, printed)
  end

  def test_a_confirmed_local_disconnect_removes_only_that_connection
    store_connection("tiny-demo-workspace")
    store_connection("development-workspace", connected_at: "2026-07-27T10:00:00Z")
    menu = ScriptedMenu.new([ selector("development-workspace"), :disconnect_local, :quit ], confirmations: [ true ])

    run_dashboard(menu)

    assert_equal [ "tiny-demo-workspace" ], stored_keys
    assert_equal 1, menu.confirmations.length, "the credential is still needed, so it is not asked about"
    assert_empty @secret_store.deletes
    # Scenario 30: a LOCAL disconnect is local. Platform still authorizes this runner, and no
    # request may be sent on its behalf — the honest posture the two actions exist to separate.
    assert_empty @platform.requests.reject { |request| request[:path] == "/api/runner/claim" },
                 "a local disconnect must reach Platform not at all"
    assert_equal [ "tiny-demo-workspace" ], @platform.grants
  end

  # Scenario 36. A grant Platform no longer holds is a safe, successful outcome — and the
  # follow-up must still be about the LOCAL entry only, never implying a project or workspace
  # was deleted.
  def test_an_already_absent_platform_grant_is_safe_and_still_offers_local_cleanup
    store_connection("tiny-demo-workspace")
    @platform.grants.clear
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :disconnect_platform, :quit ],
                            confirmations: [ true, true, true ])

    printed = capture_dashboard(menu)

    assert_empty stored_keys, "the operator asked for the local entry to go too"
    assert_match(/Platform confirmed/, menu.confirmations[1])
    refute_match(/deleted the (project|workspace)/i, printed)
    assert_match(/local entry/, menu.confirmations[1])
  end

  # Acceptance criterion 11: the credential question is SEPARATE, and only asked when nothing
  # else depends on it.
  def test_removing_the_last_connection_asks_about_the_credential_separately
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :disconnect_local, :quit ],
                            confirmations: [ true, true ])

    run_dashboard(menu)

    assert_equal 2, menu.confirmations.length
    assert_match(/Keychain/, menu.confirmations.last)
    assert_equal [ RUNNER_ACCOUNT ], @secret_store.deletes
    assert_empty stored_keys
  end

  def test_declining_the_credential_question_still_removes_the_local_entry
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :disconnect_local, :quit ],
                            confirmations: [ true, false ])

    run_dashboard(menu)

    assert_empty stored_keys
    assert_empty @secret_store.deletes, "declining must keep the credential"
    assert @secret_store.stored?(RUNNER_ACCOUNT)
  end

  # --- Platform disconnect --------------------------------------------------

  def test_declining_the_platform_disconnect_confirmation_changes_nothing_anywhere
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :disconnect_platform, :back, :quit ],
                            confirmations: [ false ])

    run_dashboard(menu)

    assert_equal [ "tiny-demo-workspace" ], @platform.grants
    assert_equal [ "tiny-demo-workspace" ], stored_keys
  end

  def test_the_platform_disconnect_warning_scopes_what_it_will_and_will_not_touch
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :disconnect_platform, :back, :quit ], confirmations: [ false ])

    printed = capture_dashboard(menu)

    assert_match(/remove THIS runner's grant for tiny-demo-workspace/, printed)
    assert_match(/runner identity, its credential, and every other connected workspace are\s+unaffected/, printed)
    assert_match(/No project, workspace, Jira connection, run, execution report, or branch\s+is deleted/, printed)
  end

  # Acceptance criterion 12 and the offer that follows it: local removal is a separate question,
  # asked only after Platform confirms.
  def test_a_confirmed_platform_disconnect_then_offers_local_removal
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :disconnect_platform, :quit ],
                            confirmations: [ true, true, true ])

    run_dashboard(menu)

    assert_empty @platform.grants
    assert_empty stored_keys
    assert_match(/Platform confirmed/, menu.confirmations[1])
  end

  def test_declining_local_removal_after_a_platform_disconnect_keeps_the_local_entry
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :disconnect_platform, :back, :quit ],
                            confirmations: [ true, false ])

    printed = capture_dashboard(menu)

    assert_empty @platform.grants
    assert_equal [ "tiny-demo-workspace" ], stored_keys
    assert_match(/Kept the local entry/, printed)
  end

  # Acceptance criterion 13. Deleting local state after a failed Platform call would leave a
  # machine holding authorization it can no longer see.
  def test_a_failed_platform_disconnect_never_deletes_local_state
    store_connection("tiny-demo-workspace")
    @secret_store.write(account: RUNNER_ACCOUNT, credential: "src_no-longer-valid")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :disconnect_platform, :back, :quit ],
                            confirmations: [ true ])

    printed = capture_dashboard(menu)

    assert_equal [ "tiny-demo-workspace" ], stored_keys
    assert_equal [ "tiny-demo-workspace" ], @platform.grants
    assert_match(/Nothing local was changed/, printed)
    assert_equal 1, menu.confirmations.length, "it must not go on to offer local removal"
  end

  # --- secret posture -------------------------------------------------------

  def test_no_dashboard_screen_prints_a_credential
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ selector("tiny-demo-workspace"), :test, :show, :default, :back, :help, :quit ])

    printed = capture_dashboard(menu)
    rendered = printed + menu.frames.map { |f| f[:header].join("\n") + f[:entries].to_s }.join

    refute_includes rendered, CREDENTIAL
    refute_match(/src_|srt_|sre_/, rendered)
  end

  def test_the_help_screen_explains_the_difference_between_the_two_disconnects
    menu = ScriptedMenu.new([ :help, :quit ])

    printed = capture_dashboard(menu)

    assert_match(/Removes this machine's stored connection.*revokes nothing/m, printed)
    assert_match(/never revokes the\s+runner itself/, printed)
  end

  private

  def run_dashboard(menu)
    capture_dashboard(menu)
    @status
  end

  def capture_dashboard(menu)
    out = StringIO.new
    @status = SpecrelayRunner::Dashboard.new(
      operations: operations, out: out, err: StringIO.new, menu: menu,
      dispatch: ->(argv) { @dispatched << argv; 0 }
    ).call
    out.string
  end

  # Runs the CLI's real no-argument path while substituting the scripted menu for the real one,
  # so the dispatcher under test is the CLI's own.
  def stub_dashboard_menu(menu)
    original = SpecrelayRunner::TerminalMenu.method(:new)
    SpecrelayRunner::TerminalMenu.define_singleton_method(:new) { |**| menu }
    yield
  ensure
    SpecrelayRunner::TerminalMenu.define_singleton_method(:new, original)
  end

  def operations
    SpecrelayRunner::ConnectionOperations.new(env: env, secret_store: @secret_store,
                                             platform: "arm64-darwin25")
  end

  def env = { "SPECRELAY_RUNNER_STATE_FILE" => @state_file, "PATH" => ENV.fetch("PATH", "") }

  # The full selector the dashboard puts on a row and hands to every action.
  def selector(workspace_key, project_slug: "tiny-demo")
    "#{@platform.base_url}##{project_slug}/#{workspace_key}"
  end

  def store_connection(workspace_key, connected_at: "2026-07-20T10:00:00Z")
    SpecrelayRunner::ConnectionStore.new(@state_file).save(
      SpecrelayRunner::ConnectionStore::Connection.new(
        base_url: @platform.base_url, runner_id: "host-runner", runner_public_id: "rnr_fake",
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
