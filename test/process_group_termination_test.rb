# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"

# A supervised command is finished only when its OWN process group is: the direct child reaped
# with its status kept, and no member of the group it was spawned into still running.
#
# Every process here is real. The command's leader forks a descendant into the same group that
# ignores TERM and keeps doing observable work — appending to a heartbeat file — so "it stopped"
# is measured as work that stopped, not inferred from a PID that may belong to a zombie. Each
# test removes only the processes it recorded, by their own PIDs, in `ensure`.
class ProcessGroupTerminationTest < Minitest::Test
  CommandRunner = SpecrelayRunner::CommandRunner

  # The whole budget one supervised run may take here: two shutdown graces and change.
  DEADLINE = (CommandRunner::TERM_GRACE_SECONDS * 2) + 10

  # The command under test. The leader records its identity, forks a TERM-ignoring descendant
  # into its own group, waits until that descendant is working, then does what its mode says.
  LEADER = <<~'RUBY'
    dir, mode, keep_output = ARGV
    File.write(File.join(dir, "leader.pid"), "#{Process.pid} #{Process.getpgrp}")
    fork do
      trap("TERM", "IGNORE")
      STDIN.reopen(File::NULL)
      unless keep_output == "keep"
        STDOUT.reopen(File::NULL, "w")
        STDERR.reopen(File::NULL, "w")
      end
      tmp = File.join(dir, "descendant.tmp")
      File.write(tmp, "#{Process.pid} #{Process.getpgrp}")
      File.rename(tmp, File.join(dir, "descendant.pid"))
      beat = File.join(dir, "beat")
      3000.times do
        File.open(beat, "a") { |file| file.write(".") }
        if keep_output == "keep"
          STDOUT.puts("descendant beat")
          STDOUT.flush
        end
        sleep 0.02
      end
    end
    sleep 0.01 until File.exist?(File.join(dir, "descendant.pid"))
    # `reopen`, not `close`: Ruby keeps descriptor 0 open under a closed STDIN, and the pipe with it.
    STDIN.reopen(File::NULL) if mode == "close_stdin"
    File.write(File.join(dir, "ready"), "")
    case mode
    when "exit3" then exit 3
    when "exit3_later"
      sleep 0.5
      exit 3
    when "exit0" then exit 0
    when "wait_ignoring_term"
      trap("TERM", "IGNORE")
      sleep 60
    else sleep 60
    end
  RUBY

  def setup
    @dir = Dir.mktmpdir("process-group-")
    @pids = []
    @kill_log = []
  end

  def teardown
    # Only this test's own processes, by the PIDs they recorded — never a group, never a scan.
    (@pids + recorded_pids).uniq.each do |pid|
      Process.kill("KILL", pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
    @controls&.each do |pid|
      Process.kill("KILL", -pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  # ---------------------------------------------------------------- S1, S2: an ordinary exit

  def test_a_failed_leader_exit_waits_for_its_descendant_and_keeps_status_three
    result = supervised("exit3")

    assert_equal 3, result.exit_code
    refute result.timed_out?
    assert_group_finished
  end

  def test_a_successful_leader_exit_waits_for_its_descendant_and_keeps_status_zero
    result = supervised("exit0")

    assert_equal 0, result.exit_code
    assert_group_finished
  end

  # ---------------------------------------------------------------- S3, S4: stop and timeout

  # The leader dies on TERM; its descendant does not, so completion needs the KILL escalation.
  def test_a_stop_request_escalates_until_the_whole_group_has_ended
    result = supervised("wait", stop_check: -> { File.exist?(ready) })

    assert_nil result.exit_code
    assert_equal false, result.timed_out, "a requested stop is not a timeout"
    assert_operator result.duration_seconds, :>=, CommandRunner::TERM_GRACE_SECONDS - 0.5,
                    "a TERM-resistant descendant is only ended by the KILL after the grace"
    assert_group_finished
    assert_only_own_group_signalled
  end

  # Both the leader and its descendant ignore TERM, so the leader itself is only reaped after KILL.
  def test_a_timeout_ends_the_whole_group_and_reaps_the_direct_child_after_kill
    result = supervised("wait_ignoring_term", timeout_seconds: 1)

    assert_equal true, result.timed_out
    assert_group_finished
    assert_raises(Errno::ECHILD, "the runner itself must have reaped its direct child") do
      Process.waitpid(leader_pid, Process::WNOHANG)
    end
  end

  # ---------------------------------------------------------------- S5: an inherited pipe

  # The descendant keeps the command's stdout open after the leader exits. Capture would block
  # until the descendant ended on its own — here, a minute later — unless the group is ended.
  def test_a_descendant_holding_the_output_pipe_cannot_hold_the_result
    result = supervised("exit0", keep_output: "keep")

    assert_equal 0, result.exit_code
    assert_includes result.stdout, "descendant beat", "what the descendant wrote is still captured"
    assert_group_finished
  end

  # ---------------------------------------------------------------- S6: callback and input

  def test_a_raising_start_callback_ends_the_group_before_its_error_escapes
    control = start_control_group
    on_start = lambda do
      wait_for(ready)
      raise "the handoff could not be recorded"
    end

    error = assert_raises(RuntimeError) { supervised("wait", on_start: on_start) }

    assert_equal "the handoff could not be recorded", error.message
    assert_group_finished
    assert_control_group_alive(control)
  end

  def test_an_undelivered_input_ends_the_group_before_its_error_escapes
    control = start_control_group
    # Larger than a pipe buffer, so the write is still in progress when the leader closes stdin.
    input = "x" * 2_000_000

    assert_raises(Errno::EPIPE) do
      supervised("close_stdin", stdin_data: input, on_start: -> { })
    end

    assert_group_finished
    assert_control_group_alive(control)
  end

  # ---------------------------------------------------------------- S7: unproved shutdown

  # The group exists but cannot be inspected. An inspection error is not evidence of absence.
  #
  # EPERM is also what this platform answers while a group holds only zombies, so it is judged by
  # the bounded observation rather than failed at once: a group that keeps refusing runs out of
  # time. The grace is shortened here so the test does not wait out the real one twice.
  def test_an_uninspectable_group_is_a_termination_failure_not_a_result
    with_grace(0.3) do
      deny_inspection_of_leader_group do
        error = assert_raises(CommandRunner::TerminationFailed) do
          supervised("exit0", argv_extra: [ "sk-live-DO-NOT-PRINT-0123456789" ])
        end

        assert_includes error.message, "process group #{leader_pid}"
        assert_includes error.message, "permission denied"
        refute_includes error.message, "sk-live-DO-NOT-PRINT"
        refute_includes error.message, @dir
      end
    end
  end

  # The group is still there after TERM and KILL and the bounded observation after each.
  def test_a_group_that_outlives_the_bounded_shutdown_is_a_termination_failure
    with_grace(0.3) do
      pretend_leader_group_persists do
        error = assert_raises(CommandRunner::TerminationFailed) { supervised("wait", timeout_seconds: 1) }

        assert_includes error.message, "process group #{leader_pid}"
      end
    end
  end

  # ---------------------------------------------------------------- S8: nothing changes here

  def test_a_command_without_descendants_is_unchanged_and_pays_no_grace
    lines = []
    started = 0
    result = bounded do
      CommandRunner.run([ RbConfig.ruby, "-e", 'STDOUT.puts(STDIN.read); STDERR.puts("warned"); exit 4' ],
                        chdir: @dir, stdin_data: "hello", on_output: ->(source, line) { lines << [ source, line ] },
                        on_start: -> { started += 1 })
    end

    assert_equal 4, result.exit_code
    assert_equal "hello\n", result.stdout
    assert_equal "warned\n", result.stderr
    assert_includes lines, [ CommandRunner::STDOUT, "hello" ]
    assert_includes lines, [ CommandRunner::STDERR, "warned" ]
    assert_equal 1, started
    assert_operator result.duration_seconds, :<, 1.0, "no descendant, so no shutdown grace"
    assert CommandRunner.run([ RbConfig.ruby, "-e", "exit 0" ], chdir: @dir).success?
  end

  # ---------------------------------------------------------------- S9: already gone

  # Something else reaped the direct child first. Its status is gone, and that is reported as
  # unknown rather than borrowed from another process; the empty group is not a failure.
  def test_a_child_reaped_elsewhere_ends_without_borrowing_a_status
    thief = -> { File.exist?(ready) && begin Process.waitpid(leader_pid) rescue Errno::ECHILD; end && false }
    result = supervised("exit3_later", stop_check: thief)

    assert_group_finished
    assert_nil result.exit_code, "a status this runner never read is not reported as the command's"
  end

  # ---------------------------------------------------------------- S7: through the CLI

  # The implementation provider's group cannot be shown to have ended. The invocation fails at the
  # command-line boundary: no report, no release of the environment, and nothing claimed after it.
  def test_an_unfinished_provider_group_stops_claim_once_without_release_or_another_claim
    code, output, platform, root = unfinished_run(%w[claim-once], group_of: :provider)

    assert_stopped_before_anything_else(code, output, platform, root)
  end

  # The same inside a loop that would otherwise go on to claim more work.
  def test_an_unfinished_provider_group_ends_the_loop_before_another_claim
    code, output, platform, root = unfinished_run(%w[loop --poll-interval 5 --on-failure continue],
                                                  group_of: :provider, claim_limit: 2)

    assert_stopped_before_anything_else(code, output, platform, root)
  end

  # The group that cannot be shown to have ended is the RELEASE command's, after the result was
  # acknowledged and the checkout removed. The invocation still fails, and says nothing that
  # denies what had already happened.
  def test_an_unfinished_release_group_fails_without_denying_the_release_it_made
    code, output, platform, root = unfinished_run(%w[claim-once], group_of: :release)

    refute_nil leader_pid, "the release command must really have run"
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "process group #{leader_pid}"
    assert_equal 1, platform.requests_to("/api/runner/reports").size, "the result was already reported"
    refute File.directory?(File.join(root, ".runs", "worktrees", TASK)), "the release had already removed it"
    refute_match(/no task environment was released|nothing further was claimed/i, output)
  ensure
    FileUtils.remove_entry(root) if root && File.directory?(root)
  end

  private

  # ---- the implementation lane, end to end ----------------------------------------------

  TASK = "DEMO-0001"

  # `group_of` names the one supervised command whose group is made uninspectable: it records its
  # own group — the one its CommandRunner spawn created — and only that group is denied.
  def unfinished_run(command, group_of:, claim_limit: nil)
    root, executor = DemoWorkspace.build
    marker = File.join(@dir, "leader.pid")
    if group_of == :provider
      File.write(executor, File.read(executor).sub("# frozen_string_literal: true\n",
                                                   "# frozen_string_literal: true\n" \
                                                   "File.write(#{marker.inspect}, \"\#{Process.pid} \#{Process.getpgrp}\")\n"))
    else
      project = File.join(root, "bin", "worktree")
      File.write(project, File.read(project).sub("release)", "release)\n    echo \"$$ $$\" > #{marker}"))
    end
    platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK, root: root), claim_limit: claim_limit).start
    config = File.join(Dir.mktmpdir("cfg", @dir), "runner.yml")
    File.write(config, <<~YAML)
      platform:
        base_url: #{platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: test-runner
        display_name: Test Runner
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{root}
    YAML
    io = StringIO.new
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => fixture_path(executor), "HOME" => ENV["HOME"].to_s }
    code = with_grace(0.3) do
      deny_inspection_of_leader_group do
        bounded { SpecrelayRunner::CLI.run([ *command, "--config", config ], out: io, err: io, env: env) }
      end
    end
    [ code, io.string, platform, root ]
  ensure
    platform&.stop
  end

  def assert_stopped_before_anything_else(code, output, platform, root)
    refute_nil leader_pid, "the provider must really have run"
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "could not be shown to have ended"
    assert_includes output, "process group #{leader_pid}"
    refute_includes output, "Released the task environment"
    assert File.directory?(File.join(root, ".runs", "worktrees", TASK)), "the environment must be kept"
    assert_equal 1, platform.requests_to("/api/runner/claim").size, "nothing may be claimed after it"
    assert_empty platform.requests_to("/api/runner/reports"), "no result may be reported for it"
    assert_empty platform.requests_to("/api/runner/claim_releases")
  ensure
    FileUtils.remove_entry(root) if root && File.directory?(root)
  end

  # ---- the supervised command -----------------------------------------------------------

  def supervised(mode, keep_output: "drop", argv_extra: [], **options)
    spy_signals do
      bounded do
        CommandRunner.run([ RbConfig.ruby, "-e", LEADER, @dir, mode, keep_output, *argv_extra ],
                          chdir: @dir, env: {}, **{ timeout_seconds: 60 }.merge(options))
      end
    end
  end

  # An outer deadline for a supervised run. A result that never arrives fails here rather than
  # hanging the suite; `teardown` then removes the recorded processes, which lets it finish.
  def bounded(seconds = DEADLINE)
    outcome = nil
    worker = Thread.new do
      Thread.current.report_on_exception = false
      outcome = [ :value, yield ]
    rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised on the test thread
      outcome = [ :error, e ]
    end
    return raise_or_return(outcome) if worker.join(seconds)

    flunk "the supervised command did not return within #{seconds}s"
  end

  def raise_or_return(outcome)
    raise outcome.last if outcome.first == :error

    outcome.last
  end

  # ---- evidence -------------------------------------------------------------------------

  def ready = File.join(@dir, "ready")
  def leader_pid = identity("leader.pid").first
  def descendant_pid = identity("descendant.pid").first

  def identity(name)
    path = File.join(@dir, name)
    File.exist?(path) ? File.read(path).split.map { |value| Integer(value) } : []
  end

  def recorded_pids = [ identity("leader.pid").first, identity("descendant.pid").first ].compact

  # Absent as a GROUP, and its descendant no longer doing work. The second half is what tells a
  # stopped process from a PID that merely still exists.
  def assert_group_finished
    refute_nil descendant_pid, "the descendant must really have started"
    assert_equal leader_pid, identity("descendant.pid").last, "the descendant shares the leader's group"
    assert_raises(Errno::ESRCH, "no member of the command's own group may remain") { Process.kill(0, -leader_pid) }
    beat = File.join(@dir, "beat")
    before = File.size(beat)
    sleep 0.2
    assert_equal before, File.size(beat), "the descendant is still doing work"
  end

  def assert_only_own_group_signalled
    sent = @kill_log.reject { |signal, _target| signal.to_s == "0" }
    refute_empty sent
    assert sent.all? { |_signal, target| target == -leader_pid }, "signalled beyond its own group: #{sent.inspect}"
  end

  # A separately spawned, separately owned group doing observable work of its own.
  def start_control_group
    beat = File.join(@dir, "control-beat")
    pid = Process.spawn(RbConfig.ruby, "-e", "loop { File.open(ARGV[0], 'a') { |f| f.write('.') }; sleep 0.02 }",
                        beat, pgroup: true, out: File::NULL, err: File::NULL)
    (@controls ||= []) << pid
    wait_for(beat)
    [ pid, beat ]
  end

  def assert_control_group_alive((pid, beat))
    Process.kill(0, -pid)
    before = File.size(beat)
    sleep 0.2
    assert_operator File.size(beat), :>, before, "an unrelated group must keep running"
  end

  def wait_for(path, seconds = 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until File.exist?(path)
      raise "#{path} never appeared" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  # ---- narrow OS-boundary doubles -------------------------------------------------------

  # Records every signal while passing it through unchanged.
  def spy_signals(&block)
    log = @kill_log
    replace_kill(->(original, signal, *targets) { targets.each { |t| log << [ signal, t ] }; original.call(signal, *targets) },
                 &block)
  end

  # Inspection of the command's own group is refused as a permissions error; nothing else is.
  def deny_inspection_of_leader_group(&block)
    replace_kill(lambda do |original, signal, *targets|
      pid = leader_pid
      raise Errno::EPERM if signal.to_s == "0" && pid && targets == [ -pid ]

      original.call(signal, *targets)
    end, &block)
  end

  # Inspection answers "still there" whatever happened; real signals are still delivered.
  def pretend_leader_group_persists(&block)
    replace_kill(lambda do |original, signal, *targets|
      pid = leader_pid
      return 1 if signal.to_s == "0" && pid && targets == [ -pid ]

      original.call(signal, *targets)
    end, &block)
  end

  def replace_kill(behaviour)
    original = Process.method(:kill)
    Process.define_singleton_method(:kill) { |signal, *targets| behaviour.call(original, signal, *targets) }
    yield
  ensure
    Process.define_singleton_method(:kill, original)
  end

  def with_grace(seconds)
    original = CommandRunner::TERM_GRACE_SECONDS
    CommandRunner.send(:remove_const, :TERM_GRACE_SECONDS)
    CommandRunner.const_set(:TERM_GRACE_SECONDS, seconds)
    yield
  ensure
    CommandRunner.send(:remove_const, :TERM_GRACE_SECONDS)
    CommandRunner.const_set(:TERM_GRACE_SECONDS, original)
  end
end
