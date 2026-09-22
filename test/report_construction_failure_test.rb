# frozen_string_literal: true

require_relative "test_helper"

# What one execution does when its REPORT cannot be built.
#
# The bundle is the last thing every reporting path makes before it says anything to Platform,
# and making it serializes the manifest through YAML — so it runs code this process loads
# lazily. A report-generation dependency that is broken or missing on the host raises from
# exactly there, after the work is over and already decided. Unhandled, that replaced a known
# verification or executor failure with a traceback about the reporting machinery, and the
# command left through the interpreter instead of through its controlled non-zero exit.
#
# Every fault here is injected for the duration of one block, into the process running the test:
# no installed library is altered, no file is corrupted, and production carries no test hook.
# S1, S2 and the first half of S3 fail the REAL builder, at its real `YAML.dump`, which is the
# incident's own shape; the rest fail the one call the three paths share.
class ReportConstructionFailureTest < Minitest::Test
  TASK = "DEMO-0001"
  Loop = SpecrelayRunner::LoopRunner
  CLI = SpecrelayRunner::CLI

  # A credential shape and an absolute local path, seeded into the causes so their ABSENCE from
  # the diagnostic is an assertion rather than an assumption. Neither is real.
  SEEDED_TOKEN = "sk-live-NOT-A-REAL-TOKEN-0123456789"
  SEEDED_PATH = "/Users/testoperator/private-checkout/manifest.yml"

  def setup
    @root, @executor = DemoWorkspace.build
    use_fixture(fixture_dir, @executor)
    @bare = FakeGithub.add_remote(@root)
    @gh_dir, @gh_log, = FakeGithub.gh_bin(bare: @bare)
  end

  def teardown
    @platform&.stop
    @loop_platform&.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    FileUtils.remove_entry(@loop_root) if @loop_root && File.directory?(@loop_root)
  end

  # ---- S1: a failed verification, and a builder that cannot load -----------

  # The primary failure is known, and it is the thing the operator has to act on. The report
  # error is a SECOND fact about why none of it was delivered, not a correction of the first.
  def test_a_failed_verification_survives_a_load_error_from_the_real_builder
    start(expected_heading: "Never Present")

    code, output = with_unloadable_yaml { run_cli }

    assert_equal CLI::RUN_FAILED, code, output
    assert_includes output, "verification failed in", "the primary failure must still be named"
    assert_includes output, "LoadError", "the secondary failure names its own class"
    assert_includes output, "Final result was not submitted to Platform"
    assert_empty @platform.requests_to("/api/runner/reports"), "a bundle that never built cannot be uploaded"
    assert_empty @platform.requests_to("/api/runner/claim_releases")
    assert_equal 0, FakeGithub.pr_creates(@gh_log), "a failed verification publishes nothing"
    assert_path_exists worktree, "the task environment is the evidence and must not be released"
    refute_includes output, "Released the task environment"
  end

  # One attempt, one build. A fallback that retried the builder would fail the same way and
  # could only add noise to a diagnosis the operator already has.
  def test_the_builder_is_invoked_once_and_the_fallback_serializes_nothing
    start(expected_heading: "Never Present")

    dumps = 0
    code, = YAML.stub(:dump, ->(*) { dumps += 1; raise LoadError, "cannot load such file -- psych" }) { run_cli }

    assert_equal CLI::RUN_FAILED, code
    assert_equal 1, dumps, "the builder ran once and the fallback did not reach for YAML again"
  end

  # ---- S2: a healthy run, and a builder that cannot load -------------------

  # Verification passed and publication had already happened when construction failed. Both facts
  # stay true: the summary says verification passed, and nothing claims the push never occurred.
  def test_a_passing_verification_and_an_earlier_publication_are_not_retracted
    start

    code, output = with_unloadable_yaml { run_cli }

    assert_equal CLI::RUN_FAILED, code, output
    assert_includes output, "1 passed", "the verification that really passed is still reported"
    assert_includes output, "Final result was not submitted to Platform"
    assert_equal 1, FakeGithub.pr_creates(@gh_log), "publication precedes construction and already happened"
    refute_includes output, "nothing was published", "publication happened and cannot be un-said"
    assert_empty @platform.requests_to("/api/runner/reports")
    assert_path_exists worktree
    refute_includes output, "Released the task environment"
  end

  # ---- S3: an ordinary construction error, and what must not leak ----------

  # Same boundary, an ordinary error rather than a missing dependency, reached through `submit`.
  def test_an_ordinary_construction_error_is_controlled_and_sanitized
    start

    code, output = with_failing_builder(IOError.new("failed writing #{SEEDED_PATH} for #{SEEDED_TOKEN}")) { run_cli }

    assert_equal CLI::RUN_FAILED, code, output
    assert_includes output, "IOError"
    assert_includes output, "Final result was not submitted to Platform"
    refute_includes output, SEEDED_TOKEN, "a credential shape must not reach the terminal"
    refute_includes output, SEEDED_PATH, "an absolute local path must not reach the terminal"
    assert_includes output, SpecrelayRunner::Redaction::REDACTION
    assert_includes output, SpecrelayRunner::PrivatePaths::REDACTION
    refute_match(/report_construction_failure_test\.rb:\d+/, output, "no backtrace is ever printed")
  end

  # The unmeasured-report path, whose PRIMARY cause is dynamic too: both causes are sanitized by
  # the same owner, so neither can leak through the other.
  def test_both_causes_are_sanitized_on_the_unmeasured_report_path
    start
    inject_measurement_failure("Too many open files reading #{SEEDED_PATH} with #{SEEDED_TOKEN}")

    code, output = with_failing_builder(IOError.new("cannot serialize #{SEEDED_PATH} for #{SEEDED_TOKEN}")) { run_cli }

    assert_equal CLI::RUN_FAILED, code, output
    assert_includes output, "could not determine what the executor changed", "the primary cause is kept"
    assert_includes output, "Final result was not submitted to Platform"
    refute_includes output, SEEDED_TOKEN
    refute_includes output, SEEDED_PATH
    assert_empty @platform.requests_to("/api/runner/reports")
  ensure
    remove_measurement_failure
  end

  # The boundary is narrow on purpose. An Interrupt is the operator, and a SystemExit is a
  # deliberate ending; neither is a report problem, and neither may be converted into one.
  def test_an_interrupt_and_a_system_exit_still_escape_the_build_boundary
    start
    assert_raises(Interrupt) { with_failing_builder(Interrupt.new) { run_cli } }

    start
    assert_raises(SystemExit) { with_failing_builder(SystemExit.new(9)) { run_cli } }
  end

  # ---- S4: an executor failure, through the failed-report path -------------

  # The executor's own exit status is the primary evidence and survives. Nothing invents a
  # verification result for a run whose verification never ran.
  def test_an_executor_failure_keeps_its_exit_evidence_and_claims_no_verification
    File.write(@executor, "#!/usr/bin/env ruby\nwarn \"[fake-executor] provider call failed\"\nexit 3\n")
    FileUtils.chmod(0o755, @executor)
    start

    code, output = with_failing_builder(IOError.new("broken report writer")) { run_cli }

    assert_equal CLI::RUN_FAILED, code, output
    assert_includes output, "executor exited 3", "the provider's own failure is the headline"
    assert_includes output, "Final result was not submitted to Platform"
    refute_includes output, "verification", "no verification ran, so none may be reported"
    assert_empty @platform.requests_to("/api/runner/reports")
  end

  # The same path reached by a refusal rather than a crashed provider: a selection this runner
  # will not act on. The refusal reason is the primary cause and still arrives.
  def test_a_refused_selection_keeps_its_reason_through_the_same_boundary
    use_fixture(fixture_dir, @executor, env: { "FAKE_EXECUTOR_SELECTION_JSON" => "{ not json" })
    start

    code, output = with_failing_builder(IOError.new("broken report writer")) { run_cli }

    assert_equal CLI::RUN_FAILED, code, output
    assert_includes output, "Refusing to publish #{TASK}", "the refusal reason is the primary cause"
    assert_includes output, "Final result was not submitted to Platform"
    assert_empty @platform.requests_to("/api/runner/reports")
  end

  # ---- S5: the claim-once adapter -----------------------------------------

  # One controlled shot, one non-zero exit, and a transcript that promises nothing it did not do.
  def test_claim_once_exits_one_with_an_explicit_non_submission_and_a_remedy
    start

    code, output = with_unloadable_yaml { run_cli }

    assert_equal 1, code, output
    assert_equal CLI::RUN_FAILED, code
    assert_includes output, "Final result was not submitted to Platform because report construction failed."
    assert_includes output, "bin/platform runner release #{TASK}", "the existing operator remedy is named"
    refute_includes output, "Report stored", "nothing was stored"
    refute_includes output, "failure was reported"
    assert_empty @platform.requests_to("/api/runner/reports")
    assert_empty @platform.requests_to("/api/runner/claim_releases")
    # The message proves what THIS runner did, and asserts nothing about Platform's own state.
    refute_includes output, "The run is still CLAIMED"
    refute_includes output, "claimable again"
  end

  # ---- S6: the loop adapter, under both failure policies -------------------

  def test_the_loop_stops_after_an_unreported_run_even_under_continue
    code, output, platform = run_failing_build_loop(policy: "continue")

    assert_equal CLI::RUN_FAILED, code, output
    assert_equal 1, platform.requests_to("/api/runner/claim").size, "the session must not poll again"
    assert_empty platform.requests_to("/api/runner/reports")
    assert_includes output, "session totals — 1 run(s) executed, 1 failed"
    refute_includes output, "continuing to poll", "the continue policy cannot apply to an unreported run"
    refute_includes output, "the failure was reported to Platform through the terminal-result contract"
  end

  def test_the_loop_stops_the_same_way_under_the_stop_policy
    code, output, platform = run_failing_build_loop(policy: "stop")

    assert_equal CLI::RUN_FAILED, code, output
    assert_equal 1, platform.requests_to("/api/runner/claim").size
    assert_empty platform.requests_to("/api/runner/reports")
    refute_includes output, "the failure was reported to Platform through the terminal-result contract"
  end

  # An operator's Ctrl-C during an execution that could not report must not be answered with the
  # ordinary reassurance that the run reported its result first.
  def test_a_stop_signal_during_an_unreported_run_never_claims_a_result_was_sent
    execute = lambda do |_payload|
      Process.kill("INT", Process.pid)
      sleep 0.05 # let the trap run
      Loop::FAILED
    end
    io = StringIO.new
    status = Loop.call(out: io, err: io, claim: -> { loop_claim("DEMO-1") }, execute: execute,
                       poll_seconds: 60, install_signals: true, max_iterations: 10,
                       sleeper: ->(_s) { nil })

    assert_equal Loop::FAILED, status
    assert_includes io.string, "stopped by signal DURING an execution"
    refute_includes io.string, "reported its result first"
    assert_includes io.string, "NOT submitted to Platform"
  end

  # The pre-provider refusal keeps its own, different ending: two distinct outcomes, two distinct
  # stop reasons, and neither acquires the other's wording.
  def test_the_pre_provider_refusal_disposition_is_unchanged
    io = StringIO.new
    status = Loop.call(out: io, err: io, claim: -> { loop_claim("DEMO-REFUSED") },
                       execute: ->(_p) { Loop::RELEASE_ATTEMPTED_REFUSAL }, poll_seconds: 60,
                       install_signals: false, max_iterations: 5, sleeper: ->(_s) { nil })

    assert_equal Loop::FAILED, status
    assert_includes io.string, "run REFUSED before the provider"
    assert_includes io.string, "stopping after a pre-provider refusal"
    refute_includes io.string, "no final result was submitted"
  end

  # ---- S7: the healthy run, and the ordinary failure it must not become ----

  def test_a_healthy_run_still_succeeds_only_after_an_accepted_submission
    start

    code, output = run_cli

    assert_equal CLI::SUCCESS, code, output
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
    assert_includes output, "Released the task environment #{TASK}"
    refute File.directory?(worktree), "a completed run releases its environment as it always did"
  end

  # An unmeasurable attempt that DID reach Platform is an ordinary reported failure. It keeps the
  # ordinary disposition, so a `continue` session goes on polling exactly as it did before.
  def test_an_acknowledged_unmeasurable_report_keeps_its_ordinary_failure_disposition
    start
    inject_measurement_failure("Too many open files")

    code, output = run_cli

    assert_equal CLI::RUN_FAILED, code, output
    assert_equal 1, @platform.requests_to("/api/runner/reports").size, "this one really was reported"
    refute_includes output, "Final result was not submitted to Platform"

    result = SpecrelayRunner::Execution::Result.new(
      outcome: :publication_failed, message: "x",
      reported_status: SpecrelayRunner::ReportBundle::STATUS_FAILED
    )
    refute_predicate result, :report_unsubmitted?, "an acknowledged failure is not an unsubmitted one"
  ensure
    remove_measurement_failure
  end

  # ---- S8: a submission Platform refused ------------------------------------

  # The bundle built; the upload failed. That is an upload failure, with its own existing
  # meaning, and the narrow boundary must not have swallowed it into the construction case.
  def test_a_rejected_submission_is_not_labelled_a_construction_failure
    start

    code, output = with_rejected_submission { run_cli }

    assert_equal CLI::RUN_FAILED, code, output
    refute_includes output, "Final result was not submitted to Platform",
                     "an answered upload is not a construction failure"
    refute_includes output, "report construction failed"
    assert_includes output, "Runner failed:", "the existing upload-failure path still owns this"
    refute_includes output, "Released the task environment"
    assert_path_exists worktree
  end

  private

  def fixture_dir = @fixture_dir ||= fixture_bin

  def worktree = File.join(@root, ".runs", "worktrees", TASK)

  def start(expected_heading: nil)
    rebuild_workspace(expected_heading) if expected_heading
    @platform&.stop
    @platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK, publication: {})).start
    @config_path = write_config(@platform, @root)
  end

  # A workspace whose verification command asks for a heading the executor never writes, so the
  # run really fails verification rather than being told that it did.
  def rebuild_workspace(expected_heading)
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    @root, @executor = DemoWorkspace.build(expected_heading: expected_heading)
    use_fixture(fixture_dir, @executor)
    @bare = FakeGithub.add_remote(@root)
    @gh_dir, @gh_log, = FakeGithub.gh_bin(bare: @bare)
  end

  def write_config(platform, root)
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, <<~YAML)
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
    path
  end

  def run_cli
    io = StringIO.new
    code = CLI.run(%W[claim-once --config #{@config_path}], out: io, err: io, env: child_env)
    [ code, io.string ]
  end

  def child_env
    { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
      "PATH" => "#{fixture_dir}:#{@gh_dir}:#{ENV['PATH']}", "HOME" => ENV["HOME"].to_s }
  end

  # The real CLI -> LoopRunner -> Execution path with the construction fault in place. The fake's
  # `claim_limit` bounds it: a session that failed to stop would otherwise never return, and a
  # hanging test proves nothing.
  def run_failing_build_loop(policy:)
    @loop_root, loop_executor = DemoWorkspace.build
    use_fixture(fixture_dir, loop_executor)
    bare = FakeGithub.add_remote(@loop_root)
    gh_dir, = FakeGithub.gh_bin(bare: bare)
    @loop_platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK, publication: {}),
                                      claim_limit: 4).start
    path = write_config(@loop_platform, @loop_root)

    io = StringIO.new
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
            "PATH" => "#{fixture_dir}:#{gh_dir}:#{ENV['PATH']}", "HOME" => ENV["HOME"].to_s }
    code = with_unloadable_yaml do
      CLI.run(%W[loop --config #{path} --poll-interval 5 --on-failure #{policy}], out: io, err: io, env: env)
    end
    [ code, io.string, @loop_platform ]
  end

  def loop_claim(task_id)
    SpecrelayRunner::PlatformClient::ClaimResult.new(
      claimed: true, payload: { "run" => { "id" => "run_#{task_id}", "task_id" => task_id } }
    )
  end

  # ---- fault injection ------------------------------------------------------

  # The REAL builder, failing where the incident did. Nothing is installed, moved or corrupted:
  # `YAML.dump` has exactly one caller in this codebase — the report bundle's manifest — so the
  # fault is scoped to report construction by construction rather than by convention.
  def with_unloadable_yaml(&block)
    YAML.stub(:dump, ->(*) { raise LoadError, "cannot load such file -- psych" }, &block)
  end

  # An ordinary failure of the one call the three reporting paths share.
  def with_failing_builder(error, &block)
    SpecrelayRunner::ReportBundle.stub(:build, ->(**) { raise error }, &block)
  end

  # The bundle builds; Platform reads it and refuses it. The upload is deliberately OUTSIDE the
  # build boundary, so this must keep travelling the existing upload-failure path.
  def with_rejected_submission
    SpecrelayRunner::PlatformClient.class_eval do
      alias_method :submit_report_without_injection, :submit_report
      define_method(:submit_report) do |**|
        raise SpecrelayRunner::PlatformClient::RequestFailed.new("Platform request failed (422)", status: 422)
      end
    end
    yield
  ensure
    SpecrelayRunner::PlatformClient.class_eval do
      alias_method :submit_report, :submit_report_without_injection
      remove_method :submit_report_without_injection
    end
  end

  # A change-measurement failure, so the attempt reaches the unmeasured-report path with a
  # primary cause this test controls the text of.
  def inject_measurement_failure(message)
    fired = false
    guard = ->(argv) { argv.first == "git" && argv.include?("status") && !fired }
    SpecrelayRunner::CommandRunner.class_eval do
      alias_method :spawn_process_without_injection, :spawn_process
      define_method(:spawn_process) do |argv|
        if guard.call(argv)
          fired = true
          raise Errno::EMFILE, message
        end
        spawn_process_without_injection(argv)
      end
    end
    @measurement_failure_injected = true
  end

  def remove_measurement_failure
    return unless @measurement_failure_injected

    SpecrelayRunner::CommandRunner.class_eval do
      alias_method :spawn_process, :spawn_process_without_injection
      remove_method :spawn_process_without_injection
    end
    @measurement_failure_injected = false
  end
end
