# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

# The second approved REAL implementation provider, as a unit.
#
# Same boundary as the Claude profile: whether the local CLI is ready, whether a claimed payload
# really resolved to this profile, and how a failure is classified. WHICH argv is approved is not
# asked here — {SpecrelayRunner::ImplementationProfile} compares a claim with CANONICAL byte for
# byte before this class is constructed, and implementation_profile_test.rb owns that contract.
# The readiness probe is exercised through the INJECTED command-execution seam, so no ENV is
# mutated, no live CLI is required, and no account is needed. The on-disk seam is proven
# separately in codex_executor_flow_test.rb.
class CodexProfileTest < Minitest::Test
  PROFILE = {
    "provider" => "codex", "command" => "codex", "mode" => "exec",
    "args" => %w[exec --json --ephemeral --dangerously-bypass-approvals-and-sandbox],
    "prompt_delivery" => "stdin", "timeout_seconds" => 1800, "env" => {}
  }.freeze

  # An environment in which nothing resolves, so `Executor.resolve_command` returns nil and both
  # the probe and the identity comparison fall back to the configured name. That keeps these unit
  # tests independent of whatever `codex` happens to be installed on the machine running them.
  NO_PATH = { "PATH" => "" }.freeze

  def profile(overrides = {}) = SpecrelayRunner::CodexProfile.new(PROFILE.merge(overrides))

  def result(exit_code: 0, stdout: "", stderr: "", timed_out: false)
    SpecrelayRunner::CommandRunner::Result.new(exit_code: exit_code, stdout: stdout, stderr: stderr,
                                               duration_seconds: 0.01, timed_out: timed_out)
  end

  # Maps the argv it is handed to a canned result: `--version` to one, `login status` to the other.
  def probe(version:, login: nil)
    ->(argv) { argv.include?("--version") ? version : login }
  end

  def readiness(version:, login: nil)
    profile.readiness(env: NO_PATH, probe: probe(version: version, login: login))
  end

  def resolvable_codex(name = "codex")
    dir = Dir.mktmpdir("resolvable-codex-")
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, path)
    [ dir, { "PATH" => dir } ]
  end

  # --- selection (S01, S04) --------------------------------------------------

  def test_selected_only_for_the_codex_provider
    assert SpecrelayRunner::CodexProfile.selected?("provider" => "codex")
    assert SpecrelayRunner::CodexProfile.selected?("provider" => "CODEX")
    refute SpecrelayRunner::CodexProfile.selected?("provider" => "claude")
    refute SpecrelayRunner::CodexProfile.selected?("provider" => "fake")
    refute SpecrelayRunner::CodexProfile.selected?({})
    refute SpecrelayRunner::CodexProfile.selected?(nil)
  end

  # --- the audited profile, as this class reads it (S04) ---------------------

  def test_reads_the_audited_profile
    assert_equal PROFILE.fetch("args"), profile.args
    assert_equal "stdin", profile.prompt_delivery
    assert_equal 1800, profile.timeout_seconds
  end

  # The one thing the constructor still refuses, because `mismatch_reason` depends on it: a payload
  # that is not this provider at all is not a usable Codex profile.
  def test_refuses_a_payload_for_another_provider
    error = assert_raises(SpecrelayRunner::CodexProfile::Error) { profile("provider" => "claude") }
    assert_match(/provider must be 'codex'/, error.message)
  end

  # --- readiness classification (S02) ----------------------------------------

  def test_an_absent_cli_is_unavailable_and_does_not_probe_login
    seen = []
    probe = lambda do |argv|
      seen << argv
      nil
    end

    state = profile.readiness(env: NO_PATH, probe: probe)

    assert_equal SpecrelayRunner::CodexProfile::UNAVAILABLE, state.version
    assert_equal SpecrelayRunner::CodexProfile::CHECK_FAILED, state.auth
    refute state.ready?
    assert_equal [ %w[codex --version] ], seen, "an unrunnable CLI must not be asked about login"
    assert_match(/install/i, state.remedy)
  end

  def test_a_version_probe_that_times_out_is_check_failed
    state = readiness(version: result(timed_out: true))

    assert_equal SpecrelayRunner::CodexProfile::CHECK_FAILED, state.version
    refute state.ready?
    assert_nil state.cli_version
  end

  def test_a_missing_login_is_not_authenticated
    state = readiness(version: result(stdout: "codex-cli 0.142.5"), login: result(exit_code: 1))

    assert_equal SpecrelayRunner::CodexProfile::AVAILABLE, state.version
    assert_equal SpecrelayRunner::CodexProfile::NOT_AUTHENTICATED, state.auth
    assert_match(/codex login/, state.remedy)
  end

  def test_a_login_probe_that_fails_to_run_is_check_failed
    state = readiness(version: result(stdout: "codex-cli 0.142.5"), login: nil)

    assert_equal SpecrelayRunner::CodexProfile::CHECK_FAILED, state.auth
    refute state.ready?
  end

  def test_a_logged_in_probe_is_ready
    state = readiness(version: result(stdout: "codex-cli 0.142.5"), login: result(stdout: "Logged in"))

    assert state.ready?
    assert_nil state.remedy
  end

  # The word the CLI prints when it is signed out, even on a zero exit.
  def test_a_signed_out_message_is_not_authenticated_even_on_a_zero_exit
    state = readiness(version: result(stdout: "codex-cli 0.142.5"), login: result(stdout: "Not logged in"))

    assert_equal SpecrelayRunner::CodexProfile::NOT_AUTHENTICATED, state.auth
  end

  # The probe resolves the SAME file the launch will, so readiness cannot pass against a
  # different `codex` than the one that would run.
  def test_the_probe_targets_the_resolved_executable
    dir, env = resolvable_codex
    seen = []
    probe = lambda do |argv|
      seen << argv
      result(stdout: "codex-cli 0.142.5")
    end
    profile.readiness(env: env, probe: probe)

    # `realpath`, because the runner resolves symlinks so two paths naming the same executable
    # compare equal — and macOS's temporary root is itself a symlink.
    resolved = File.realpath(File.join(dir, "codex"))
    assert_equal [ [ resolved, "--version" ], [ resolved, "login", "status" ] ], seen
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end

  # --- version privacy and bounded reporting (S03) ---------------------------

  def test_the_proven_version_form_is_parsed_and_reported
    state = readiness(version: result(stdout: "codex-cli 0.142.5\n"), login: result(stdout: "Logged in"))

    assert_equal "codex-cli 0.142.5", state.cli_version
    assert_equal "codex-cli 0.142.5", state.detail
    assert_match(/codex-cli 0\.142\.5/, state.summary)
  end

  # Unexpected text is a failed check, and none of it is echoed anywhere.
  def test_unexpected_version_text_is_check_failed_and_never_echoed
    secret = "operator-account@example.test /Users/someone/private"
    state = readiness(version: result(stdout: secret), login: result(stdout: "Logged in"))

    assert_equal SpecrelayRunner::CodexProfile::CHECK_FAILED, state.version
    assert_nil state.cli_version
    [ state.summary, state.detail.to_s, state.remedy.to_s ].each do |text|
      refute_match(/operator-account/, text)
      refute_match(%r{/Users/}, text)
    end
  end

  def test_an_overlong_version_value_is_bounded
    state = readiness(version: result(stdout: "codex-cli #{'9' * 200}"), login: result(stdout: "Logged in"))

    assert_equal SpecrelayRunner::CodexProfile::CHECK_FAILED, state.version,
                 "a value past the bound is unexpected text, not a very long version"
    assert_nil state.cli_version
  end

  # The login probe's raw output is the operator's private account evidence. It reaches nothing.
  def test_raw_login_output_never_reaches_a_reportable_field
    private_output = "Logged in as operator-account@example.test (org-do-not-leak)"
    state = readiness(version: result(stdout: "codex-cli 0.142.5"), login: result(stdout: private_output))

    refute state.respond_to?(:stdout)
    [ state.summary, state.detail.to_s, state.remedy.to_s, state.to_a.join(" ") ].each do |text|
      refute_match(/operator-account/, text)
      refute_match(/org-do-not-leak/, text)
    end
  end

  # --- fail-closed payload comparison (S04) ----------------------------------

  def test_no_mismatch_for_an_identical_claimed_payload
    assert_nil profile.mismatch_reason(PROFILE, env: NO_PATH)
  end

  def test_mismatch_when_the_claimed_payload_is_the_fixture
    reason = profile.mismatch_reason({ "provider" => "fake", "command" => "specrelay-fake-executor",
                                       "args" => [], "prompt_delivery" => "file_argument" }, env: NO_PATH)

    assert_match(/not a usable Codex profile/, reason)
  end

  def test_mismatch_when_the_claimed_args_differ
    reason = profile.mismatch_reason(PROFILE.merge("args" => %w[exec --json --ephemeral]), env: NO_PATH)

    assert_match(/differs from the selected profile in args/, reason)
  end

  def test_mismatch_when_the_claimed_payload_shrinks_the_timeout
    reason = profile.mismatch_reason(PROFILE.merge("timeout_seconds" => 1), env: NO_PATH)

    assert_match(/differs from the selected profile in timeout_seconds/, reason)
  end

  def test_mismatch_when_the_claimed_payload_injects_provider_env
    reason = profile.mismatch_reason(PROFILE.merge("env" => { "OPENAI_BASE_URL" => "http://attacker.example" }),
                                     env: NO_PATH)

    assert_match(/differs from the selected profile in env/, reason)
  end

  # A different executable that merely happens to be named `codex` is not this profile.
  def test_mismatch_when_the_claimed_command_is_a_different_file_named_codex
    dir, env = resolvable_codex
    attacker = Dir.mktmpdir("attacker-codex-")
    File.write(File.join(attacker, "codex"), "#!/bin/sh\necho pwned\n")
    FileUtils.chmod(0o755, File.join(attacker, "codex"))

    reason = profile.mismatch_reason(PROFILE.merge("command" => File.join(attacker, "codex")), env: env)

    assert_match(/differs from the selected profile in command/, reason)
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    FileUtils.remove_entry(attacker) if attacker && File.directory?(attacker)
  end

  def test_describe_is_redacted_and_names_the_delivery
    assert_match(/codex codex exec --json .*prompt via stdin/, profile.describe)
  end

  # --- failure classification (S07) ------------------------------------------

  def test_a_launch_error_is_classified_as_unavailable
    outcome = SpecrelayRunner::Executor::Result.new(exit_code: nil, stdout: "", stderr: "", timed_out: false,
                                                    launch_error: "could not launch")

    assert_equal SpecrelayRunner::CodexProfile::EXECUTOR_UNAVAILABLE, profile.classify_failure(outcome)
  end

  def test_a_timeout_is_classified_as_a_timeout
    outcome = SpecrelayRunner::Executor::Result.new(exit_code: nil, stdout: "", stderr: "", timed_out: true)

    assert_equal SpecrelayRunner::CodexProfile::EXECUTOR_TIMEOUT, profile.classify_failure(outcome)
  end

  def test_an_auth_indicated_exit_is_classified_as_not_authenticated
    outcome = SpecrelayRunner::Executor::Result.new(exit_code: 1, stdout: "", timed_out: false,
                                                    stderr: "You are not logged in. Run `codex login`.")

    assert_equal SpecrelayRunner::CodexProfile::EXECUTOR_NOT_AUTHENTICATED, profile.classify_failure(outcome)
  end

  def test_an_ordinary_nonzero_exit_is_a_plain_failure
    outcome = SpecrelayRunner::Executor::Result.new(exit_code: 3, stdout: "", stderr: "task failed", timed_out: false)

    assert_equal SpecrelayRunner::CodexProfile::EXECUTOR_FAILED, profile.classify_failure(outcome)
  end
end
