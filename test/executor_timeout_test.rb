# frozen_string_literal: true

require_relative "test_helper"

# A REAL wall-clock timeout against a real hanging process: the runner's own Timeout and
# process-group kill are what end it, not a stub.
#
# This proof used to live in real_executor_flow_test.rb, driven by a claimed payload carrying a
# two-second timeout. Once a claimed profile had to be EXACT, a payload could no longer shorten the
# approved 1800-second timeout — so provoking it through the whole flow would mean waiting half an
# hour. It is exercised here at the boundary that actually owns the timeout instead. What the flow
# added on top was the CLASSIFICATION, which claude_profile_test.rb and codex_profile_test.rb prove
# against this same `timed_out` result.
class ExecutorTimeoutTest < Minitest::Test
  def setup
    @worktree = Dir.mktmpdir("executor-timeout-worktree-")
    @staging = Dir.mktmpdir("executor-timeout-staging-")
    @bin = Dir.mktmpdir("executor-timeout-bin-")
  end

  def teardown
    [ @worktree, @staging, @bin ].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  # A child that sleeps far past the timeout and records that it started, so the assertions are
  # about a process that really ran rather than about one that failed to launch.
  def hanging_executable(name)
    started = File.join(@bin, "started")
    path = File.join(@bin, name)
    File.write(path, "#!/bin/sh\n: > #{started}\nsleep 600\n")
    FileUtils.chmod(0o755, path)
    started
  end

  def run_executor(command:, timeout_seconds:)
    SpecrelayRunner::Executor.new(
      config: { "command" => command, "args" => [], "prompt_delivery" => "file_argument",
                "timeout_seconds" => timeout_seconds, "env" => {} },
      # The double's own directory FIRST, then the ordinary system directories the child's own
      # `sleep` comes from — the shape of a real host PATH, not a synthetic one.
      worktree_path: @worktree, staging_dir: @staging, env: { "PATH" => "#{@bin}:/usr/bin:/bin" }
    ).run("the prompt")
  end

  def test_a_hanging_executor_times_out_and_is_reported_as_such
    started = hanging_executable("hanging-executor")

    result = run_executor(command: "hanging-executor", timeout_seconds: 2)

    assert File.exist?(started), "the child must really have started"
    assert result.timed_out, "a child that outlived the timeout must be reported as timed out"
    refute result.success?
    assert_nil result.launch_error, "a timeout is not a launch failure"
  end

  # The two endings a terminal report has to tell apart: a child that ran and outlived its limit,
  # and one that could not be started at all.
  def test_an_absent_executable_is_a_launch_error_rather_than_a_timeout
    result = run_executor(command: "not-installed-anywhere", timeout_seconds: 2)

    refute result.timed_out
    refute_nil result.launch_error
    refute result.success?
  end

  # The timeout is bounded by the profile's own value, so a child well inside it is untouched.
  def test_a_child_inside_the_timeout_is_not_killed
    path = File.join(@bin, "quick-executor")
    File.write(path, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, path)

    result = run_executor(command: "quick-executor", timeout_seconds: 30)

    refute result.timed_out
    assert result.success?
  end
end
