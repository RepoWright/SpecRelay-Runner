# frozen_string_literal: true

require_relative "test_helper"

# MAPIAI-60 — the ONE Claude structured-output decoder both execution lanes use.
#
# Two products come out of the same byte stream and must never contaminate each other:
# safe public progress the operator sees WHILE Claude works, and the terminal result the
# existing report/package parsers still own. The tests below are organised around that
# split, plus the fail-closed rule that makes the split trustworthy: if the runner cannot
# prove which bytes are progress and which are the result, it must refuse both.
class ClaudeStreamTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("claude-stream")
    @seen = []
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
  end

  # ---- S01: a real child process emitting timed JSONL --------------------

  # Not a parser unit test: a real process writes real JSONL over time, through the real
  # CommandRunner reader, so "progress arrives before exit" is measured rather than assumed.
  def test_progress_arrives_from_a_live_child_process_before_it_exits
    script = write_script(<<~RUBY)
      $stdout.sync = true
      puts JSON.generate({ "type" => "system", "subtype" => "init", "cwd" => "/private/home/op" })
      puts JSON.generate({ "type" => "assistant", "message" => { "content" => [
        { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => #{File.join(@tmp, 'app/index.html').inspect} } }
      ] } })
      sleep 0.5
      puts JSON.generate({ "type" => "result", "subtype" => "success", "is_error" => false,
                           "result" => "done" })
    RUBY
    times = []
    stream = SpecrelayRunner::ClaudeStream.new(
      sink: ->(source, text) { @seen << [ source, text ] and times << monotonic },
      repository_path: @tmp
    )

    result = SpecrelayRunner::CommandRunner.run([ RbConfig.ruby, script ], chdir: @tmp,
                                                env: { "PATH" => ENV["PATH"] }, timeout_seconds: 20,
                                                on_output: stream.sink)

    assert_equal 0, result.exit_code
    assert_nil stream.close.failure
    assert_equal "done", stream.final_text
    # MAPIAI-77 — the assigned worktree is the ONE approved root, so an in-root path reaches the
    # operator in its repository-relative form and the temporary root itself never does.
    assert_equal [ "Provider started", "> Read app/index.html", "Provider completed" ], texts
    gap = times.last - times[1]
    assert_operator gap, :>=, 0.4,
                    "the tool progress must arrive BEFORE the provider's terminal result, not with it"
  end

  def test_every_normalized_event_is_reported_on_the_status_stream
    feed(init, tool_use("Read", "file_path" => File.join(@tmp, "a.rb")), result_message)

    assert_equal [ "status" ], @seen.map(&:first).uniq
  end

  # ---- S02 / S07: the terminal result stays separate and byte-exact ------

  def test_the_terminal_result_is_returned_verbatim_and_never_displayed
    documents = JSON.generate({ "spec.md" => "# Title\n\nbody with {braces}\n" })
    stream = feed(init, assistant_text("here is the package"), result_message(documents))

    assert_equal documents, stream.final_text
    # CR-005 shows the narration; what must NEVER be duplicated into the live view is the
    # terminal RESULT, which is the package the parsers own.
    assert_includes texts.join("\n"), "here is the package"
    refute_includes texts.join("\n"), "spec.md"
    refute_includes texts.join("\n"), "body with {braces}"
  end

  # ---- incremental parsing ----------------------------------------------

  # CommandRunner hands over a partial line once it passes MAX_PENDING_LINE_BYTES, so one
  # JSONL message can arrive in several pieces. Re-assembly is the decoder's job.
  def test_one_message_split_across_reads_is_reassembled
    message = JSON.generate(result_message("assembled"))
    head, tail = message[0, 20], message[20..]
    stream = build_stream
    stream.accept("stdout", head)
    stream.accept("stdout", tail)

    assert_nil stream.close.failure
    assert_equal "assembled", stream.final_text
  end

  def test_several_messages_delivered_in_one_batch_each_produce_their_own_event
    feed(init, tool_use("Edit", "file_path" => File.join(@tmp, "b.rb")), result_message)

    assert_equal [ "Provider started", "> Edit b.rb", "Provider completed" ], texts
  end

  # ---- S03: private material and the transport itself never reach a surface ----

  def test_initialization_never_exposes_account_model_cwd_or_mcp_detail
    feed("type" => "system", "subtype" => "init", "cwd" => "/private/home/operator",
         "model" => "claude-opus-5", "apiKeySource" => "keychain",
         "mcp_servers" => [ { "name" => "internal" } ], "account" => { "email" => "op@example.test" })

    assert_equal [ "Provider started" ], texts
    %w[operator claude-opus-5 keychain internal op@example.test].each do |secret|
      refute_includes texts.join("\n"), secret
    end
  end

  # ---- S06 / terminal result classification -----------------------------

  def test_completion_and_failure_are_distinct_terminal_statuses
    feed(result_message)
    completed = texts

    @seen = []
    stream = build_stream
    stream.accept("stdout", JSON.generate("type" => "result", "subtype" => "error_during_execution",
                                          "is_error" => true, "result" => "boom"))

    assert_equal [ "Provider completed" ], completed
    assert_equal [ "Provider failed" ], texts
    assert_nil stream.close.failure, "a provider that reported a failure still produced a readable stream"
  end

  # ---- S08: fail closed, without ever showing the frame ------------------

  def test_malformed_output_fails_closed_and_never_displays_the_frame
    stream = build_stream
    stream.accept("stdout", "Warning: something odd sk-live-DO-NOT-LEAK")

    refute_nil stream.close.failure
    assert_empty texts
    refute_includes stream.close.failure, "sk-live-DO-NOT-LEAK"
  end

  def test_a_stream_with_no_terminal_result_fails_closed
    stream = build_stream
    stream.accept("stdout", JSON.generate(init))

    refute_nil stream.close.failure
    assert_equal "", stream.final_text
  end

  def test_a_second_terminal_result_fails_closed
    stream = build_stream
    stream.accept("stdout", JSON.generate(result_message("first")))
    stream.accept("stdout", JSON.generate(result_message("second")))

    refute_nil stream.close.failure
  end

# ---- a result frame that belongs to a REFUSED question turn -------------
#
# The one exception to the one-result rule, and it is not the decoder's to grant: `refusals`
# is the attempt's question bridge reporting how many question turns it has refused back to
# the same provider process so far. A held result may be superseded only by a later frame
# from that same process, and only when a refusal the bridge recorded BEFORE the held result
# has not already explained an earlier one.

def test_a_result_that_followed_a_refused_question_turn_is_superseded_by_the_final_one
  stream = build_stream(refusals: -> { 1 })
  stream.accept("stdout", JSON.generate(result_message("stopped on the refused question")))
  stream.accept("stdout", JSON.generate(result_message("final")))

  assert_nil stream.close.failure
  assert_equal "final", stream.final_text
  refute_includes texts.join("\n"), "stopped on the refused question", "a superseded result is never displayed"
end

def test_a_second_result_with_no_recorded_refusal_still_fails_closed
  stream = build_stream(refusals: -> { 0 })
  stream.accept("stdout", JSON.generate(result_message("first")))
  stream.accept("stdout", JSON.generate(result_message("second")))

  assert_equal SpecrelayRunner::ClaudeStream::FAILURE_TWO_RESULTS, stream.close.failure
  assert_equal "", stream.final_text
end

def test_each_refusal_explains_exactly_one_superseded_result
  stream = build_stream(refusals: -> { 1 })
  %w[first second third].each { |text| stream.accept("stdout", JSON.generate(result_message(text))) }

  assert_equal SpecrelayRunner::ClaudeStream::FAILURE_TWO_RESULTS, stream.close.failure
  assert_equal "", stream.final_text
end

def test_a_refusal_recorded_after_a_result_does_not_explain_it
  refusals = 0
  stream = build_stream(refusals: -> { refusals })
  stream.accept("stdout", JSON.generate(result_message("before any refusal")))
  refusals = 1
  stream.accept("stdout", JSON.generate(result_message("after the refusal")))

  assert_equal SpecrelayRunner::ClaudeStream::FAILURE_TWO_RESULTS, stream.close.failure
end

# The allowance lifts no bound: an oversized frame still fails closed at the first bound it
# crosses (here the pending-message cap, which is the smaller), and nothing later rescues it.
def test_a_refused_turn_never_lifts_the_size_bounds_on_a_result
  stream = build_stream(refusals: -> { 1 })
  stream.accept("stdout", JSON.generate(result_message("x" * (SpecrelayRunner::ClaudeStream::MAX_PENDING_BYTES + 1))))
  stream.accept("stdout", JSON.generate(result_message("final")))

  assert_equal SpecrelayRunner::ClaudeStream::FAILURE_UNREADABLE, stream.close.failure
  assert_equal "", stream.final_text
end

  def test_a_non_object_json_line_fails_closed
    stream = build_stream
    stream.accept("stdout", "42")

    refute_nil stream.close.failure
  end

  # ---- stderr is provider bytes, so it is never forwarded ----------------

  # CR-001 F2. stderr is not structured output and never passed the allowlist: review 001 sent an
  # account-like email and an absolute home path on stderr and both reached the public sink. The
  # complete stderr still reaches the report through the buffered capture, which is untouched.
  def test_stderr_bytes_are_never_forwarded_and_become_one_bounded_notice
    stream = build_stream
    stream.accept("stderr", "operator@example.test could not read /Users/alice/private.py")
    stream.accept("stderr", "arbitrary provider chatter nobody vetted")
    stream.accept("stdout", JSON.generate(result_message))

    assert_nil stream.close.failure
    notices = @seen.select { |source, _text| source == "stderr" }
    assert_equal 1, notices.size, "one bounded notice, not one per line: #{notices.inspect}"
    [ "operator@example.test", "/Users/alice/private.py", "arbitrary provider chatter" ].each do |raw|
      refute_includes @seen.flatten.join(" "), raw
    end
  end

  private

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def build_stream(repository_path: @tmp, **options)
    SpecrelayRunner::ClaudeStream.new(
      sink: ->(source, text) { @seen << [ source, text ] }, repository_path: repository_path, **options
    )
  end

  # Feeds each message as one complete JSONL line, the way CommandRunner delivers them.
  def feed(*messages)
    stream = build_stream
    messages.each { |message| stream.accept("stdout", JSON.generate(message)) }
    stream
  end

  def texts = @seen.map(&:last)

  def init = { "type" => "system", "subtype" => "init" }

  def assistant_text(text)
    { "type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => text } ] } }
  end

  # `id` is the provider's own tool-use identity. It stays positional and optional so the
  # pre-CR-004 cases that pass a brace-less input hash keep reading as they did.
  def tool_use(name, input, id = nil)
    block = { "type" => "tool_use", "name" => name, "input" => input }
    block["id"] = id if id
    { "type" => "assistant", "message" => { "content" => [ block ] } }
  end

  def tool_result(id: nil, error: false, content: "raw tool output")
    block = { "type" => "tool_result", "is_error" => error, "content" => content }
    block["tool_use_id"] = id if id
    { "type" => "user", "message" => { "content" => [ block ] } }
  end

  def result_message(text = "final result text")
    { "type" => "result", "subtype" => "success", "is_error" => false, "result" => text }
  end

  def write_script(body)
    path = File.join(@tmp, "provider.rb")
    File.write(path, %(require "json"\n#{body}))
    path
  end
end
