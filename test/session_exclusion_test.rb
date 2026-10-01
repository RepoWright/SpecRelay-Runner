# frozen_string_literal: true

require_relative "test_helper"

# Which work-running sessions may run together on one OS account, and how many of one
# registration Platform admits.
#
# A saved connection's session takes the local gate SHARED, so saved sessions of any registration
# — including several of the same one — run side by side. How many terminals one registration may
# run is Platform's decision: each session asks to be admitted against the registration's stored
# maximum before it probes a provider, starts a connector, polls or claims, and every claim names
# the session it is made for. A hand-written config has no stored registration identity on this
# machine, so its session takes the gate EXCLUSIVE and runs alone; a registered credential in it is
# still admitted by Platform and counts against the same maximum.
#
# What the tests below have to prove:
#
#   - two saved sessions of one registration are both admitted, claim through their own session,
#     run their tickets and connectors side by side, and stop independently;
#   - a start over the maximum is refused — for loop, claim-once and a registered hand-written
#     config — before the provider probe, the connector and the claim, naming the count and maximum;
#   - a hand-written-config session and any other session refuse each other in both start orders;
#   - a failed selection takes no lock, and every ending releases exactly what was acquired.
#
# The contention cases run REAL processes. Two threads in one process share a file description
# and would prove nothing about two operators' terminals.
class SessionExclusionTest < Minitest::Test
  RUNNER_BINARY = File.expand_path("../bin/specrelay-runner", __dir__)
  RUBY_BIN = RbConfig.ruby
  # Bounded so a lock that never releases fails this test rather than hanging the suite.
  WAIT_TIMEOUT_SECONDS = 30

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

  def saved = SpecrelayRunner::SessionLock.saved(env: env)

  def exclusive = SpecrelayRunner::SessionLock.exclusive(env: env)

  def test_the_gate_lives_under_the_local_users_home
    assert_equal File.join(@home, ".specrelay/runner/session.lock"), SpecrelayRunner::SessionLock.path(env: env)
  end

  def test_saved_sessions_hold_together
    with_holder("saved") do
      assert_equal :second, saved.hold { :second }
    end
  end

  def test_an_exclusive_session_and_a_saved_one_refuse_each_other
    with_holder("saved") do
      refused = assert_raises(SpecrelayRunner::SessionLock::Busy) { exclusive.hold { flunk "ran" } }

      assert_match(/hand-written config runs only alone/, refused.message)
      refute_match(/registration/, refused.message)
    end
    with_holder("exclusive") do
      refused = assert_raises(SpecrelayRunner::SessionLock::Busy) { saved.hold { flunk "ran" } }

      assert_match(/hand-written config is already running/, refused.message)
      refute_match(/registration/, refused.message)
      assert_raises(SpecrelayRunner::SessionLock::Busy) { exclusive.hold { flunk "ran" } }
    end
  end

  def test_every_ending_releases_both_modes
    [ -> { saved }, -> { exclusive } ].each do |lock|
      lock.call.hold { :done }
      assert_raises(RuntimeError) { lock.call.hold { raise "startup failed" } }
      assert_raises(Interrupt) { lock.call.hold { raise Interrupt } }

      assert_equal 0, run_holder_once("exclusive"), "a released session still held the gate"
    end
    assert File.file?(SpecrelayRunner::SessionLock.path(env: env)), "releasing removed the gate file"
  end

  # A provider or connector the session launches must not inherit the gate's descriptor. If it did,
  # an orphaned child outliving the runner would keep the session claimed with nothing to Ctrl-C.
  def test_a_surviving_child_process_does_not_retain_the_gate
    stop = File.join(@home, "child-stop")
    child = saved.hold do
      Process.spawn(RUBY_BIN, "-e", "sleep 0.05 until File.exist?(#{stop.inspect})")
    end

    assert_equal 0, run_holder_once("exclusive"), "the child kept the gate"
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

  # --- one registration, several admitted sessions ----------------------------

  # Scenario 11 and AC1: two terminals of ONE registration — the same saved connection, against its
  # one Platform — are both admitted, each claims under its own session id, and stopping one stops
  # only its own session while the other keeps polling.
  def test_two_saved_sessions_of_one_registration_are_admitted_and_stop_independently
    alpha = saved_connection("alpha")
    alpha[:platform].maximum_sessions = 2
    first_loop = spawn_saved_loop(alpha)
    second_loop = spawn_saved_loop(alpha, label: "alpha-second-loop")
    wait_for { claims(alpha[:platform]) >= 2 && alpha[:platform].admitted_sessions.size == 2 }

    admitted = alpha[:platform].admitted_sessions
    assert_equal admitted.sort, claim_session_ids(alpha[:platform]).uniq.sort

    stop_process(first_loop[:pid])
    wait_for { alpha[:platform].admitted_sessions.size == 1 }
    polled = claims(alpha[:platform])
    wait_for { claims(alpha[:platform]) > polled }

    assert running?(second_loop[:pid]), "stopping one session stopped the other"
    assert_equal [ alpha[:platform].admitted_sessions.first ], claim_session_ids(alpha[:platform]).last(1)
  end

  # Scenario 11: a start over the registration's maximum is refused before the provider probe, the
  # preview connector and the claim, for `loop` and `claim-once` alike, and names the count and
  # maximum Platform reported.
  def test_a_saved_session_over_the_maximum_is_refused_before_any_work
    alpha = saved_connection("alpha")
    alpha[:platform].maximum_sessions = 1
    alpha[:platform].occupy_session!("another-terminal-session")

    %w[loop claim-once].each do |command|
      refused = run_saved([ command, "--workspace", alpha[:workspace_key] ])

      assert_equal SpecrelayRunner::CLI::RUN_FAILED, refused[:status], "#{command}: #{refused[:stderr]}"
      assert_match(/1 of 1 sessions/, refused[:stderr])
    end
    assert_equal 0, claims(alpha[:platform]), "a refused session claimed"
    assert_empty alpha[:platform].requests_to("/api/runner/cancellation_cleanup_target")
    refute File.exist?(connector_marker), "a refused session started its preview connector"
    assert_equal [ "started" ], alpha[:platform].requests_to("/api/runner/presence").map { |r| r[:body]["event"] }.uniq
  end

  # Only an explicit `accepted` admits a terminal. An unknown, missing or malformed answer is not
  # an admission, so neither command probes its provider, starts its connector or claims.
  def test_an_unrecognized_admission_answer_starts_no_work
    [ { "outcome" => "admitted" }, { "slot_number" => 1 }, "accepted" ].each do |answer|
      alpha = saved_connection("alpha-#{SecureRandom.hex(2)}")
      alpha[:platform].answer_starts_with!(answer)
      %w[loop claim-once].each do |command|
        refused = run_saved([ command, "--workspace", alpha[:workspace_key] ])

        assert_equal SpecrelayRunner::CLI::RUN_FAILED, refused[:status], "#{answer.inspect} #{command}: #{refused[:stderr]}"
      end
      assert_equal 0, claims(alpha[:platform]), "#{answer.inspect}: an unadmitted session claimed"
      assert_empty alpha[:platform].requests_to("/api/runner/cancellation_cleanup_target")
      refute File.exist?(connector_marker), "#{answer.inspect}: an unadmitted session started its connector"

      platform = idle_platform
      platform.answer_starts_with!(answer)
      probe = File.join(@home, "provider-probed")
      refused = run_config([ "claim-once", "--config", config_for(platform, "alpha-runner", provider: "claude") ],
                           overrides: { "PATH" => "#{File.dirname(provider_probe(probe))}:/usr/bin:/bin" })

      assert_equal SpecrelayRunner::CLI::RUN_FAILED, refused[:status], refused[:stdout] + refused[:stderr]
      refute File.exist?(probe), "#{answer.inspect}: the provider was probed without admission"
      assert_equal 0, claims(platform)
    end
  end

  # Scenario 11: a registered credential in a hand-written config is admitted by Platform too, with
  # no selected workspace, and is refused at the same maximum before its provider probe runs.
  def test_a_registered_hand_written_config_counts_against_the_same_maximum
    platform = idle_platform
    platform.maximum_sessions = 1
    platform.occupy_session!("another-terminal-session")
    probe = File.join(@home, "provider-probed")

    refused = run_config([ "claim-once", "--config", config_for(platform, "alpha-runner", provider: "claude") ],
                         overrides: { "PATH" => "#{File.dirname(provider_probe(probe))}:/usr/bin:/bin" })

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, refused[:status], refused[:stdout] + refused[:stderr]
    assert_match(/1 of 1 sessions/, refused[:stderr])
    refute File.exist?(probe), "the provider was probed before admission"
    assert_equal 0, claims(platform)
    started = platform.requests_to("/api/runner/presence").first[:body]
    assert_equal "started", started["event"]
    refute started.key?("workspace_key"), "a hand-written config selected a workspace"
  end

  # Scenario 12: two terminals of one saved connection, in its ONE checkout, each claim a different
  # ticket and execute it at the same time. Each executor finishes only once the other has started,
  # so both runs complete only if their task environments really ran side by side.
  def test_two_sessions_of_one_registration_execute_their_own_tickets_in_one_checkout
    root, = DemoWorkspace.build
    markers = Dir.mktmpdir("executors")
    platform = start_platform(claim_payload_for(task_id: "DEMO-UNUSED", root: root))
    platform.maximum_sessions = 2
    connection = saved_connection("lane", platform: platform, root: root)
    platform.queue_claims(%w[ALPHA BETA].map { |name| lane_payload(name, connection[:workspace_key], root) })
    executor = handshake_pair(root, markers)

    started = %w[alpha beta].map do |name|
      spawn_saved([ "claim-once", "--workspace", connection[:workspace_key] ], name,
                  overrides: { "PATH" => fixture_path(executor, base: saved_path) })
    end
    results = started.map { |process| finish(process) }

    results.each { |result| assert_equal 0, result[:status], result[:stdout] + result[:stderr] }
    assert_equal 2, platform.requests_to("/api/runner/reports").size
    assert_equal 2, claim_session_ids(platform).uniq.size
    assert_empty platform.admitted_sessions, "a finished claim-once kept its session"
  end

  # Scenario 12: each loop of one registration launches its own preview connector child. Stopping
  # one session stops its own connector and leaves the other's running and answering.
  def test_two_sessions_of_one_registration_keep_their_own_preview_connectors
    alpha = saved_connection("alpha")
    alpha[:platform].maximum_sessions = 2
    first_loop = spawn_saved_loop(alpha)
    spawn_saved_loop(alpha, label: "alpha-second-loop")
    wait_for { connector_pids.size == 2 && connector_pids.all? { |pid| alive?(pid) } }
    connectors = connector_pids

    stop_process(first_loop[:pid])
    wait_for { connectors.one? { |pid| alive?(pid) } }

    survivor = connectors.find { |pid| alive?(pid) }
    assert survivor, "stopping one session stopped every connector"
    assert connector_answers?(survivor), "the remaining connector stopped answering"
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

  def claim_session_ids(platform) = platform.requests_to("/api/runner/claim").map { |r| r[:body]["session_id"] }

  # One terminal's own ticket in the shared workspace.
  def lane_payload(name, workspace_key, root)
    payload = claim_payload_for(task_id: "DEMO-#{name}", root: root)
    payload["workspace"]["workspace_key"] = workspace_key
    payload["run"]["id"] = "run_#{name.downcase}"
    payload["claim"]["runner_execution_id"] = "rex_#{name.downcase}"
    payload
  end

  # One executor for both terminals: whichever ticket it runs, it records its start and finishes
  # only once the OTHER ticket's executor has started too.
  def handshake_pair(root, markers)
    path = File.join(root, "bin", "handshake-pair-executor")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      mine = Dir.pwd.include?("DEMO-ALPHA") ? "alpha" : "beta"
      peer = mine == "alpha" ? "beta" : "alpha"
      File.write(File.join(#{markers.inspect}, mine), "started")
      deadline = Time.now + #{WAIT_TIMEOUT_SECONDS}
      sleep 0.05 until File.exist?(File.join(#{markers.inspect}, peer)) || Time.now > deadline
      abort "the \#{peer} executor never ran alongside this one" unless File.exist?(File.join(#{markers.inspect}, peer))
      file = "demo-app/index.html"
      File.write(file, File.read(file).gsub("Hello Demo", "Hello SpecRelay Demo"))
      #{DemoWorkspace.selection_snippet}
      exit 0
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # A provider CLI stand-in that records that it was probed at all.
  def provider_probe(marker)
    path = File.join(Dir.mktmpdir("probe"), "claude")
    File.write(path, "#!/bin/sh\ntouch #{marker}\nexit 1\n")
    FileUtils.chmod(0o755, path)
    path
  end

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
        port = ARGV[ARGV.index("--metrics") + 1].split(":").last.to_i
        server = TCPServer.new("127.0.0.1", port)
        File.write(File.join(#{connector_directory.inspect}, Process.pid.to_s), port.to_s)
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

  # Each connector stand-in records its pid and readiness port here when it starts.
  def connector_directory = @connector_directory ||= Dir.mktmpdir("connectors")
  def connector_marker = Dir.glob(File.join(connector_directory, "*")).first.to_s
  def connector_pids = Dir.children(connector_directory).map(&:to_i)

  def connector_answers?(pid)
    port = File.read(File.join(connector_directory, pid.to_s)).to_i
    TCPSocket.new("127.0.0.1", port).close
    true
  rescue SystemCallError
    false
  end

  def spawn_saved(argv, label, overrides: {})
    spawn_process([ RUBY_BIN, saved_driver, *argv ], label, { "PATH" => saved_path }.merge(overrides))
  end

  def spawn_saved_loop(connection, label: "#{connection[:name]}-loop")
    spawn_saved([ "loop", "--workspace", connection[:workspace_key], "--poll-interval", "5" ], label)
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
  def holder_script(mode, started, release)
    lock = mode == "saved" ? "saved(env: ENV)" : "exclusive(env: ENV)"
    wait = release ? "sleep 0.05 until File.exist?(#{release.inspect})" : ""
    <<~RUBY
      require_relative #{File.expand_path('../lib/specrelay_runner', __dir__).inspect}
      SpecrelayRunner::SessionLock.#{lock}.hold do
        File.write(#{started.inspect}, "held")
        #{wait}
      end
    RUBY
  end

  def with_holder(mode)
    started = File.join(@home, "holder-started")
    release = File.join(@home, "holder-release")
    [ started, release ].each { |path| FileUtils.rm_f(path) }
    script = File.join(@home, "holder.rb")
    File.write(script, holder_script(mode, started, release))
    pid = Process.spawn(env, RUBY_BIN, script)
    wait_for { File.exist?(started) }
    yield
  ensure
    File.write(release, "go")
    Process.waitpid(pid) if pid
  end

  def run_holder_once(mode)
    script = File.join(@home, "once.rb")
    File.write(script, holder_script(mode, File.join(@home, "once-started"), nil))
    _pid, status = Process.waitpid2(Process.spawn(env, RUBY_BIN, script, err: File::NULL))
    status.exitstatus
  end
end
