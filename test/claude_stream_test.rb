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
    assert_equal [ "Provider started", "Inspecting app/index.html", "Provider completed" ], texts
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
    refute_includes texts.join("\n"), "spec.md"
    refute_includes texts.join("\n"), "here is the package"
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

    assert_equal [ "Provider started", "Editing b.rb", "Provider completed" ], texts
  end

  # ---- S03: private and raw material never reaches a surface -------------

  def test_assistant_prose_and_user_messages_produce_no_progress
    feed(assistant_text("I will now consider the approach in detail"),
         { "type" => "user", "message" => { "content" => [ { "type" => "text", "text" => "hidden" } ] } })

    assert_empty texts
  end

  def test_initialization_never_exposes_account_model_cwd_or_mcp_detail
    feed("type" => "system", "subtype" => "init", "cwd" => "/private/home/operator",
         "model" => "claude-opus-5", "apiKeySource" => "keychain",
         "mcp_servers" => [ { "name" => "internal" } ], "account" => { "email" => "op@example.test" })

    assert_equal [ "Provider started" ], texts
    %w[operator claude-opus-5 keychain internal op@example.test].each do |secret|
      refute_includes texts.join("\n"), secret
    end
  end

  def test_a_raw_tool_result_becomes_a_status_only
    feed({ "type" => "user", "message" => { "content" => [
            { "type" => "tool_result", "is_error" => false, "content" => "SECRET FILE CONTENT" }
          ] } },
         { "type" => "user", "message" => { "content" => [
            { "type" => "tool_result", "is_error" => true, "content" => "stack trace" }
          ] } })

    assert_equal [ "Step completed", "Step failed" ], texts
    refute_includes texts.join("\n"), "SECRET FILE CONTENT"
    refute_includes texts.join("\n"), "stack trace"
  end

  def test_an_unknown_but_valid_event_or_tool_becomes_one_generic_status
    feed({ "type" => "future_event", "payload" => { "internal" => "detail" } },
         tool_use("SomeFutureTool", "secret" => "do-not-leak"))

    assert_equal [ "Provider activity", "Provider activity" ], texts
    refute_includes texts.join("\n"), "do-not-leak"
    refute_includes texts.join("\n"), "future_event"
  end

  # ---- S04: only a proven repository-relative path may appear ------------

  def test_a_contained_path_is_shown_relative_to_the_repository
    feed(tool_use("Edit", "file_path" => File.join(@tmp, "app/views/home.html.erb")))

    assert_equal [ "Editing app/views/home.html.erb" ], texts
  end

  def test_an_uncontained_absolute_path_is_omitted_rather_than_shown
    feed(tool_use("Read", "file_path" => "/etc/passwd"))

    assert_equal [ "Inspecting a file" ], texts
  end

  def test_a_traversal_shaped_path_that_escapes_the_repository_is_omitted
    feed(tool_use("Read", "file_path" => "../../etc/shadow"))

    assert_equal [ "Inspecting a file" ], texts
    refute_includes texts.join("\n"), "shadow"
  end

  # The specification lane is assigned no repository, so containment can never be proven
  # and a path may never be printed — the same rule, not a second one.
  def test_no_path_is_shown_when_the_lane_has_no_repository
    stream = build_stream(repository_path: nil)
    stream.accept("stdout", JSON.generate(tool_use("Edit", "file_path" => "/anywhere/x.rb")))

    assert_equal [ "Editing a file" ], texts
  end

  # ---- S05: command previews pass an explicit allowlist ------------------

  def test_a_recognized_test_command_is_previewed_and_named_as_a_test
    feed(tool_use("Bash", "command" => "bundle exec rspec spec/models"))

    assert_equal [ "Running test command: bundle exec rspec spec/models" ], texts
  end

  def test_an_ordinary_allowlisted_command_is_previewed_without_the_test_category
    feed(tool_use("Bash", "command" => "npm install"))

    assert_equal [ "Running command: npm install" ], texts
  end

  def test_an_unknown_or_credential_bearing_command_collapses_to_a_generic_status
    feed(tool_use("Bash", "command" => "curl -H 'Authorization: Bearer sk-live-do-not-leak' https://x"),
         tool_use("Bash", "command" => "AWS_SECRET_ACCESS_KEY=abc bundle exec rspec"),
         tool_use("Bash", "command" => "bundle exec rspec && cat ~/.netrc"))

    assert_equal [ "Running a command" ] * 3, texts
    refute_includes texts.join("\n"), "sk-live-do-not-leak"
    refute_includes texts.join("\n"), "netrc"
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

  def test_a_non_object_json_line_fails_closed
    stream = build_stream
    stream.accept("stdout", "42")

    refute_nil stream.close.failure
  end

  # ---- stderr keeps its own stream identity ------------------------------

  # stderr is not structured output and is not decoded. It stays on its own stream so the
  # existing redaction/bounding path still shows it, and it can never be mistaken for a frame.
  def test_stderr_passes_through_unchanged_on_its_own_stream
    stream = build_stream
    stream.accept("stderr", "claude: a diagnostic line")
    stream.accept("stdout", JSON.generate(result_message))

    assert_includes @seen, [ "stderr", "claude: a diagnostic line" ]
    assert_nil stream.close.failure
  end

  private

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def build_stream(repository_path: @tmp)
    SpecrelayRunner::ClaudeStream.new(
      sink: ->(source, text) { @seen << [ source, text ] }, repository_path: repository_path
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

  def tool_use(name, input)
    { "type" => "assistant",
      "message" => { "content" => [ { "type" => "tool_use", "name" => name, "input" => input } ] } }
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
