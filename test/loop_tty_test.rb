# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/pty_session"

# RUNNER-0001 — the live loop under a REAL controlling terminal, and with no terminal at all.
#
# `loop_terminal_test.rb` proves the presentation logic against an injected sink. That is the
# right place for the arithmetic, and it is not evidence for the two claims that only a real
# terminal can settle:
#
#   1. IDLE POLLING NO LONGER GROWS TERMINAL HISTORY. The old loop wrote three lines per poll,
#      so a runner left open for an afternoon buried everything worth reading. Here a real
#      process polls a real (fake) Platform over real HTTP five times, and the pty's own byte
#      stream is counted.
#   2. THE TERMINAL IS HANDED BACK, on every exit path. Raw mode, or a spinner left mid-row, is
#      a failure that outlives the program — so `stty -a` is read from a separate process after
#      the runner has exited, exactly as MVP-0021 does for the dashboard.
#
# It also covers the two non-TTY halves, because a capability-based design is only proved by
# exercising BOTH capabilities: a redirected loop must contain no cursor control at all, and a
# no-argument invocation with no terminal must still refuse rather than animate.
#
# Nothing here reaches a real Platform, a real Keychain, or a real executor: the config is the
# advanced/legacy `--config` path pointed at FakePlatform, which authorizes no work.
class LoopTtyTest < Minitest::Test
  include PtySession

  IDLE_POLLS = 5
  # Written as a named constant rather than as an invisible 0x03 in a string literal.
  CTRL_C = 3.chr

  def setup
    @dir = Dir.mktmpdir("loop-tty")
    @root, = DemoWorkspace.build
    @platform = FakePlatform.new(
      claim_payload: claim_payload_for(task_id: "DEMO-RUNNER-0001", executor_command: slow_executor)
    )
    @platform.offer_no_work!
    @platform.start
    @config = write_config
    @state_file = write_state
  end

  def teardown
    @platform&.stop
    [ @dir, @root ].each { |path| FileUtils.remove_entry(path) if path && File.exist?(path) }
  end

  # ---- criterion 4 / scenario 6: five real polls, no history --------------

  def test_five_real_idle_polls_on_a_real_terminal_add_no_durable_line
    output = drive_direct_loop(polls: IDLE_POLLS)

    assert_operator claims, :>=, IDLE_POLLS, "the runner must really have polled #{IDLE_POLLS} times"
    durable = durable_lines(output)
    assert_empty durable.grep(/\[loop\] idle/), "an idle poll may not be durable: #{durable.inspect}"
    assert_empty durable.grep(/\[loop\] sleeping/), "a healthy wait may not be durable: #{durable.inspect}"
    assert_empty durable.grep(/\[loop\] waiting/)
    # start (2) + stop (2). Everything else the process printed is the announce block, which is
    # not a `[loop]` line, and the transient row, which never terminates a line.
    assert_equal 4, durable.grep(/\[loop\]/).length, durable.inspect
    assert_includes output, "no eligible work", "the state was visible while it was true"
  end

  # Scenario 6, second half: one CURRENT row. Every frame is written to the same row, so the
  # pty stream carries many carriage returns and — between the start and stop blocks — no
  # newline at all.
  def test_the_waiting_row_is_one_row_that_replaces_itself
    output = drive_direct_loop(polls: 3)

    body = output[/finishes its report first\r?\n(.*?)\[loop\] stopped/m, 1]
    refute_nil body, output.inspect
    assert_operator body.count("\r"), :>=, 3, "the row must be redrawn in place"
    assert_equal 0, body.count("\n"),
                 "between the start block and the stop line nothing may terminate a line: #{body.inspect}"
  end

  # Scenario 9: at a narrow width the row stays ONE row. The pty itself is resized, so the
  # runner reads the terminal's own width rather than a `COLUMNS` convention it could ignore.
  def test_at_a_narrow_width_the_row_still_occupies_one_line
    output = drive_direct_loop(polls: 2, columns: 30)

    rows = transient_rows(output)
    refute_empty rows
    rows.each do |row|
      assert_operator row.length, :<=, 30, "a row wider than the terminal wraps into a second: #{row.inspect}"
    end
    # A shorter TRUTHFUL message, not a clipped one: the countdown is dropped where it does not
    # fit rather than the row being wrapped or cut mid-word.
    assert(rows.any? { |row| row.match?(/no eligible work\z/) }, rows.inspect)
    refute(rows.any? { |row| row.include?("next check in") },
           "the countdown cannot fit in 30 columns and must not be forced in: #{rows.inspect}")
  end

  # ---- scenario 10 / 26 / 37: Ctrl-C in a direct loop --------------------

  def test_idle_ctrl_c_clears_the_row_prints_one_summary_and_returns_to_the_shell
    output = drive_direct_loop(polls: 2)

    assert_equal 1, output.scan("session totals").length
    assert_includes output, "stopped by signal while IDLE"
    tail = output.split("session totals").last
    refute_includes tail, "next check in", "a live row was left on screen after the summary"
    refute_includes output, "Press any key", "a direct command returns to the shell, not to a menu"
  end

  def test_a_direct_loop_leaves_the_terminal_in_cooked_mode_after_ctrl_c
    report = probe_terminal("direct-loop", loop_argv, [ polled(2), CTRL_C ], env: child_env)

    assert_terminal_restored(report, "an idle Ctrl-C in a direct loop")
  end

  # Scenario 20 and 37: a fatal polling failure. Platform rejects the credential, so the loop
  # stops on its own — no signal, no key — and must still hand the terminal back with no row
  # left behind.
  def test_a_loop_that_stops_on_a_rejected_credential_leaves_the_terminal_cooked
    report = probe_terminal("unauthorized-loop", loop_argv, [],
                            env: child_env.merge("TEST_TOKEN" => "not-the-expected-credential"))

    assert_terminal_restored(report, "a loop stopped by a rejected credential")
  end

  def test_a_rejected_credential_clears_the_row_and_prints_one_reconnect_remedy
    output = pty_session(loop_argv, [],
                         env: child_env.merge("TEST_TOKEN" => "not-the-expected-credential"))

    assert_includes output, "credential was rejected by Platform"
    assert_includes output, "specrelay-runner connect"
    refute_includes output, "next check in", "a rejected credential must not be retried on a timer"
    refute_includes output, "retry #", "and no backoff timer is started either"
  end

  # ---- scenario 25 / 37: Ctrl-C in a MENU-launched loop ------------------

  # The behaviour this specification changed: the operator pressed Ctrl-C to get back to the
  # project menu, so that is where they land — with no extra keypress in between.
  def test_a_menu_launched_loop_returns_straight_to_the_project_menu_on_ctrl_c
    output = pty_session([ RbConfig.ruby, runner_bin ], [ "1", "L", polled(2), CTRL_C, "B", "Q" ],
                         env: child_env)

    assert_includes output, "$ specrelay-runner loop --workspace tiny-demo-workspace",
                    "the menu dispatches the direct command, echoed so it can be copied"
    assert_includes output, "stopped by signal while IDLE"
    after_loop = output.split("session totals").last
    refute_includes after_loop, "Press any key to return",
                    "an idle Ctrl-C must not cost the operator an extra keypress"
    assert_includes after_loop, "Start live loop", "the project menu is redrawn immediately"
  end

  # The same session, twice. The dashboard shares one write boundary for its whole lifetime, so a
  # second `L` has to render its status row exactly like the first.
  def test_a_second_menu_launched_loop_in_the_same_session_still_renders_its_status_row
    output = pty_session([ RbConfig.ruby, runner_bin ],
                         [ "1", "L", polled(2), CTRL_C, "L", polled(3), CTRL_C, "B", "Q" ],
                         env: child_env)

    sessions = output.split("[loop] started —")
    assert_equal 3, sessions.length, "two loops must have started: #{sessions.length - 1}"
    assert(transient_rows(sessions.last).any? { |row| row.include?("no eligible work") },
           "the second loop rendered no transient row: #{transient_rows(sessions.last).inspect}")
    assert_equal 2, output.scan("session totals").length
  end

  def test_a_menu_launched_loop_leaves_the_terminal_cooked_after_returning_and_quitting
    report = probe_terminal("menu-loop", [ RbConfig.ruby, runner_bin ],
                            [ "1", "L", polled(2), CTRL_C, "B", "Q" ], env: child_env)

    assert_terminal_restored(report, "a menu-launched loop interrupted while idle")
  end

  # ---- scenario 23 / 37: Ctrl-C DURING a real execution -----------------

  # The safety contract this specification must not weaken: an interrupt mid-execution asks the
  # loop to stop AFTER the run has finished its terminal-result/report path. It must not abandon a
  # claimed run, and the operator must be told so while it is still finishing — otherwise a Ctrl-C
  # in the middle of a long provider run looks ignored.
  def test_ctrl_c_during_a_real_execution_finishes_the_run_first_and_claims_nothing_more
    @platform.offer_again!
    output = pty_session(loop_argv, [ executing, CTRL_C, reported ], env: child_env)

    claims_at_interrupt = 1
    assert_includes output, "stop requested"
    assert_includes output, "the run in progress finishes its report first"
    assert_includes output, "[verification.completed]", "the run really finished its own phases"
    assert_includes output, "stopped by signal DURING an execution"
    assert_equal claims_at_interrupt, claims, "no further claim may be sent after the interrupt"
    refute_nil @platform.last_report, "the run reported its result before the loop stopped"
    # MAPIAI-97 — the task environment is handed back at the LOOP boundary, before the loop could
    # poll again. A preview of this same ticket addresses the same task id, so an environment left
    # behind here is one the next claim would be built on top of.
    assert_includes output, "Released the task environment DEMO-RUNNER-0001"
    assert_operator output.index("Released the task environment"), :<,
                    output.index("stopped by signal"),
                    "the release must happen before the loop winds down, not after"
  end

  def test_ctrl_c_during_a_real_execution_still_leaves_the_terminal_cooked
    @platform.offer_again!
    report = probe_terminal("interrupted-run", loop_argv, [ executing, CTRL_C, reported ], env: child_env)

    assert_terminal_restored(report, "an interrupt during an active execution")
  end

  # ---- scenario 38: no cross-session state ------------------------------

  # A second dashboard, started in the same terminal after an interrupted live loop, must open
  # clean: no leftover row, no phantom running state, and no signal trap left behind (the loop
  # restores the previous handlers, so Ctrl-C in the second dashboard is handled by the MENU
  # again — which is what the final `Q`-less exit proves).
  def test_a_second_dashboard_after_an_interrupted_loop_opens_clean
    report = probe_terminal("twice", [ RbConfig.ruby, runner_bin ],
                            [ "1", "L", polled(2), CTRL_C, "B", "Q", "Q" ], env: child_env, repeat: 2)

    assert_terminal_restored(report, "a second dashboard after an interrupted loop")
  end

  def test_the_second_dashboard_shows_no_stale_transient_text_or_running_state
    output = pty_session([ "/bin/sh", twice_script ], [ "1", "L", polled(2), CTRL_C, "B", "Q", "Q" ],
                         env: child_env)

    second = output.split("SESSION-2").last
    refute_nil second
    assert_includes second, "1 project connected to this runner", "the second dashboard opened normally"
    refute_includes second, "next check in", "stale transient text survived into the next session"
    refute_includes second, "executing —"
  end

  # ---- scenario 28: no terminal, no animation ---------------------------

  def test_a_redirected_loop_contains_no_cursor_animation_and_no_per_poll_spam
    result = run_loop_without_tty(polls: 3)

    assert_includes result[:stdout], "[loop] started"
    refute_includes result[:stdout], "\r", "a log file must receive no carriage return"
    refute_match(/\e\[/, result[:stdout], "a log file must receive no ANSI escape")
    assert_equal 1, result[:stdout].scan("[loop] idle —").length,
                 "the reason is printed once, not once per poll:\n#{result[:stdout]}"
    assert_includes result[:stdout], "[loop] stopped by signal while IDLE"
    assert_includes result[:stdout], "[loop] session totals"
    assert_equal 0, result[:status]
    # Live means flushed: every line above arrived before the process exited, because the
    # capture is read after a signal the runner handled rather than after a crash.
    assert_operator result[:stdout].lines.length, :>=, 6
  end

  # ---- scenario 29: no arguments, no terminal ---------------------------

  def test_a_no_argument_invocation_with_no_terminal_still_refuses_rather_than_animating
    stdout_path = File.join(@dir, "usage.out")
    stderr_path = File.join(@dir, "usage.err")
    pid = Process.spawn(child_env, RbConfig.ruby, runner_bin, in: File::NULL, out: stdout_path,
                                                              err: stderr_path)
    _, status = Process.wait2(pid)

    assert_equal 2, status.exitstatus
    assert_includes File.read(stderr_path), "needs a command when there is no terminal"
    assert_empty File.read(stdout_path).delete("\n")
  end

  private

  def claims = @platform.requests_to("/api/runner/claim").length

  # The terminal HISTORY: what survives on screen once the row it was written over is gone.
  #
  # A pty in cooked mode turns every "\n" into "\r\n", so a durable line is the LAST
  # carriage-return-delimited field of its line — everything before it was overwritten in place.
  def durable_lines(output)
    output.split(/\r?\n/).map { |line| line.split("\r").last.to_s.strip }.reject(&:empty?)
  end

  # The successive contents of the one reusable row. A transient frame is `\r<text>\r` where the
  # trailing carriage return is NOT followed by a newline; a durable line ends `\r\n`, which is
  # how the two are told apart in one byte stream. Long durable lines legitimately wrap — that is
  # ordinary terminal behaviour and not what the one-row rule is about.
  def transient_rows(output)
    output.scan(/\r([^\r\n]+)\r(?!\n)/).flatten.reject { |row| row.strip.empty? }
  end

  # Wait until the runner has really polled `count` times, so every assertion is about
  # observed behaviour rather than about a sleep that happened to be long enough.
  def polled(count) = -> { claims >= count }

  # The executor process has really started (Platform received the `core.started` event), so the
  # interrupt lands DURING the execution rather than before or after it.
  def executing = -> { @platform.protocol_events.any? { |event| event["event_type"] == "core.started" } }

  def reported = -> { !@platform.last_report.nil? }

  # A real child process that is still running when the interrupt arrives, then applies the edit
  # the demo workspace's own `./bin/test` checks for.
  def slow_executor
    path = File.join(@root, "bin", "slow-executor")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      $stdout.sync = true
      puts "reading the approved specification"
      sleep 3
      file = "demo-app/index.html"
      content = File.read(file)
      File.write(file, content.gsub("Hello Demo", "Hello SpecRelay Demo")) if content.include?("Hello Demo")
      puts "[executor] applied the edit"
      #{DemoWorkspace.selection_snippet}
      exit 0
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end

  def drive_direct_loop(polls:, columns: nil)
    pty_session(loop_argv, [ polled(polls), CTRL_C ], env: child_env, columns: columns)
  end

  def loop_argv = [ RbConfig.ruby, runner_bin, "loop", "--config", @config, "--poll-interval", "5" ]

  # Two runs of the dashboard in one terminal session, so "no cross-session state" is asserted
  # against the same real terminal rather than against two unrelated processes.
  def twice_script
    path = File.join(@dir, "twice.rb.sh")
    quoted = [ RbConfig.ruby, runner_bin ].map { |part| shell_quote(part) }.join(" ")
    File.write(path, "#!/bin/sh\n#{quoted}\nprintf '\\nSESSION-2\\n'\n#{quoted}\n")
    File.chmod(0o755, path)
    path
  end

  # A redirected loop, stopped with a real signal once it has really polled `polls` times.
  def run_loop_without_tty(polls:)
    stdout_path = File.join(@dir, "loop.out")
    stderr_path = File.join(@dir, "loop.err")
    pid = Process.spawn(child_env, *loop_argv[1..], in: File::NULL, out: stdout_path, err: stderr_path)
    deadline = monotonic + WAIT_TIMEOUT_SECONDS
    sleep 0.2 while claims < polls && monotonic < deadline
    Process.kill("INT", pid)
    _, status = Process.wait2(pid)
    { status: status.exitstatus, stdout: File.read(stdout_path), stderr: File.read(stderr_path) }
  end

  def write_config
    path = File.join(@dir, "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{@platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: tty-loop-runner
        display_name: TTY Loop Runner
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{@root}
    YAML
    path
  end

  # One connected project, so the dashboard opens on it with `1`. The menu-launched loop then
  # resolves its config from SPECRELAY_RUNNER_CONFIG rather than from the Keychain: the exact
  # `--workspace` argv the menu dispatches is asserted in `dashboard_test.rb`, and reading a
  # real credential from a real Keychain is not something a test may do.
  def write_state
    path = File.join(@dir, "connections.json")
    File.write(path, JSON.pretty_generate(
      "version" => 2,
      "connections" => [ { "base_url" => @platform.base_url, "runner_id" => "tty-loop-runner",
                           "runner_public_id" => "rnr_fake", "runner_display_name" => "host runner",
                           "project_slug" => "tiny-demo", "project_key" => "tiny-demo",
                           "workspace_key" => "tiny-demo-workspace",
                           "workspace_display_name" => "Tiny Demo Workspace",
                           "repository_url" => "https://github.com/SpecRelay/tiny-demo-workspace",
                           "default_branch" => "main", "local_path" => @dir,
                           "connected_at" => "2026-07-20T10:00:00Z" } ]
    ))
    File.chmod(0o600, path)
    path
  end

  def runner_bin = File.expand_path("../bin/specrelay-runner", __dir__)

  def child_env
    { "SPECRELAY_RUNNER_STATE_FILE" => @state_file, "SPECRELAY_RUNNER_CONFIG" => @config,
      "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "RUNNER_LIB" => File.expand_path("../lib", __dir__),
      "PATH" => ENV.fetch("PATH", ""), "TERM" => "xterm" }
  end
end
