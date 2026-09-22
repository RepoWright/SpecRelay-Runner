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
  ALPHA_TASK = "ALPHA-1"
  BETA_TASK = "BETA-1"
  # Bounded so a lane that never stops fails this test instead of hanging the suite.
  LANE_TIMEOUT_SECONDS = 120

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
    teardown_lanes
    [ @alpha, @beta ].each { |platform| platform&.stop }
    [ @dir, @alpha_root, @beta_root ].each do |path|
      FileUtils.remove_entry(path) if path && File.exist?(path)
    end
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

  # --- the real running-session lifecycle -----------------------------------

  # The scenario the earlier no-work `claim-once` walk did not reach: start A's LIVE LOOP, let it
  # claim and execute a real run, stop it with a real SIGINT through its own trap, land back on the
  # menu, run B, stop it, and run A again — all in one process, through the real dashboard and the
  # real CLI.
  #
  # Nothing here reconstructs a configuration to assert against. Every fact is observed where the
  # running session produced it: the credential on the wire at each origin, the raw workspace key in
  # the presence and claim payloads, and the local root in the `bin/worktree` invocations the
  # execution really made inside that project's own checkout.
  #
  # Synchronization is on observed requests, never on a sleep: each lane is stopped once it has
  # polled past its own work.
  def test_a_real_loop_executes_stops_and_the_next_project_runs_in_the_same_process
    prepare_execution_lanes

    run_walk([ alpha_selector, :loop, :back,
               beta_selector, :loop, :back,
               alpha_selector, :loop, :back, :quit ])

    # Each origin ran, and only ever with its own project's credential.
    assert_operator claims(@alpha).length, :>=, 2, "A's loop did not poll"
    assert_operator claims(@beta).length, :>=, 2, "B's loop did not poll"
    assert_equal [ "Bearer #{ALPHA_CREDENTIAL}" ], authorizations(@alpha).uniq
    assert_equal [ "Bearer #{BETA_CREDENTIAL}" ], authorizations(@beta).uniq
  end

  def test_each_running_loop_reports_presence_for_its_own_raw_workspace_key
    prepare_execution_lanes

    run_walk([ alpha_selector, :loop, :back, beta_selector, :loop, :back, :quit ])

    [ @alpha, @beta ].each do |platform|
      keys = platform.requests_to("/api/runner/presence").map { |r| r.dig(:body, "workspace_key") }

      refute_empty keys, "a running session reported no presence"
      assert_equal [ SHARED_KEY ], keys.uniq, "the raw workspace key, not the local selector"
    end
  end

  # The local root, observed where the session actually used it: the project command each execution
  # ran, inside that project's own checkout. Both projects share a workspace key, so a lane that
  # resolved the wrong root would show the other project's task here.
  def test_each_execution_ran_inside_its_own_projects_checkout
    prepare_execution_lanes

    run_walk([ alpha_selector, :loop, :back, beta_selector, :loop, :back, :quit ])

    assert_includes worktree_log(@alpha_root), "create #{ALPHA_TASK}"
    assert_includes worktree_log(@beta_root), "create #{BETA_TASK}"
    refute_includes worktree_log(@alpha_root), BETA_TASK, "A's checkout ran B's task"
    refute_includes worktree_log(@beta_root), ALPHA_TASK, "B's checkout ran A's task"
  end

  def test_switching_between_running_loops_enrolls_nothing
    prepare_execution_lanes

    run_walk([ alpha_selector, :loop, :back, beta_selector, :loop, :back, :quit ])

    [ @alpha, @beta ].each do |platform|
      assert_empty platform.requests_to("/api/runner/enrollment")
      assert_empty platform.requests_to("/api/runner/enrollment_preview")
    end
    assert_equal 2, store.connections.length
  end

  # A running session resolved its connection once. Changing the saved default while it runs is a
  # change to what the NEXT bare invocation picks, and must not retarget the claims this one is
  # still making.
  def test_changing_the_default_while_a_loop_runs_does_not_retarget_its_claims
    prepare_execution_lanes
    @change_default_to = beta_selector

    run_walk([ alpha_selector, :loop, :back, :quit ])

    assert_equal beta_selector, store.default_selector, "the default was not changed mid-session"
    # Everything A's session did, before and after the change, went to A with A's credential.
    assert_operator claims(@alpha).length, :>=, 2
    assert_equal [ "Bearer #{ALPHA_CREDENTIAL}" ], authorizations(@alpha).uniq
    assert_empty @beta.requests, "the running session was retargeted at the new default"
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
    platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: task_id), token: token)
    platform.claim_payload_workspace_key = SHARED_KEY
    platform.start.tap(&:offer_no_work!)
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
    menu = ScriptedMenu.new(selections, confirmations: confirmations, on_select: method(:note_choice))
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
    def initialize(selections, confirmations: [], on_select: nil)
      @selections = selections
      @answers = confirmations
      @on_select = on_select || ->(_choice) { }
    end

    # Being asked again is the proof that whatever was chosen last has finished — which is how the
    # supervisor knows a lane ended without inspecting the loop.
    def select(**)
      raise "the dashboard asked for more input than the script provides" if @selections.empty?

      @on_select.call(:before)
      @selections.shift.tap { |choice| @on_select.call(choice) }
    end

    def confirm(_prompt) = @answers.empty? ? false : @answers.shift
    def pause(_message = nil) = nil
    def clear = nil
    def restore = nil
    def width = 100
  end

  # The supervisor's whole view of the walk: a lane is live from the moment `:loop` is chosen
  # until the menu is asked for the next thing.
  def note_choice(choice)
    case choice
    when :before then @lane_baseline = nil
    when :loop
      @lane_baseline = total_claims
      change_default_mid_session
    end
  end

  # Done while A's loop is already running, which is the only time the claim under test can be
  # made: a default changed before the session starts would simply have been the one it resolved.
  def change_default_mid_session
    return if @change_default_to.nil?

    target = @change_default_to
    @change_default_to = nil
    Thread.new do
      wait_until { total_claims >= @lane_baseline.to_i + 1 }
      store.set_default(target)
    end
  end

  def wait_until(timeout: LANE_TIMEOUT_SECONDS)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  # --- the running-session harness -----------------------------------------

  # Turn both lanes into ones that can really run: a hermetic git workspace per project, one
  # unit of work waiting at each origin, a connector token and a stand-in connector program, and
  # a supervisor that stops each loop once it has polled past its own work.
  def prepare_execution_lanes
    @alpha_root = build_execution_workspace(@alpha_root)
    @beta_root = build_execution_workspace(@beta_root)
    rebind_connection_roots
    install_connector_stand_in
    [ [ @alpha, ALPHA_PUBLIC_ID ], [ @beta, BETA_PUBLIC_ID ] ].each do |platform, public_id|
      @secret_store.write(account: SpecrelayRunner::SecretStore.preview_connector_account_for(public_id),
                          credential: "connector-token-#{public_id}")
      platform.offer_again!
    end
    supervise_lanes
  end

  # A real workspace whose project command records every invocation, which is how "this execution
  # ran in THIS project's checkout" becomes an observed fact rather than an inference.
  def build_execution_workspace(previous)
    FileUtils.remove_entry(previous) if previous && File.exist?(previous)
    root, executor = DemoWorkspace.build
    use_fixture(fixture_directory, executor)
    command = File.join(root, "bin", "worktree")
    logging = "mkdir -p \"$(dirname \"$0\")/../.runs\"\n" \
              "echo \"$*\" >> \"$(dirname \"$0\")/../.runs/worktree.log\"\n"
    source = File.read(command)
    raise "the fixture project command changed shape" unless source.include?("set -u\n")

    File.write(command, source.sub("set -u\n", "set -u\n#{logging}"))
    FileUtils.chmod(0o755, command)
    root
  end

  def worktree_log(root)
    path = File.join(root, ".runs", "worktree.log")
    File.file?(path) ? File.read(path) : ""
  end

  def fixture_directory = @fixture_directory ||= fixture_bin

  # The connection records were stored against the setup roots; the execution lanes replace those
  # checkouts, so the saved connections are rewritten to point at them.
  def rebind_connection_roots
    File.write(@state_file, "")
    store_connection(project: "alpha", platform: @alpha, public_id: ALPHA_PUBLIC_ID,
                     root: @alpha_root, connected_at: "2026-07-20T10:00:00Z")
    store_connection(project: "beta", platform: @beta, public_id: BETA_PUBLIC_ID,
                     root: @beta_root, connected_at: "2026-07-27T10:00:00Z")
  end

  # A stand-in for the connector program, answering its own readiness endpoint the way the real
  # client does. It keeps this test off every external service: nothing here reaches a provider,
  # and the token it is handed is synthetic.
  def install_connector_stand_in
    directory = Dir.mktmpdir("connector-bin")
    path = File.join(directory, "cloudflared")
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      require "socket"
      server = TCPServer.new("127.0.0.1", ARGV[ARGV.index("--metrics") + 1].split(":").last.to_i)
      loop do
        client = server.accept
        ok = client.gets.to_s.include?("/ready")
        client.print("HTTP/1.1 \#{ok ? '200 OK' : '503 Service Unavailable'}\r\n" \
                     "Content-Length: 0\r\nConnection: close\r\n\r\n")
        client.close
      end
    RUBY
    FileUtils.chmod(0o755, path)
    @restore_path = ENV["PATH"]
    ENV["PATH"] = "#{directory}:#{fixture_directory}:#{@restore_path}"
  end

  # Stops each lane with a REAL SIGINT, through the trap the loop installs itself — the same path
  # Ctrl-C takes. The signal is sent only once the lane has polled past its own work, so the loop
  # is provably running and trapped; it is repeated until the lane ends, so a signal that raced the
  # trap cannot hang the walk.
  #
  # A no-op trap is installed for the whole test, and the loop saves and restores it, so a stray
  # signal after a lane has ended cannot terminate the suite.
  def supervise_lanes
    @previous_int_trap = Signal.trap("INT") { nil }
    @finished = false
    @supervisor = Thread.new do
      until @finished
        stop_current_lane if @lane_baseline && total_claims >= @lane_baseline + 2
        sleep 0.1
      end
    end
  end

  def stop_current_lane
    Process.kill("INT", Process.pid)
  rescue Errno::ESRCH
    nil
  end

  def total_claims = [ @alpha, @beta ].sum { |platform| claims(platform).length }

  def teardown_lanes
    @finished = true
    @supervisor&.join(5)
    Signal.trap("INT", @previous_int_trap) if @previous_int_trap
    ENV["PATH"] = @restore_path if @restore_path
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
