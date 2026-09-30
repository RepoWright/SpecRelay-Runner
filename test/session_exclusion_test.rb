# frozen_string_literal: true

require_relative "test_helper"

# Which work-running sessions may run together on one OS account.
#
# Platform keeps one presence session and one active execution per REGISTERED RUNNER, and a
# machine holds a separate registration per project. Two terminals working for two SAVED
# connections of different registrations therefore meet nothing shared on the server, and each
# keeps its own project, credential, root and provider children. Two terminals for the SAME
# registration would overwrite each other's presence, so they may not run together.
#
# A saved connection names its registration by the Platform-issued public id it stores, which
# survives reconnect and credential rotation. A hand-written config has no such identity — its
# declared id is the client's own claim — so a session started from one runs alone.
#
# What the tests below have to prove is narrow and exact:
#
#   - two saved connections of different registrations run at the same time, and stopping one
#     leaves the other running;
#   - a second saved session of the same registration — through another saved workspace, or after
#     the credential was rotated — is refused before anything the first would observe;
#   - a hand-written-config session and any other session refuse each other in both start orders,
#     whatever config path, declared id or credential the second one uses;
#   - a failed selection takes no lock, and every ending releases exactly what was acquired.
#
# The contention cases run REAL processes. Two threads in one process share a file description
# and would prove nothing about two operators' terminals.
class SessionExclusionTest < Minitest::Test
  RUNNER_BINARY = File.expand_path("../bin/specrelay-runner", __dir__)
  RUBY_BIN = RbConfig.ruby
  # Bounded so a lock that never releases fails this test rather than hanging the suite.
  WAIT_TIMEOUT_SECONDS = 30
  ORIGIN = "http://platform.test"

  def setup
    @home = Dir.mktmpdir("runner-home")
    @state_file = File.join(@home, "connections.json")
    @secrets_file = File.join(@home, "secrets.json")
    @platforms = []
    @children = []
    @connections = []
    @secrets = {}
    @config_credentials = {}
    File.write(@secrets_file, "{}")
  end

  def teardown
    @children.dup.each { |pid| stop_process(pid) }
    @platforms.each(&:stop)
  end

  # Only the variable a config names can authenticate; the defaults are cleared.
  def env(overrides = {})
    { "HOME" => @home, "PATH" => ENV["PATH"].to_s, "SPECRELAY_RUNNER_STATE_FILE" => @state_file,
      "SPECRELAY_RUNNER_CONFIG" => nil, "SPECRELAY_RUNNER_CREDENTIAL" => nil,
      "SPECRELAY_RUNNER_API_TOKEN" => nil }.merge(overrides)
  end

  # --- the lock itself ------------------------------------------------------

  def saved(public_id, origin: ORIGIN)
    SpecrelayRunner::SessionLock.saved(base_url: origin, runner_public_id: public_id, env: env)
  end

  def exclusive = SpecrelayRunner::SessionLock.exclusive(env: env)

  def registration_path(origin, public_id, environment = env)
    SpecrelayRunner::SessionLock.registration_path(base_url: origin, runner_public_id: public_id, env: environment)
  end

  def test_the_gate_and_the_registration_locks_live_under_the_local_users_home
    assert_equal File.join(@home, ".specrelay/runner/session.lock"), SpecrelayRunner::SessionLock.path(env: env)
    path = registration_path(ORIGIN, "rnr_alpha")

    assert_equal File.join(@home, ".specrelay/runner/sessions"), File.dirname(path)
    assert_match(/\A\h{64}\.lock\z/, File.basename(path))
  end

  # One registration is one stored public id on one Platform: a path or trailing slash on the same
  # origin is the same registration, another public id or another Platform is not, and nothing
  # else the invocation points at moves it.
  def test_the_registration_lock_follows_the_stored_public_id_and_nothing_else
    moved = env("SPECRELAY_RUNNER_STATE_FILE" => File.join(Dir.mktmpdir("other"), "connections.json"),
                "SPECRELAY_RUNNER_CONFIG" => "/tmp/other.yml", "PWD" => Dir.mktmpdir("cwd"))

    assert_equal registration_path(ORIGIN, "rnr_alpha"), registration_path("#{ORIGIN}/", "rnr_alpha", moved)
    refute_equal registration_path(ORIGIN, "rnr_alpha"), registration_path(ORIGIN, "rnr_beta")
    refute_equal registration_path(ORIGIN, "rnr_alpha"), registration_path("http://other-platform.test", "rnr_alpha")
  end

  def test_saved_sessions_of_different_registrations_hold_together
    with_holder("saved", "rnr_alpha") do
      assert_equal :beta, saved("rnr_beta").hold { :beta }
    end
  end

  def test_a_saved_session_of_the_same_registration_is_refused
    with_holder("saved", "rnr_alpha") do
      refused = assert_raises(SpecrelayRunner::SessionLock::Busy) { saved("rnr_alpha").hold { flunk "ran" } }

      assert_match(/for this Runner registration is already running/, refused.message)
    end
  end

  def test_an_exclusive_session_and_a_saved_one_refuse_each_other
    with_holder("saved", "rnr_alpha") do
      refused = assert_raises(SpecrelayRunner::SessionLock::Busy) { exclusive.hold { flunk "ran" } }

      assert_match(/hand-written config runs only alone/, refused.message)
      refute_match(/registration/, refused.message)
    end
    with_holder("exclusive") do
      refused = assert_raises(SpecrelayRunner::SessionLock::Busy) { saved("rnr_beta").hold { flunk "ran" } }

      assert_match(/hand-written config is already running/, refused.message)
      refute_match(/registration/, refused.message)
      assert_raises(SpecrelayRunner::SessionLock::Busy) { exclusive.hold { flunk "ran" } }
    end
  end

  # A saved session that gets the gate but not its registration must hand the gate back, or it
  # would keep a later hand-written session out after it had already been refused.
  def test_a_partly_acquired_session_releases_what_it_took
    with_holder("saved", "rnr_alpha") do
      assert_raises(SpecrelayRunner::SessionLock::Busy) { saved("rnr_alpha").hold { flunk "ran" } }
    end

    assert_equal 0, run_holder_once("exclusive"), "the refused session kept the gate"
  end

  def test_every_ending_releases_both_modes
    [ -> { saved("rnr_alpha") }, -> { exclusive } ].each do |lock|
      lock.call.hold { :done }
      assert_raises(RuntimeError) { lock.call.hold { raise "startup failed" } }
      assert_raises(Interrupt) { lock.call.hold { raise Interrupt } }

      assert_equal 0, run_holder_once("exclusive"), "a released session still held the gate"
      assert_equal 0, run_holder_once("saved", "rnr_alpha"), "a released session still held its registration"
    end
    assert File.file?(SpecrelayRunner::SessionLock.path(env: env)), "releasing removed the gate file"
  end

  # A provider or connector the session launches must not inherit either descriptor. If it did,
  # an orphaned child outliving the runner would keep the session claimed with nothing to Ctrl-C.
  def test_a_surviving_child_process_retains_neither_lock
    stop = File.join(@home, "child-stop")
    child = saved("rnr_alpha").hold do
      Process.spawn(RUBY_BIN, "-e", "sleep 0.05 until File.exist?(#{stop.inspect})")
    end

    assert_equal 0, run_holder_once("exclusive"), "the child kept the gate"
    assert_equal 0, run_holder_once("saved", "rnr_alpha"), "the child kept the registration"
  ensure
    File.write(stop, "go")
    Process.waitpid(child) if child
  end

  # --- saved connections, as real processes ----------------------------------

  # Scenarios 1 and 6: two saved connections of two registrations both reach their polling, each
  # against its own Platform with its own output. Stopping one leaves the other polling, and the
  # stopped registration can start again while the other still runs.
  def test_two_saved_registrations_loop_together_and_stop_independently
    alpha = saved_connection("alpha")
    beta = saved_connection("beta")
    alpha_loop = spawn_saved_loop(alpha)
    wait_for { claims(alpha[:platform]) >= 1 }
    beta_loop = spawn_saved_loop(beta)
    wait_for { claims(beta[:platform]) >= 1 }

    assert running?(alpha_loop[:pid]), "the first registration's loop stopped when the second started"

    stop_process(alpha_loop[:pid])
    polled = claims(beta[:platform])
    wait_for { claims(beta[:platform]) > polled }

    assert running?(beta_loop[:pid]), "stopping one registration stopped the other"
    assert_includes File.read(alpha_loop[:stdout]), alpha[:workspace_key]
    refute_includes File.read(alpha_loop[:stdout]), beta[:workspace_key]
    assert_includes File.read(beta_loop[:stdout]), beta[:workspace_key]

    restarted = run_saved([ "claim-once", "--workspace", alpha[:workspace_key] ])

    assert_equal 0, restarted[:status], restarted[:stderr]
  end

  # Scenario 2: each saved registration claims and executes its own ticket at the same time. Each
  # executor waits for the other to have started before it finishes, so both runs can only
  # complete if the two provider processes really ran side by side.
  def test_two_saved_registrations_execute_their_own_tickets_concurrently
    markers = Dir.mktmpdir("executors")
    lanes = %w[alpha beta].map do |name|
      root, = DemoWorkspace.build
      lane = saved_connection(name, root: root, work: "DEMO-#{name.upcase}")
      peer = name == "alpha" ? "beta" : "alpha"
      lane.merge(path: fixture_path(handshake_executor(root, markers, name, peer), base: saved_path))
    end

    started = lanes.map do |lane|
      spawn_saved([ "claim-once", "--workspace", lane[:workspace_key] ], lane[:name],
                  overrides: { "PATH" => lane[:path] })
    end
    results = started.map { |process| finish(process) }

    lanes.zip(results).each do |lane, result|
      assert_equal 0, result[:status], "#{lane[:name]}: #{result[:stdout]}#{result[:stderr]}"
      assert_equal 1, lane[:platform].requests_to("/api/runner/reports").size
      assert_includes result[:stdout], "DEMO-#{lane[:name].upcase}"
    end
  end

  # Scenario 3: another saved workspace of the same registration is the same registration.
  def test_another_saved_workspace_of_the_same_registration_is_refused_before_any_side_effect
    alpha = saved_connection("alpha")
    second = saved_connection("alpha-second", platform: alpha[:platform], public_id: alpha[:public_id])

    assert_refused_while_held(spawn_saved_loop(alpha), alpha[:platform],
                              ->(command) { [ run_saved([ command, "--workspace", second[:workspace_key] ]) ] },
                              message: /for this Runner registration is already running/)
  end

  # Scenario 3: rotating the credential keeps the registration, so it keeps the lock too. The one
  # fake Platform stands for that one registration and accepts both its old and its new credential.
  def test_a_rotated_credential_of_the_same_registration_is_refused_before_any_side_effect
    alpha = saved_connection("alpha")
    holder = spawn_saved_loop(alpha)
    wait_for { claims(alpha[:platform]) >= 1 }
    store_secret(SpecrelayRunner::SecretStore.account_for_runner(alpha[:public_id]), FakePlatform::ISSUED_CREDENTIAL)

    assert_refused_while_held(holder, alpha[:platform],
                              ->(command) { [ run_saved([ command, "--workspace", alpha[:workspace_key] ]) ] },
                              message: /for this Runner registration is already running/)
  end

  # --- hand-written configs, as real processes -------------------------------

  # Scenario 4: a hand-written config — through --config or the config-path variable, with its own
  # credential and declared id — is refused while a saved session runs.
  def test_a_hand_written_config_is_refused_while_a_saved_session_runs
    alpha = saved_connection("alpha")
    other = idle_platform
    config = config_for(other, "alpha-runner")

    attempt = lambda do |command|
      explicit = run_config([ command, "--config", config ])
      selected = run_config([ command ], overrides: { "SPECRELAY_RUNNER_CONFIG" => config })
      assert_empty other.requests, "the refused config reached its Platform"
      [ explicit, selected ]
    end
    assert_refused_while_held(spawn_saved_loop(alpha), alpha[:platform], attempt,
                              message: /hand-written config runs only alone/)
  end

  # Scenario 4, reversed: a saved session is refused while a hand-written one runs, and the saved
  # one can start once the hand-written session has been interrupted.
  def test_a_saved_session_is_refused_while_a_hand_written_one_runs
    alpha = saved_connection("alpha")
    platform = idle_platform
    holder = spawn_config_loop(config_for(platform, "any-runner"))

    attempt = lambda do |command|
      refused = run_saved([ command, "--workspace", alpha[:workspace_key] ])
      assert_empty alpha[:platform].requests, "the refused saved session reached its Platform"
      [ refused ]
    end
    assert_refused_while_held(holder, platform, attempt, message: /hand-written config is already running/)

    stop_process(holder[:pid])
    released = run_saved([ "claim-once", "--workspace", alpha[:workspace_key] ])

    assert_equal 0, released[:status], released[:stderr]
  end

  # Scenario 5: two hand-written configs refuse each other whatever path, declared id and
  # credential the second one uses.
  def test_a_second_hand_written_config_is_refused
    platform = idle_platform
    other = idle_platform

    attempt = lambda do |command|
      refused = run_config([ command, "--config", config_for(other, "renamed-runner") ])
      assert_empty other.requests, "the refused config reached its Platform"
      [ refused ]
    end
    assert_refused_while_held(spawn_config_loop(config_for(platform, "alpha-runner")), platform, attempt,
                              message: /hand-written config runs only alone/)
  end

  # --- selection, startup and the lock path ----------------------------------

  # A selection that cannot be resolved names nothing to lock, so it reports its own problem even
  # while a hand-written session — which excludes everything — is running. A saved connection with
  # no stored public id cannot name its registration and fails closed the same way.
  def test_a_failed_selection_takes_no_lock_and_reports_itself
    platform = idle_platform
    spawn_config_loop(config_for(platform, "any-runner"))
    wait_for { claims(platform) >= 1 }
    anonymous = saved_connection("anonymous", public_id: "")

    missing = run_config([ "claim-once", "--config", File.join(@home, "absent.yml") ])
    unidentified = run_saved([ "claim-once", "--workspace", anonymous[:workspace_key] ])
    File.write(@state_file, "")
    unconnected = run_saved([ "loop" ])

    assert_equal SpecrelayRunner::CLI::USAGE_ERROR, missing[:status]
    assert_match(/Invalid runner config/, missing[:stderr])
    assert_equal SpecrelayRunner::CLI::USAGE_ERROR, unidentified[:status], unidentified[:stderr]
    assert_match(/no stored credential/, unidentified[:stderr])
    assert_empty anonymous[:platform].requests
    assert_equal SpecrelayRunner::CLI::USAGE_ERROR, unconnected[:status]
    assert_match(/not connected to a workspace/, unconnected[:stderr])
    [ missing, unidentified, unconnected ].each { |result| refute_match(/already running/i, result[:stderr]) }
  end

  # A startup failure inside the session — here the selected provider is not installed — ends the
  # invocation before any claim and frees the gate for the next one.
  def test_a_startup_failure_releases_the_session
    platform = idle_platform

    failed = run_config([ "claim-once", "--config", config_for(platform, "alpha-runner", provider: "claude") ],
                        overrides: { "PATH" => "/usr/bin:/bin" })
    retried = run_config([ "claim-once", "--config", config_for(platform, "alpha-runner") ])

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, failed[:status], failed[:stdout] + failed[:stderr]
    assert_match(/not ready on this host/, failed[:stderr])
    assert_equal 0, retried[:status], retried[:stderr]
    assert_equal 1, claims(platform)
  end

  def test_listing_and_help_are_not_execution_sessions
    platform = idle_platform
    spawn_config_loop(config_for(platform, "any-runner"))
    wait_for { claims(platform) >= 1 }

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_config([ "connections", "list" ])[:status]
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_config([ "help" ])[:status]
  end

  # A regular file where the lock's directory belongs. `flock` never gets a chance, so the session
  # cannot be acquired for a reason that is neither "free" nor "held" — an expected environment
  # failure the command must report, not an exception that escapes the CLI with no message.
  def test_an_unopenable_lock_path_is_an_expected_failure_with_no_platform_request
    platform = idle_platform
    config = config_for(platform, "alpha-runner")
    File.write(File.join(@home, ".specrelay"), "not a directory")

    %w[loop claim-once].each do |command|
      result = run_config([ command, "--config", config ])

      assert_equal SpecrelayRunner::CLI::USAGE_ERROR, result[:status], "#{command}: #{result[:stderr]}"
      assert_match(/session lock/, result[:stderr])
      assert_match(/directory exists and this user can write to it/, result[:stderr])
      assert_equal "", result[:stdout]
    end
    assert_empty platform.requests, "the refused command reached Platform"

    File.delete(File.join(@home, ".specrelay"))

    assert_equal 0, run_config([ "claim-once", "--config", config ])[:status]
  end

  private

  # Hold `holder` paused, so every Platform request in the window is the second invocation's, try
  # both work-running commands — `attempt` returns every result it produced — and check the holder
  # carries on afterwards.
  def assert_refused_while_held(holder, platform, attempt, message:)
    wait_for { claims(platform) >= 1 }
    Process.kill("STOP", holder[:pid])
    before = platform.requests.size
    %w[claim-once loop].each do |command|
      attempt.call(command).each do |refused|
        assert_equal SpecrelayRunner::CLI::RUN_FAILED, refused[:status], "#{command} was not refused: #{refused[:stderr]}"
        assert_match(message, refused[:stderr])
        assert_includes refused[:stderr], "kill -CONT #{holder[:pid]}"
        assert_equal "", refused[:stdout], "#{command} announced or probed before refusing"
      end
    end
    assert_equal before, platform.requests.size, "a refused invocation reached the holder's Platform"
    Process.kill("CONT", holder[:pid])
    polled = claims(platform)
    wait_for { claims(platform) > polled }

    assert running?(holder[:pid]), "the holding session stopped"
  end

  def start_platform(claim_payload)
    platform = FakePlatform.new(claim_payload: claim_payload, token: "src_#{SecureRandom.hex(16)}")
    @platforms << platform.start
    platform
  end

  def idle_platform
    platform = start_platform(claim_payload_for(task_id: "DEMO-IDLE"))
    platform.offer_no_work!
    platform
  end

  def claims(platform) = platform.requests_to("/api/runner/claim").size

  # The one credential a fake Platform accepts besides the fake's issued one.
  def credential_of(platform) = platform.instance_variable_get(:@token)

  # One saved connection record, its credential and its preview-connector token in the fake secret
  # store, and — unless given — a Platform of its own that accepts only that credential.
  def saved_connection(name, platform: nil, public_id: "rnr_#{name}", root: Dir.mktmpdir("root"), work: nil)
    platform ||= work ? start_platform(claim_payload_for(task_id: work, root: root)) : idle_platform
    workspace_key = "#{name}-workspace"
    platform.claim_payload_workspace_key = workspace_key if work
    unless public_id.empty?
      store_secret(SpecrelayRunner::SecretStore.account_for_runner(public_id), credential_of(platform))
      store_secret(SpecrelayRunner::SecretStore.preview_connector_account_for(public_id), "connector-#{name}")
    end
    @connections << { "base_url" => platform.base_url, "runner_id" => "#{name}-runner",
                      "runner_public_id" => public_id, "runner_display_name" => "#{name} runner",
                      "project_slug" => name, "workspace_key" => workspace_key,
                      "repository_url" => "https://github.com/SpecRelay/tiny-demo-workspace",
                      "default_branch" => "main", "local_path" => root, "connected_at" => "2026-09-30T00:00:00Z" }
    File.write(@state_file, JSON.generate("version" => SpecrelayRunner::ConnectionStore::VERSION,
                                          "connections" => @connections))
    File.chmod(0o600, @state_file)
    { name: name, platform: platform, public_id: public_id, workspace_key: workspace_key }
  end

  def store_secret(account, value)
    @secrets[account] = value
    File.write(@secrets_file, JSON.generate(@secrets))
  end

  # A fresh config FILE per call. It presents that Platform's credential through its own variable.
  def config_for(platform, runner_id, provider: nil)
    variable = "RUNNER_CREDENTIAL_#{platform.port}"
    @config_credentials[variable] = credential_of(platform)
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{platform.base_url}
      runner:
        id: #{runner_id}
        display_name: #{runner_id} display
        credential_env: #{variable}
        #{provider ? "executor: { provider: #{provider} }" : ''}
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{Dir.mktmpdir('root')}
    YAML
    path
  end

  # An executor that records its own start and finishes only once the other registration's
  # executor has started too, then makes the edit the demo workspace's test checks for.
  def handshake_executor(root, markers, name, peer)
    path = File.join(root, "bin", "handshake-executor")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      File.write(#{File.join(markers, name).inspect}, "started")
      deadline = Time.now + #{WAIT_TIMEOUT_SECONDS}
      sleep 0.05 until File.exist?(#{File.join(markers, peer).inspect}) || Time.now > deadline
      abort "the #{peer} executor never ran alongside this one" unless File.exist?(#{File.join(markers, peer).inspect})
      file = "demo-app/index.html"
      File.write(file, File.read(file).gsub("Hello Demo", "Hello SpecRelay Demo"))
      #{DemoWorkspace.selection_snippet}
      exit 0
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end

  # The real CLI in its own process, with the file-backed fake secret store in place of the
  # Keychain — the one seam the in-process suites also replace — so a saved connection resolves
  # its credential without touching the developer's real Keychain.
  def saved_driver
    @saved_driver ||= File.join(@home, "saved-runner.rb").tap do |path|
      File.write(path, <<~RUBY)
        require_relative #{File.expand_path('../lib/specrelay_runner', __dir__).inspect}
        require_relative #{File.expand_path('support/fake_secret_store', __dir__).inspect}
        require "json"
        store = FakeSecretStore.new(entries: JSON.parse(File.read(#{@secrets_file.inspect})))
        exit SpecrelayRunner::CLI.new(secret_store: store).run(ARGV)
      RUBY
    end
  end

  # A stand-in for the preview connector program, answering its own readiness endpoint, so a saved
  # loop reaches no external service. The provider status probe finds no provider on this PATH.
  def saved_path
    @saved_path ||= begin
      directory = Dir.mktmpdir("connector-bin")
      path = File.join(directory, "cloudflared")
      File.write(path, <<~RUBY)
        #!#{RUBY_BIN}
        require "socket"
        server = TCPServer.new("127.0.0.1", ARGV[ARGV.index("--metrics") + 1].split(":").last.to_i)
        loop do
          client = server.accept
          client.print("HTTP/1.1 200 OK\\r\\nContent-Length: 0\\r\\nConnection: close\\r\\n\\r\\n")
          client.close
        end
      RUBY
      FileUtils.chmod(0o755, path)
      "#{directory}:/usr/bin:/bin:/usr/sbin"
    end
  end

  def spawn_saved(argv, label, overrides: {})
    spawn_process([ RUBY_BIN, saved_driver, *argv ], label, { "PATH" => saved_path }.merge(overrides))
  end

  def spawn_saved_loop(connection)
    spawn_saved([ "loop", "--workspace", connection[:workspace_key], "--poll-interval", "5" ],
                "#{connection[:name]}-loop")
  end

  def spawn_config_loop(config)
    spawn_process([ RUBY_BIN, RUNNER_BINARY, "loop", "--config", config, "--poll-interval", "5" ], "config-loop", {})
  end

  def run_saved(argv) = finish(spawn_saved(argv, "saved-#{SecureRandom.hex(4)}"))

  def run_config(argv, overrides: {})
    finish(spawn_process([ RUBY_BIN, RUNNER_BINARY, *argv ], "config-#{SecureRandom.hex(4)}", overrides))
  end

  def spawn_process(argv, label, overrides)
    stdout = File.join(@home, "#{label}.out")
    stderr = File.join(@home, "#{label}.err")
    pid = Process.spawn(env(@config_credentials).merge(overrides), *argv, in: File::NULL, out: stdout, err: stderr)
    @children << pid
    { pid: pid, stdout: stdout, stderr: stderr }
  end

  def finish(started)
    deadline = monotonic + (WAIT_TIMEOUT_SECONDS * 2)
    status = nil
    until (status = Process.waitpid2(started[:pid], Process::WNOHANG)&.last)
      raise "the runner did not finish within #{WAIT_TIMEOUT_SECONDS * 2}s" if monotonic > deadline

      sleep 0.05
    end
    @children.delete(started[:pid])
    { status: status.exitstatus, stdout: File.read(started[:stdout]), stderr: File.read(started[:stderr]) }
  end

  def running?(pid) = Process.waitpid(pid, Process::WNOHANG).nil?

  def stop_process(pid)
    Process.kill("CONT", pid)
    Process.kill("INT", pid)
    Process.waitpid(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    @children.delete(pid)
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def wait_for(timeout: WAIT_TIMEOUT_SECONDS)
    deadline = monotonic + timeout
    until yield
      raise "condition was not met within #{timeout}s" if monotonic > deadline

      sleep 0.02
    end
  end

  # A lock taken in ANOTHER process, because `flock` is per file description: a second `flock` on
  # the same description in this process would be granted and prove nothing. Without `release` it
  # lets go at once, so its exit status says whether the lock was free.
  def holder_script(mode, public_id, started, release)
    saved = "saved(base_url: #{ORIGIN.inspect}, runner_public_id: #{public_id.inspect}, env: ENV)"
    lock = mode == "saved" ? saved : "exclusive(env: ENV)"
    wait = release ? "sleep 0.05 until File.exist?(#{release.inspect})" : ""
    <<~RUBY
      require_relative #{File.expand_path('../lib/specrelay_runner', __dir__).inspect}
      SpecrelayRunner::SessionLock.#{lock}.hold do
        File.write(#{started.inspect}, "held")
        #{wait}
      end
    RUBY
  end

  def with_holder(mode, public_id = nil)
    started = File.join(@home, "holder-started")
    release = File.join(@home, "holder-release")
    [ started, release ].each { |path| FileUtils.rm_f(path) }
    script = File.join(@home, "holder.rb")
    File.write(script, holder_script(mode, public_id, started, release))
    pid = Process.spawn(env, RUBY_BIN, script)
    wait_for { File.exist?(started) }
    yield
  ensure
    File.write(release, "go")
    Process.waitpid(pid) if pid
  end

  def run_holder_once(mode, public_id = nil)
    script = File.join(@home, "once.rb")
    File.write(script, holder_script(mode, public_id, File.join(@home, "once-started"), nil))
    _pid, status = Process.waitpid2(Process.spawn(env, RUBY_BIN, script, err: File::NULL))
    status.exitstatus
  end
end
