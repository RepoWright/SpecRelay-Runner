# frozen_string_literal: true

require_relative "test_helper"

# MAPIAI-93 — the runner's INDEPENDENT replay of the verification the executor selected, at its
# own boundary.
#
# The executor chose these commands and may already have run them; none of that is evidence. This
# class is the only thing that produces a repository's outcome, and it produces it from what the
# processes it launched actually did: an exit status, a timeout, or a failure to launch at all.
#
# Three outcomes and no fourth. `NOT_FOUND` is a first-class answer for a repository with nothing
# to run — it is never turned into a fabricated command or a borrowed success.
class RepositoryVerificationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("verify-")
    File.write(File.join(@dir, "marker.txt"), "final\n")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def repository(path: @dir, relative: "component-a", id: "SpecRelay/component-a")
    SpecrelayRunner::Workspace::Repository.new(id: id, relative_path: relative, path: path,
                                               clone_url: "https://github.com/#{id}.git",
                                               default_branch: "main", branch: "MAPIAI-93",
                                               base_commit: "a" * 40, head_commit: "b" * 40,
                                               changed_files: [ "marker.txt" ], diff: "")
  end

  def verify(commands, repository: repository())
    SpecrelayRunner::RepositoryVerification.call(repository: repository, commands: commands,
                                                 env: { "PATH" => ENV["PATH"].to_s })
  end

  def script(body, name: "check")
    path = File.join(@dir, name)
    File.write(path, "#!/usr/bin/env sh\n#{body}\n")
    FileUtils.chmod(0o755, path)
    "./#{name}"
  end

  # --- S02: a changed repository with no verification at all ----------------

  def test_no_commands_is_not_found_and_carries_no_attempt
    result = verify([])

    assert_equal SpecrelayRunner::RepositoryVerification::NOT_FOUND, result.status
    assert_empty result.attempts, "a repository with nothing to run must not report a command"
    refute result.failed?, "no verification found is a valid, non-blocking outcome"
  end

  # --- S03: every selected command succeeded --------------------------------

  def test_every_zero_exit_is_passed
    result = verify([ [ script("exit 0", name: "ok-one") ], [ script("exit 0", name: "ok-two") ] ])

    assert_equal SpecrelayRunner::RepositoryVerification::PASSED, result.status
    assert_equal 2, result.attempts.length
    assert_equal [ 0, 0 ], result.attempts.map(&:exit_code)
    assert_equal "component-a", result.repository_path
    assert_equal "SpecRelay/component-a", result.repository_id
  end

  # --- S09: the three ways a command fails ----------------------------------

  def test_a_non_zero_exit_is_failed
    result = verify([ [ script("echo boom >&2; exit 3") ] ])

    assert_equal SpecrelayRunner::RepositoryVerification::FAILED, result.status
    assert_equal 3, result.attempts.first.exit_code
    assert_includes result.attempts.first.output, "boom"
  end

  def test_a_command_that_cannot_be_launched_is_failed_rather_than_not_found
    result = verify([ [ "definitely-not-on-this-machine-93" ] ])

    assert_equal SpecrelayRunner::RepositoryVerification::FAILED, result.status
    refute_nil result.attempts.first.launch_error, "a command that never ran is not a passing one"
    assert_nil result.attempts.first.exit_code
  end

  def test_a_timeout_is_failed_and_recorded_as_a_timeout
    result = SpecrelayRunner::RepositoryVerification.call(
      repository: repository, commands: [ [ script("sleep 30") ] ],
      env: { "PATH" => ENV["PATH"].to_s }, timeout_seconds: 1
    )

    assert_equal SpecrelayRunner::RepositoryVerification::FAILED, result.status
    assert result.attempts.first.timed_out, "a command killed at the deadline did not pass"
  end

  # Every changed repository must receive a COMPLETE outcome, so an ordinary failure does not
  # stop the remaining bounded commands — the operator sees all of them, not just the first.
  def test_a_failure_does_not_stop_the_remaining_commands
    result = verify([ [ script("exit 1", name: "fails") ], [ script("exit 0", name: "then-passes") ] ])

    assert_equal SpecrelayRunner::RepositoryVerification::FAILED, result.status
    assert_equal 2, result.attempts.length
    assert_equal [ 1, 0 ], result.attempts.map(&:exit_code)
  end

  # --- S08: the repository root, and the FINAL files ------------------------

  def test_commands_run_from_the_repository_root_not_the_workspace_above_it
    nested = File.join(@dir, "inner")
    FileUtils.mkdir_p(nested)
    File.write(File.join(nested, "marker.txt"), "inner-final\n")
    File.write(File.join(nested, "check"), "#!/usr/bin/env sh\ngrep -q inner-final marker.txt\n")
    FileUtils.chmod(0o755, File.join(nested, "check"))

    result = verify([ [ "./check" ] ], repository: repository(path: nested, relative: "inner"))

    assert_equal SpecrelayRunner::RepositoryVerification::PASSED, result.status,
                 "a relative program and a relative read only resolve when cwd is the repository root"
  end

  def test_a_command_sees_the_final_file_the_executor_left
    name = script("grep -q edited-last marker.txt")
    File.write(File.join(@dir, "marker.txt"), "edited-last\n")

    assert_equal SpecrelayRunner::RepositoryVerification::PASSED, verify([ [ name ] ]).status
  end

  # --- argv only: no shell, ever -------------------------------------------

  def test_arguments_are_passed_as_argv_and_never_interpreted_by_a_shell
    name = script('printf "%s" "$1"', name: "echo-arg")
    result = verify([ [ name, "$(touch pwned); a && b" ] ])

    assert_equal SpecrelayRunner::RepositoryVerification::PASSED, result.status
    assert_includes result.attempts.first.output, "$(touch pwned); a && b"
    refute_path_exists File.join(@dir, "pwned"), "an argv element must never reach a shell"
  end

  # --- bounded, redacted evidence ------------------------------------------

  def test_command_output_is_redacted_before_it_becomes_evidence
    name = script('echo "leaking sk-live-DO-NOT-LEAK-0123456789"')
    output = verify([ [ name ] ]).attempts.first.output

    refute_includes output, "sk-live-DO-NOT-LEAK"
    assert_includes output, "[REDACTED]"
  end

  def test_command_output_is_bounded
    name = script("ruby -e 'print(\"y\" * 200_000)'")
    output = verify([ [ name ] ]).attempts.first.output

    assert_operator output.bytesize, :<=, SpecrelayRunner::RepositoryVerification::MAX_OUTPUT_BYTES
  end

  # The argv travels into a report, a pull-request body and an operator's terminal, so it is
  # redacted for the same reason the output is.
  def test_the_recorded_argv_is_redacted
    argv = [ script("exit 0"), "--token=sk-live-DO-NOT-LEAK-0123456789" ]

    refute_includes verify([ argv ]).attempts.first.argv.join(" "), "sk-live-DO-NOT-LEAK"
  end

  # --- the one status rule -------------------------------------------------

  # One authoritative derivation, asserted directly, so execution, report projection and the
  # tests cannot each hold their own idea of what PASSED means.
  def test_the_status_rule_has_one_implementation
    rule = SpecrelayRunner::RepositoryVerification

    assert_equal rule::NOT_FOUND, rule.status_for([])
    assert_equal rule::PASSED, rule.status_for([ attempt(exit_code: 0) ])
    assert_equal rule::FAILED, rule.status_for([ attempt(exit_code: 0), attempt(exit_code: 1) ])
    assert_equal rule::FAILED, rule.status_for([ attempt(exit_code: nil, timed_out: true) ])
    assert_equal rule::FAILED, rule.status_for([ attempt(exit_code: nil, launch_error: "no such file") ])
  end

  def attempt(exit_code:, timed_out: false, launch_error: nil)
    SpecrelayRunner::RepositoryVerification::Attempt.new(
      argv: [ "bin/test" ], exit_code: exit_code, timed_out: timed_out,
      launch_error: launch_error, output: ""
    )
  end
end
