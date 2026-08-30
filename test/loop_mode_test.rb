# frozen_string_literal: true

require_relative "test_helper"

# MVP-0018 proof for `specrelay-runner loop`.
#
# The loop is driven with injected `claim`/`execute`/`sleeper` collaborators, so
# every property is asserted deterministically without a socket, a child process,
# or a real wall-clock wait. What it does NOT fake is signal handling: the real
# SIGINT/SIGTERM traps are installed and a real signal is delivered, because a
# handler that only works in theory is exactly the class of bug MVP-0017 round 004
# was written to prevent.
class LoopModeTest < Minitest::Test
  Loop = SpecrelayRunner::LoopRunner
  Interval = SpecrelayRunner::PollInterval

  # ---- --poll-interval bounds --------------------------------------------

  def test_the_default_interval_is_conservative
    interval = Interval.resolve(nil)
    assert_predicate interval, :valid?
    assert_equal Interval::DEFAULT, interval.seconds
    assert_nil interval.notice
  end

  def test_an_in_range_interval_is_taken_verbatim
    interval = Interval.resolve("30")
    assert_predicate interval, :valid?
    assert_equal 30, interval.seconds
    assert_nil interval.notice
  end

  def test_a_value_below_the_lower_bound_is_clamped_visibly
    interval = Interval.resolve("1")
    assert_predicate interval, :valid?
    assert_equal Interval::MINIMUM, interval.seconds
    assert_includes interval.notice, "below the #{Interval::MINIMUM}s lower bound"
  end

  def test_a_value_above_the_upper_bound_is_clamped_visibly
    interval = Interval.resolve("86400")
    assert_predicate interval, :valid?
    assert_equal Interval::MAXIMUM, interval.seconds
    assert_includes interval.notice, "above the #{Interval::MAXIMUM}s upper bound"
  end

  def test_a_non_numeric_interval_is_refused_rather_than_defaulted
    interval = Interval.resolve("soon")
    refute_predicate interval, :valid?
    assert_includes interval.error, "whole number of seconds"
  end

  def test_the_cli_refuses_a_non_numeric_interval_without_touching_the_network
    io = StringIO.new
    code = SpecrelayRunner::CLI.run(%w[loop --poll-interval soon], out: io, err: io, env: {})
    assert_equal SpecrelayRunner::CLI::USAGE_ERROR, code
    assert_includes io.string, "whole number of seconds"
  end

  def test_the_cli_refuses_an_unknown_failure_policy
    io = StringIO.new
    code = SpecrelayRunner::CLI.run(%w[loop --on-failure explode], out: io, err: io, env: {})
    assert_equal SpecrelayRunner::CLI::USAGE_ERROR, code
    assert_includes io.string, "--on-failure must be one of"
  end

  # ---- polling ------------------------------------------------------------

  def test_it_stays_alive_across_no_work_responses_and_then_claims
    claims = [ not_claimed("nothing eligible"), not_claimed("nothing eligible"), claimed("DEMO-1") ]
    executed = []
    execute = lambda do |payload|
      executed << payload.dig("run", "task_id")
      true
    end
    status = run_loop(claim: -> { claims.shift }, execute: execute, max_iterations: 3)

    assert_equal Loop::OK, status
    assert_equal [ "DEMO-1" ], executed, "two idle polls must not stop the loop"
    # RUNNER-0001 scope 3/10: a healthy no-work poll is not a durable event. With no
    # terminal to redraw (this is a StringIO) Platform's REASON is still printed —
    # "Platform authorized no run for this runner" is the one not-claimed answer an
    # operator has to act on — but ONCE, not once per poll.
    assert_equal 1, output.scan("idle —").size, "two identical idle polls must not print twice"
    assert_includes output, "nothing eligible"
    refute_includes output, "sleeping", "a healthy wait is not a durable event"
  end

  def test_a_changed_idle_reason_is_printed_again_so_a_new_state_is_never_hidden
    reasons = [ "nothing eligible", "nothing eligible", "runner has no workspace grant" ]
    run_loop(claim: -> { not_claimed(reasons.shift) }, execute: ->(_p) { true }, max_iterations: 3)

    assert_equal 2, output.scan("idle —").size
    assert_includes output, "runner has no workspace grant"
  end

  # The transient half of the same behaviour: with a terminal to redraw, a healthy
  # poll adds NO line at all — the row is replaced in place.
  def test_in_a_terminal_healthy_idle_polls_add_no_durable_lines_at_all
    io = StringIO.new
    presenter = SpecrelayRunner::TerminalPresenter.new(out: io, transient: true, columns: 100)
    run_loop(claim: -> { not_claimed("nothing eligible") }, execute: ->(_p) { true },
             max_iterations: 5, presenter: presenter)

    # Only the runner's own `[loop] ` lines are durable; the transient row carries no
    # prefix, so counting the prefix counts terminal history exactly.
    assert_equal 4, io.string.scan("[loop] ").size,
                 "five idle polls may add nothing beyond the 2 start lines and the 2 stop lines"
    refute_includes io.string, "[loop] idle"
    assert_includes io.string, "no eligible work", "the state is still visible — on the transient row"
  end

  def test_it_claims_and_executes_exactly_one_run_at_a_time
    overlapping = false
    active = false
    execute = lambda do |_payload|
      overlapping ||= active
      active = true
      # If the loop could start a second executor, it would have to be while this
      # one is still inside `execute`.
      active = false
      true
    end
    run_loop(claim: -> { claimed("DEMO-N") }, execute: execute, max_iterations: 4)

    refute overlapping, "the loop must never start a second executor while one is active"
    assert_equal 4, output.scan("executing —").size
  end

  def test_a_completed_run_polls_again_immediately_rather_than_sleeping
    run_loop(claim: -> { claimed("DEMO-1") }, execute: ->(_p) { true }, max_iterations: 1)

    assert_includes output, "run completed — polling again immediately"
    refute_includes output, "sleeping", "a drained queue should not be delayed by an artificial wait"
  end

  # ---- failure handling ---------------------------------------------------

  def test_a_failed_run_is_never_presented_as_idle_and_sets_a_failing_exit_status
    status = run_loop(claim: -> { claimed("DEMO-BAD") }, execute: ->(_p) { false }, max_iterations: 1)

    assert_equal Loop::FAILED, status
    assert_includes output, "run FAILED"
    assert_includes output, "reported to Platform through the terminal-result contract"
    refute_includes output, "idle —"
  end

  def test_the_default_failure_policy_keeps_polling
    status = run_loop(claim: -> { claimed("DEMO-BAD") }, execute: ->(_p) { false }, max_iterations: 3)

    assert_equal Loop::FAILED, status
    assert_equal 3, output.scan("run FAILED").size, "continue means the loop survives a failed run"
  end

  def test_the_stop_failure_policy_ends_the_session_after_one_failure
    status = run_loop(claim: -> { claimed("DEMO-BAD") }, execute: ->(_p) { false },
                      max_iterations: 5, on_failure: Loop::ON_FAILURE_STOP)

    assert_equal Loop::FAILED, status
    assert_equal 1, output.scan("run FAILED").size
    assert_includes output, "stopping after a failed run"
  end

  # ---- MAPIAI-107 S11: a released pre-provider refusal ends the session ---
  #
  # The one execution outcome a session must not poll past. Every other failure has already been
  # REPORTED, so the run is terminal and the next poll is about different work; a deterministic
  # refusal hands the claim back instead, which makes the very same run eligible again. Under the
  # default `continue` policy a loop that only learned "failed" reclaimed and re-refused it — the
  # live session did so twelve times in a row.

  def test_a_release_attempted_pre_provider_refusal_stops_the_session_even_under_default_continue
    claims = 0
    claim = lambda do
      claims += 1
      claimed("DEMO-REFUSED")
    end
    status = run_loop(claim: claim, execute: ->(_p) { Loop::RELEASE_ATTEMPTED_REFUSAL }, max_iterations: 5)

    assert_equal Loop::FAILED, status
    assert_equal 1, claims, "the released run is eligible again; claiming it a second time re-refuses it"
    assert_equal 1, output.scan("run REFUSED before the provider").size
    assert_includes output, "stopping after a pre-provider refusal"
    refute_includes output, "continuing to poll", "the continue policy must not apply to this outcome"
    assert_includes output, "session totals — 1 run(s) executed, 1 failed",
                    "the attempt really happened and is counted once"
    # Whether Platform accepted the release is Execution's to report; the loop may not assert it.
    refute_includes output, "claimable again"
    refute_includes output, "lease will expire"
  end

  # The disposition is about THIS outcome, not about the policy: `--on-failure stop` already
  # stopped, and must still say so in its own words rather than acquire a second meaning.
  def test_the_stop_policy_is_unchanged_by_the_release_attempted_refusal_disposition
    status = run_loop(claim: -> { claimed("DEMO-BAD") }, execute: ->(_p) { false },
                      max_iterations: 5, on_failure: Loop::ON_FAILURE_STOP)

    assert_equal Loop::FAILED, status
    assert_includes output, "stopping after a failed run"
    refute_includes output, "pre-provider refusal"
  end

  def test_a_transport_failure_backs_off_with_a_bound_and_keeps_polling
    attempts = 0
    claim = lambda do
      attempts += 1
      raise SpecrelayRunner::PlatformClient::Error, "could not reach Platform at http://127.0.0.1:1: SocketError"
    end
    status = run_loop(claim: claim, execute: ->(_p) { true }, max_iterations: 4, poll_seconds: 100)

    assert_equal Loop::OK, status, "a reachability problem is not a failed run"
    assert_equal 4, attempts, "the loop keeps polling through a transport failure"
    assert_includes output, "polling failed —"
    # 100, 200, then 400 clamped to the cap, then the cap again.
    assert_equal [ 100, 200, Loop::MAX_BACKOFF_SECONDS, Loop::MAX_BACKOFF_SECONDS ], announced_waits,
                 "backoff grows exponentially and is capped at #{Loop::MAX_BACKOFF_SECONDS}s"
  end

  def test_a_rejected_credential_stops_immediately_with_a_remedy
    claim = -> { raise SpecrelayRunner::PlatformClient::Unauthorized, "401 from /api/runner/claim" }
    status = run_loop(claim: claim, execute: ->(_p) { true }, max_iterations: 10)

    assert_equal Loop::FAILED, status
    assert_includes output, "credential was rejected by Platform"
    assert_includes output, "specrelay-runner connect"
    assert_empty announced_waits, "a credential that will never work must not be retried on a timer"
  end

  def test_a_transport_failure_message_is_redacted
    claim = -> { raise SpecrelayRunner::PlatformClient::Error, "refused for token sk-live-LEAKME-0123456789" }
    run_loop(claim: claim, execute: ->(_p) { true }, max_iterations: 1)

    refute_includes output, "sk-live-LEAKME-0123456789"
    assert_includes output, "[REDACTED]"
  end

  # ---- signals ------------------------------------------------------------

  def test_a_signal_while_idle_stops_cleanly_and_says_it_was_idle
    # The signal is delivered from inside the sleep, i.e. exactly where an operator's
    # Ctrl-C lands when the runner is waiting for work.
    signal_on_first_sleep!
    status = run_loop(claim: -> { not_claimed("nothing eligible") }, execute: ->(_p) { true },
                      max_iterations: 10, install_signals: true)

    assert_equal Loop::OK, status
    assert_includes output, "stopped by signal while IDLE"
    assert_includes output, "nothing was claimed"
  end

  def test_a_signal_during_an_execution_says_the_run_finished_reporting_first
    execute = lambda do |_payload|
      Process.kill("INT", Process.pid)
      sleep 0.05 # let the trap run
      true
    end
    status = run_loop(claim: -> { claimed("DEMO-1") }, execute: execute,
                      max_iterations: 10, install_signals: true)

    assert_equal Loop::OK, status
    assert_includes output, "stopped by signal DURING an execution"
    assert_includes output, "reported its result first"
  end

  def test_it_restores_the_previous_signal_handlers
    marker = proc { :mine }
    previous = Signal.trap("INT", marker)
    run_loop(claim: -> { not_claimed("idle") }, execute: ->(_p) { true }, max_iterations: 1,
             install_signals: true)
    restored = Signal.trap("INT", previous)

    assert_equal marker, restored, "the loop must not leave its own handler installed"
  ensure
    Signal.trap("INT", previous || "DEFAULT")
  end

  # ---- claim-once compatibility ------------------------------------------

  def test_claim_once_is_unchanged_and_prints_no_loop_status
    root, executor = DemoWorkspace.build
    platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: "DEMO-ONCE", executor_command: executor)).start
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: once-runner
        display_name: Once Runner
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{root}
    YAML
    io = StringIO.new
    code = SpecrelayRunner::CLI.run(%W[claim-once --config #{path}], out: io, err: io,
                                                                    env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] })

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, io.string
    refute_includes io.string, "[loop]", "claim-once must remain a single shot with no loop output"
    assert_equal 1, platform.requests_to("/api/runner/claim").size, "exactly one claim request"
    assert_equal 1, platform.requests_to("/api/runner/reports").size, "exactly one report"
  ensure
    platform&.stop
    FileUtils.remove_entry(root) if root && File.directory?(root)
  end

  # The same property through the REAL Execution -> CLI -> LoopRunner path, because the unit test
  # above can only prove what the loop does with the disposition, not that a genuine refusal
  # produces one. The refusal is real: the reviewed head this claim names is not what the remote
  # shows, so the runner hands the claim back before any provider — and Platform offers the same
  # run again, exactly as it did in the live session this ticket exists to fix.
  #
  # `claim_limit` is the fake's bound rather than the loop's: a session that fails to stop would
  # otherwise never return, and a hanging test proves nothing.
  def test_a_real_pre_provider_refusal_stops_a_default_continue_loop_after_one_claim
    code, output, platform, gh_log = run_refusing_loop

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_equal 1, platform.requests_to("/api/runner/claim").size,
                 "the released run is eligible again; a session that polls past this re-refuses it"
    assert_equal 1, platform.requests_to("/api/runner/claim_releases").size,
                 "the claim is still handed back, so another machine can try"
    assert_empty platform.requests_to("/api/runner/reports"), "nothing was executed to report"
    assert_includes output, "session totals — 1 run(s) executed, 1 failed"
    assert_includes output, "stopping after a pre-provider refusal"
    # The release RESULT is Execution's to state, and here it really did succeed.
    assert_includes output, "Released this claim on Platform; the run is claimable again."
    refute_includes output, "credential was rejected", "the session stopped on its own, not on the fake's bound"
    assert_equal 0, FakeGithub.pr_creates(gh_log)
  end

  # CR-001 F2 — the same stop, when Platform REFUSED the release.
  #
  # The disposition is about a deterministic pre-provider refusal that attempted a release, not
  # about the release having succeeded: either way this session must not try the same run again.
  # What must differ is what the operator is told, and only `Execution#release_claim` may say it.
  def test_a_refusal_whose_release_platform_rejected_stops_the_same_way_and_claims_no_success
    code, output, platform, gh_log = run_refusing_loop(release_status: 500)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_equal 1, platform.requests_to("/api/runner/claim").size
    assert_equal 1, platform.requests_to("/api/runner/claim_releases").size,
                 "one release ATTEMPT and no retry of it"
    assert_empty platform.requests_to("/api/runner/reports")
    assert_includes output, "session totals — 1 run(s) executed, 1 failed"
    assert_includes output, "stopping after a pre-provider refusal"
    # What the operator must be told, and what must never be claimed.
    assert_includes output, "its lease will expire on Platform"
    refute_includes output, "the run is claimable again",
                     "nothing released the claim, so nothing may say the run is claimable"
    refute_includes output, "Released this claim on Platform"
    assert_equal 0, FakeGithub.pr_creates(gh_log)
  end

  # One deterministic pre-provider refusal, driven through the REAL Execution -> CLI -> LoopRunner
  # path rather than an injected lambda: the reviewed head this claim names is not what the remote
  # shows, so the runner hands the claim back before any provider.
  #
  # `claim_limit` is the fake's bound rather than the loop's. A session that fails to stop would
  # otherwise never return, and a hanging test proves nothing.
  def run_refusing_loop(release_status: 201)
    @loop_root, = DemoWorkspace.build
    bare = FakeGithub.add_remote(@loop_root)
    %w[main DEMO-LOOP].each do |branch|
      system("git", "-C", @loop_root, "push", "-q", "origin", "HEAD:refs/heads/#{branch}", exception: true)
    end
    gh_dir, gh_log, = FakeGithub.gh_bin(bare: bare)

    reviewed = { "repository_key" => "tiny-demo-workspace",
                 "clone_url" => "git@github.com:SpecRelay/tiny-demo-workspace.git",
                 "branch" => "DEMO-LOOP", "head_commit" => "a" * 40,
                 "pull_request_url" => "https://github.com/SpecRelay/tiny-demo-workspace/pull/9" }
    payload = claim_payload_for(task_id: "DEMO-LOOP", executor_command: "/bin/true",
                                publication: {}, rework: { "repositories" => [ reviewed ] })
    @loop_platform = FakePlatform.new(claim_payload: payload, claim_limit: 4,
                                      release_status: release_status).start
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{@loop_platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: loop-runner
        display_name: Loop Runner
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{@loop_root}
    YAML

    io = StringIO.new
    code = SpecrelayRunner::CLI.run(%W[loop --config #{path} --on-failure continue], out: io, err: io,
                                    env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
                                           "PATH" => "#{gh_dir}:#{ENV['PATH']}", "HOME" => ENV["HOME"].to_s })
    [ code, io.string, @loop_platform, gh_log ]
  end


  def setup
    @pending_signal = nil
  end

  # Only the two tests that build a real loop harness set these.
  def teardown
    @loop_platform&.stop
    FileUtils.remove_entry(@loop_root) if @loop_root && File.directory?(@loop_root)
  end

  private

  def output = @io.string

  # The wait durations the loop ANNOUNCED, in order. Asserting on the operator-
  # visible line rather than on the injected sleeper keeps the assertion about
  # behaviour the operator can actually see.
  def announced_waits
    output.scan(/^\[loop\] sleeping (\d+)s until/).flatten.map(&:to_i)
  end

  def run_loop(claim:, execute:, max_iterations:, poll_seconds: 60,
               on_failure: Loop::ON_FAILURE_CONTINUE, install_signals: false, presenter: nil)
    @io = StringIO.new
    @clock = FakeClock.new
    Loop.call(out: @io, err: @io, claim: claim, execute: execute, poll_seconds: poll_seconds,
              on_failure: on_failure, install_signals: install_signals, max_iterations: max_iterations,
              sleeper: sleeper, clock: @clock, presenter: presenter)
  end

  # Never actually sleeps: it ADVANCES the injected monotonic clock by the slice the
  # loop asked for, so a 300-second backoff costs no wall-clock time and the
  # countdown is still driven by real elapsed-time arithmetic rather than by a
  # counter that only exists in the test.
  #
  # It also delivers a queued signal at the first slice — which is exactly where an
  # operator's Ctrl-C lands while the runner is waiting for work.
  def sleeper
    lambda do |slice|
      @clock.advance(slice)
      pending = @pending_signal
      @pending_signal = nil
      pending&.call
      nil
    end
  end

  # A monotonic clock the test owns, so waiting is deterministic and instant.
  class FakeClock
    def initialize = @now = 5_000.0
    def advance(seconds) = @now += seconds.to_f
    def clock_gettime(_id) = @now
  end

  def signal_on_first_sleep!
    @pending_signal = -> { Process.kill("INT", Process.pid) }
  end

  def not_claimed(reason)
    SpecrelayRunner::PlatformClient::ClaimResult.new(claimed: false, payload: { "reason" => reason })
  end

  def claimed(task_id)
    SpecrelayRunner::PlatformClient::ClaimResult.new(
      claimed: true, payload: { "run" => { "id" => "run_#{task_id}", "task_id" => task_id } }
    )
  end
end
