# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/claude_stream_json"

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
  J = ClaudeStreamJson
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

    def run(argv, chdir:, env:, timeout_seconds:, on_output: nil, stop_check: nil)
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

  def provider_for(result:, lines: [], profile: build_profile, env: {})
    runner = FakeCommandRunner.new(result: result, lines: lines)
    [ Provider::Claude.new(profile: profile, env: env,
                           working_directory: Dir.mktmpdir("specrelay-spec-task-"),
                           command_runner: runner), runner ]
  end

  # A provider that worked and then answered: one `init`, one PUBLIC narration line the operator
  # must now read (CR-005), one `thinking` block that must never surface whatever else changes,
  # and one terminal result. The document map is the result's schema-constrained
  # `structured_output`; its textual `result` is what the model also wrote and is never read.
  def answering(structured = VALID_STRUCTURED, text: "", is_error: false, subtype: "success", duration_seconds: 1.2)
    terminal = { "type" => "result", "subtype" => subtype, "is_error" => is_error, "result" => text }
    terminal["structured_output"] = structured unless structured == :absent
    lines = [ JSON.generate("type" => "system", "subtype" => "init"),
              JSON.generate("type" => "assistant", "message" => { "content" => [
                { "type" => "text", "text" => "Composing the package." },
                { "type" => "thinking", "thinking" => "private reasoning that must never be shown",
                  "signature" => "sig-1" } ] }),
              JSON.generate(terminal) ]
    [ Result.new(exit_code: 0, stdout: "", stderr: "", duration_seconds: duration_seconds, timed_out: false),
      lines ]
  end

  # Drives `generate` for a provider whose terminal result carries `structured`; returns
  # [documents, runner, progress].
  def generate(packet, structured: VALID_STRUCTURED, text: "", profile: build_profile, env: {})
    result, lines = answering(structured, text: text)
    provider, runner = provider_for(result: result, lines: lines, profile: profile, env: env)
    progress = []
    documents = provider.generate(packet, on_output: ->(source, text) { progress << [ source, text ] })
    [ documents, runner, progress ]
  end

  def refusal(structured = VALID_STRUCTURED, **terminal)
    result, lines = answering(structured, **terminal)
    provider, = provider_for(result: result, lines: lines)
    assert_raises(Provider::Failed) { provider.generate({}) }
  end

  def failure(exit_code:, stdout: "", stderr: "")
    Result.new(exit_code: exit_code, stdout: stdout, stderr: stderr, duration_seconds: 0.8, timed_out: false)
  end

  VALID_DOCUMENTS = { "spec.md" => "# Spec\n", "analysis/business.md" => "business case",
                     "analysis/technical.md" => "technical detail" }.freeze
  # The same documents under the property names the requested schema declares.
  VALID_STRUCTURED = { "spec.md" => "# Spec\n", "analysis_business.md" => "business case",
                       "analysis_technical.md" => "technical detail" }.freeze
  # A textual answer that is plausible but not valid JSON: a literal line feed inside a quoted
  # document, the shape that used to lose a whole package at the parser.
  BROKEN_TEXT = %({"spec.md": "# Spec\nline two", "analysis/business.md": "ok"})

  # ------------------------------------------------------------------ a valid response

  def test_a_valid_three_document_response_is_parsed_into_the_package
    documents, = generate({ "issue_key" => "SR-700" })

    assert_equal VALID_DOCUMENTS, documents
  end

  # MAPIAI-60 — the two products of one stream, proven together: the package comes ONLY from the
  # terminal result, and what the operator saw is status, never the model's prose. This lane
  # withholds assistant text entirely, because the documents themselves may arrive that way.
  def test_progress_reaches_the_caller_while_the_package_comes_only_from_the_terminal_result
    documents, _runner, progress = generate({ "issue_key" => "SR-700" })

    assert_equal VALID_DOCUMENTS, documents
    assert_equal [ [ "status", "Provider started" ], [ "status", "Provider completed" ] ], progress
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

  # The textual answer reproduces the original rejection, and it no longer matters: the documents
  # come from the structured value, byte for byte, including real line feeds, quotes,
  # backslashes and non-ASCII text.
  def test_structured_documents_survive_byte_for_byte_whatever_the_textual_answer_was
    assert_raises(JSON::ParserError) { JSON.parse(BROKEN_TEXT) }
    content = "# Spec\n\nShe said \"hi\" \\ C:\\path\nGrüße — ✓\n"
    documents, = generate({ "issue_key" => "SR-700" },
                          structured: VALID_STRUCTURED.merge("spec.md" => content), text: BROKEN_TEXT)

    assert_equal content, documents["spec.md"]
    assert_equal VALID_DOCUMENTS.keys.sort, documents.keys.sort
  end

  def test_the_optional_open_questions_alias_maps_to_its_exact_path_when_present
    documents, = generate({}, structured: VALID_STRUCTURED.merge("analysis_open-questions.md" => "# Open questions\n",
                                                                 "analysis_input-evidence.md" => "# Input evidence\n"))

    assert_equal "# Open questions\n", documents["analysis/open-questions.md"]
    assert_equal "# Input evidence\n", documents["analysis/input-evidence.md"]
    refute documents.key?("analysis_open-questions.md")
  end

  # A missing required document is not this provider's rule: it passes the map through and the
  # one owner of that rule, DocumentSet, refuses it before anything is written.
  def test_a_missing_required_alias_is_refused_by_the_document_set_not_coerced
    documents, = generate({}, structured: VALID_STRUCTURED.except("analysis_business.md"))

    refute documents.key?("analysis/business.md")
    error = assert_raises(SpecrelayRunner::Specification::DocumentSet::Invalid) do
      SpecrelayRunner::Specification::DocumentSet.validate!(documents, issue_key: "SR-700")
    end
    assert_includes error.message, "analysis/business.md"
  end

  def test_an_unknown_or_respelled_alias_is_refused_without_naming_its_content
    [ "notes", " spec.md", "analysis/business.md" ].each do |key|
      error = refusal(VALID_STRUCTURED.merge(key => "secret-ish content"))

      assert_includes error.message, "unrecognized document"
      assert_match(/entry \d+/, error.message)
      refute_includes error.message, "secret-ish content"
    end
  end

  def test_a_non_string_document_is_refused_rather_than_coerced
    [ 42, nil, [ "# Spec" ], { "text" => "# Spec" } ].each do |value|
      error = refusal(VALID_STRUCTURED.merge("spec.md" => value))

      assert_includes error.message, "spec.md is not text"
    end
  end

  # No structured map means no package, however plausible the text beside it.
  def test_a_missing_null_or_non_object_structured_value_is_refused_despite_a_plausible_text_result
    [ :absent, nil, [ VALID_STRUCTURED ], "{}", 1 ].each do |structured|
      error = refusal(structured, text: JSON.generate(VALID_DOCUMENTS))

      assert_includes error.message, "returned no structured document map"
    end
  end

  def test_an_error_flagged_or_unsuccessful_terminal_result_is_refused_despite_a_valid_map_and_exit_zero
    [ { is_error: true }, { subtype: "error_max_turns" } ].each do |terminal|
      error = refusal(VALID_STRUCTURED, text: JSON.generate(VALID_DOCUMENTS), **terminal)

      assert_includes error.message, "did not finish successfully"
    end
  end

  # A structured value inside a frame the decoder refused is never handed over.
  def test_a_truncated_transport_with_a_structured_value_is_refused_as_unreadable
    result, lines = answering
    provider, = provider_for(result: result, lines: [ *lines[0..1], lines.last[0...-2] ])

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "could not be read"
  end

  # The content rules stay DocumentSet's: a structured map that passes this provider still fails
  # there when its documents are not a specification.
  def test_structured_documents_with_invalid_content_still_fail_the_document_set
    documents, = generate({}, structured: { "spec.md" => "no title", "analysis_input-evidence.md" => "x",
                                            "analysis_business.md" => "x", "analysis_technical.md" => "x" })

    assert_raises(SpecrelayRunner::Specification::DocumentSet::Invalid) do
      SpecrelayRunner::Specification::DocumentSet.validate!(documents, issue_key: "SR-700")
    end
  end

  # A model may ALSO write the documents as ordinary text, and may split them across turns. No
  # fragment of them reaches progress, while tool identities, dispositions and status still do.
  def test_documents_written_as_assistant_text_never_reach_progress_even_when_split
    result, lines = answering
    copy = JSON.generate(VALID_DOCUMENTS.merge("spec.md" => "# Spec\nASSISTANT-COPY-MARKER line"))
    half = copy.length / 2
    text = ->(fragment) { JSON.generate("type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => fragment } ] }) }
    read = JSON.generate("type" => "assistant", "message" => { "content" => [
      { "type" => "tool_use", "id" => "t1", "name" => "Grep", "input" => { "pattern" => "export" } } ] })
    read_result = JSON.generate("type" => "user", "message" => { "content" => [
      { "type" => "tool_result", "tool_use_id" => "t1", "content" => "app/export.rb" } ] })
    provider, = provider_for(result: result,
                             lines: [ lines[0], read, read_result, text.(copy[0, half]), text.(copy[half..]), lines.last ])
    progress = []

    documents = provider.generate({}, on_output: ->(source, line) { progress << [ source, line ] })

    assert_equal VALID_DOCUMENTS, documents
    shown = progress.map(&:last).join("\n")
    [ "ASSISTANT-COPY-MARKER", "business case", "technical detail", copy[0, 20], copy[half, 20] ].each do |fragment|
      refute_includes shown, fragment
    end
    assert_equal [ "Provider started", "> Grep", "< step completed", "Provider completed" ], progress.map(&:last)
  end

  # Every supported free-form route at once: the same string could be source the model read or
  # a fragment of the documents, so this lane shows each tool's identity and disposition and none
  # of their text. The package still comes whole from the structured terminal map.
  def test_no_free_form_route_carries_document_text_into_progress
    marker = "DOC-MARKER"
    path = "specs/SR-700-sample/spec.md"
    messages = [
      J.narration("# Spec #{marker}"),
      J.tool_call("Write", { "file_path" => path, "content" => "# Spec #{marker}" }, "w1"),
      J.result("w1", "File created successfully at #{path}"),
      J.tool_call("Write", { "file_path" => path, "contents" => "# Spec #{marker}" }, "w2"),
      J.result("w2", "File created successfully at #{path}"),
      J.edit_call(path, "old", "#{marker} new"),
      J.edit_result("toolu_edit", path, "old", "#{marker} new"),
      J.read_call(path),
      J.read_result("toolu_read", path, "# Spec #{marker}\n"),
      J.bash_call("printf '#{marker}'", description: "Print #{marker}"),
      J.bash_result("toolu_bash", stdout: "#{marker} out", stderr: "#{marker} err"),
      J.task_call("Draft #{marker}", "Write #{marker}"),
      J.task_output_result("toolu_task", "t1", "#{marker} task output"),
      J.tool_call("TaskOutput", { "task_id" => "t1", "note" => marker }, "o1"),
      J.result("o1", "#{marker} fallback body"),
      J.bash_call("false", id: "b2"),
      J.failed_result("b2", "#{marker} failure text"),
      J.bash_call("sleep 9", id: "b3"),
      J.result("b3", "#{marker} interrupted", detail: { "interrupted" => true, "stdout" => marker }),
      J.tool_call("StructuredOutput", VALID_STRUCTURED.merge("spec.md" => "# Spec #{marker}"), "s1")
    ]
    result, lines = answering
    provider, = provider_for(result: result, lines: [ lines[0], *messages.map { |m| JSON.generate(m) }, lines.last ])
    progress = []

    documents = provider.generate({}, on_output: ->(source, line) { progress << [ source, line ] })

    assert_equal VALID_DOCUMENTS, documents
    shown = progress.map(&:last)
    refute_includes shown.join("\n"), marker
    assert_equal [ "Provider started", "> Write", "< step completed", "> Write", "< step completed",
                   "> Edit", "< step completed", "> Read", "< step completed", "> Bash", "< step completed",
                   "> Task", "< step completed", "> TaskOutput", "< step completed", "> Bash", "! step failed",
                   "> Bash", "! step interrupted", "> StructuredOutput", "Provider completed" ], shown
  end

  # The instruction names what this run actually accepts: the schema's property names, submitted
  # as structured output, never as text.
  def test_the_prompt_asks_for_the_schema_properties_through_structured_output_only
    _documents, runner = generate({ "issue_key" => "SR-700" })

    prompt = runner.calls.fetch(0).argv.last
    %w[spec.md analysis_input-evidence.md analysis_business.md analysis_technical.md analysis_open-questions.md].each do |name|
      assert_includes prompt, %("#{name}")
    end
    assert_includes prompt, "structured output"
    assert_includes prompt, "Never write any document, or any part of one, as ordinary text."
    refute_includes prompt, "Return ONLY a JSON object mapping file paths"
  end

  # A malformed frame is reported by its stage, category and the parser's numeric location —
  # never by the parser's message or any of the frame's bytes.
  def test_a_malformed_terminal_frame_reports_a_safe_located_failure
    result, lines = answering
    malformed = %({"type":"result","subtype":"success","is_error":false,"result":"FRAME-MARKER\nsecond line"})
    provider, = provider_for(result: result, lines: [ lines[0], malformed ])

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_equal "the Claude specification provider's output could not be read: " \
                 "the provider's structured output is malformed at line 2, column 0", error.message
    refute_includes error.message, "FRAME-MARKER"
  end

  # The documents arrive as the StructuredOutput tool's input; they are the answer, not progress.
  def test_the_structured_output_tool_payload_never_reaches_progress
    result, lines = answering
    payload = JSON.generate("type" => "assistant", "message" => { "content" => [
      { "type" => "tool_use", "id" => "t1", "name" => "StructuredOutput",
        "input" => VALID_STRUCTURED.merge("spec.md" => "# Spec\nconfidential draft line") } ] })
    provider, = provider_for(result: result, lines: [ *lines[0..1], payload, lines.last ])
    progress = []

    provider.generate({}, on_output: ->(source, text) { progress << [ source, text ] })

    assert_includes progress, [ "status", "> StructuredOutput" ]
    refute_includes progress.flatten.join(" "), "confidential draft line"
    refute_includes progress.flatten.join(" "), "technical detail"
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
    argv = [ "claude", "--print", "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions",
             "--json-schema", JSON.generate(SpecrelayRunner::Specification::PackagePath::PROVIDER_SCHEMA) ]
    assert_equal argv, call.argv[0, argv.length]
    assert_equal 1, call.argv.length - argv.length, "the packet-derived prompt is exactly one argv element"
    assert_includes call.argv.last, "SR-700"
    assert_includes call.argv.last, "Add an export button"
    assert_includes call.argv.last, "Submit the package ONLY through the structured output"
    assert_equal 42, call.timeout_seconds
    assert_equal({ "PATH" => "/usr/bin:/bin", "HOME" => "/home/operator", "CLAUDE_EXTRA" => "yes" }, call.env,
                "only PATH, HOME and the profile's own extra_env travel — never an unrelated variable")
  end

  # The specification writer shares the exact implementation profile, and with it the approved
  # 18,000-second process limit.
  # The operator reads the invocation that actually ran, not the base argv it extends.
  def test_the_description_names_the_effective_schema_invocation
    provider, = provider_for(result: failure(exit_code: 0))

    assert_includes provider.describe, "--dangerously-skip-permissions --json-schema {"
    assert_includes provider.describe, '"additionalProperties":false'
  end

  # The fixed schema is the whole contract with the provider: four required string documents, one
  # optional, nothing else admitted, each property a path spelled without "/".
  def test_the_requested_schema_is_the_fixed_document_contract
    assert_equal({ "type" => "object",
                   "properties" => { "spec.md" => { "type" => "string" },
                                     "analysis_input-evidence.md" => { "type" => "string" },
                                     "analysis_business.md" => { "type" => "string" },
                                     "analysis_technical.md" => { "type" => "string" },
                                     "analysis_open-questions.md" => { "type" => "string" } },
                   "required" => %w[spec.md analysis_input-evidence.md analysis_business.md analysis_technical.md],
                   "additionalProperties" => false },
                 SpecrelayRunner::Specification::PackagePath::PROVIDER_SCHEMA)
  end

  def test_the_approved_profile_bounds_the_specification_writer_at_18000_seconds
    profile = SpecrelayRunner::ImplementationProfile.for(SpecrelayRunner::ImplementationProfile.canonical("claude"))

    _documents, runner = generate({ "issue_key" => "SR-700" }, profile: profile)

    assert_equal 18_000, runner.calls.fetch(0).timeout_seconds
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

  # Claude's launch-error behaviour is UNCHANGED, and this test exists to hold it that way.
  #
  # An absent or unexecutable CLI raises the operating system's own error out of this adapter,
  # exactly as it did before the second provider existed. Classifying it as a bounded
  # `Provider::Failed` would be an improvement to Claude's failure boundary, and this slice is
  # not allowed to make one: the accepted boundary is that Claude's argv, stream, parser and
  # FAILURE behaviour are byte-for-byte what they were. The bounded classification is Codex's
  # own, proven in its own suite, and the asymmetry is deliberate rather than an oversight.
  def test_a_launch_error_propagates_unchanged_rather_than_being_reclassified
    runner = Object.new
    def runner.run(*, **) = raise(Errno::ENOENT, "/usr/local/bin/claude")
    provider = Provider::Claude.new(profile: build_profile, env: {},
                                    working_directory: Dir.mktmpdir("specrelay-spec-task-"),
                                    command_runner: runner)

    assert_raises(Errno::ENOENT) { provider.generate({}) }
  end

  def test_a_timeout_is_a_generation_failure_naming_the_timeout
    result = Result.new(exit_code: nil, stdout: "", stderr: "", duration_seconds: 900.0, timed_out: true)
    provider, = provider_for(result: result)

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "timed out"
  end

  # The size bound moved to the decoder with the bytes it guards, so an oversized answer is
  # refused as an unreadable stream rather than parsed and then rejected.
  def test_an_oversized_terminal_result_is_a_generation_failure_before_any_parsing_is_attempted
    oversized = "x" * (SpecrelayRunner::ClaudeStream::MAX_RESULT_BYTES + 1)
    result, lines = answering(VALID_STRUCTURED.merge("spec.md" => oversized))
    provider, = provider_for(result: result, lines: lines)

    error = assert_raises(Provider::Failed) { provider.generate({}) }

    assert_includes error.message, "could not be read"
  end

  # The fixed schema adapter rejects an unknown alias before DocumentSet; the text-map
  # adapter still sends file names to that existing validation gate unchanged.
  def test_a_leading_space_schema_alias_is_rejected_before_the_document_gate
    error = refusal(VALID_STRUCTURED.merge(" analysis_business.md" => "business case"))

    assert_includes error.message, "unrecognized document"
    refute_includes error.message, "business case"
  end
end
