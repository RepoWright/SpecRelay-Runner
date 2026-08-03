# frozen_string_literal: true

require_relative "test_helper"

# MVP-0028 remediation slice 2 correction (review-005) — WHICH capability actually analyses an
# external reference, and the STRICT evidence contract every analyzer's output is judged
# against.
#
# review-005 finding F1: an analyzer that claimed `contributed: true` with a blank, missing, or
# wrong-typed summary was accepted as real evidence, recreating D2's original false-confidence
# defect behind a different flag. Finding F2: the only analyzer the product shipped was an
# extension point nothing configured, so the ordinary connected Runner could never actually
# analyse a reference. Every test here drives `ReferenceAnalyzer` directly — resolution
# precedence, the strict contract, and the Claude adapter's execution through an INJECTED fake
# command runner — never the live Claude service.
class SpecificationReferenceAnalyzerTest < Minitest::Test
  ReferenceAnalyzer = SpecrelayRunner::Specification::ReferenceAnalyzer
  Settings = SpecrelayRunner::Specification::Settings
  Result = SpecrelayRunner::CommandRunner::Result

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

  def settings_for(document, env: {}) = Settings.new(document, env: env)

  def claude_profile(command: "claude", args: [ "--print", "--dangerously-skip-permissions" ], env: {})
    SpecrelayRunner::ClaudeProfile.new("provider" => "claude", "command" => command, "args" => args, "env" => env)
  end

  def success(stdout:, duration_seconds: 0.2)
    Result.new(exit_code: 0, stdout: stdout, stderr: "", duration_seconds: duration_seconds, timed_out: false)
  end

  # ------------------------------------------------------------------ resolution precedence

  def test_an_explicit_command_wins_even_when_a_claude_profile_is_also_configured
    settings = settings_for({ "external_references" => { "command" => "/usr/local/bin/analyzer" } })

    analyzer = ReferenceAnalyzer.resolve(settings: settings, claude_profile: claude_profile, env: {})

    assert_instance_of ReferenceAnalyzer::Command, analyzer
  end

  # The ordinary path: no explicit command, and the same real Claude profile already validated
  # for generation (defect 1) is offered as the analyzer — nothing new to configure.
  def test_the_real_claude_profile_is_used_when_no_explicit_command_is_configured
    settings = settings_for({})

    analyzer = ReferenceAnalyzer.resolve(settings: settings, claude_profile: claude_profile, env: {})

    assert_instance_of ReferenceAnalyzer::Claude, analyzer
  end

  def test_resolution_is_nil_when_neither_a_command_nor_a_profile_exists
    settings = settings_for({})

    assert_nil ReferenceAnalyzer.resolve(settings: settings, claude_profile: nil, env: {})
  end

  # ------------------------------------------------------------------ the strict contract (F1)

  def test_contributed_true_with_a_real_summary_is_accepted
    outcome = ReferenceAnalyzer.evaluate({ "contributed" => true, "summary" => "Jam shows the export click." })

    assert outcome.contributed?
    assert_equal "Jam shows the export click.", outcome.summary
  end

  def test_contributed_true_with_a_blank_summary_fails_closed
    outcome = ReferenceAnalyzer.evaluate({ "contributed" => true, "summary" => "" })

    refute outcome.contributed?
    assert_equal :failed, outcome.verdict
    assert_includes outcome.summary, "no usable summary"
  end

  def test_contributed_true_with_a_missing_summary_fails_closed
    outcome = ReferenceAnalyzer.evaluate({ "contributed" => true })

    refute outcome.contributed?
    assert_equal :failed, outcome.verdict
  end

  def test_contributed_true_with_a_non_string_summary_fails_closed
    [ 42, [ "a summary" ], { "text" => "a summary" }, nil ].each do |wrong_type|
      outcome = ReferenceAnalyzer.evaluate({ "contributed" => true, "summary" => wrong_type })

      refute outcome.contributed?, "summary #{wrong_type.inspect} must not be accepted"
      assert_equal :failed, outcome.verdict
    end
  end

  def test_contributed_true_with_a_whitespace_only_summary_fails_closed
    outcome = ReferenceAnalyzer.evaluate({ "contributed" => true, "summary" => "   \n\t  " })

    refute outcome.contributed?
    assert_equal :failed, outcome.verdict
  end

  def test_contributed_false_with_a_real_summary_is_not_contributed_but_not_a_failure
    outcome = ReferenceAnalyzer.evaluate({ "contributed" => false, "summary" => "not a page this tool can read" })

    refute outcome.contributed?
    assert_equal :not_contributed, outcome.verdict
    assert_equal "not a page this tool can read", outcome.summary
  end

  def test_contributed_false_with_no_summary_gets_a_default_rather_than_a_failure
    outcome = ReferenceAnalyzer.evaluate({ "contributed" => false })

    assert_equal :not_contributed, outcome.verdict
    assert_equal "found no usable evidence", outcome.summary
  end

  def test_a_non_object_document_fails_closed
    [ [ 1, 2 ], "a string", nil ].each do |wrong_shape|
      outcome = ReferenceAnalyzer.evaluate(wrong_shape)

      assert_equal :failed, outcome.verdict
    end
  end

  # ------------------------------------------------------------------ the Claude adapter, direct execution

  def build_claude_analyzer(result:, profile: claude_profile, env: {}, settings: settings_for({}))
    runner = FakeCommandRunner.new(result: result)
    [ ReferenceAnalyzer::Claude.new(profile: profile, settings: settings, env: env, command_runner: runner),
      runner ]
  end

  def test_a_valid_contributed_response_is_parsed
    analyzer, = build_claude_analyzer(result: success(stdout: JSON.generate(
      { "contributed" => true, "summary" => "Jam recording shows the export click flow." }
    )))

    outcome = analyzer.analyze(kind: "jam_recording", reference: "https://jam.dev/c/abc123")

    assert outcome.contributed?
    assert_equal "Jam recording shows the export click flow.", outcome.summary
  end

  def test_the_prompt_carries_the_kind_and_reference_as_one_argv_element
    settings = settings_for({ "external_references" => { "timeout_seconds" => 45 } })
    analyzer, runner = build_claude_analyzer(
      result: success(stdout: JSON.generate({ "contributed" => true, "summary" => "ok" })),
      settings: settings, env: { "PATH" => "/usr/bin", "HOME" => "/home/operator", "UNRELATED" => "must-not-travel" }
    )

    analyzer.analyze(kind: "jam_recording", reference: "https://jam.dev/c/abc123")

    call = runner.calls.fetch(0)
    assert_equal [ "claude", "--print", "--dangerously-skip-permissions" ], call.argv[0, 3]
    assert_equal 1, call.argv.length - 3, "the prompt is exactly one argv element"
    assert_includes call.argv.last, "jam_recording"
    assert_includes call.argv.last, "https://jam.dev/c/abc123"
    assert_equal 45, call.timeout_seconds
    assert_equal({ "PATH" => "/usr/bin", "HOME" => "/home/operator" }, call.env)
  end

  def test_a_non_zero_exit_is_a_failure
    analyzer, = build_claude_analyzer(result: Result.new(exit_code: 1, stdout: "", stderr: "boom",
                                                          duration_seconds: 0.1, timed_out: false))

    outcome = analyzer.analyze(kind: "jam_recording", reference: "https://jam.dev/c/abc123")

    assert_equal :failed, outcome.verdict
    assert_includes outcome.summary, "exited 1"
  end

  def test_a_timeout_is_a_failure
    analyzer, = build_claude_analyzer(result: Result.new(exit_code: nil, stdout: "", stderr: "",
                                                          duration_seconds: 60.0, timed_out: true))

    outcome = analyzer.analyze(kind: "jam_recording", reference: "https://jam.dev/c/abc123")

    assert_equal :failed, outcome.verdict
    assert_includes outcome.summary, "timed out"
  end

  def test_output_with_no_json_object_is_a_failure
    analyzer, = build_claude_analyzer(result: success(stdout: "I could not read that link."))

    outcome = analyzer.analyze(kind: "jam_recording", reference: "https://jam.dev/c/abc123")

    assert_equal :failed, outcome.verdict
    assert_includes outcome.summary, "no JSON object"
  end

  def test_malformed_json_is_a_failure
    analyzer, = build_claude_analyzer(result: success(stdout: '{"contributed": true,}'))

    outcome = analyzer.analyze(kind: "jam_recording", reference: "https://jam.dev/c/abc123")

    assert_equal :failed, outcome.verdict
    assert_includes outcome.summary, "valid JSON"
  end

  def test_oversized_output_is_a_failure
    analyzer, = build_claude_analyzer(result: success(stdout: "x" * (ReferenceAnalyzer::MAX_OUTPUT_BYTES + 1)))

    outcome = analyzer.analyze(kind: "jam_recording", reference: "https://jam.dev/c/abc123")

    assert_equal :failed, outcome.verdict
    assert_includes outcome.summary, "more output"
  end

  # A trailing aside with its own braces must not break a valid response — the same balanced
  # extraction {Provider::Claude} uses, now shared through {BalancedJson}.
  def test_a_response_wrapped_in_prose_with_unrelated_braces_still_parses
    wrapped = <<~TEXT
      Sure, here is what I found:
      #{JSON.generate({ "contributed" => true, "summary" => "See {note} in the recording." })}
      (based on config{key: value} if useful)
    TEXT
    analyzer, = build_claude_analyzer(result: success(stdout: wrapped))

    outcome = analyzer.analyze(kind: "jam_recording", reference: "https://jam.dev/c/abc123")

    assert outcome.contributed?
    assert_equal "See {note} in the recording.", outcome.summary
  end

  # An analyzer that itself claims success with nothing behind it — the exact F1 scenario, now
  # proven at the adapter boundary rather than only against a hand-built document.
  def test_the_claude_adapter_refuses_a_contributed_claim_with_no_summary
    analyzer, = build_claude_analyzer(result: success(stdout: JSON.generate({ "contributed" => true })))

    outcome = analyzer.analyze(kind: "jam_recording", reference: "https://jam.dev/c/abc123")

    refute outcome.contributed?
    assert_equal :failed, outcome.verdict
    assert_includes outcome.summary, "no usable summary"
  end
end
