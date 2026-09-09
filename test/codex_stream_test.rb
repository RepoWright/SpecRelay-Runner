# frozen_string_literal: true

require_relative "test_helper"

# The Codex JSONL decoder: the ONE boundary that turns the audited Codex profile's structured
# output into safe public progress and one terminal implementation report.
#
# Same narrow contract the implementation lane already consumes — sink, close, failure,
# final_text — and the same two products that never mix. The event and terminal contracts are
# Codex's own, which is why this is a separate decoder rather than a second mode of an existing one.
class CodexStreamTest < Minitest::Test
  def setup
    @seen = []
    @tmp = Dir.mktmpdir("codex-stream-root-")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
  end

  # --- the supported success shape (S05) -------------------------------------

  def test_a_complete_turn_yields_ordered_progress_and_the_final_message
    stream = feed(thread_started, turn_started,
                  command_started("npm test"),
                  command_completed("npm test", output: "2 passing", exit_code: 0),
                  agent_message("halfway through"),
                  agent_message("## Implementation report\nchanged one file"),
                  turn_completed)

    assert_nil stream.close.failure
    assert_equal "## Implementation report\nchanged one file", stream.final_text
    assert_equal [ "Provider started", "> npm test", "< step completed", "  2 passing",
                   "halfway through", "## Implementation report", "changed one file",
                   "Provider completed" ], texts
  end

  # CommandRunner hands over a partial line once it passes its own pending cap, so a message
  # arriving in fragments must reassemble rather than fail.
  def test_a_fragmented_message_is_reassembled
    stream = build_stream
    json = JSON.generate(agent_message("the whole answer"))
    stream.accept("stdout", json[0, 12])
    stream.accept("stdout", json[12..])
    stream.accept("stdout", JSON.generate(turn_completed))

    assert_nil stream.close.failure
    assert_equal "the whole answer", stream.final_text
  end

  # A tool that failed is public progress, not a verdict on the turn: Codex may recover and
  # complete. Only the terminal event decides the turn.
  def test_a_failed_command_does_not_override_a_later_successful_turn
    stream = feed(thread_started,
                  command_completed("bin/rspec", output: "1 failure", exit_code: 1),
                  command_completed("bin/rspec", output: "0 failures", exit_code: 0),
                  agent_message("fixed and green"),
                  turn_completed)

    assert_nil stream.close.failure
    assert_equal "fixed and green", stream.final_text
    assert_includes texts, "! step failed"
    assert_includes texts, "< step completed"
  end

  def test_only_the_last_public_agent_message_becomes_the_report
    stream = feed(agent_message("first"), agent_message("second"), agent_message("third"), turn_completed)

    assert_equal "third", stream.close.final_text
  end

  # An empty message is not a report. The last NON-EMPTY one is.
  def test_an_empty_trailing_message_does_not_replace_the_report
    stream = feed(agent_message("the report"), agent_message("   "), turn_completed)

    assert_nil stream.close.failure
    assert_equal "the report", stream.final_text
  end

  # An EXACT transcript in the public provider shape, written as literal JSON rather than through
  # this file's builders. The builders and the decoder previously agreed on an `item_type` key the
  # provider does not emit, so the suite proved only that the double matched the implementation.
  # Traced to the official Codex SDK: https://github.com/openai/codex —
  # `sdk/typescript/src/thread.ts` and `sdk/typescript/samples/basic_streaming.ts` both discriminate
  # on `item.type`.
  def test_the_official_public_event_shape_produces_progress_and_the_report
    stream = build_stream
    [
      %({"type":"thread.started","thread_id":"0199a5f0-0000-7000-8000-000000000000"}),
      %({"type":"turn.started"}),
      %({"type":"item.started","item":{"id":"item_0","type":"command_execution",) +
        %("command":"bash -lc ls","status":"in_progress"}}),
      %({"type":"item.completed","item":{"id":"item_0","type":"command_execution",) +
        %("command":"bash -lc ls","aggregated_output":"README.md","exit_code":0,"status":"completed"}}),
      %({"type":"item.completed","item":{"id":"item_1","type":"reasoning","text":"private"}}),
      %({"type":"item.completed","item":{"id":"item_2","type":"agent_message",) +
        %("text":"## Implementation report\\nedited one file"}}),
      %({"type":"turn.completed","usage":{"input_tokens":9,"output_tokens":3}})
    ].each { |line| stream.accept("stdout", "#{line}\n") }

    assert_nil stream.close.failure
    assert_equal "## Implementation report\nedited one file", stream.final_text
    assert_equal [ "Provider started", "> bash -lc ls", "< step completed", "  README.md",
                   "## Implementation report", "edited one file", "Provider completed" ], texts
    refute_includes texts.join("\n"), "private"
  end

  # --- fail closed (S06) -----------------------------------------------------

  def test_malformed_json_fails_closed
    stream = build_stream
    stream.accept("stdout", "{\"type\": not json}\n")
    stream.accept("stdout", JSON.generate(agent_message("ignored")))

    refute_nil stream.close.failure
    assert_equal "", stream.final_text
  end

  def test_valid_json_that_is_not_an_event_object_fails_closed
    stream = build_stream
    stream.accept("stdout", JSON.generate([ 1, 2, 3 ]))

    refute_nil stream.close.failure
  end

  def test_a_stream_that_ends_mid_message_fails_closed
    stream = build_stream
    stream.accept("stdout", JSON.generate(agent_message("truncated"))[0, 20])

    assert_equal SpecrelayRunner::CodexStream::FAILURE_INCOMPLETE, stream.close.failure
    assert_equal "", stream.final_text
  end

  def test_no_terminal_event_fails_closed
    stream = feed(thread_started, agent_message("looks finished but is not"))

    assert_equal SpecrelayRunner::CodexStream::FAILURE_NO_TERMINAL, stream.close.failure
    assert_equal "", stream.final_text
  end

  def test_no_agent_message_fails_closed
    stream = feed(thread_started, command_completed("ls", output: "x", exit_code: 0), turn_completed)

    assert_equal SpecrelayRunner::CodexStream::FAILURE_NO_REPORT, stream.close.failure
    assert_equal "", stream.final_text
  end

  def test_two_terminal_events_fail_closed
    stream = feed(agent_message("report"), turn_completed, turn_completed)

    assert_equal SpecrelayRunner::CodexStream::FAILURE_TWO_TERMINALS, stream.close.failure
    assert_equal "", stream.final_text
  end

  def test_an_event_after_the_terminal_event_fails_closed
    stream = feed(agent_message("report"), turn_completed, agent_message("afterthought"))

    assert_equal SpecrelayRunner::CodexStream::FAILURE_AFTER_TERMINAL, stream.close.failure
    assert_equal "", stream.final_text
  end

  def test_a_failed_turn_fails_closed
    stream = feed(agent_message("report"), { "type" => "turn.failed", "error" => { "message" => "model unavailable" } })

    assert_equal SpecrelayRunner::CodexStream::FAILURE_TURN_FAILED, stream.close.failure
    assert_equal "", stream.final_text
  end

  def test_a_top_level_error_event_fails_closed
    stream = feed(agent_message("report"), { "type" => "error", "message" => "stream aborted" })

    assert_equal SpecrelayRunner::CodexStream::FAILURE_PROVIDER_ERROR, stream.close.failure
    assert_equal "", stream.final_text
  end

  # A failure reason is the runner's own sentence. It never carries provider bytes.
  def test_a_failure_reason_never_carries_provider_bytes
    stream = feed(agent_message("report"),
                  { "type" => "turn.failed", "error" => { "message" => "quota for account operator@example.test" } })

    refute_match(/operator@example\.test/, stream.close.failure)
    refute_match(/quota/, stream.failure)
  end

  # Nothing after a fatal decode failure is trusted, so nothing after it is shown.
  def test_nothing_is_shown_after_a_failure
    stream = build_stream
    stream.accept("stdout", JSON.generate({ "type" => "error", "message" => "boom" }))
    before = @seen.length
    stream.accept("stdout", JSON.generate(agent_message("later")))

    assert_equal before, @seen.length
  end

  # --- privacy (S08) ---------------------------------------------------------

  def test_private_reasoning_is_never_public
    stream = feed(thread_started,
                  { "type" => "item.completed",
                    "item" => { "id" => "i1", "type" => "reasoning", "text" => "my private plan" } },
                  agent_message("the public answer"), turn_completed)

    assert_nil stream.close.failure
    refute_includes texts.join("\n"), "my private plan"
    assert_includes texts, "the public answer"
  end

  def test_an_unknown_item_type_renders_nothing_rather_than_its_object
    stream = feed(thread_started,
                  { "type" => "item.completed",
                    "item" => { "id" => "i1", "type" => "future_thing", "secret" => "leak-me" } },
                  agent_message("report"), turn_completed)

    assert_nil stream.close.failure
    refute_includes texts.join("\n"), "leak-me"
    refute_includes texts.join("\n"), "future_thing"
  end

  def test_an_unknown_event_type_renders_nothing
    stream = feed(thread_started, { "type" => "future.event", "payload" => "leak-me" },
                  agent_message("report"), turn_completed)

    assert_nil stream.close.failure
    refute_includes texts.join("\n"), "leak-me"
  end

  # Redaction stays the ONE owner of secret shapes and is called, not copied.
  def test_a_credential_shaped_value_is_redacted_in_public_progress
    stream = feed(agent_message("token sk-live-CODEX-DO-NOT-LEAK-0123456789 used"), turn_completed)
    stream.close

    refute_includes texts.join("\n"), "sk-live-CODEX-DO-NOT-LEAK-0123456789"
    assert_includes texts.join("\n"), "[REDACTED]"
  end

  # The approved worktree root is the only prefix a public path may be shown relative to.
  def test_an_in_root_path_renders_relative_and_an_outside_path_is_withheld
    stream = feed(command_completed("cat", output: "#{@tmp}/app/thing.rb\n/Users/someone/private.rb",
                                    exit_code: 0),
                  agent_message("report"), turn_completed)
    stream.close

    joined = texts.join("\n")
    assert_includes joined, "app/thing.rb"
    refute_includes joined, @tmp
    refute_includes joined, "/Users/someone/private.rb"
    assert_includes joined, "[LOCAL_PATH]"
  end

  # stderr is provider bytes, not structured output. Its bytes are not forwarded at all; ONE
  # bounded notice records that the provider wrote diagnostics.
  def test_stderr_bytes_never_reach_the_public_stream
    stream = build_stream
    stream.accept("stderr", "operator@example.test could not read /Users/alice/private.py")
    stream.accept("stderr", "more unvetted chatter")
    stream.accept("stdout", JSON.generate(agent_message("report")))
    stream.accept("stdout", JSON.generate(turn_completed))

    assert_nil stream.close.failure
    notices = @seen.select { |source, _| source == "stderr" }
    assert_equal 1, notices.size, "one bounded notice, not one per line: #{notices.inspect}"
    [ "operator@example.test", "/Users/alice/private.py", "unvetted chatter" ].each do |raw|
      refute_includes @seen.flatten.join(" "), raw
    end
  end

  # One event's bytes are bounded, so an unbounded report cannot complete a parse and cannot
  # become this attempt's evidence.
  def test_a_report_past_the_event_bound_fails_closed
    stream = feed(agent_message("x" * (SpecrelayRunner::CodexStream::MAX_PENDING_BYTES + 1)), turn_completed)

    assert_equal SpecrelayRunner::CodexStream::FAILURE_UNREADABLE, stream.close.failure
    assert_equal "", stream.final_text
  end

  private

  def build_stream(repository_path: @tmp)
    SpecrelayRunner::CodexStream.new(sink: ->(source, text) { @seen << [ source, text ] },
                                     repository_path: repository_path)
  end

  def feed(*events)
    stream = build_stream
    events.each { |event| stream.accept("stdout", "#{JSON.generate(event)}\n") }
    stream
  end

  def texts = @seen.map(&:last)

  def thread_started = { "type" => "thread.started", "thread_id" => "th_1" }
  def turn_started = { "type" => "turn.started" }
  def turn_completed = { "type" => "turn.completed", "usage" => { "input_tokens" => 10 } }

  # The nested item discriminator is `item.type`, as the public Codex thread contract emits it.
  # See the official SDK: sdk/typescript/src/thread.ts and samples/basic_streaming.ts in
  # https://github.com/openai/codex — both branch on `item.type`, never on an `item_type` key.
  def agent_message(text)
    { "type" => "item.completed", "item" => { "id" => "i_msg", "type" => "agent_message", "text" => text } }
  end

  def command_started(command)
    { "type" => "item.started",
      "item" => { "id" => "i_cmd", "type" => "command_execution", "command" => command,
                  "status" => "in_progress" } }
  end

  def command_completed(command, output:, exit_code:)
    { "type" => "item.completed",
      "item" => { "id" => "i_cmd", "type" => "command_execution", "command" => command,
                  "aggregated_output" => output, "exit_code" => exit_code, "status" => "completed" } }
  end
end
