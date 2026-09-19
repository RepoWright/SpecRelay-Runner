# frozen_string_literal: true

require_relative "test_helper"

# Switching projects from the menu: A, then B, then back to A, on one machine.
#
# The terminal half of this walk — real raw mode, real keystrokes, the frame at two sizes, and the
# terminal handed back afterwards — is proved under an actual pty in `dashboard_tty_test.rb`. That
# harness deliberately drives the runner through the legacy `--config` path so it never touches the
# developer's Keychain, which means it cannot prove WHICH project a lane used: an explicit config
# wins over the stored connection by design.
#
# So this file proves the other half, in process and against two real HTTP fakes on two origins:
# every lane uses its own project's credential, its own origin, its own raw workspace key and its
# own local checkout, and switching between them enrolls nothing.
#
# The two projects deliberately share the workspace key `shared`. That is the case a machine
# reaches legitimately — Platform scopes a key to a project — and the one where getting routing
# wrong sends a credential, a claim, or a working directory to the wrong project.
class ProjectSwitchingTest < Minitest::Test
  ALPHA_CREDENTIAL = "src_alpha_only_credential"
  BETA_CREDENTIAL = "src_beta_only_credential"
  ALPHA_PUBLIC_ID = "rnr_alpha"
  BETA_PUBLIC_ID = "rnr_beta"
  SHARED_KEY = "shared"
  REPOSITORY = "https://github.com/SpecRelay/tiny-demo-workspace"

  def setup
    @dir = Dir.mktmpdir("project-switching")
    @state_file = File.join(@dir, "connections.json")
    # Each project gets its OWN token, so a request carrying the other project's credential is
    # rejected by the fake rather than quietly accepted.
    @alpha = start_platform("ALPHA-1", ALPHA_CREDENTIAL)
    @beta = start_platform("BETA-1", BETA_CREDENTIAL)
    @alpha_root = git_checkout("alpha")
    @beta_root = git_checkout("beta")
    @secret_store = FakeSecretStore.new(
      entries: { "runner:#{ALPHA_PUBLIC_ID}" => ALPHA_CREDENTIAL,
                 "runner:#{BETA_PUBLIC_ID}" => BETA_CREDENTIAL }
    )
    store_connection(project: "alpha", platform: @alpha, public_id: ALPHA_PUBLIC_ID,
                     root: @alpha_root, connected_at: "2026-07-20T10:00:00Z")
    store_connection(project: "beta", platform: @beta, public_id: BETA_PUBLIC_ID,
                     root: @beta_root, connected_at: "2026-07-27T10:00:00Z")
  end

  def teardown
    [ @alpha, @beta ].each { |platform| platform&.stop }
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # --- the walk -------------------------------------------------------------

  # A, back, B, back, A again — each one a real `claim-once` dispatched by the real menu through
  # the CLI's own dispatcher, exactly as `Start loop` dispatches a loop.
  def test_switching_between_projects_uses_each_ones_own_platform_and_credential
    run_walk([ alpha_selector, :claim_once, :back,
               beta_selector, :claim_once, :back,
               alpha_selector, :claim_once, :back, :quit ])

    assert_equal 2, claims(@alpha).length, "alpha did not receive both of its claims"
    assert_equal 1, claims(@beta).length, "beta did not receive exactly its own claim"
    # Each origin only ever saw its own project's credential.
    assert_equal [ "Bearer #{ALPHA_CREDENTIAL}" ], authorizations(@alpha).uniq
    assert_equal [ "Bearer #{BETA_CREDENTIAL}" ], authorizations(@beta).uniq
  end

  def test_no_lane_presents_another_projects_credential_anywhere
    run_walk([ alpha_selector, :claim_once, :back, beta_selector, :claim_once, :back, :quit ])

    refute_includes authorizations(@alpha), "Bearer #{BETA_CREDENTIAL}"
    refute_includes authorizations(@beta), "Bearer #{ALPHA_CREDENTIAL}"
  end

  # Switching is selection, never re-enrollment: the operator keeps both saved connections and is
  # never sent back for another one-time code.
  def test_switching_enrolls_nothing_and_keeps_both_connections
    run_walk([ alpha_selector, :claim_once, :back, beta_selector, :claim_once, :back, :quit ])

    [ @alpha, @beta ].each do |platform|
      assert_empty platform.requests_to("/api/runner/enrollment")
      assert_empty platform.requests_to("/api/runner/enrollment_preview")
    end
    assert_equal 2, store.connections.length
    assert_equal %w[alpha beta], store.connections.map(&:project_slug).sort
  end

  def test_each_lane_announces_the_project_it_is_really_running
    printed = run_walk([ alpha_selector, :claim_once, :back, beta_selector, :claim_once, :back, :quit ])

    assert_includes printed, "--workspace #{alpha_selector}"
    assert_includes printed, "--workspace #{beta_selector}"
    assert_includes printed, "Platform: #{@alpha.base_url}"
    assert_includes printed, "Platform: #{@beta.base_url}"
  end

  # --- what each lane is bound to ------------------------------------------

  # The raw workspace key still goes to Platform — the selector is a LOCAL label — and each
  # project's key resolves to its own checkout even though both keys are the same string.
  def test_each_project_keeps_its_own_raw_workspace_key_and_local_root
    alpha = config_for(alpha_selector)
    beta = config_for(beta_selector)

    assert_equal SHARED_KEY, alpha.connection.workspace_key
    assert_equal SHARED_KEY, beta.connection.workspace_key
    assert_equal @alpha_root, alpha.workspace_root(SHARED_KEY, env: {})
    assert_equal @beta_root, beta.workspace_root(SHARED_KEY, env: {})
    refute_equal alpha.workspace_root(SHARED_KEY, env: {}), beta.workspace_root(SHARED_KEY, env: {})
  end

  def test_each_lane_resolves_only_its_own_registrations_credential
    assert_equal ALPHA_CREDENTIAL, resolved_token(alpha_selector)
    assert_equal BETA_CREDENTIAL, resolved_token(beta_selector)
  end

  # A running session resolved its connection once, at the start. Changing the saved default
  # afterwards is a change to what the NEXT bare invocation picks, and must not retarget work
  # already under way.
  def test_changing_the_default_does_not_retarget_an_already_resolved_session
    running = config_for(alpha_selector)

    store.set_default(beta_selector)

    assert_equal @alpha.base_url, running.base_url
    assert_equal ALPHA_CREDENTIAL, running.resolve_auth(env: {}).token
    assert_equal @alpha_root, running.workspace_root(SHARED_KEY, env: {})
  end

  # And an explicit selection keeps beating the default, so the operator who names a project gets
  # that project whatever the default now says.
  def test_an_explicit_selection_still_wins_over_a_changed_default
    store.set_default(beta_selector)
    run_walk([ alpha_selector, :claim_once, :back, :quit ])

    assert_equal 1, claims(@alpha).length
    assert_empty claims(@beta)
  end

  # --- disconnecting one project leaves the other whole ---------------------

  # The confirmed menu flow, on B only. A keeps its registration, its credential, its explicit
  # default and its ability to start — which is the whole point of holding several connections.
  def test_disconnecting_one_project_leaves_the_other_able_to_start
    store.set_default(alpha_selector)
    run_walk([ beta_selector, :disconnect_local, :quit ], confirmations: [ true ])

    assert_equal [ "alpha" ], store.connections.map(&:project_slug)
    assert_equal alpha_selector, store.default_selector, "A's explicit default was disturbed"
    assert @secret_store.stored?("runner:#{ALPHA_PUBLIC_ID}"), "A's credential was removed"
    # B's own secret is KEPT unless the operator asked for it, and B's Platform grant is untouched.
    assert @secret_store.stored?("runner:#{BETA_PUBLIC_ID}")
    assert_empty @beta.requests, "a local disconnect must not reach Platform"

    run_walk([ alpha_selector, :claim_once, :back, :quit ])

    assert_equal 1, claims(@alpha).length, "A could not start after B was disconnected"
  end

  # Nothing any of these screens prints is a credential, on either the success or the failure path.
  def test_no_screen_in_the_switch_or_disconnect_flow_prints_a_credential
    printed = run_walk([ alpha_selector, :claim_once, :back,
                         beta_selector, :disconnect_local, :quit ], confirmations: [ true ])

    refute_includes printed, ALPHA_CREDENTIAL
    refute_includes printed, BETA_CREDENTIAL
  end

  private

  def start_platform(task_id, token)
    FakePlatform.new(claim_payload: claim_payload_for(task_id: task_id), token: token)
                .tap(&:start).tap(&:offer_no_work!)
  end

  def store = SpecrelayRunner::ConnectionStore.new(@state_file)

  def selector_for(project, platform) = "#{platform.base_url}##{project}/#{SHARED_KEY}"
  def alpha_selector = selector_for("alpha", @alpha)
  def beta_selector = selector_for("beta", @beta)

  def claims(platform) = platform.requests_to("/api/runner/claim")
  def authorizations(platform) = platform.requests.map { |request| request.dig(:headers, "authorization") }

  # The credential this lane would really authenticate with, through the same precedence rule the
  # claim path uses rather than by reading the stored value back.
  def resolved_token(selector) = config_for(selector).resolve_auth(env: {}).token

  # The same resolution the claim path performs, so what is asserted is what would really run.
  def config_for(selector)
    connection = store.resolve(selector).connection
    credential = @secret_store.read(account: SpecrelayRunner::SecretStore.account_for_runner(connection.runner_public_id))
    SpecrelayRunner::Config.from_connection(connection, credential: credential)
  end

  # Drive the real Dashboard with scripted selections, dispatching through the real CLI.
  def run_walk(selections, confirmations: [])
    out = StringIO.new
    menu = ScriptedMenu.new(selections, confirmations: confirmations)
    cli = SpecrelayRunner::CLI.new(out: out, err: StringIO.new, env: env, input: StringIO.new,
                                   secret_store: @secret_store)
    SpecrelayRunner::Dashboard.new(
      operations: SpecrelayRunner::ConnectionOperations.new(env: env, secret_store: @secret_store,
                                                            platform: "arm64-darwin25"),
      dispatch: ->(argv) { cli.run(argv) }, out: out, err: StringIO.new, menu: menu
    ).call
    out.string
  end

  def env = { "SPECRELAY_RUNNER_STATE_FILE" => @state_file, "PATH" => ENV.fetch("PATH", "") }

  # A minimal stand-in for TerminalMenu: this file is about which project a lane runs, and the
  # real menu's rendering and raw mode are proved under a pty elsewhere.
  class ScriptedMenu
    def initialize(selections, confirmations: [])
      @selections = selections
      @answers = confirmations
    end

    def select(**)
      raise "the dashboard asked for more input than the script provides" if @selections.empty?

      @selections.shift
    end

    def confirm(_prompt) = @answers.empty? ? false : @answers.shift
    def pause(_message = nil) = nil
    def clear = nil
    def restore = nil
    def width = 100
  end

  def store_connection(project:, platform:, public_id:, root:, connected_at:)
    SpecrelayRunner::ConnectionStore.new(@state_file).save(
      SpecrelayRunner::ConnectionStore::Connection.new(
        base_url: platform.base_url, runner_id: "host-runner-#{project}",
        runner_public_id: public_id, runner_display_name: "host runner",
        project_slug: project, workspace_key: SHARED_KEY, project_key: project,
        workspace_display_name: "#{project} workspace", repository_url: REPOSITORY,
        default_branch: "main", local_path: root, connected_at: connected_at
      )
    )
  end

  def git_checkout(name)
    path = File.join(@dir, name)
    FileUtils.mkdir_p(path)
    run_git(path, %w[init --initial-branch main])
    run_git(path, [ "remote", "add", "origin", REPOSITORY ])
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
