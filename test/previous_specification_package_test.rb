# frozen_string_literal: true

require_relative "test_helper"

# MVP-0028 decision D6 — direct unit coverage for {SpecrelayRunner::Specification::PreviousSpecificationPackage}.
# `specification_generation_revision_test.rb` proves the real-git end-to-end behavior through the
# CLI; this file proves each failure boundary in isolation, including the secret-redaction
# positive control the workspace's validation requires: a git error can legitimately echo the
# remote URL it failed on, and this class must never let that reach an operator unredacted.
class PreviousSpecificationPackageTest < Minitest::Test
  PreviousSpecificationPackage = SpecrelayRunner::Specification::PreviousSpecificationPackage
  Result = SpecrelayRunner::CommandRunner::Result

  # A `commands` double that returns exactly what each test configures for `git`/`git_value`,
  # without invoking a real process — this file is about the class's OWN branching, not git.
  class FakeCommands
    def initialize(git_results: {}, git_values: {})
      @git_results = git_results
      @git_values = git_values
      @calls = []
    end

    attr_reader :calls

    def git(args, extra_env: {})
      @calls << [ :git, args ]
      @git_results.fetch(args, Result.new(exit_code: 0, stdout: "", stderr: "", duration_seconds: 0.1,
                                          timed_out: false))
    end

    def git_value(args, extra_env: {})
      @calls << [ :git_value, args ]
      @git_values[args]
    end

    def failure_reason(result, label)
      return "#{label} timed out" if result.timed_out?

      "#{label} failed: #{result.stderr}"
    end
  end

  COMMIT = "a" * 40

  def test_reads_every_file_a_branch_carries_at_the_package_path
    commands = FakeCommands.new(
      git_values: {
        %w[rev-parse FETCH_HEAD] => COMMIT,
        [ "show", "#{COMMIT}:specs/SR-700/spec.md" ] => "# SR-700\n\nprevious text",
        [ "show", "#{COMMIT}:specs/SR-700/analysis/business.md" ] => "business text"
      },
      git_results: {
        [ "fetch", "--quiet", "origin", "specrelay/spec/SR-700-x" ] =>
          Result.new(exit_code: 0, stdout: "", stderr: "", duration_seconds: 0.1, timed_out: false),
        [ "ls-tree", "-r", "--name-only", COMMIT, "--", "specs/SR-700" ] =>
          Result.new(exit_code: 0, stdout: "specs/SR-700/spec.md\nspecs/SR-700/analysis/business.md\n",
                    stderr: "", duration_seconds: 0.1, timed_out: false)
      }
    )

    result = PreviousSpecificationPackage.call(commands: commands, branch: "specrelay/spec/SR-700-x",
                                               package_path: "specs/SR-700")

    assert result.ok?
    assert_equal({ "spec.md" => "# SR-700\n\nprevious text", "analysis/business.md" => "business text" },
                result.files)
    assert_equal "specrelay/spec/SR-700-x", result.branch
  end

  def test_a_fetch_failure_is_unreadable_not_a_crash
    commands = FakeCommands.new(
      git_results: {
        [ "fetch", "--quiet", "origin", "branch-x" ] =>
          Result.new(exit_code: 1, stdout: "", stderr: "fatal: could not read from remote",
                    duration_seconds: 0.1, timed_out: false)
      }
    )

    result = PreviousSpecificationPackage.call(commands: commands, branch: "branch-x", package_path: "specs/SR-700")

    refute result.ok?
    assert_equal PreviousSpecificationPackage::UNREADABLE, result.failure_class
    assert_includes result.message, "git fetch failed"
  end

  def test_an_empty_tree_at_the_package_path_is_unreadable_with_a_named_reason
    commands = FakeCommands.new(
      git_values: { %w[rev-parse FETCH_HEAD] => COMMIT },
      git_results: {
        [ "fetch", "--quiet", "origin", "branch-x" ] =>
          Result.new(exit_code: 0, stdout: "", stderr: "", duration_seconds: 0.1, timed_out: false),
        [ "ls-tree", "-r", "--name-only", COMMIT, "--", "specs/SR-700" ] =>
          Result.new(exit_code: 0, stdout: "", stderr: "", duration_seconds: 0.1, timed_out: false)
      }
    )

    result = PreviousSpecificationPackage.call(commands: commands, branch: "branch-x", package_path: "specs/SR-700")

    refute result.ok?
    assert_includes result.message, "does not carry a previously"
  end

  # SECRET-REDACTION POSITIVE CONTROL. A `git fetch` failure legitimately echoes the remote URL
  # it failed on, and that URL can carry credential userinfo (a real shape `git` itself prints).
  # This proves the redaction actually FIRES on a genuine secret shape, not merely that no secret
  # was found in ordinary output.
  def test_a_credential_bearing_remote_url_in_a_fetch_failure_is_redacted
    tainted = "fatal: unable to access " \
              "'https://oauth2:ghp_1234567890abcdefghijklmnopqrstuvwxyz@github.com/SpecRelay/x.git/'"
    commands = FakeCommands.new(
      git_results: {
        [ "fetch", "--quiet", "origin", "branch-x" ] =>
          Result.new(exit_code: 1, stdout: "", stderr: tainted, duration_seconds: 0.1, timed_out: false)
      }
    )

    result = PreviousSpecificationPackage.call(commands: commands, branch: "branch-x", package_path: "specs/SR-700")

    refute_includes result.message, "ghp_1234567890abcdefghijklmnopqrstuvwxyz"
    refute_includes result.message, "oauth2:"
    assert_includes result.message, "[REDACTED]"
  end

  def test_a_git_show_failure_for_one_file_is_unreadable_rather_than_a_partial_package
    commands = FakeCommands.new(
      git_values: {
        %w[rev-parse FETCH_HEAD] => COMMIT,
        [ "show", "#{COMMIT}:specs/SR-700/spec.md" ] => nil
      },
      git_results: {
        [ "fetch", "--quiet", "origin", "branch-x" ] =>
          Result.new(exit_code: 0, stdout: "", stderr: "", duration_seconds: 0.1, timed_out: false),
        [ "ls-tree", "-r", "--name-only", COMMIT, "--", "specs/SR-700" ] =>
          Result.new(exit_code: 0, stdout: "specs/SR-700/spec.md\n", stderr: "", duration_seconds: 0.1,
                    timed_out: false)
      }
    )

    result = PreviousSpecificationPackage.call(commands: commands, branch: "branch-x", package_path: "specs/SR-700")

    refute result.ok?
    assert_includes result.message, "spec.md"
  end
end
