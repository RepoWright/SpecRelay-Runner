# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "timeout"

# An implementation Run's task environment is handed back once its ending is DEFINITIVE in this
# process: Platform accepted the attempt's terminal result, success or failure, or Platform
# explicitly returned cancellation. Every other ending — a superseded, refused or unreachable
# result, an expired lease, a generic terminal signal — keeps the environment exactly as it is.
#
# Driven through the real `claim-once`/`loop` CLI against the fake Platform over HTTP, on a real
# git worktree built by the project's own `bin/worktree`. The project's release step appends to
# an ORDER log, and so does the fake Platform when it receives a report, so "acknowledgement
# precedes release" is read from one file rather than inferred.
class AcknowledgedTerminalCleanupTest < Minitest::Test
  TASK = "DEMO-0001"
  RUN = "run_test123"

  # The fake Platform, recording the moment it received the report in the same log the project's
  # release step writes to.
  class OrderedPlatform < FakePlatform
    attr_accessor :order_log

    private

    # Platform answers a stored FAILED result `tests_failed` and a stored success `completed`; the
    # shared fake answers `completed` to both, which would make every failure read as success here.
    def report(request)
      File.open(order_log, "a") { |file| file.puts("report") } if order_log
      status, body = super
      failed = request.dig(:body, "terminal_result", "outcome") == "failed"
      failed && status == 201 && body[:outcome] == "completed" ? [ status, body.merge(outcome: "tests_failed") ] : [ status, body ]
    end
  end

  def setup
    build_workspace
  end

  def teardown
    @platform&.stop
    kill_recorded_provider_group
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # ---------------------------------------------------------------- acknowledged failure

  # Scenario 1. A failed provider is reported, Platform accepts the report, and only then is the
  # environment released — its checkout, its owner record and the edit nobody published.
  def test_an_accepted_executor_failure_releases_the_environment_after_the_report
    fail_the_executor

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_equal %w[report release], order, @io.string
    refute File.directory?(worktree), "the owned environment outlived its accepted failure"
    refute File.exist?(owner_file(TASK)), "the project still records an owner for the released environment"
    assert_includes @io.string, "Released the task environment #{TASK}"
  end

  # Scenario 2. A verification failure travels the same accepted terminal result.
  def test_an_accepted_verification_failure_releases_the_environment_after_the_report
    build_workspace(expected_heading: "A heading the executor never writes")

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_equal "failed", @platform.last_terminal_result["outcome"]
    assert_equal %w[report release], order, @io.string
    refute File.directory?(worktree)
  end

  # Scenario 9. Success keeps its ordering: acceptance first, release second.
  def test_an_accepted_success_still_releases_only_after_the_report
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    assert_equal %w[report release], order
    refute File.directory?(worktree)
  end

  # AC4. The envelope is a snapshot taken when the result is SUBMITTED, before any release was
  # attempted, so it cannot say cleanup succeeded — on a success or on a failure.
  def test_every_terminal_envelope_says_cleanup_has_not_yet_succeeded
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string
    assert_release_pending(@platform.last_terminal_result)

    build_workspace
    fail_the_executor
    run_cli
    assert_release_pending(@platform.last_terminal_result)
  end

  # ---------------------------------------------------------------- unacknowledged endings

  # A superseded answer is Platform declining to record the result, even though it answered 201.
  def test_a_superseded_result_keeps_the_environment
    fail_the_executor
    @platform.report_response = [ 201, { outcome: "superseded", execution_state: "CANCELLED",
                                         report: nil, run_state: "CANCELLED" } ]

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_environment_kept
  end

  def test_a_refused_result_keeps_the_environment
    fail_the_executor
    @platform.report_response = [ 422, { error: "terminal result refused" } ]

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_environment_kept
  end

  # ---------------------------------------------------------------- cancellation versus expiry

  # Scenario 3. Platform explicitly cancelled the Run while the provider held it, and the
  # provider left a TERM-resistant descendant in its own group. No late report is sent; the group
  # has ended before the release runs; then the environment is gone.
  def test_an_active_cancellation_releases_after_the_provider_group_has_ended
    leave_a_term_resistant_descendant

    assert_equal SpecrelayRunner::CLI::RUN_FAILED,
                 while_the_provider_runs("state" => "cancelled", "cancel_requested" => true) { run_cli },
                 @io.string

    assert_empty @platform.requests_to("/api/runner/reports"), "a cancelled run received a late report"
    assert_equal %w[group-gone release], order, @io.string
    assert_raises(Errno::ESRCH) { Process.kill(0, -recorded_provider_group) }
    refute File.directory?(worktree)
  end

  # Scenario 4. The same active signal reported as `expired`, and as a generic `terminal`, is not
  # a definitive ending known to this process: nothing is released.
  def test_an_expired_lease_keeps_the_environment
    hold_the_provider

    assert_equal SpecrelayRunner::CLI::RUN_FAILED,
                 while_the_provider_runs("state" => "expired", "cancel_requested" => false) { run_cli },
                 @io.string

    assert_environment_kept
  end

  def test_a_generic_terminal_signal_keeps_the_environment
    hold_the_provider

    assert_equal SpecrelayRunner::CLI::RUN_FAILED,
                 while_the_provider_runs("state" => "terminal", "cancel_requested" => false) { run_cli },
                 @io.string

    assert_environment_kept
  end

  # ---------------------------------------------------------------- cleanup failure

  # Scenario 11. The project cannot release the environment after an accepted failure. The report
  # stands as sent, the exit is nonzero with the project's reason, and the environment keeps its
  # owner so it can be repaired.
  def test_an_incomplete_release_after_an_accepted_failure_is_a_visible_nonzero_outcome
    fail_the_executor
    refuse_release

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_equal 1, @platform.requests_to("/api/runner/reports").size
    assert_includes @io.string, "still allocated"
    assert_includes @io.string, "Release it by hand"
    refute_includes @io.string, "Released the task environment"
    assert File.directory?(worktree)
    assert_equal RUN, File.read(owner_file(TASK))
  end

  # A loop that would otherwise claim more work stops before a second claim.
  def test_an_incomplete_release_stops_the_loop_before_another_claim
    fail_the_executor
    refuse_release
    @platform = start_platform(claim_limit: 2)

    code = Timeout.timeout(45) { run_cli(%w[loop --poll-interval 5 --on-failure continue]) }

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, @io.string
    assert_equal 1, @platform.requests_to("/api/runner/claim").size, "the loop claimed again"
    assert_includes @io.string, "still allocated"
  end

  # ---------------------------------------------------------------- other allocations

  # Scenario 12. Ending this Run changes only this Run's environment. Another Run's allocation, a
  # manual one, and an unrelated runtime file survive byte for byte.
  def test_ending_one_run_leaves_other_allocations_and_shared_resources_unchanged
    allocate("DEMO-0002", run_id: "run_somebody_else")
    allocate("DEMO-0003", run_id: nil)
    shared = File.join(@root, ".runs", "shared-service.state")
    File.write(shared, "shared database handle\n")
    before = snapshot_of(%w[DEMO-0002 DEMO-0003], shared)
    fail_the_executor

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    refute File.directory?(worktree)
    assert_equal before, snapshot_of(%w[DEMO-0002 DEMO-0003], shared)
  end

  private

  def build_workspace(**options)
    @platform&.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    @root, @executor = DemoWorkspace.build(**options)
    FileUtils.mkdir_p(File.join(@root, ".runs"))
    record_release_order
    @platform = start_platform
    @io = StringIO.new
  end

  def start_platform(claim_limit: nil)
    @platform&.stop
    platform = OrderedPlatform.new(claim_payload: claim_payload_for(task_id: TASK, root: @root),
                                   claim_limit: claim_limit)
    platform.order_log = order_log
    platform.start
  end

  def run_cli(command = %w[claim-once])
    SpecrelayRunner::CLI.run([ *command, "--config", config_path ], out: @io, err: @io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
                                    "PATH" => fixture_path(@executor), "HOME" => ENV["HOME"].to_s })
  end

  def config_path
    path = File.join(Dir.mktmpdir("cfg", @root), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{@platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: test-runner
        display_name: Test Runner
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{@root}
    YAML
    path
  end

  def worktree = File.join(@root, ".runs", "worktrees", TASK)
  def owner_file(task) = File.join(@root, ".runs", "owners", task)
  def order_log = File.join(@root, ".runs", "order.log")
  def order = File.exist?(order_log) ? File.read(order_log).split("\n") : []
  def provider_group_file = File.join(@root, ".runs", "provider.pgid")

  # The project's release step records itself — and, when a provider recorded its group, whether
  # that group still exists at the moment the release begins.
  def record_release_order
    path = File.join(@root, "bin", "worktree")
    File.write(path, File.read(path).sub(/^\s*release\)\n/, <<~SH))
      release)
        if [ -f "$ROOT_DIR/.runs/provider.pgid" ]; then
          if kill -0 -- "-$(cat "$ROOT_DIR/.runs/provider.pgid")" 2>/dev/null; then
            echo group-alive >> "$ROOT_DIR/.runs/order.log"
          else
            echo group-gone >> "$ROOT_DIR/.runs/order.log"
          fi
        fi
        echo release >> "$ROOT_DIR/.runs/order.log"
    SH
  end

  # A project whose release fails outright after recording that it was asked.
  def refuse_release
    path = File.join(@root, "bin", "worktree")
    File.write(path, File.read(path).sub("echo release >> \"$ROOT_DIR/.runs/order.log\"\n",
                                         "echo release >> \"$ROOT_DIR/.runs/order.log\"\n" \
                                         "echo 'release is not available' >&2\nexit 9\n"))
  end

  def fail_the_executor
    File.write(@executor, <<~RUBY)
      #!/usr/bin/env ruby
      File.write("unpublished.txt", "an edit nobody published")
      warn "[fake-executor] provider call failed"
      exit 3
    RUBY
    FileUtils.chmod(0o755, @executor)
  end

  # The provider records its own process group, then waits — bounded — until the test has
  # changed Platform's lease signal, so the signal lands while the provider holds the claim.
  def hold_the_provider(prelude = "")
    code = File.read(@executor)
    File.write(@executor, code.sub("# frozen_string_literal: true\n", <<~RUBY))
      # frozen_string_literal: true
      File.write(#{provider_group_file.inspect}, Process.getpgrp.to_s)
      #{prelude}
      200.times { break if File.exist?(#{signalled_file.inspect}); sleep 0.05 }
    RUBY
  end

  # The same, with a descendant forked into the provider's group that ignores TERM and keeps
  # working after the provider itself exits.
  def leave_a_term_resistant_descendant
    hold_the_provider(<<~RUBY)
      fork do
        trap("TERM", "IGNORE")
        STDIN.reopen(File::NULL)
        STDOUT.reopen(File::NULL, "w")
        STDERR.reopen(File::NULL, "w")
        loop { sleep 0.05 }
      end
    RUBY
  end

  def signalled_file = File.join(@root, ".runs", "signalled")

  # Change the lease signal once the provider has recorded itself, then let it continue.
  def while_the_provider_runs(signal)
    watcher = Thread.new do
      200.times { break if File.exist?(provider_group_file); sleep 0.05 }
      @platform.set_signal(signal)
      File.write(signalled_file, "")
    end
    yield
  ensure
    watcher&.join(5)
  end

  def recorded_provider_group = Integer(File.read(provider_group_file).strip)

  def kill_recorded_provider_group
    return unless @root && File.exist?(provider_group_file)

    Process.kill("KILL", -recorded_provider_group)
  rescue Errno::ESRCH, Errno::EPERM, ArgumentError
    nil
  end

  def allocate(task, run_id:)
    arguments = [ File.join(@root, "bin", "worktree"), "create", task ]
    arguments += [ "--run-id", run_id ] if run_id
    out, status = Open3.capture2e(*arguments, chdir: @root)
    assert status.success?, out
    File.write(File.join(@root, ".runs", "worktrees", task, "unpublished.txt"), "#{task} work\n")
  end

  def snapshot_of(tasks, shared)
    tasks.to_h do |task|
      tree = File.join(@root, ".runs", "worktrees", task)
      files = Dir.glob("**/*", File::FNM_DOTMATCH, base: tree).reject { |path| path.start_with?(".git") }
      [ task, { owner: File.read(owner_file(task)),
                files: files.sort.to_h { |path| [ path, File.file?(File.join(tree, path)) ? File.read(File.join(tree, path)) : :dir ] } } ]
    end.merge(shared => File.read(shared))
  end

  def assert_environment_kept
    assert File.directory?(worktree), "the environment was released for an ending that is not definitive\n#{@io.string}"
    assert_equal RUN, File.read(owner_file(TASK))
    refute_includes order, "release"
  end

  def assert_release_pending(terminal)
    refute terminal.dig("cleanup", "succeeded"), "a submitted envelope claimed a cleanup not yet attempted"
    assert_match(/after Platform accepts/, terminal.dig("cleanup", "error").to_s)
  end
end
