# frozen_string_literal: true

require_relative "test_helper"

# The Codex specification adapter's own EXECUTION path.
#
# It is the counterpart of specification_claude_provider_generation_test.rb and deliberately asks
# the same questions of the second real provider: what argv it launches, how the prompt is
# delivered, which environment travels, what a usable answer is, and what happens to everything
# that is not one. Both adapters answer to one prompt and one file-map parser, so the tests that
# prove the CONTENT contract assert the same rules for both.
#
# Every test drives `generate` through an INJECTED command runner — never the live `codex` CLI — so
# the adapter's own logic is proven directly, fast, and without inference. The genuine-provider
# proof is a separate, later gate; a double cannot stand in for it and does not try to.
class SpecificationCodexProviderGenerationTest < Minitest::Test
  Provider = SpecrelayRunner::Specification::Provider
  Result = SpecrelayRunner::CommandRunner::Result

  # Records every call it receives and replays the provider's JSONL to the sink as it arrives, the
  # way CommandRunner does for a structured-output profile: the Result's stdout is NOT what the
  # adapter reads.
  class FakeCommandRunner
    Call = Struct.new(:argv, :chdir, :env, :timeout_seconds, :stdin_data, keyword_init: true)

    def initialize(result:, lines: [], stderr_lines: [])
      @result = result
      @lines = lines
      @stderr_lines = stderr_lines
      @calls = []
    end

    attr_reader :calls

    def run(argv, chdir:, env:, timeout_seconds:, stdin_data: nil, on_output: nil)
      @calls << Call.new(argv: argv, chdir: chdir, env: env, timeout_seconds: timeout_seconds,
                         stdin_data: stdin_data)
      @stderr_lines.each { |line| on_output&.call("stderr", line) }
      @lines.each { |line| on_output&.call("stdout", line) }
      @result
    end
  end

  VALID_DOCUMENTS = { "spec.md" => "# Spec\n", "analysis/business.md" => "business case",
                     "analysis/technical.md" => "technical detail" }.freeze

  PRIVATE_REASONING = "private-codex-reasoning-that-must-never-be-published"

  def profile = SpecrelayRunner::CodexProfile.new(SpecrelayRunner::CodexProfile::CANONICAL)

  def provider_for(result:, lines: [], stderr_lines: [], env: {})
    runner = FakeCommandRunner.new(result: result, lines: lines, stderr_lines: stderr_lines)
    [ Provider::Codex.new(profile: profile, env: env, working_directory: working_directory,
                          command_runner: runner), runner ]
  end

  def ok(duration_seconds: 1.2) =
    Result.new(exit_code: 0, stdout: "", stderr: "", duration_seconds: duration_seconds, timed_out: false)

  def event(hash) = JSON.generate(hash)

  def item(type, fields) = { "id" => "item_0", "type" => type }.merge(fields)

  # The observed success shape: a started thread, a reported command, private reasoning, one public
  # message carrying the file map, and exactly one terminal event.
  def answering(answer)
    [ event("type" => "thread.started", "thread_id" => "th_fake"),
      event("type" => "turn.started"),
      event("type" => "item.completed", "item" => item("reasoning", "text" => PRIVATE_REASONING)),
      event("type" => "item.started",
            "item" => item("command_execution", "command" => "ls /elsewhere", "status" => "in_progress")),
      event("type" => "item.completed",
            "item" => item("command_execution", "command" => "ls /elsewhere",
                           "aggregated_output" => "notes.md", "exit_code" => 0, "status" => "completed")),
      event("type" => "item.completed", "item" => item("agent_message", "text" => answer)),
      event("type" => "turn.completed", "usage" => { "input_tokens" => 12 }) ]
  end

  def generate(packet, answer: JSON.generate(VALID_DOCUMENTS), env: {}, progress: [])
    provider, runner = provider_for(result: ok, lines: answering(answer), env: env)
    documents = provider.generate(packet, on_output: ->(source, text) { progress << [ source, text ] })
    [ documents, runner, progress ]
  end

  # ------------------------------------------------------------------ S05: a valid response

  def test_a_fragmented_valid_response_is_parsed_into_the_package
    documents, = generate({ "issue_key" => "SR-700" })

    assert_equal VALID_DOCUMENTS, documents
  end

  # The two products of one stream, proven together: the package comes ONLY from the terminal
  # public message, and what the operator saw is normalized status.
  def test_progress_reaches_the_caller_while_the_package_comes_only_from_the_final_message
    documents, _runner, progress = generate({ "issue_key" => "SR-700" })

    assert_equal VALID_DOCUMENTS, documents
    # The command's absolute path renders as the placeholder: this lane is assigned no repository,
    # so containment can never be proven and no local path may ever be shown.
    assert_equal [ "Provider started", "> ls [LOCAL_PATH]", "< step completed", "  notes.md",
                   "Provider completed" ],
                 progress.map(&:last).reject { |line| line.include?("spec.md") }
    assert_equal [ "status" ], progress.map(&:first).uniq
  end

  # ------------------------------------------------------------------ S06: what never surfaces

  STDERR_IDENTITY = "operator-account@do-not-leak.test /Users/operator/.codex/auth.json"

  def test_reasoning_wrappers_and_stderr_bytes_never_reach_the_caller
    provider, = provider_for(result: ok, lines: answering(JSON.generate(VALID_DOCUMENTS)),
                             stderr_lines: [ STDERR_IDENTITY ])
    progress = []
    provider.generate({ "issue_key" => "SR-700" }, on_output: ->(source, text) { progress << [ source, text ] })
    shown = progress.map(&:last).join("\n")

    refute_includes shown, PRIVATE_REASONING
    refute_includes shown, STDERR_IDENTITY
    refute_includes shown, "thread.started"
    refute_includes shown, %("type":)
    assert_includes shown, SpecrelayRunner::CodexStream::DIAGNOSTIC,
                    "one bounded notice records that the provider wrote diagnostics"
  end

  # The credential-shaped value a provider echoed into its own public message is redacted by the
  # existing owner before it can reach a generated file.
  def test_a_credential_shaped_value_in_the_final_message_is_redacted_by_the_existing_owner
    answer = JSON.generate(VALID_DOCUMENTS.merge("spec.md" => "# Spec\n\ntoken=ghp_abcdefghijklmnop1234\n"))
    documents, = generate({ "issue_key" => "SR-700" }, answer: answer)

    refute_includes SpecrelayRunner::Redaction.redact(documents.fetch("spec.md")), "ghp_abcdefghijklmnop1234"
  end

  # ------------------------------------------------------------------ the launch itself

  def test_the_launch_carries_the_approved_argv_stdin_prompt_timeout_and_environment
    _documents, runner = generate({ "issue_key" => "SR-700", "title" => "Add an export button" },
                                  env: { "PATH" => "/usr/bin:/bin", "HOME" => "/home/operator",
                                        "UNRELATED_SECRET" => "must-not-travel" })

    call = runner.calls.fetch(0)
    assert_equal [ "codex", "exec", "--json", "--ephemeral", "--dangerously-bypass-approvals-and-sandbox" ],
                 call.argv
    assert_includes call.stdin_data, "SR-700"
    assert_includes call.stdin_data, "Add an export button"
    assert_includes call.stdin_data, "Return ONLY a JSON object"
    refute call.argv.any? { |argument| argument.include?("Return ONLY a JSON object") },
           "the prompt must never become a process argument for a stdin profile"
    assert_equal 1800, call.timeout_seconds
    assert_equal({ "PATH" => "/usr/bin:/bin", "HOME" => "/home/operator" }, call.env,
                 "only PATH and HOME travel — never an unrelated variable")
  end

  # ------------------------------------------------------------------ S09: one content contract

  # The prompt is the SAME document Claude receives. Asserted by comparing the two adapters'
  # launches for one packet rather than by re-listing the prompt's rules here, which would be a
  # second, drifting copy of the contract.
  def test_both_real_providers_send_the_identical_prompt_for_one_packet
    packet = { "issue_key" => "SR-700", "title" => "Add an export button" }
    _documents, codex_runner = generate(packet)
    claude_runner = FakeCommandRunner.new(result: ok, lines: [
      event("type" => "system", "subtype" => "init"),
      event("type" => "result", "subtype" => "success", "is_error" => false,
            "result" => JSON.generate(VALID_DOCUMENTS))
    ])
    Provider::Claude.new(profile: SpecrelayRunner::ClaudeProfile.new(SpecrelayRunner::ClaudeProfile::CANONICAL),
                         env: {}, working_directory: working_directory,
                         command_runner: claude_runner).generate(packet)

    assert_equal claude_runner.calls.fetch(0).argv.last, codex_runner.calls.fetch(0).stdin_data
  end

  def test_a_response_wrapped_in_prose_with_unrelated_braces_still_parses
    wrapped = <<~TEXT
      Sure, here is the package:
      #{JSON.generate({ "spec.md" => "See {note} below.", "analysis/business.md" => "ok" })}
      (based on config{key: value} if that helps)
    TEXT
    documents, = generate({ "issue_key" => "SR-700" }, answer: wrapped)

    assert_equal "See {note} below.", documents["spec.md"]
    assert_equal "ok", documents["analysis/business.md"]
  end

  def test_output_with_no_json_object_at_all_is_a_generation_failure
    provider, = provider_for(result: ok, lines: answering("I could not complete this request."))

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "the Codex specification provider returned no JSON object"
  end

  def test_malformed_json_inside_a_found_object_is_a_generation_failure
    provider, = provider_for(result: ok, lines: answering('{"spec.md": "ok",}'))

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "did not return valid JSON"
  end

  # A JSON value that is not an object is not a file map: the balanced-object rule finds no object
  # in it at all, so it fails at extraction rather than reaching the document set.
  def test_a_json_value_that_is_not_an_object_of_paths_is_a_generation_failure
    provider, = provider_for(result: ok, lines: answering('["spec.md"]'))

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "the Codex specification provider returned no JSON object"
  end

  # ------------------------------------------------------------------ S07: the process misbehaves

  # A provider that cannot be launched at all is a bounded generation failure, not an exception
  # escaping the lane: the claim would otherwise stay held with no recorded reason. The message
  # names the condition and nothing about the host, because the underlying error carries a path.
  def test_a_launch_error_is_a_bounded_generation_failure
    runner = Object.new
    def runner.run(*, **) = raise(Errno::ENOENT, "/usr/local/bin/codex")
    provider = Provider::Codex.new(profile: profile, env: {}, working_directory: working_directory,
                                   command_runner: runner)

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "the Codex specification provider could not be launched"
    refute_includes error.message, "/usr/local/bin/codex"
  end

  def test_a_timeout_is_a_generation_failure_naming_the_timeout
    result = Result.new(exit_code: nil, stdout: "", stderr: "", duration_seconds: 1800.0, timed_out: true)
    provider, = provider_for(result: result)

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "the Codex specification provider timed out"
  end

  def test_a_non_zero_provider_exit_is_a_generation_failure
    result = Result.new(exit_code: 4, stdout: "", stderr: "boom", duration_seconds: 0.8, timed_out: false)
    provider, = provider_for(result: result)

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "the Codex specification provider exited 4"
    refute_includes error.message, "boom", "a classification must not republish provider bytes"
  end

  # ------------------------------------------------------------------ S08: the stream fails closed

  def unusable(lines)
    provider, = provider_for(result: ok, lines: lines)
    error = assert_raises(Provider::Failed) { provider.generate({}) }
    assert_includes error.message, "the Codex specification provider's output could not be read"
    error.message
  end

  def test_a_stream_with_no_terminal_event_is_unusable
    assert_includes unusable(answering(JSON.generate(VALID_DOCUMENTS))[0..-2]),
                    SpecrelayRunner::CodexStream::FAILURE_NO_TERMINAL
  end

  def test_a_stream_with_two_terminal_events_is_unusable
    assert_includes unusable(answering(JSON.generate(VALID_DOCUMENTS)) + [ event("type" => "turn.completed") ]),
                    SpecrelayRunner::CodexStream::FAILURE_TWO_TERMINALS
  end

  def test_an_event_after_the_terminal_event_is_unusable
    lines = answering(JSON.generate(VALID_DOCUMENTS)) +
            [ event("type" => "item.completed", "item" => item("agent_message", "text" => "late")) ]

    assert_includes unusable(lines), SpecrelayRunner::CodexStream::FAILURE_AFTER_TERMINAL
  end

  def test_a_failed_turn_is_unusable
    lines = [ event("type" => "thread.started"), event("type" => "turn.failed",
                                                       "error" => { "message" => "quota exhausted" }) ]

    message = unusable(lines)
    assert_includes message, SpecrelayRunner::CodexStream::FAILURE_TURN_FAILED
    refute_includes message, "quota exhausted"
  end

  def test_a_top_level_error_event_is_unusable
    lines = [ event("type" => "thread.started"), event("type" => "error", "message" => "boom") ]

    assert_includes unusable(lines), SpecrelayRunner::CodexStream::FAILURE_PROVIDER_ERROR
  end

  def test_a_terminal_event_with_no_public_message_is_unusable
    lines = [ event("type" => "thread.started"), event("type" => "turn.completed") ]

    assert_includes unusable(lines), SpecrelayRunner::CodexStream::FAILURE_NO_REPORT
  end

  def test_output_that_is_not_a_json_event_object_is_unusable
    assert_includes unusable([ event("type" => "thread.started"), JSON.generate([ 1, 2 ]) ]),
                    SpecrelayRunner::CodexStream::FAILURE_UNREADABLE
  end

  def test_a_truncated_final_event_is_unusable
    lines = [ event("type" => "thread.started"), '{"type":"turn.comp' ]

    assert_includes unusable(lines), SpecrelayRunner::CodexStream::FAILURE_INCOMPLETE
  end

  # The prepared task environment a real run hands the provider. These examples are about the
  # stream and the file map, so an ordinary directory is enough; what matters is that the
  # boundary requires one at all.
  def working_directory = @working_directory ||= Dir.mktmpdir("specrelay-spec-task-")
end
