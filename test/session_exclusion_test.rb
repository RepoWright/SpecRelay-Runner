# frozen_string_literal: true

require_relative "test_helper"

# One work-running session per local OS user.
#
# Platform serializes work per REGISTERED RUNNER, and a machine that now holds a separate
# registration per project has several of those. Nothing on the server therefore stops one laptop
# from running two projects' loops at once, each convinced it owns the machine's checkouts,
# provider session and task environments. The guard is local because the resource being protected
# is local.
#
# What the tests below have to prove is narrow and exact:
#
#   - the second invocation is refused BEFORE it does anything a first one would observe — no
#     provider probe, no presence, no claim;
#   - the refusal does not depend on the second invocation picking the same project, working
#     directory, state file or config, because none of those is the thing being shared;
#   - every ordinary ending — success, startup failure, interruption — releases the session for
#     the next invocation, with no file to clean up by hand.
#
# The contention case runs REAL processes. Two threads in one process share a file description
# and would prove nothing about two operators' terminals.
class SessionExclusionTest < Minitest::Test
  RUNNER_BINARY = File.expand_path("../bin/specrelay-runner", __dir__)
  # Bounded so a lock that never releases fails this test rather than hanging the suite.
  WAIT_TIMEOUT_SECONDS = 30

  def setup
    @home = Dir.mktmpdir("runner-home")
    # An empty connection store of its own, so nothing here reads — or locks against — the
    # developer's real state or Keychain. It also makes the point under test: the session lock
    # is NOT derived from this path.
    @state_file = File.join(Dir.mktmpdir("state"), "connections.json")
  end

  def env(overrides = {})
    { "HOME" => @home, "PATH" => ENV["PATH"].to_s,
      "SPECRELAY_RUNNER_STATE_FILE" => @state_file }.merge(overrides)
  end

  # --- the lock itself ------------------------------------------------------

  def test_the_lock_lives_under_the_local_users_home
    assert_equal File.join(@home, ".specrelay/runner/session.lock"),
                 SpecrelayRunner::SessionLock.path(env: env)
  end

  # The location must not follow the project, the checkout, the config or the state file: a
  # second session that moved any of those would otherwise slip past the guard.
  def test_the_lock_location_ignores_the_state_file_override_and_the_working_directory
    elsewhere = File.join(Dir.mktmpdir("other"), "connections.json")
    moved = SpecrelayRunner::SessionLock.path(
      env: env("SPECRELAY_RUNNER_STATE_FILE" => elsewhere, "SPECRELAY_RUNNER_CONFIG" => "/tmp/other.yml",
               "PWD" => Dir.mktmpdir("cwd"))
    )

    assert_equal SpecrelayRunner::SessionLock.path(env: env), moved
  end

  # The holder is a real second process, because `flock` is per file DESCRIPTION: a second
  # `flock` from the same process is granted and would prove nothing about two terminals.
  def test_a_second_hold_is_refused_while_another_process_holds_it
    with_held_session do
      refused = assert_raises(SpecrelayRunner::SessionLock::Busy) do
        SpecrelayRunner::SessionLock.hold(env: env) { flunk "the second session ran anyway" }
      end

      assert_match(/already running/i, refused.message)
    end
  end

  def test_the_lock_is_released_when_the_block_returns
    SpecrelayRunner::SessionLock.hold(env: env) { :first }

    assert_equal :second, SpecrelayRunner::SessionLock.hold(env: env) { :second }
  end

  # A startup failure is the common case: the provider was missing, the credential was gone. The
  # session must not stay claimed by a process that has already given up.
  def test_the_lock_is_released_when_the_block_raises
    assert_raises(RuntimeError) do
      SpecrelayRunner::SessionLock.hold(env: env) { raise "startup failed" }
    end

    assert_equal :next, SpecrelayRunner::SessionLock.hold(env: env) { :next }
  end

  def test_an_interrupted_session_releases_the_lock
    assert_raises(Interrupt) { SpecrelayRunner::SessionLock.hold(env: env) { raise Interrupt } }

    assert_equal :next, SpecrelayRunner::SessionLock.hold(env: env) { :next }
  end

  # Releasing must not remove the file: a later invocation recreating it is fine, but a session
  # that unlinks the path another process is already holding by descriptor would let two sessions
  # each hold a different file at the same name.
  def test_releasing_keeps_the_lock_file
    SpecrelayRunner::SessionLock.hold(env: env) { :done }

    assert File.file?(SpecrelayRunner::SessionLock.path(env: env))
  end

  # A provider or connector the session launches must not inherit the descriptor. If it did, an
  # orphaned child outliving the runner would keep the session claimed with nothing to Ctrl-C.
  def test_a_surviving_child_process_does_not_keep_the_session_claimed
    stop = File.join(@home, "child-stop")
    child = SpecrelayRunner::SessionLock.hold(env: env) do
      # Launched while the lock is held, exactly as a provider is, and outliving the session.
      Process.spawn(RUBY_BIN, "-e", "sleep 0.05 until File.exist?(#{stop.inspect})")
    end

    assert_equal :next, SpecrelayRunner::SessionLock.hold(env: env) { :next }
  ensure
    File.write(stop, "go")
    Process.waitpid(child) if child
  end

  # --- the CLI's two execution entry points ---------------------------------

  def test_loop_is_refused_while_a_session_is_held
    out, err, status = with_held_session { run_cli([ "loop" ]) }

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, status
    assert_match(/already running/i, err)
    # Nothing about the refused invocation reached the connection or the provider.
    assert_equal "", out
  end

  def test_claim_once_is_refused_while_a_session_is_held
    _out, err, status = with_held_session { run_cli([ "claim-once" ]) }

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, status
    assert_match(/already running/i, err)
  end

  # The refusal must beat the resolution that would otherwise complain about something else
  # first — a machine with no connection at all still reports the session, not the connection.
  def test_the_refusal_names_the_session_rather_than_the_missing_connection
    _out, err, = with_held_session { run_cli([ "loop" ]) }

    refute_match(/not connected to a workspace/, err)
  end

  def test_a_released_session_lets_the_next_invocation_run
    SpecrelayRunner::SessionLock.hold(env: env) { :done }
    _out, err, status = run_cli([ "loop" ])

    # It gets as far as resolving a connection, which is the first thing past the guard.
    assert_equal SpecrelayRunner::CLI::USAGE_ERROR, status
    assert_match(/not connected to a workspace/, err)
  end

  def test_listing_and_help_are_not_execution_sessions
    with_held_session do
      assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli([ "connections", "list" ]).last
      assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli([ "help" ]).last
    end
  end

  # --- the lock path itself cannot be opened --------------------------------

  # A regular file where the lock's directory belongs. `flock` never gets a chance, so the session
  # cannot be acquired for a reason that is neither "free" nor "held" — an expected environment
  # failure the command must report, not an exception that escapes the CLI with no message.
  def block_lock_path = File.write(File.join(@home, ".specrelay"), "not a directory")

  def test_an_unopenable_lock_path_is_an_expected_failure_for_both_execution_commands
    block_lock_path

    %w[loop claim-once].each do |command|
      out, err, status = run_cli([ command ])

      assert_equal SpecrelayRunner::CLI::USAGE_ERROR, status,
                   "#{command} did not report the lock path as unusable local state"
      assert_match(/session lock/, err, "#{command} printed no operator message")
      assert_match(/directory exists and this user can write to it/, err,
                   "#{command} named no remedy")
      assert_equal "", out
    end
  end

  # The refusal happens at the session boundary, so nothing downstream starts: no connection is
  # resolved, no credential is read, and Platform is never contacted.
  def test_an_unopenable_lock_path_has_no_startup_side_effects
    platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: "DEMO-171")).start
    connected = connected_state_file(platform.base_url)
    block_lock_path

    _out, err, status = run_cli([ "claim-once" ], overrides: { "SPECRELAY_RUNNER_STATE_FILE" => connected })

    refute_equal 0, status
    assert_empty platform.requests, "the refused command reached Platform"
    refute_match(/not connected to a workspace/, err, "it resolved a connection before refusing")
  ensure
    platform&.stop
  end

  def test_the_session_works_again_once_the_lock_path_is_repaired
    block_lock_path

    assert_equal SpecrelayRunner::CLI::USAGE_ERROR, run_cli([ "claim-once" ]).last

    File.delete(File.join(@home, ".specrelay"))
    _out, err, status = run_cli([ "loop" ])

    # Past the session boundary now: it fails on the connection instead, which is the next gate.
    assert_equal SpecrelayRunner::CLI::USAGE_ERROR, status
    assert_match(/not connected to a workspace/, err)
    assert File.file?(SpecrelayRunner::SessionLock.path(env: env)), "the lock file was created"
  end

  # --- real processes -------------------------------------------------------

  # Two real invocations, in different working directories, with different state files and a
  # config path the second one names explicitly. The only thing they share is the OS user, which
  # is the whole point.
  def test_a_second_real_invocation_is_refused_whatever_it_points_at
    holder_started = File.join(@home, "holder-started")
    holder = spawn_holder(holder_started)
    wait_for { File.exist?(holder_started) }

    second = Dir.mktmpdir("second")
    output = capture_subprocess(
      [ RUBY_BIN, RUNNER_BINARY, "loop" ],
      chdir: second,
      env: env("SPECRELAY_RUNNER_STATE_FILE" => File.join(second, "connections.json"))
    )

    refute_equal 0, output[:status], "the second session was not refused"
    assert_match(/already running/i, output[:stderr] + output[:stdout])
  ensure
    release_holder(holder)
  end

  def test_the_losing_process_makes_no_platform_request_at_all
    platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: "DEMO-171")).start
    holder_started = File.join(@home, "holder-started")
    holder = spawn_holder(holder_started)
    wait_for { File.exist?(holder_started) }

    connected = connected_state_file(platform.base_url)
    capture_subprocess([ RUBY_BIN, RUNNER_BINARY, "claim-once" ],
                       env: env("SPECRELAY_RUNNER_STATE_FILE" => connected))

    assert_empty platform.requests,
                 "the refused session reached Platform: #{platform.requests.map { |r| r[:path] }}"
  ensure
    release_holder(holder)
    platform&.stop
  end

  def test_the_holder_is_unaffected_by_the_refused_session
    holder_started = File.join(@home, "holder-started")
    holder = spawn_holder(holder_started)
    wait_for { File.exist?(holder_started) }

    capture_subprocess([ RUBY_BIN, RUNNER_BINARY, "claim-once" ], env: env)

    assert_equal 0, release_holder(holder), "the holding session did not finish cleanly"
    # And the session is free again for the next one.
    assert_equal :next, SpecrelayRunner::SessionLock.hold(env: env) { :next }
  end

  private

  RUBY_BIN = RbConfig.ruby

  # A real process that takes the session lock, says so through the filesystem, and then waits to
  # be told to let go. Synchronization is by file, never by sleeping for a guessed duration.
  def spawn_holder(started_marker)
    release_marker = File.join(@home, "holder-release")
    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.expand_path('../lib', __dir__).inspect})
      require "specrelay_runner"
      SpecrelayRunner::SessionLock.hold(env: ENV) do
        File.write(#{started_marker.inspect}, "held")
        sleep 0.05 until File.exist?(#{release_marker.inspect})
      end
    RUBY
    path = File.join(@home, "holder.rb")
    File.write(path, script)
    { pid: Process.spawn(env, RUBY_BIN, path), release: release_marker }
  end

  def release_holder(holder)
    return nil if holder.nil?

    File.write(holder[:release], "go")
    _pid, status = Process.waitpid2(holder[:pid])
    status.exitstatus
  rescue Errno::ECHILD
    nil
  end

  def wait_for(timeout: WAIT_TIMEOUT_SECONDS)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition was not met within #{timeout}s" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  def capture_subprocess(argv, env: {}, chdir: Dir.pwd)
    out_read, out_write = IO.pipe
    err_read, err_write = IO.pipe
    pid = Process.spawn(env, *argv, out: out_write, err: err_write, chdir: chdir)
    [ out_write, err_write ].each(&:close)
    stdout = out_read.read
    stderr = err_read.read
    _pid, status = Process.waitpid2(pid)
    { stdout: stdout, stderr: stderr, status: status.exitstatus }
  end

  # Run the CLI in this process, which is where the guard's ordering relative to connection
  # resolution and the provider gate is observable.
  def run_cli(argv, overrides: {})
    out = StringIO.new
    err = StringIO.new
    status = SpecrelayRunner::CLI.new(out: out, err: err, env: env(overrides),
                                      input: StringIO.new).run(argv)
    [ out.string, err.string, status ]
  end

  # Hold the session from ANOTHER process, because `flock` is per file description: a second
  # `flock` on the same description in this process would be granted and prove nothing.
  def with_held_session
    started = File.join(@home, "holder-started")
    holder = spawn_holder(started)
    wait_for { File.exist?(started) }
    yield
  ensure
    release_holder(holder)
  end

  # A minimally complete connection record, so `claim-once` would really try to reach Platform if
  # the guard let it through.
  def connected_state_file(base_url)
    path = File.join(Dir.mktmpdir("connected"), "connections.json")
    document = {
      "version" => SpecrelayRunner::ConnectionStore::VERSION,
      "connections" => [ { "base_url" => base_url, "runner_id" => "host-runner",
                           "runner_public_id" => "rnr_fake", "runner_display_name" => "host runner",
                           "project_slug" => "tiny-demo", "workspace_key" => "tiny-demo-workspace",
                           "repository_url" => "https://github.com/SpecRelay/tiny-demo-workspace",
                           "default_branch" => "main", "local_path" => Dir.mktmpdir("checkout"),
                           "connected_at" => "2026-09-18T00:00:00Z" } ]
    }
    File.write(path, "#{JSON.pretty_generate(document)}\n")
    path
  end
end
