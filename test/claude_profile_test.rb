# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

# MVP-0016 — the one supported REAL provider profile, as a unit.
#
# These tests cover the value/validation/classification boundary. The readiness
# probe is exercised through an INJECTED command-execution seam: no ENV is
# mutated, no live CLI is required, and no global process state is touched. The
# end-to-end seam (real PATH lookup, real argv launch, real timeout) is proven
# separately in real_executor_flow_test.rb against an on-disk CLI double.
class ClaudeProfileTest < Minitest::Test
  PROFILE = {
    "provider" => "claude", "command" => "claude",
    "args" => %w[--print --dangerously-skip-permissions],
    "prompt_delivery" => "argument", "timeout_seconds" => 900, "env" => {}
  }.freeze

  # An environment in which nothing resolves, so `Executor.resolve_command` returns
  # nil and both the readiness probe and the identity comparison fall back to the
  # configured name. That keeps these unit tests independent of whatever `claude`
  # happens to be installed on the machine running them.
  NO_PATH = { "PATH" => "" }.freeze

  def profile(overrides = {}) = SpecrelayRunner::ClaudeProfile.new(PROFILE.merge(overrides))

  # Build a real executable named `claude` in its own directory and return
  # [bin_dir, env] so a test can exercise genuine path resolution.
  def resolvable_claude
    dir = Dir.mktmpdir("resolvable-claude-")
    path = File.join(dir, "claude")
    File.write(path, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, path)
    [ dir, { "PATH" => dir } ]
  end

  # A probe stub: maps the argv it is handed to a canned CommandRunner::Result.
  def probe(version:, auth: nil)
    lambda do |argv|
      argv.include?("--version") ? version : auth
    end
  end

  def result(exit_code: 0, stdout: "", timed_out: false)
    SpecrelayRunner::CommandRunner::Result.new(exit_code: exit_code, stdout: stdout, stderr: "",
                                              duration_seconds: 0.01, timed_out: timed_out)
  end

  def auth_json(logged_in) = %({"loggedIn": #{logged_in}, "email": "#{FakeClaudeCli::ACCOUNT_EMAIL}"})

  # --- selection -------------------------------------------------------------

  def test_selected_only_for_the_claude_provider
    assert SpecrelayRunner::ClaudeProfile.selected?("provider" => "claude")
    assert SpecrelayRunner::ClaudeProfile.selected?("provider" => "CLAUDE")
    refute SpecrelayRunner::ClaudeProfile.selected?("provider" => "fake")
    refute SpecrelayRunner::ClaudeProfile.selected?({})
    refute SpecrelayRunner::ClaudeProfile.selected?(nil)
  end

  # --- the exact supported argv (acceptance criterion 1) ---------------------

  def test_accepts_the_documented_profile
    assert_equal %w[--print --dangerously-skip-permissions], profile.args
    assert_equal "argument", profile.prompt_delivery
  end

  def test_accepts_the_short_print_flag
    assert_equal %w[-p], profile("args" => %w[-p]).args
  end

  def test_requires_non_interactive_output
    error = assert_raises(SpecrelayRunner::ClaudeProfile::Error) { profile("args" => %w[--dangerously-skip-permissions]) }
    assert_match(/non-interactive/, error.message)
  end

  # The prompt must stay a distinct argv element. `file_argument`/`stdin` are
  # legitimate generic executor deliveries but are not this profile's contract.
  def test_requires_the_prompt_to_be_a_distinct_argv_element
    error = assert_raises(SpecrelayRunner::ClaudeProfile::Error) { profile("prompt_delivery" => "stdin") }
    assert_match(/distinct argv element/, error.message)
  end

  def test_refuses_a_command_that_is_not_the_claude_cli
    error = assert_raises(SpecrelayRunner::ClaudeProfile::Error) { profile("command" => "codex") }
    assert_match(/must be the Claude Code CLI/, error.message)
  end

  def test_allows_an_absolute_path_to_the_claude_cli
    assert_equal "/opt/homebrew/bin/claude", profile("command" => "/opt/homebrew/bin/claude").command
  end

  # Each forbidden flag breaks a boundary this MVP proves; refusing them is what
  # makes "non-interactive, text output, no session reuse, no MCP, no remote
  # control" an enforced property rather than a documented hope.
  def test_refuses_every_flag_that_breaks_the_bounded_profile
    %w[--output-format --input-format --mcp-config --strict-mcp-config --bg --background
       --chrome --remote-control --tmux -c --continue -r --resume --fork-session --session-id].each do |flag|
      error = assert_raises(SpecrelayRunner::ClaudeProfile::Error, "#{flag} must be refused") do
        profile("args" => [ "--print", flag ])
      end
      assert_match(/must not pass #{Regexp.escape(flag)}/, error.message)
    end
  end

  def test_refuses_a_forbidden_flag_written_with_an_equals_sign
    error = assert_raises(SpecrelayRunner::ClaudeProfile::Error) { profile("args" => %w[--print --output-format=stream-json]) }
    assert_match(/--output-format/, error.message)
  end

  # `executor.env` travels to Platform in the claim request, so a credential
  # smuggled in there would leave this machine. Fail closed instead of redacting.
  def test_refuses_a_credential_in_the_profile_env
    %w[ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN MY_SECRET DB_PASSWORD SOME_CREDENTIAL AWS_ACCESS_KEY].each do |key|
      error = assert_raises(SpecrelayRunner::ClaudeProfile::Error, "#{key} must be refused") do
        profile("env" => { key => "value" })
      end
      assert_match(/no credential/, error.message)
    end
  end

  def test_allows_a_non_secret_env_entry
    built = profile("env" => { "CLAUDE_CODE_MAX_OUTPUT_TOKENS" => "8000" })

    assert_equal %w[--print --dangerously-skip-permissions], built.args
  end

  def test_describe_is_a_single_safe_line
    assert_equal "claude claude --print --dangerously-skip-permissions (prompt via argument)", profile.describe
  end

  # --- readiness (acceptance criterion 2) ------------------------------------

  def test_ready_when_the_cli_is_installed_and_logged_in
    readiness = profile.readiness(env: NO_PATH, probe: probe(version: result, auth: result(stdout: auth_json(true))))

    assert readiness.ready?
    assert_equal "claude=available, auth=authenticated", readiness.summary
    assert_nil readiness.remedy
  end

  # The absent-CLI case: the probe reports it could not launch the executable at all.
  def test_unavailable_when_the_cli_cannot_be_launched
    readiness = profile.readiness(env: NO_PATH, probe: probe(version: nil))

    refute readiness.ready?
    assert_equal "unavailable", readiness.version
    assert_match(/install Claude Code/, readiness.remedy)
  end

  def test_unavailable_when_the_version_probe_exits_non_zero
    readiness = profile.readiness(env: NO_PATH, probe: probe(version: result(exit_code: 1)))

    assert_equal "unavailable", readiness.version
  end

  def test_not_authenticated_when_the_auth_probe_reports_logged_out
    readiness = profile.readiness(env: NO_PATH, probe: probe(version: result, auth: result(stdout: auth_json(false))))

    refute readiness.ready?
    assert_equal "not_authenticated", readiness.auth
    assert_match(/claude auth login/, readiness.remedy)
  end

  def test_not_authenticated_when_the_auth_probe_exits_non_zero
    readiness = profile.readiness(env: NO_PATH, probe: probe(version: result, auth: result(exit_code: 1)))

    assert_equal "not_authenticated", readiness.auth
  end

  def test_check_failed_when_a_probe_times_out
    timed = profile.readiness(env: NO_PATH, probe: probe(version: result, auth: result(timed_out: true)))

    refute timed.ready?
    assert_equal "check_failed", timed.auth
    assert_match(/did not complete/, timed.remedy)
  end

  def test_check_failed_when_the_version_probe_times_out
    timed = profile.readiness(env: NO_PATH, probe: probe(version: result(timed_out: true)))

    assert_equal "check_failed", timed.version
    # Auth was never probed, so it is reported as undetermined rather than as a
    # login problem the operator would chase in the wrong place.
    assert_equal "check_failed", timed.auth
    assert_match(/installation/, timed.remedy)
  end

  # A future CLI whose status output shape changed must not read as a false
  # failure: exit status remains the contract.
  def test_authenticated_when_the_probe_succeeds_without_a_recognizable_field
    readiness = profile.readiness(env: NO_PATH, probe: probe(version: result, auth: result(stdout: "logged in as someone")))

    assert_equal "authenticated", readiness.auth
  end

  # The readiness result carries ONLY classifications. The raw auth output holds
  # the operator's email/org and must not survive anywhere in the returned value.
  def test_readiness_never_carries_account_details
    readiness = profile.readiness(env: NO_PATH, probe: probe(version: result, auth: result(stdout: auth_json(true))))
    serialized = [ readiness.to_h.inspect, readiness.summary, readiness.remedy.to_s ].join(" ")

    refute_includes serialized, FakeClaudeCli::ACCOUNT_EMAIL
    refute_includes serialized, "loggedIn"
  end

  # The probe must never send a prompt or run inference — only the two bounded
  # metadata calls, in that order.
  def test_readiness_only_runs_the_two_bounded_metadata_probes
    seen = []
    probe = lambda do |argv|
      seen << argv
      result(stdout: auth_json(true))
    end
    profile.readiness(env: NO_PATH, probe: probe)

    assert_equal [ %w[claude --version], %w[claude auth status] ], seen
  end

  # --- fail-closed payload comparison (acceptance criterion 4) ---------------

  def test_no_mismatch_for_an_identical_claimed_payload
    payload = PROFILE.merge("mode" => "print", "semantic_events" => "auto")

    assert_nil profile.mismatch_reason(payload, env: NO_PATH)
  end

  def test_mismatch_when_the_claimed_payload_is_the_fake_executor
    reason = profile.mismatch_reason({ "provider" => "fake", "command" => "specrelay-fake-executor",
                                       "args" => [], "prompt_delivery" => "file_argument" }, env: NO_PATH)

    assert_match(/not a usable Claude Code profile/, reason)
  end

  def test_mismatch_when_the_claimed_payload_is_another_cli
    reason = profile.mismatch_reason(PROFILE.merge("command" => "codex"), env: NO_PATH)

    assert_match(/not a usable Claude Code profile/, reason)
  end

  def test_mismatch_when_the_claimed_args_differ
    reason = profile.mismatch_reason(PROFILE.merge("args" => %w[--print]), env: NO_PATH)

    assert_match(/differs from the selected profile in args/, reason)
  end

  def test_mismatch_when_the_claimed_payload_would_stream_json
    reason = profile.mismatch_reason(PROFILE.merge("args" => %w[--print --output-format stream-json]), env: NO_PATH)

    assert_match(/--output-format/, reason)
  end

  # review-001 finding F1. The guard used to compare only File.basename(command), so
  # ANY file named `claude` anywhere on the host passed as a match and was then
  # spawned. It must compare the executable that will actually run.
  def test_mismatch_when_the_claimed_command_is_a_different_file_named_claude
    dir, env = resolvable_claude                     # the selected profile's `claude`
    attacker = Dir.mktmpdir("attacker-")
    File.write(File.join(attacker, "claude"), "#!/bin/sh\necho pwned\n")
    FileUtils.chmod(0o755, File.join(attacker, "claude"))

    reason = profile.mismatch_reason(PROFILE.merge("command" => File.join(attacker, "claude")), env: env)

    refute_nil reason, "a different executable named `claude` must NOT pass the guard"
    assert_match(/differs from the selected profile in command/, reason)
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    FileUtils.remove_entry(attacker) if attacker && File.directory?(attacker)
  end

  # The legitimate case the basename comparison was originally trying to allow: an
  # absolute path naming the SAME file as the bare command still matches.
  def test_an_absolute_path_to_the_same_executable_matches
    dir, env = resolvable_claude

    assert_nil profile.mismatch_reason(PROFILE.merge("command" => File.join(dir, "claude")), env: env)
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end

  # review-001 finding F1. timeout_seconds and env were absent from the comparison, so
  # a payload could shrink the timeout or inject provider environment with no mismatch.
  def test_mismatch_when_the_claimed_payload_shrinks_the_timeout
    reason = profile.mismatch_reason(PROFILE.merge("timeout_seconds" => 1), env: NO_PATH)

    assert_match(/differs from the selected profile in timeout_seconds/, reason)
  end

  # ANTHROPIC_BASE_URL is not credential-shaped, so validation accepts it — which is
  # exactly why the fail-closed comparison has to catch it.
  def test_mismatch_when_the_claimed_payload_injects_provider_env
    reason = profile.mismatch_reason(PROFILE.merge("env" => { "ANTHROPIC_BASE_URL" => "http://attacker.example" }),
                                     env: NO_PATH)

    assert_match(/differs from the selected profile in env/, reason)
  end

  # An omitted timeout must not read as a mismatch against the effective default the
  # executor would apply anyway.
  def test_an_omitted_timeout_matches_the_effective_default
    bare = PROFILE.reject { |key, _| key == "timeout_seconds" }
    selected = SpecrelayRunner::ClaudeProfile.new(bare)

    assert_equal SpecrelayRunner::ClaudeProfile::DEFAULT_TIMEOUT_SECONDS, selected.timeout_seconds
    assert_nil selected.mismatch_reason(bare.merge("timeout_seconds" => 1800), env: NO_PATH)
  end

  # The identity is what the guard compares; it must carry every launch-deciding
  # dimension, not a subset.
  def test_identity_covers_every_launch_deciding_dimension
    identity = profile.identity(env: NO_PATH)

    assert_equal SpecrelayRunner::ClaudeProfile::IDENTITY_FIELDS.length, identity.length
    assert_equal [ "claude", "claude", %w[--print --dangerously-skip-permissions], "argument", 900, {} ], identity
  end

  # --- failure classification (acceptance criterion 5) -----------------------

  def executor_result(exit_code: 1, stdout: "", stderr: "", timed_out: false, launch_error: nil)
    SpecrelayRunner::Executor::Result.new(exit_code: exit_code, stdout: stdout, stderr: stderr,
                                          duration_seconds: 1.0, timed_out: timed_out,
                                          argv: %w[claude --print <PROMPT>], launch_error: launch_error)
  end

  def test_classifies_an_unlaunchable_cli_as_unavailable
    assert_equal "executor_unavailable", profile.classify_failure(executor_result(exit_code: nil, launch_error: "no such file"))
  end

  def test_classifies_a_timeout_as_timeout
    assert_equal "executor_timeout", profile.classify_failure(executor_result(exit_code: nil, timed_out: true))
  end

  def test_classifies_an_auth_failure_from_local_evidence
    [ "Not logged in. Please run `claude auth login`.", "authentication required",
      "Invalid API key", "unauthorized", "HTTP 401" ].each do |message|
      assert_equal "executor_not_authenticated", profile.classify_failure(executor_result(stderr: message)),
                   "#{message.inspect} must classify as an authentication failure"
    end
  end

  def test_classifies_any_other_non_zero_exit_as_a_plain_failure
    assert_equal "executor_failed", profile.classify_failure(executor_result(stderr: "the model produced no usable change"))
  end

  # A timeout wins over auth-looking text: the process never got to finish, so
  # "timed out" is the fact the operator needs.
  def test_a_timeout_outranks_an_auth_hint
    assert_equal "executor_timeout", profile.classify_failure(executor_result(timed_out: true, stderr: "unauthorized"))
  end
end
