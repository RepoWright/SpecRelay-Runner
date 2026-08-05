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

  # Every state the transient row is allowed to describe. The list is exhaustive on purpose:
  # a new phrase has to be added here deliberately, which is what stops invented activity
  # from arriving by accident.
  TRUTHFUL_STATES = [ "checking for eligible work", "no eligible work", "polling failed" ].freeze

  def setup
    @terminal = RecordingTerminal.new
    @clock = FakeClock.new
    @pending_signal = nil
  end

  # ---- criterion 4 / scenario 6: idle adds no history ---------------------

  def test_five_healthy_polls_add_no_durable_line_and_occupy_one_row
    run_loop(claim: -> { not_claimed("nothing eligible") }, max_iterations: 5)

    durable = @terminal.durable_lines
    assert_equal 4, durable.length, "only the 2 start lines and the 2 stop lines: #{durable.inspect}"
    refute(durable.any? { |line| line.include?("idle") || line.include?("sleeping") },
           "no per-poll waiting/idle/sleeping line may survive: #{durable.inspect}")
    refute_empty @terminal.transient_rows
  end

  def test_no_durable_line_ever_carries_a_cursor_or_spinner_byte
    run_loop(claim: -> { not_claimed("nothing eligible") }, max_iterations: 3)

    @terminal.string.split("\n").each do |segment|
      durable = segment.rpartition("\r").last
      next if durable.empty?

      refute_includes durable, "\r"
      refute_match(/\e\[/, durable, "the runner writes no ANSI at all")
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
      @terminal.writes[before..].count { |write| write.start_with?("\r") && !write.include?("\n") }
    end

    assert_operator frames.last, :>, 0, "the second loop rendered no transient row: #{frames.inspect}"
    assert_equal frames.first, frames.last, "both sessions render the same row lifecycle"
  end

  # ---- criterion 6 / scenario 8: every word is a real state ---------------

  def test_every_rotating_word_maps_to_a_state_the_runner_is_really_in
    answers = [ -> { not_claimed("nothing eligible") },
                -> { raise SpecrelayRunner::PlatformClient::Error, "could not reach Platform" },
                -> { not_claimed("nothing eligible") } ]
    run_loop(claim: -> { answers.shift.call }, max_iterations: 3, poll_seconds: 10)

    rows = @terminal.transient_rows
    refute_empty rows
    rows.each do |row|
      assert(TRUTHFUL_STATES.any? { |state| row.include?(state) },
             "no state in #{TRUTHFUL_STATES.inspect} explains the row #{row.inspect}")
    end
    INVENTED_ACTIVITY.each { |word| refute_includes @terminal.string, word }
  end

  def test_the_row_names_the_connection_it_is_polling_for
    run_loop(claim: -> { not_claimed("nothing eligible") }, max_iterations: 2,
             label: "tiny-demo (tiny-demo-workspace)")

    assert(@terminal.transient_rows.all? { |row| row.start_with?("tiny-demo (tiny-demo-workspace) — ") },
           @terminal.transient_rows.inspect)
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

    counts = @terminal.transient_rows.filter_map { |row| row[/next check in (\d+)s/, 1]&.to_i }
    refute_empty counts, @terminal.transient_rows.inspect
    assert_equal counts.sort.reverse, counts, "the countdown must only ever count down"
    assert_equal 5, counts.first
    assert_equal 1, counts.last
  end

  # ---- scenario 11 / 16: claim and completion are durable ----------------

  def test_a_claim_clears_the_row_before_the_durable_claim_line
    claims = [ not_claimed("nothing eligible"), claimed("DEMO-1") ]
    run_loop(claim: -> { claims.shift }, max_iterations: 2)

    claim_line = @terminal.durable_lines.find { |line| line.include?("claimed DEMO-1") }
    refute_nil claim_line
    refute_includes claim_line, "no eligible work", "the row was still on screen under the claim line"
    erase_before_claim = @terminal.writes[@terminal.writes.index { |w| w.include?("claimed DEMO-1") } - 1]
    assert_match(/\A\r +\r\z/, erase_before_claim)
  end

  def test_after_a_completed_run_the_single_waiting_row_resumes_below_the_completion_line
    claims = [ claimed("DEMO-1"), not_claimed("nothing eligible") ]
    run_loop(claim: -> { claims.shift }, max_iterations: 2)

    durable = @terminal.durable_lines
    assert(durable.any? { |line| line.include?("run completed — polling again immediately") })
    completion = @terminal.writes.index { |w| w.include?("run completed") }
    resumed = @terminal.writes[(completion + 1)..].select { |w| w.start_with?("\r") && !w.include?("\n") }
    refute_empty resumed, "the transient row must resume after the durable result"
  end

  # ---- scenario 18: a stopped session leaves no row behind ---------------

  def test_a_failing_stop_policy_leaves_no_row_on_screen_and_returns_the_failing_status
    status = run_loop(claim: -> { claimed("DEMO-BAD") }, execute: ->(_p) { false },
                      max_iterations: 5, on_failure: Loop::ON_FAILURE_STOP)

    assert_equal Loop::FAILED, status
    assert_row_cleared
    assert(@terminal.durable_lines.any? { |line| line.include?("stopping after a failed run") })
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
    assert(@terminal.transient_rows.any? { |row| row.include?("retry #") }, "the wait itself stays transient")
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
    refute(@terminal.transient_rows.any? { |row| row.include?("retry #") },
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
  def test_ctrl_c_during_an_execution_says_so_while_the_run_finishes_reporting
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
    assert(durable.any? { |line| line.include?("the run in progress finishes its report first") })
    assert(durable.any? { |line| line.include?("stopped by signal DURING an execution") })
    assert(durable.any? { |line| line.include?("run completed — stopping as requested") },
           "claiming it would poll again would be untrue: #{durable.inspect}")
  end

  private

  def assert_row_cleared
    last = @terminal.writes.last
    refute_nil last
    assert(last.end_with?("\n") || last.match?(/\A\r +\r\z/),
           "the last thing written must be a durable line or an erase, not a live row: #{last.inspect}")
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
