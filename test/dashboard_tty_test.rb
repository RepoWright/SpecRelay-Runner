# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/pty_session"

# MVP-0021 scope 1 — the dashboard under a REAL controlling terminal.
#
# This file exists for the same reason `keychain_tty_test.rb` does. The one environmental fact
# the whole feature depends on — whether stdin and stdout are a terminal, and what raw mode does
# to them — is the fact no StringIO can reproduce. A suite that only ever ran the dashboard
# against fakes could be entirely green while:
#
#   - the no-argument invocation never opened a dashboard on a real terminal at all;
#   - raw mode was never actually entered, so no keypress registered without Enter;
#   - the frame staircased down and to the right, because ONLCR is off in raw mode and a bare
#     "\n" does not return the cursor to column 0;
#   - or — the one that outlives the program — raw mode leaked, leaving the operator's shell
#     with no echo and no working Ctrl-C after `specrelay-runner` exited.
#
# So these examples run the real CLI inside a real pty, drive it with real keystrokes, and read
# the terminal's own attributes afterwards. `termios` is inspected through `stty -a` on the pty
# rather than trusted from inside the program, because "the program thinks it restored the
# terminal" is precisely the claim under test.
#
# Nothing here touches Platform or the Keychain: the state file is a fixture in a temporary
# directory, and every asserted behaviour is local.
class DashboardTtyTest < Minitest::Test
  # The pty harness itself lives in support/pty_session.rb, shared with RUNNER-0001's
  # loop-in-a-pty proof so there is one implementation of "drive the real program in a real
  # terminal and then ask the terminal what state it is in".
  include PtySession

  def setup
    @dir = Dir.mktmpdir("dashboard-tty")
    @state_file = File.join(@dir, "connections.json")
    write_state
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # --- the dashboard really opens on a real terminal -------------------------

  def test_a_no_argument_invocation_opens_the_dashboard_under_a_controlling_terminal
    output = drive([ "Q" ])

    assert_includes output, "SpecRelay Runner — local control center"
    assert_includes output, "2 projects connected to this runner"
    assert_includes output, "tiny-demo-workspace"
    assert_includes output, "development-workspace"
  end

  # The same binary, the same arguments, no terminal: usage and a non-zero exit. Asserted here
  # rather than only against StringIO so the two halves of the decision are proved against the
  # same real process.
  def test_the_same_invocation_with_no_terminal_prints_usage_and_exits_non_zero
    result = run_without_tty([])

    refute_equal 0, result[:status]
    assert_equal 2, result[:status]
    assert_includes result[:stderr], "needs a command when there is no terminal"
    refute_includes result[:stdout], "local control center"
    refute_match(/\e\[2J/, result[:stdout] + result[:stderr], "no screen clear may reach a log")
  end

  def test_help_exits_zero_with_no_terminal
    result = run_without_tty([ "help" ])

    assert_equal 0, result[:status]
    assert_includes result[:stdout], "opens the local control center"
  end

  # --- keys act immediately -------------------------------------------------

  # The whole promise of the menu: a single keypress acts, with no Enter. That only holds if raw
  # mode was really entered on the real terminal, which is what this proves.
  # The listing is newest-first, so `1` is `development-workspace`.
  def test_a_single_keypress_with_no_enter_opens_a_workspace
    output = drive([ "1", "B", "Q" ])

    assert_includes output, "local control center — tiny-demo  ·  development-workspace"
    assert_includes output, "Start live loop"
    assert_includes output, "Test connection and readiness"
  end

  def test_arrow_keys_move_the_highlight_on_a_real_terminal
    output = drive([ "\e[B", "\r", "B", "Q" ])

    # Down once from the first row, then Enter, opens the SECOND listed workspace — the older one.
    assert_includes output, "local control center — tiny-demo  ·  tiny-demo-workspace"
  end

  def test_escape_leaves_the_workspace_view_and_returns_to_the_top_level
    output = drive([ "1", "\e", "Q" ])

    assert_includes output, "local control center — tiny-demo  ·  development-workspace"
    # Returning re-renders the top level, so its header appears again after the detail view.
    assert_operator output.scan("2 projects connected to this runner").length, :>=, 2
  end

  # --- the frame renders as a frame -----------------------------------------

  # In raw mode ONLCR is off, so a bare "\n" moves down WITHOUT returning to column 0 and the
  # whole frame drifts right. Every row must therefore start at column 0.
  def test_the_frame_does_not_staircase_on_a_real_terminal
    output = drive([ "Q" ])

    rows = output.split("\r\n").grep(/tiny-demo-workspace|development-workspace/)

    refute_empty rows, "the workspace rows must be present at all"
    rows.each do |row|
      refute_match(/\A\s{4,}/, row.gsub(/\e\[[\d;]*m/, ""),
                   "a row indented this far is the staircase a bare newline produces")
    end
  end

  # --- the terminal is handed back ------------------------------------------

  # The failure that outlives the program. If raw mode leaks, the operator's shell is left with
  # no echo and no working Ctrl-C, and nothing in the program's own output would reveal it — so
  # the terminal's attributes are read from OUTSIDE the program, after it exits.
  def test_quitting_leaves_the_terminal_in_cooked_mode
    assert_cooked_after([ "Q" ])
  end

  # Raw mode disables ISIG, so Ctrl-C arrives as a byte the menu handles rather than as a signal.
  # It must still exit AND still restore.
  def test_ctrl_c_at_the_top_level_exits_and_leaves_the_terminal_in_cooked_mode
    assert_cooked_after([ "" ])
  end

  def test_escape_at_the_top_level_exits_and_leaves_the_terminal_in_cooked_mode
    assert_cooked_after([ "\e" ])
  end

  # Nested views enter and leave raw mode repeatedly; the restoration has to survive that.
  def test_the_terminal_is_restored_after_nested_views
    assert_cooked_after([ "1", "S", " ", "B", "2", "\e", "Q" ])
  end

  # An unexpected error must not be a reason to keep the operator's terminal. `IO#raw` restores
  # through its ensure, and this proves it against a real failure on a real terminal.
  def test_an_error_inside_the_dashboard_still_restores_the_terminal
    attributes = attributes_after_failure

    assert_includes attributes, "echo", "a crashed dashboard must not leave echo off"
    assert_includes attributes, "icanon"
    assert_includes attributes, "isig"
  end

  private

  # Two connections on one machine — the shape that used to refuse with "several workspaces are
  # connected". Local paths point at the temporary directory, so nothing outside it is read.
  def write_state
    File.write(@state_file, JSON.pretty_generate(
      "version" => 2,
      "connections" => [ entry("development-workspace", "2026-07-27T10:00:00Z"),
                        entry("tiny-demo-workspace", "2026-07-20T10:00:00Z") ]
    ))
    File.chmod(0o600, @state_file)
  end

  def entry(workspace_key, connected_at)
    { "base_url" => "http://127.0.0.1:65535", "runner_id" => "host-runner",
      "runner_public_id" => "rnr_fake", "runner_display_name" => "host runner",
      "project_slug" => "tiny-demo", "workspace_key" => workspace_key, "project_key" => "tiny-demo",
      "workspace_display_name" => "Tiny Demo Workspace",
      "repository_url" => "https://github.com/SpecRelay/tiny-demo-workspace", "default_branch" => "main",
      "local_path" => @dir, "connected_at" => connected_at }
  end

  # Run the real `specrelay-runner` inside a pty and send `keys`.
  def drive(keys) = pty_session([ RbConfig.ruby, runner_bin ], keys, env: child_env)

  # Drive the dashboard, then ask the PTY ITSELF what state it is in — from a separate process, so
  # the answer does not depend on the program under test being honest about it.
  def assert_cooked_after(keys) = assert_terminal_restored(attributes_after(keys), "the dashboard exited")

  def attributes_after(keys) = probe_terminal("drive", [ RbConfig.ruby, runner_bin ], keys, env: child_env)

  # The same probe for a program that DIED inside raw mode. The ensure in `IO#raw` is the only
  # thing that can hand the terminal back there, so this is the one assertion that proves it.
  def attributes_after_failure = probe_terminal("crash", [ RbConfig.ruby, crash_program ], [], env: child_env)

  # A program that enters the REAL raw mode through the real TerminalMenu and then raises while
  # rendering the first frame. The failure is injected through an entry that raises when it is
  # drawn, so no test-only branch exists in production code — and the exception escapes from
  # INSIDE the raw block, which is the state that matters.
  def crash_program
    path = File.join(@dir, "crash.rb")
    File.write(path, <<~RUBY)
      $LOAD_PATH.unshift ENV.fetch("RUNNER_LIB")
      require "specrelay_runner"

      exploding = Object.new
      exploding.define_singleton_method(:shortcut) { raise "boom while rendering" }
      exploding.define_singleton_method(:label) { "never drawn" }
      exploding.define_singleton_method(:value) { :never }

      begin
        SpecrelayRunner::TerminalMenu.new.select(title: "crash", footer: "", entries: [ exploding ])
      rescue StandardError
        # Swallowed: the assertion is about the TERMINAL afterwards, not about the exception.
      end
    RUBY
    path
  end

  def runner_bin = File.expand_path("../bin/specrelay-runner", __dir__)

  def child_env
    { "SPECRELAY_RUNNER_STATE_FILE" => @state_file,
      "RUNNER_LIB" => File.expand_path("../lib", __dir__),
      "PATH" => ENV.fetch("PATH", ""), "TERM" => "xterm", "LINES" => "40", "COLUMNS" => "100" }
  end

  # Run the real command with NO terminal on either end, capturing both streams and the status.
  def run_without_tty(argv)
    stdout_path = File.join(@dir, "stdout.log")
    stderr_path = File.join(@dir, "stderr.log")
    pid = Process.spawn(child_env, RbConfig.ruby, runner_bin, *argv,
                        in: File::NULL, out: stdout_path, err: stderr_path)
    _, status = Process.wait2(pid)
    { status: status.exitstatus, stdout: File.read(stdout_path), stderr: File.read(stderr_path) }
  end
end
