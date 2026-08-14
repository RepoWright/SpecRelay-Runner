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

    # ONE line, not two: CR-004 collapses consecutive generic activity, and an unknown event and
    # an unknown tool are the same generic fact twice.
    assert_equal [ "Provider activity" ], texts
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

  # CR-001 F2 — an ALLOWLISTED executable is not a licence to echo the rest of the line. Review
  # 001 sent `python3 /Users/alice/private.py` and the full absolute path reached the sink,
  # because the preview matched a permissive character pattern rather than a closed grammar.
  def test_an_argument_path_outside_the_repository_collapses_to_the_generic_status
    feed(tool_use("Bash", "command" => "python3 /Users/alice/private.py"),
         tool_use("Bash", "command" => "ruby ../../../etc/shadow"))

    assert_equal [ "Running a command" ] * 2, texts
    refute_includes texts.join("\n"), "alice"
    refute_includes texts.join("\n"), "shadow"
  end

  def test_arbitrary_bare_argument_text_is_never_echoed
    feed(tool_use("Bash", "command" => "bundle exec rspec --seed sk-live-DO-NOT-LEAK"),
         tool_use("Bash", "command" => "npm run publish-as operator@example.test"))

    assert_equal [ "Running a command" ] * 2, texts
    refute_includes texts.join("\n"), "sk-live-DO-NOT-LEAK"
    refute_includes texts.join("\n"), "operator@example.test"
  end

  # The positive control: every token is an approved fact, and the one path is projected through
  # the SAME containment rule a tool path uses — so what is shown is the projection, not the
  # provider's own string.
  def test_a_command_of_wholly_approved_facts_is_previewed_with_projected_paths
    feed(tool_use("Bash", "command" => "bundle exec rspec #{File.join(@tmp, 'spec/models')}"),
         tool_use("Bash", "command" => "npm install"))

    assert_equal [ "Running test command: bundle exec rspec spec/models",
                   "Running command: npm install" ], texts
    refute_includes texts.join("\n"), @tmp
  end

  # ---- CR-004: a completion says WHAT it completed -----------------------
  #
  # The live S12 run proved the transport and rendering but produced a log of interchangeable
  # "Step completed" lines. A completion is only useful when it names the operation it ends, so
  # the decoder now correlates a `tool_use` with its later `tool_result` by the provider's own
  # tool-use identity. Nothing new is READ to do it: the completion is worded from the SAME
  # projected facts the start line was already allowed to show, so a description can never be
  # safer or less safe than the start line it belongs to.

  def test_a_correlated_read_completion_names_the_file_it_finished
    feed(tool_use("Read", { "file_path" => File.join(@tmp, "demo-app/index.html") }, "toolu_1"),
         tool_result(id: "toolu_1"),
         tool_use("Read", { "file_path" => File.join(@tmp, "demo-app/index.html") }, "toolu_2"),
         tool_result(id: "toolu_2", error: true))

    assert_equal [ "Inspecting demo-app/index.html", "Finished inspecting demo-app/index.html",
                   "Inspecting demo-app/index.html", "Failed inspecting demo-app/index.html" ], texts
  end

  def test_a_correlated_edit_completion_names_the_file_it_finished
    feed(tool_use("Edit", { "file_path" => File.join(@tmp, "demo-app/index.html") }, "toolu_1"),
         tool_result(id: "toolu_1"),
         tool_use("Write", { "file_path" => File.join(@tmp, "demo-app/index.html") }, "toolu_2"),
         tool_result(id: "toolu_2", error: true))

    assert_equal [ "Editing demo-app/index.html", "Finished editing demo-app/index.html",
                   "Editing demo-app/index.html", "Failed editing demo-app/index.html" ], texts
  end

  def test_a_correlated_test_command_completion_says_whether_the_tests_passed
    feed(tool_use("Bash", { "command" => "npm test" }, "toolu_1"),
         tool_result(id: "toolu_1"),
         tool_use("Bash", { "command" => "npm test" }, "toolu_2"),
         tool_result(id: "toolu_2", error: true))

    assert_equal [ "Running test command: npm test", "Test command completed successfully",
                   "Running test command: npm test", "Test command failed" ], texts
  end

  def test_a_correlated_ordinary_command_completion_is_named_without_repeating_its_text
    feed(tool_use("Bash", { "command" => "npm install" }, "toolu_1"),
         tool_result(id: "toolu_1"),
         tool_use("Bash", { "command" => "npm install" }, "toolu_2"),
         tool_result(id: "toolu_2", error: true))

    assert_equal [ "Running command: npm install", "Command completed successfully",
                   "Running command: npm install", "Command failed" ], texts
  end

  # A command the allowlist refused has no safe description, so neither end of it may gain one.
  def test_an_unsafe_command_stays_generic_at_both_ends_without_leaking_its_text
    feed(tool_use("Bash", { "command" => "curl -H 'Authorization: Bearer sk-live-do-not-leak' https://x" },
                  "toolu_1"),
         tool_result(id: "toolu_1"))

    assert_equal [ "Running a command", "Step completed" ], texts
    refute_includes texts.join("\n"), "sk-live-do-not-leak"
    refute_includes texts.join("\n"), "curl"
  end

  def test_a_result_for_an_unknown_tool_use_id_falls_back_to_the_generic_status
    feed(tool_use("Read", { "file_path" => File.join(@tmp, "a.rb") }, "toolu_1"),
         tool_result(id: "toolu_elsewhere"),
         tool_result(error: true))

    assert_equal [ "Inspecting a.rb", "Step completed", "Step failed" ], texts
  end

  def test_several_outstanding_tool_calls_are_each_completed_by_their_own_identity
    feed(tool_use("Read", { "file_path" => File.join(@tmp, "a.rb") }, "toolu_a"),
         tool_use("Edit", { "file_path" => File.join(@tmp, "b.rb") }, "toolu_b"),
         tool_use("Bash", { "command" => "npm test" }, "toolu_c"),
         tool_result(id: "toolu_b"),
         tool_result(id: "toolu_c", error: true),
         tool_result(id: "toolu_a"))

    assert_equal [ "Inspecting a.rb", "Editing b.rb", "Running test command: npm test",
                   "Finished editing b.rb", "Test command failed", "Finished inspecting a.rb" ], texts
  end

  # A correlation the decoder no longer holds must degrade to the generic wording rather than
  # keeping every unanswered tool call for the life of the process.
  def test_the_outstanding_correlation_map_is_bounded
    limit = SpecrelayRunner::ClaudeStream::MAX_OUTSTANDING_TOOLS
    stream = build_stream
    (limit + 1).times do |index|
      stream.accept("stdout", JSON.generate(
        tool_use("Read", { "file_path" => File.join(@tmp, "a.rb") }, "toolu_#{index}")
      ))
    end
    stream.accept("stdout", JSON.generate(tool_result(id: "toolu_0")))
    stream.accept("stdout", JSON.generate(tool_result(id: "toolu_#{limit}")))

    assert_equal "Step completed", texts[-2], "the evicted oldest call falls back safely"
    assert_equal "Finished inspecting a.rb", texts.last, "the newest call is still correlated"
  end

  def test_consecutive_generic_activity_does_not_flood_the_stream
    feed({ "type" => "future_event" }, { "type" => "future_event" },
         tool_use("SomeFutureTool", { "secret" => "do-not-leak" }),
         tool_use("Read", { "file_path" => File.join(@tmp, "a.rb") }, "toolu_1"),
         { "type" => "future_event" })

    assert_equal [ "Provider activity", "Inspecting a.rb", "Provider activity" ], texts
  end

  def test_a_correlated_completion_never_carries_prose_result_content_or_uncontained_paths
    feed(assistant_text("private reasoning about the task"),
         tool_use("Read", { "file_path" => "/Users/alice/private.rb" }, "toolu_1"),
         tool_result(id: "toolu_1", content: "SECRET FILE CONTENT"),
         tool_use("Edit", { "file_path" => "../../etc/shadow" }, "toolu_2"),
         tool_result(id: "toolu_2", error: true, content: "stack trace"))

    assert_equal [ "Inspecting a file", "Finished inspecting a file",
                   "Editing a file", "Failed editing a file" ], texts
    %w[private\ reasoning SECRET\ FILE\ CONTENT stack\ trace alice shadow /Users/].each do |secret|
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
