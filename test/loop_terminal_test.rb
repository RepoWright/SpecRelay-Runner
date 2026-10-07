# frozen_string_literal: true

require_relative "test_helper"

# RUNNER-0001 scope 3, 4, and 6 — what a poll LOOKS LIKE, and where Ctrl-C leaves you.
#
# `loop_mode_test.rb` proves the loop's SEMANTICS (one run at a time, backoff bounds, failure
# policies, signal handling). This file proves its PRESENTATION against the same injected
# collaborators: a recording terminal instead of the developer's, a clock the test advances
# instead of wall time, and a sleeper that never sleeps.
#
# What must hold:
#   - a healthy poll adds NO terminal history, however many times it happens;
#   - every word on the row corresponds to a state the runner is really in;
#   - the row is erased before every durable line and on every exit path — normal stop,
#     Ctrl-C, SIGTERM, a rejected credential, and an exception on its way past; and
#   - a durable event never carries a spinner byte, and a countdown never becomes one.
class LoopTerminalTest < Minitest::Test
  Loop = SpecrelayRunner::LoopRunner

  # Words a runner must never display unless a real executor line or a real runner phase
  # produced them. A spinner that says "Thinking" is decoration pretending to be telemetry.
  INVENTED_ACTIVITY = %w[Thinking Compiling Analyzing Editing Reasoning Planning].freeze

  # Every state the waiting region or its compact row is allowed to describe. The list is
  # exhaustive on purpose: a new phrase has to be added here deliberately, which is what stops
  # invented activity from arriving by accident.
  TRUTHFUL_STATES = [ "CHECKING FOR WORK", "WAITING FOR WORK", "WAITING TO RETRY" ].freeze
  Presenter = SpecrelayRunner::TerminalPresenter

  def setup
    @terminal = RecordingTerminal.new
    @clock = FakeClock.new
    @pending_signal = nil
  end

  # ---- criterion 4 / scenario 6: idle adds no history ---------------------

  def test_five_healthy_polls_add_no_durable_line_and_occupy_one_region
    run_loop(claim: -> { not_claimed("nothing eligible") }, max_iterations: 5)

    durable = @terminal.durable_lines
    assert_equal 4, durable.length, "only the 2 start lines and the 2 stop lines: #{durable.inspect}"
    refute(durable.any? { |line| line.include?("idle") || line.include?("sleeping") },
           "no per-poll waiting/idle/sleeping line may survive: #{durable.inspect}")
    refute_empty @terminal.regions
    assert_equal durable, @terminal.screen.reject(&:empty?), "the ticks left nothing in the scrollback"
  end

  def test_no_durable_line_ever_carries_a_cursor_or_spinner_byte
    run_loop(claim: -> { not_claimed("nothing eligible") }, max_iterations: 3)

    @terminal.durable_lines.each do |durable|
      refute_includes durable, "\r"
      refute_match(/\e\[/, durable, "a log line carries no ANSI")
    end
  end

  # Scenario 38, from the other side. The dashboard reuses ONE presenter for the whole session, so
  # a loop that ended the presenter rather than releasing its row would leave every LATER
  # menu-launched loop with no status row at all — silently, because the loop still works. Caught
  # by reading the diff, not by a failing test, so this is the test that would have caught it.
  def test_a_second_loop_sharing_one_presenter_still_renders_its_row
    presenter = SpecrelayRunner::TerminalPresenter.new(out: @terminal, transient: true, columns: 100)
    frames = 2.times.map do
      before = @terminal.writes.length
      Loop.call(out: @terminal, err: StringIO.new, presenter: presenter, claim: -> { not_claimed("x") },
                execute: ->(_p) { true }, poll_seconds: 5, max_iterations: 1, install_signals: false,
                sleeper: sleeper, clock: @clock)
      @terminal.writes[before..].count { |write| write.include?("\n") && !write.end_with?("\n") }
    end

    assert_operator frames.last, :>, 0, "the second loop rendered no waiting region: #{frames.inspect}"
    assert_equal frames.first, frames.last, "both sessions render the same row lifecycle"
  end

  # ---- criterion 6 / scenario 8: every word is a real state ---------------

  def test_every_rotating_word_maps_to_a_state_the_runner_is_really_in
    answers = [ -> { not_claimed("nothing eligible") },
                -> { raise SpecrelayRunner::PlatformClient::Error, "could not reach Platform" },
                -> { not_claimed("nothing eligible") } ]
    run_loop(claim: -> { answers.shift.call }, max_iterations: 3, poll_seconds: 10)

    regions = @terminal.regions
    refute_empty regions
    regions.each do |region|
      assert_equal 1, TRUTHFUL_STATES.count { |state| region.join.include?(state) },
                   "exactly one state in #{TRUTHFUL_STATES.inspect} explains the region #{region.inspect}"
    end
    INVENTED_ACTIVITY.each { |word| refute_includes @terminal.string, word }
  end

  def test_the_region_names_the_connection_it_is_polling_for
    run_loop(claim: -> { not_claimed("nothing eligible") }, max_iterations: 2,
             label: "tiny-demo (tiny-demo-workspace)")

    assert(@terminal.regions.all? { |region| region[1].start_with?("│ tiny-demo (tiny-demo-workspace) ") },
           @terminal.regions.inspect)
  end

  def test_a_session_with_no_label_omits_the_identity_row
    run_loop(claim: -> { not_claimed("nothing eligible") }, max_iterations: 1)

    assert(@terminal.regions.all? { |region| TRUTHFUL_STATES.any? { |state| region[1].include?(state) } },
           @terminal.regions.inspect)
  end

  # Scenario 9: at a width where the identity does not fit, the row drops it rather than
  # rendering a half-truncated project name — the identity was already named durably at start.
  def test_a_narrow_terminal_drops_the_identity_instead_of_truncating_it
    @terminal = RecordingTerminal.new(columns: 44)
    run_loop(claim: -> { not_claimed("nothing eligible") }, max_iterations: 2,
             label: "a-very-long-project-name (its-workspace-key)", columns: 44)

    rows = @terminal.transient_rows
    refute_empty rows
    rows.each do |row|
      refute_includes row, "a-very-long-project-name", "a clipped identity is worse than none"
      assert(TRUTHFUL_STATES.any? { |state| row.include?(state) })
    end
  end

  # ---- criterion 5 / scenario 6: a monotonic countdown -------------------

  def test_the_countdown_comes_from_the_monotonic_clock_and_decreases
    run_loop(claim: -> { not_claimed("nothing eligible") }, max_iterations: 1, poll_seconds: 5)

    counts = @terminal.regions.filter_map { |region| countdown(region) }
    refute_empty counts, @terminal.regions.inspect
    assert_equal counts.sort.reverse, counts, "the countdown must only ever count down"
    assert_equal [ 5, 4, 3, 2, 1 ], counts, "one redraw per whole second, and none in between"
  end

  def test_the_compact_row_carries_the_same_countdown_on_a_narrow_terminal
    @terminal = RecordingTerminal.new(columns: 50)
    run_loop(claim: -> { not_claimed("nothing eligible") }, max_iterations: 1, poll_seconds: 5, columns: 50)

    assert_empty @terminal.regions
    counts = @terminal.transient_rows.filter_map { |row| row[/WAITING FOR WORK; next check in (\d+)s/, 1]&.to_i }
    assert_equal 5, counts.first
    assert_equal 1, counts.last
  end

  # ---- scenario groups 6-8: checking, idle and retry ------------------------

  def test_checking_is_blue_and_shows_no_countdown
    run_loop(claim: -> { not_claimed("nothing eligible") }, max_iterations: 1)

    checking = @terminal.regions.first
    assert_includes checking.join, "CHECKING FOR WORK"
    assert_includes checking.join, "Checking for eligible work"
    refute_includes checking.join, "█", "a claim request in flight implies no completion time"
    refute_includes checking.join, "seconds until"
    assert_includes region_writes.first, "\e[34m┌"
    assert_includes region_writes.first, "\e[1;34mCHECKING FOR WORK\e[0m"
  end

  def test_healthy_idle_is_cyan_and_counts_down_every_digit
    { 60 => 60, 300 => 300, 3600 => 3600 }.each do |poll, expected|
      @terminal = RecordingTerminal.new
      run_loop(claim: -> { not_claimed("nothing eligible") }, max_iterations: 1, poll_seconds: poll)

      idle = @terminal.regions.find { |region| region.join.include?("WAITING FOR WORK") }
      assert_equal expected, countdown(idle), idle.inspect
      assert_includes idle.join, "No eligible work"
      assert_includes idle.join, "seconds until next check"
      assert(region_writes.any? { |write| write.include?("\e[36m┌") && write.include?("WAITING FOR WORK") })
    end
  end

  def test_a_polling_error_retry_is_amber_and_counts_down_the_backoff
    claim = -> { raise SpecrelayRunner::PlatformClient::Error, "could not reach Platform" }
    run_loop(claim: claim, max_iterations: 1, poll_seconds: 10)

    retrying = @terminal.regions.find { |region| region.join.include?("WAITING TO RETRY") }
    refute_nil retrying, @terminal.regions.inspect
    assert_includes retrying.join, "Polling failed"
    assert_includes retrying.join, "seconds until retry"
    assert_equal 10, countdown(retrying)
    assert(region_writes.any? { |write| write.include?("\e[33m┌") && write.include?("WAITING TO RETRY") })
  end

  # ---- scenario 11 / 16: claim and completion are durable ----------------

  def test_a_claim_clears_the_row_before_the_durable_claim_line
    claims = [ not_claimed("nothing eligible"), claimed("DEMO-1") ]
    run_loop(claim: -> { claims.shift }, max_iterations: 2)

    claim_line = @terminal.durable_lines.find { |line| line.include?("claimed DEMO-1") }
    refute_nil claim_line
    refute_includes claim_line, "WAITING FOR WORK", "the region was still on screen under the claim line"
    erase_before_claim = @terminal.writes[@terminal.writes.index { |w| w.include?("claimed DEMO-1") } - 1]
    assert_equal "\r\e[J", erase_before_claim, "the whole region is erased before the claim line"
  end

  # ---- scenario groups 1-3 and 5: results ------------------------------------

  def test_before_the_first_run_there_is_no_previous_result
    run_loop(claim: -> { not_claimed("nothing eligible") }, max_iterations: 3)

    refute_includes @terminal.string, "LAST RUN"
  end

  def test_a_success_prints_one_green_result_and_the_waiting_region_resumes_below_it
    claims = [ claimed("DEMO-1"), not_claimed("nothing eligible") ]
    execute = lambda do |_payload, &report|
      report&.call(ticket_key: "DEMO-1", title: "Add a totals row", message: "Runner outcome: completed.")
      true
    end
    run_loop(claim: -> { claims.shift }, execute: execute, max_iterations: 2)

    screen = @terminal.screen.reject(&:empty?)
    completion = screen.index { |row| row.include?("run completed — polling again immediately") }
    frame = screen[(completion + 1)..].take_while { |row| !row.start_with?("[loop]") }
    assert_equal [ "┌", "│ LAST RUN", "│ [OK] DEMO-1 · SUCCESS", "│ Add a totals row", "│ Runner outcome: completed.", "└" ],
                 frame.map { |row| row.delete("─┐┘").sub(/ *│\z/, "") }
    assert_includes @terminal.string, "\e[1;32m[OK] DEMO-1 · SUCCESS\e[0m"
    assert_equal 1, @terminal.screen.count { |row| row.include?("LAST RUN") }
    result = @terminal.writes.index { |write| write.include?("LAST RUN") }
    after = @terminal.regions.last(@terminal.writes[result..].count { |w| w.include?("\n") && !w.end_with?("\n") })
    assert_includes after.first.join, "CHECKING FOR WORK", "an immediate re-poll shows checking first"
    assert(after.any? { |region| region.join.include?("WAITING FOR WORK") })
  end

  def test_a_failure_with_continue_is_red_and_keeps_polling
    claims = [ claimed("DEMO-BAD"), not_claimed("nothing eligible") ]
    status = run_loop(claim: -> { claims.shift }, execute: ->(_p) { false }, max_iterations: 2)

    assert_equal Loop::FAILED, status
    assert_includes @terminal.screen.join("\n"), "[FAIL] FAILED"
    assert_includes @terminal.string, "\e[1;31m[FAIL] FAILED\e[0m"
    result = @terminal.writes.index { |write| write.include?("LAST RUN") }
    assert(@terminal.writes[result..].any? { |w| w.include?("WAITING FOR WORK") }, "the loop kept polling")
  end

  # ---- scenario 18: a stopped session leaves no row behind ---------------

  def test_a_failing_stop_policy_leaves_no_row_on_screen_and_returns_the_failing_status
    status = run_loop(claim: -> { claimed("DEMO-BAD") }, execute: ->(_p) { false },
                      max_iterations: 5, on_failure: Loop::ON_FAILURE_STOP)

    assert_equal Loop::FAILED, status
    assert_row_cleared
    durable = @terminal.durable_lines
    assert(durable.any? { |line| line.include?("stopping after a failed run") })
    result = @terminal.writes.index { |write| write.include?("LAST RUN") }
    refute(@terminal.writes[result..].any? { |write| write.include?("WAITING") || write.include?("CHECKING") },
           "a session that stopped shows no waiting region after its result")
    assert_operator durable.index { |line| line.include?("[FAIL] FAILED") }, :<,
                    durable.index { |line| line.include?("session totals") }, "the stop summary follows the result"
  end

  # ---- scenario group 4: outcomes that are not success ----------------------

  def test_every_non_success_outcome_is_labelled_truthfully_and_keeps_its_loop_policy
    cases = {
      [ true, :awaiting_input ] => [ "[WAIT] DEMO-1 · AWAITING_INPUT", "33", :continue ],
      [ true, :stale ] => [ "[STOP] DEMO-1 · STALE", "33", :continue ],
      [ true, :failed_clean ] => [ "[FAIL] DEMO-1 · FAILED", "31", :continue ],
      [ true, :failed_cleanup ] => [ "[FAIL] DEMO-1 · FAILED", "31", :continue ],
      [ true, :stopped ] => [ "[STOP] DEMO-1 · STOPPED", "33", :continue ],
      [ true, :release_failed ] => [ "[FAIL] DEMO-1 · FAILED", "31", :continue ],
      [ false, nil ] => [ "[FAIL] DEMO-1 · FAILED", "31", :continue ],
      [ Loop::RELEASE_ATTEMPTED_REFUSAL, nil ] => [ "[STOP] DEMO-1 · REFUSED", "33", :stop ],
      [ Loop::FAILED, nil ] => [ "[FAIL] DEMO-1 · FAILED", "31", :stop ]
    }
    cases.each do |(disposition, outcome), (label, color, policy)|
      @terminal = RecordingTerminal.new
      claims = 0
      execute = lambda do |_payload, &report|
        report.call(ticket_key: "DEMO-1", message: "the lane's own result", outcome: outcome)
        disposition
      end
      status = run_loop(claim: -> { (claims += 1) == 1 ? claimed("DEMO-1") : not_claimed("x") },
                        execute: execute, max_iterations: 2)

      context = "#{disposition.inspect}/#{outcome.inspect}"
      assert_includes @terminal.screen.join("\n"), label, context
      assert_includes @terminal.string, "\e[1;#{color}m#{label}\e[0m", context
      refute_includes @terminal.string, "[OK]", context
      assert_equal(policy == :continue ? 2 : 1, claims, "#{context}: the loop policy is unchanged")
      expected = disposition == true ? Loop::OK : Loop::FAILED
      assert_equal expected, status, "#{context}: the session status is unchanged"
    end
  end

  # ---- scenario group 9: concurrent durable output -------------------------

  def test_a_durable_line_during_the_wait_lands_once_above_the_redrawn_region
    presenter = nil
    noticed = false
    sleeper = lambda do |slice|
      @clock.advance(slice)
      presenter.line("[loop] Platform notice") unless noticed
      noticed = true
    end
    presenter = Presenter.new(out: @terminal, transient: true)
    Loop.call(out: @terminal, err: StringIO.new, presenter: presenter, claim: -> { not_claimed("x") },
              execute: ->(_p) { true }, poll_seconds: 3, max_iterations: 1, install_signals: false,
              sleeper: sleeper, clock: @clock)

    assert_equal 1, @terminal.screen.count { |row| row == "[loop] Platform notice" }
    notice = @terminal.writes.index { |write| write.include?("Platform notice") }
    assert_equal "\r\e[J", @terminal.writes[notice - 1], "the region is erased before the notice"
    assert(@terminal.writes[(notice + 1)..].any? { |write| write.include?("WAITING FOR WORK") }, "and redrawn after it")
    refute(@terminal.screen.any? { |row| row.include?("WAITING FOR WORK") }, "no stale region remains")
  end

  # ---- scenario 19: failure visible, recovery printed once ---------------

  def test_a_polling_failure_and_its_recovery_are_durable_and_the_countdown_between_is_not
    attempts = 0
    claim = lambda do
      attempts += 1
      raise SpecrelayRunner::PlatformClient::Error, "could not reach Platform" if attempts < 3

      not_claimed("nothing eligible")
    end
    run_loop(claim: claim, max_iterations: 3, poll_seconds: 10)

    durable = @terminal.durable_lines
    assert_equal 2, durable.count { |line| line.include?("polling failed —") }
    assert_equal 1, durable.count { |line| line.include?("recovered — Platform answered again after 2") },
                 "recovery is printed once, not per poll: #{durable.inspect}"
    assert(@terminal.regions.any? { |region| region.join.include?("WAITING TO RETRY") }, "the wait itself stays transient")
  end

  def test_a_failure_message_is_redacted_on_the_transient_row_too
    claim = -> { raise SpecrelayRunner::PlatformClient::Error, "refused token sk-live-LEAKME-0123456789" }
    run_loop(claim: claim, max_iterations: 1)

    refute_includes @terminal.string, "sk-live-LEAKME-0123456789"
    assert_includes @terminal.string, "[REDACTED]"
  end

  # ---- scenarios 10, 20, 21, 22: every exit path clears the row ----------

  def test_idle_ctrl_c_clears_the_row_sends_no_further_claim_and_summarises_once
    claims = 0
    signal_at_first_slice!("INT")
    status = run_loop(claim: lambda {
      claims += 1
      not_claimed("nothing eligible")
    }, max_iterations: 10, install_signals: true)

    assert_equal Loop::OK, status
    assert_equal 1, claims, "no further claim request may be sent after the interrupt"
    assert_row_cleared
    summaries = @terminal.durable_lines.grep(/session totals/)
    assert_equal 1, summaries.length
    assert(@terminal.durable_lines.any? { |line| line.include?("stopped by signal while IDLE") })
  end

  def test_sigterm_while_idle_clears_the_row_and_prints_the_final_state_once
    claims = 0
    signal_at_first_slice!("TERM")
    run_loop(claim: lambda {
      claims += 1
      not_claimed("nothing eligible")
    }, max_iterations: 10, install_signals: true)

    assert_equal 1, claims
    assert_row_cleared
    assert_equal 1, @terminal.durable_lines.grep(/session totals/).length
  end

  def test_a_rejected_credential_clears_the_row_before_the_remedy_and_does_not_retry
    err = StringIO.new
    claim = -> { raise SpecrelayRunner::PlatformClient::Unauthorized, "401 from /api/runner/claim" }
    status = run_loop(claim: claim, max_iterations: 10, err: err)

    assert_equal Loop::FAILED, status
    assert_row_cleared
    assert_includes err.string, "credential was rejected by Platform"
    assert_includes err.string, "specrelay-runner connect"
    refute(@terminal.regions.any? { |region| region.join.include?("WAITING TO RETRY") },
           "a credential that will never work must not be retried on a timer")
  end

  # Scenario 21. The row is cleared by the `ensure`, and the exception still travels the
  # existing CLI failure boundary rather than being swallowed here.
  def test_an_unexpected_exception_still_clears_the_row_on_its_way_out
    boom = -> { raise ArgumentError, "something no one expected" }

    assert_raises(ArgumentError) { run_loop(claim: boom, max_iterations: 1) }
    assert_row_cleared
  end

  # ---- scenario 23: Ctrl-C during an execution is acknowledged -----------

  # The signal handler may only set a flag, so the acknowledgement has to come from a normal
  # execution path. Without it an operator who interrupts a long Claude run sees nothing at
  # all until the run ends, and presses Ctrl-C again.
  def test_ctrl_c_during_an_execution_says_so_while_the_run_finishes
    execute = lambda do |_payload|
      Process.kill("INT", Process.pid)
      sleep 0.3
      true
    end
    status = run_loop(claim: -> { claimed("DEMO-1") }, execute: execute, max_iterations: 10,
                      install_signals: true)

    assert_equal Loop::OK, status
    durable = @terminal.durable_lines
    assert_equal 1, durable.count { |line| line.include?("stop requested") }, durable.inspect
    assert(durable.any? { |line| line.include?("the run in progress finishes first") })
    assert(durable.any? { |line| line.include?("stopped by signal DURING an execution") })
    assert(durable.any? { |line| line.include?("run completed — stopping as requested") },
           "claiming it would poll again would be untrue: #{durable.inspect}")
  end

  private

  def assert_row_cleared
    last = @terminal.writes.last
    refute_nil last
    assert(last.end_with?("\n") || last.match?(/\A\r( +\r|\e\[J)\z/),
           "the last thing written must be a durable line or an erase, not a live row: #{last.inspect}")
    refute(@terminal.screen.any? { |row| row.include?("Ctrl+C to stop") }, "a waiting region was left on screen")
  end

  def region_writes = @terminal.writes.select { |write| write.include?("\n") && !write.end_with?("\n") }

  # The seconds a region's large digits show, read back through the presenter's own glyphs.
  def countdown(region)
    rows = region.select { |row| row.include?("█") }.map { |row| row[2...-2].tr("█", "#") }
    return nil if rows.empty?

    left = rows.map { |row| row.length - row.lstrip.length }.min
    rows = rows.map { |row| row[left..].rstrip }
    width = rows.map(&:length).max
    (0...width).step(4).map do |col|
      Presenter::DIGITS.key(rows.map { |row| row[col, 3].to_s.ljust(3) })
    end.join.to_i
  end

  def run_loop(claim:, max_iterations:, execute: ->(_p) { true }, poll_seconds: 60,
               on_failure: Loop::ON_FAILURE_CONTINUE, install_signals: false, label: nil,
               err: StringIO.new, columns: 100)
    presenter = SpecrelayRunner::TerminalPresenter.new(out: @terminal, err: err, transient: true,
                                                      columns: columns)
    Loop.call(out: @terminal, err: err, presenter: presenter, label: label, claim: claim,
              execute: execute, poll_seconds: poll_seconds, on_failure: on_failure,
              install_signals: install_signals, max_iterations: max_iterations,
              sleeper: sleeper, clock: @clock)
  end

  def sleeper
    lambda do |slice|
      @clock.advance(slice)
      pending = @pending_signal
      @pending_signal = nil
      pending&.call
      nil
    end
  end

  def signal_at_first_slice!(name)
    @pending_signal = lambda do
      Process.kill(name, Process.pid)
      sleep 0.05 # let the trap run before the loop looks at the flag
    end
  end

  def not_claimed(reason)
    SpecrelayRunner::PlatformClient::ClaimResult.new(claimed: false, payload: { "reason" => reason })
  end

  def claimed(task_id)
    SpecrelayRunner::PlatformClient::ClaimResult.new(
      claimed: true, payload: { "run" => { "id" => "run_#{task_id}", "task_id" => task_id } }
    )
  end

  class FakeClock
    def initialize = @now = 9_000.0
    def advance(seconds) = @now += seconds.to_f
    def clock_gettime(_id) = @now
  end
end
