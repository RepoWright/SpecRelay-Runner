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
  #
  # MAPIAI-60 — the profile is structured-output-only, so this double behaves the way the real
  # CommandRunner does for it: each JSONL line is handed to `on_output` WHILE the provider is
  # notionally running, and the Result's stdout is no longer what the adapter reads.
  class FakeCommandRunner
    Call = Struct.new(:argv, :chdir, :env, :timeout_seconds, keyword_init: true)

    def initialize(result:, lines: [])
      @result = result
      @lines = lines
      @calls = []
    end

    attr_reader :calls

    def run(argv, chdir:, env:, timeout_seconds:, on_output: nil)
      @calls << Call.new(argv: argv, chdir: chdir, env: env, timeout_seconds: timeout_seconds)
      @lines.each { |line| on_output&.call("stdout", line) }
      @result
    end
  end

  def build_profile(command: "claude", args: [ "--print", "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions" ],
                    timeout_seconds: 900, env: {})
    SpecrelayRunner::ClaudeProfile.new("provider" => "claude", "command" => command, "args" => args,
                                      "timeout_seconds" => timeout_seconds, "env" => env)
  end

  def settings = Settings.new({}, env: {})

  def provider_for(result:, lines: [], profile: build_profile, env: {})
    runner = FakeCommandRunner.new(result: result, lines: lines)
    [ Provider::Claude.new(profile: profile, settings: settings, env: env,
                          working_directory: Dir.mktmpdir("specrelay-spec-task-"),
                          command_runner: runner), runner ]
  end

  # A provider that worked and then answered: one `init`, one PUBLIC narration line the operator
  # must now read (CR-005), one `thinking` block that must never surface whatever else changes,
  # and one terminal result carrying `answer` — which is what the package parser, and only the
  # package parser, is given.
  def answering(answer, duration_seconds: 1.2)
    lines = [ JSON.generate("type" => "system", "subtype" => "init"),
              JSON.generate("type" => "assistant", "message" => { "content" => [
                { "type" => "text", "text" => "Composing the package." },
                { "type" => "thinking", "thinking" => "private reasoning that must never be shown",
                  "signature" => "sig-1" } ] }),
              JSON.generate("type" => "result", "subtype" => "success", "is_error" => false,
                            "result" => answer) ]
    [ Result.new(exit_code: 0, stdout: "", stderr: "", duration_seconds: duration_seconds, timed_out: false),
      lines ]
  end

  # Drives `generate` for a provider that answers `answer`; returns [documents, runner, progress].
  def generate(packet, answer: JSON.generate(VALID_DOCUMENTS), profile: build_profile, env: {})
    result, lines = answering(answer)
    provider, runner = provider_for(result: result, lines: lines, profile: profile, env: env)
    progress = []
    documents = provider.generate(packet, on_output: ->(source, text) { progress << [ source, text ] })
    [ documents, runner, progress ]
  end

  def failure(exit_code:, stdout: "", stderr: "")
    Result.new(exit_code: exit_code, stdout: stdout, stderr: stderr, duration_seconds: 0.8, timed_out: false)
  end

  VALID_DOCUMENTS = { "spec.md" => "# Spec\n", "analysis/business.md" => "business case",
                     "analysis/technical.md" => "technical detail" }.freeze

  # ------------------------------------------------------------------ a valid response

  def test_a_valid_three_document_response_is_parsed_into_the_package
    documents, = generate({ "issue_key" => "SR-700" })

    assert_equal VALID_DOCUMENTS, documents
  end

  # MAPIAI-60 — the two products of one stream, proven together: the package comes ONLY from the
  # terminal result, and what the operator saw is normalized status, never the model's prose.
  def test_progress_reaches_the_caller_while_the_package_comes_only_from_the_terminal_result
    documents, _runner, progress = generate({ "issue_key" => "SR-700" })

    assert_equal VALID_DOCUMENTS, documents
    assert_equal [ [ "status", "Provider started" ], [ "status", "Composing the package." ],
                   [ "status", "Provider completed" ] ], progress
    refute_includes progress.flatten.join(" "), "private reasoning"
    refute_includes progress.flatten.join(" "), "spec.md"
  end

  # An unreadable stream means the runner cannot prove which bytes were the answer, so there is
  # no package to validate — a refusal, never a partially trusted parse.
  def test_structured_output_without_a_terminal_result_is_a_generation_failure
    provider, = provider_for(result: Result.new(exit_code: 0, stdout: "", stderr: "",
                                                duration_seconds: 1.0, timed_out: false),
                             lines: [ JSON.generate("type" => "system", "subtype" => "init") ])

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "could not be read"
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
    documents, = generate({ "issue_key" => "SR-700" }, answer: wrapped)

    assert_equal "See {note} below.", documents["spec.md"]
    assert_equal "ok", documents["analysis/business.md"]
  end

  # ------------------------------------------------------------------ the launch itself

  def test_the_launch_carries_the_configured_command_arguments_prompt_timeout_and_environment
    profile = build_profile(command: "claude", args: [ "--print", "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions" ],
                            timeout_seconds: 42, env: { "CLAUDE_EXTRA" => "yes" })
    _documents, runner = generate({ "issue_key" => "SR-700", "title" => "Add an export button" },
                                  profile: profile,
                                  env: { "PATH" => "/usr/bin:/bin", "HOME" => "/home/operator",
                                        "UNRELATED_SECRET" => "must-not-travel" })

    call = runner.calls.fetch(0)
    argv = [ "claude", "--print", "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions" ]
    assert_equal argv, call.argv[0, argv.length]
    assert_equal 1, call.argv.length - argv.length, "the packet-derived prompt is exactly one argv element"
    assert_includes call.argv.last, "SR-700"
    assert_includes call.argv.last, "Add an export button"
    assert_includes call.argv.last, "Return ONLY a JSON object"
    assert_equal 42, call.timeout_seconds
    assert_equal({ "PATH" => "/usr/bin:/bin", "HOME" => "/home/operator", "CLAUDE_EXTRA" => "yes" }, call.env,
                "only PATH, HOME and the profile's own extra_env travel — never an unrelated variable")
  end

  # MVP-0028 remediation, defect 3 — the prompt must actually name the new required key and the
  # D3 synthesis rules the live MAPIAI-52 package violated, or a real model has no way to know
  # this runner's document contract changed.
  def test_the_prompt_names_the_new_required_key_and_the_synthesis_rules
    _documents, runner = generate({ "issue_key" => "SR-700" })

    prompt = runner.calls.fetch(0).argv.last
    assert_includes prompt, "analysis/input-evidence.md"
    assert_includes prompt, "analysis/open-questions.md"
    assert_includes prompt, "PRODUCT BEHAVIOR"
    assert_includes prompt, "Resolve a vague reference"
    assert_includes prompt, "DURABLE TRUTH"
    assert_includes prompt, "not yet published"
  end

  # Review 006, F2 second pass — a linked issue that reaches the evidence has already had its
  # content READ by Platform; the prompt must ask for genuine analysis of it, not permission to
  # disclose that it was skipped.
  def test_the_prompt_requires_genuine_analysis_of_a_linked_issues_own_content
    _documents, runner = generate({ "issue_key" => "SR-700" })

    prompt = runner.calls.fetch(0).argv.last
    assert_includes prompt, "already had its OWN key, title, and description read"
    assert_includes prompt, "its own stated acceptance criteria"
  end

  # MVP-0028 decision D6 — a same-ticket revision must preserve stable open-question ids and
  # resolution history rather than starting from a blank slate every run.
  def test_the_prompt_requires_stable_open_question_ids_and_the_resolved_shape_on_revision
    _documents, runner = generate({ "issue_key" => "SR-700",
                                   "revision" => { "previous_files" => { "spec.md" => "# SR-700\n\nprevious text" } } })

    prompt = runner.calls.fetch(0).argv.last
    assert_includes prompt, "reuse the previous package's own"
    assert_includes prompt, "never renumber or reissue it"
    assert_includes prompt, "Status: resolved"
    assert_includes prompt, "Never resolve"
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
    result, lines = answering("I could not complete this request.")
    provider, = provider_for(result: result, lines: lines)

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "returned no JSON object"
  end

  # A brace is present, but what it encloses is not valid JSON (a trailing comma) — distinct
  # from "no object found" and from the oversized-output boundary below.
  def test_malformed_json_inside_a_found_object_is_a_generation_failure
    result, lines = answering('{"spec.md": "ok",}')
    provider, = provider_for(result: result, lines: lines)

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "did not return valid JSON"
  end

  # The size bound moved to the decoder with the bytes it guards, so an oversized answer is
  # refused as an unreadable stream rather than parsed and then rejected.
  def test_an_oversized_terminal_result_is_a_generation_failure_before_any_parsing_is_attempted
    oversized = "x" * (SpecrelayRunner::ClaudeStream::MAX_RESULT_BYTES + 1)
    result, lines = answering(oversized)
    provider, = provider_for(result: result, lines: lines)

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "could not be read"
  end
end
