# frozen_string_literal: true

require_relative "test_helper"

# MVP-0028 remediation slice 1, review-004 finding F1 — the new real-provider EXECUTION path.
#
# Round 004's first pass proved provider SELECTION (which kind resolves) but never called
# `Provider::Claude#generate`, so the suite could stay green even if the adapter launched the
# wrong argv, forwarded the wrong environment, mishandled a timeout, or accepted malformed
# output as a package. That is the same class of green-suite blind spot that let the
# deterministic composer reach the live MAPIAI-52 run undetected.
#
# Every test here drives `generate` through an INJECTED fake command runner — never the live
# `claude` CLI — so the adapter's own logic (prompt construction, argv, environment, timeout and
# failure handling, and JSON extraction) is proven directly and fast.
class SpecificationClaudeProviderGenerationTest < Minitest::Test
  Provider = SpecrelayRunner::Specification::Provider
  Settings = SpecrelayRunner::Specification::Settings
  Result = SpecrelayRunner::CommandRunner::Result

  # Records every call it receives and returns a pre-baked Result, so a test can assert on
  # exactly what the adapter launched without spawning a process.
  class FakeCommandRunner
    Call = Struct.new(:argv, :chdir, :env, :timeout_seconds, keyword_init: true)

    def initialize(result:)
      @result = result
      @calls = []
    end

    attr_reader :calls

    def run(argv, chdir:, env:, timeout_seconds:)
      @calls << Call.new(argv: argv, chdir: chdir, env: env, timeout_seconds: timeout_seconds)
      @result
    end
  end

  def build_profile(command: "claude", args: [ "--print", "--dangerously-skip-permissions" ],
                    timeout_seconds: 900, env: {})
    SpecrelayRunner::ClaudeProfile.new("provider" => "claude", "command" => command, "args" => args,
                                      "timeout_seconds" => timeout_seconds, "env" => env)
  end

  def settings = Settings.new({}, env: {})

  def provider_for(result:, profile: build_profile, env: {})
    runner = FakeCommandRunner.new(result: result)
    [ Provider::Claude.new(profile: profile, settings: settings, env: env, command_runner: runner), runner ]
  end

  def success(stdout:, duration_seconds: 1.2)
    Result.new(exit_code: 0, stdout: stdout, stderr: "", duration_seconds: duration_seconds, timed_out: false)
  end

  def failure(exit_code:, stdout: "", stderr: "")
    Result.new(exit_code: exit_code, stdout: stdout, stderr: stderr, duration_seconds: 0.8, timed_out: false)
  end

  VALID_DOCUMENTS = { "spec.md" => "# Spec\n", "analysis/business.md" => "business case",
                     "analysis/technical.md" => "technical detail" }.freeze

  # ------------------------------------------------------------------ a valid response

  def test_a_valid_three_document_response_is_parsed_into_the_package
    provider, = provider_for(result: success(stdout: JSON.generate(VALID_DOCUMENTS)))

    documents = provider.generate({ "issue_key" => "SR-700" })

    assert_equal VALID_DOCUMENTS, documents
  end

  # The prompt may arrive with a sentence or a fence around it despite the instruction not to,
  # and that surrounding text may itself contain braces (an aside, a code fragment). Only
  # genuine object nesting inside the JSON may move the match — this is the case review-004
  # flagged as unproven by the "first `{` to last `}`" implementation.
  def test_a_response_wrapped_in_prose_with_unrelated_braces_still_parses
    wrapped = <<~TEXT
      Sure, here is the package:
      #{JSON.generate({ "spec.md" => "See {note} below.", "analysis/business.md" => "ok",
                       "analysis/technical.md" => "ok" })}
      (based on config{key: value} if that helps)
    TEXT
    provider, = provider_for(result: success(stdout: wrapped))

    documents = provider.generate({ "issue_key" => "SR-700" })

    assert_equal "See {note} below.", documents["spec.md"]
    assert_equal "ok", documents["analysis/business.md"]
  end

  # ------------------------------------------------------------------ the launch itself

  def test_the_launch_carries_the_configured_command_arguments_prompt_timeout_and_environment
    profile = build_profile(command: "claude", args: [ "--print", "--dangerously-skip-permissions" ],
                            timeout_seconds: 42, env: { "CLAUDE_EXTRA" => "yes" })
    provider, runner = provider_for(result: success(stdout: JSON.generate(VALID_DOCUMENTS)), profile: profile,
                                    env: { "PATH" => "/usr/bin:/bin", "HOME" => "/home/operator",
                                          "UNRELATED_SECRET" => "must-not-travel" })

    provider.generate({ "issue_key" => "SR-700", "title" => "Add an export button" })

    call = runner.calls.fetch(0)
    assert_equal [ "claude", "--print", "--dangerously-skip-permissions" ], call.argv[0, 3]
    assert_equal 1, call.argv.length - 3, "the packet-derived prompt is exactly one argv element"
    assert_includes call.argv.last, "SR-700"
    assert_includes call.argv.last, "Add an export button"
    assert_includes call.argv.last, "Return ONLY a JSON object"
    assert_equal 42, call.timeout_seconds
    assert_equal({ "PATH" => "/usr/bin:/bin", "HOME" => "/home/operator", "CLAUDE_EXTRA" => "yes" }, call.env,
                "only PATH, HOME and the profile's own extra_env travel — never an unrelated variable")
  end

  # ------------------------------------------------------------------ the provider misbehaves

  def test_a_non_zero_provider_exit_is_a_generation_failure
    provider, = provider_for(result: failure(exit_code: 1))

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "exited 1"
  end

  def test_a_timeout_is_a_generation_failure_naming_the_timeout
    result = Result.new(exit_code: nil, stdout: "", stderr: "", duration_seconds: 900.0, timed_out: true)
    provider, = provider_for(result: result)

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "timed out"
  end

  def test_output_with_no_json_object_at_all_is_a_generation_failure
    provider, = provider_for(result: success(stdout: "I could not complete this request."))

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "returned no JSON object"
  end

  # A brace is present, but what it encloses is not valid JSON (a trailing comma) — distinct
  # from "no object found" and from the oversized-output boundary below.
  def test_malformed_json_inside_a_found_object_is_a_generation_failure
    provider, = provider_for(result: success(stdout: '{"spec.md": "ok",}'))

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "did not return valid JSON"
  end

  def test_oversized_output_is_a_generation_failure_before_any_parsing_is_attempted
    oversized = "x" * (Provider::MAX_OUTPUT_BYTES + 1)
    provider, = provider_for(result: success(stdout: oversized))

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "more output than the runner will accept"
  end
end
