# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/claude_stream_json"

# MAPIAI-60 CR-005 — the operator must read the SAME public transcript Claude Code shows,
# not a normalized title for each event. These tests are written against the supported
# stream-json shapes recorded in `support/claude_stream_json.rb`, so what they assert is what
# the CLI actually emits.
#
# The safety line moved, and moved in ONE direction only: ordinary narration, paths, source,
# commands, output and diffs are now required to appear, while credentials and the model's
# private reasoning are still required to be absent.
class ClaudeTranscriptTest < Minitest::Test
  J = ClaudeStreamJson

  def setup
    @tmp = Dir.mktmpdir("claude-transcript")
    @seen = []
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
  end

  # ---- the transcript itself ---------------------------------------------

  def test_public_assistant_narration_is_shown_verbatim
    feed(J.narration("I'll start by reading the file.\nThen I will edit it."))

    assert_includes transcript, "I'll start by reading the file."
    assert_includes transcript, "Then I will edit it."
  end

  def test_a_command_shows_its_exact_text_description_and_output
    feed(J.bash_call("npm test --silent", description: "Run the project test suite"),
         J.bash_result("toolu_bash", stdout: "1 passing\n0 failing\n"))

    assert_includes transcript, "npm test --silent"
    assert_includes transcript, "Run the project test suite"
    assert_includes transcript, "1 passing"
    assert_includes transcript, "0 failing"
  end

  def test_command_stderr_and_failure_are_both_shown
    feed(J.bash_call("npm test"),
         J.bash_result("toolu_bash", stdout: "run\n", stderr: "Error: boom\n", is_error: true))

    assert_includes transcript, "Error: boom"
    assert_match(/fail/i, transcript)
  end

  # MAPIAI-77 — the file the provider names is in the assigned worktree, so the operator reads
  # the repository-relative path. What must still be true is that the path is USEFUL and the
  # content is intact; `claude_path_privacy_test` owns the policy itself.
  def test_a_file_read_shows_its_path_and_content
    path = File.join(@tmp, "demo-app/index.html")
    feed(J.read_call(path), J.read_result("toolu_read", path, "<h1>Hello</h1>\n"))

    assert_includes transcript, "demo-app/index.html"
    assert_includes transcript, "<h1>Hello</h1>"
  end

  def test_an_edit_shows_the_before_and_after_content_as_a_diff
    path = File.join(@tmp, "a.css")
    feed(J.edit_call(path, "color: red;", "color: green;"),
         J.edit_result("toolu_edit", path, "color: red;", "color: green;"))

    assert_includes transcript, "a.css"
    assert_includes transcript, "-color: red;"
    assert_includes transcript, "+color: green;"
  end

  # Task carries no dedicated shape in the capture: it is an ordinary `tool_use` whose input
  # names the delegated work, and its output returns as an ordinary `tool_result`.
  def test_task_input_and_task_output_content_are_shown
    feed(J.task_call("Audit the CSS", "Find every unused rule in app.css"),
         J.result("toolu_task", "Found 3 unused rules:\n- .legacy\n- .old\n- .unused"))

    assert_includes transcript, "Audit the CSS"
    assert_includes transcript, "Find every unused rule in app.css"
    assert_includes transcript, "Found 3 unused rules:"
    assert_includes transcript, "- .legacy"
  end

  def test_multiline_output_keeps_every_line
    body = (1..12).map { |n| "line #{n}" }.join("\n")
    feed(J.bash_call("cat notes.txt"), J.bash_result("toolu_bash", stdout: "#{body}\n"))

    (1..12).each { |n| assert_includes transcript, "line #{n}" }
  end

  def test_public_timing_and_status_are_shown_when_the_provider_emits_them
    feed(J.terminal("done", duration_ms: 43_673, num_turns: 8))

    assert_match(/43\.7s|43673/, transcript)
    assert_includes transcript, "8"
  end

  def test_canonical_order_is_the_order_the_provider_emitted
    feed(J.narration("first, read"), J.read_call("/work/a.rb"),
         J.read_result("toolu_read", "/work/a.rb", "puts :hello\n"),
         J.narration("now, edit"),
         J.edit_call("/work/a.rb", "puts :hello", "puts :goodbye"),
         J.edit_result("toolu_edit", "/work/a.rb", "puts :hello", "puts :goodbye"))

    positions = [ "first, read", "puts :hello", "now, edit", "+puts :goodbye" ]
                .map { |needle| transcript.index(needle) }
    refute_includes positions, nil, "every fragment must be present: #{transcript}"
    assert_equal positions.sort, positions, "the transcript must keep provider order"
  end

  # ---- the safety boundary -----------------------------------------------

  def test_private_reasoning_is_never_shown
    feed(J.thinking("the user probably wants me to consider the edge case first"),
         J.narration("Reading the file."))

    refute_includes transcript, "edge case"
    refute_includes transcript, "sig-abc"
    assert_includes transcript, "Reading the file."
  end

  def test_raw_transport_wrappers_never_appear
    feed(J.narration("hello"), J.read_call("/work/a.rb"),
         J.read_result("toolu_read", "/work/a.rb", "x = 1\n"), J.terminal)

    [ '"type":"assistant"', '"tool_use"', '"tool_result"', "parent_tool_use_id",
      "session_id", "toolu_read" ].each do |wrapper|
      refute_includes transcript, wrapper
    end
  end

  # Redaction has ONE owner, and it is not this class: ExecutorLogStream redacts every line once,
  # on the way to both surfaces. So the proof has to run through that boundary — a bare sink is
  # deliberately unredacted, which is why nothing but the fan-out may be wired to a surface.
  def test_credentials_are_redacted_without_suppressing_the_surrounding_command
    secret = "ghp_#{'a' * 36}"
    text = through_fan_out(
      J.bash_call("git push https://#{secret}@github.com/acme/app.git"),
      J.bash_result("toolu_bash", stdout: "Authorization: Bearer sk-live-#{'b' * 24}\nDone\n")
    ).first

    refute_includes text, secret
    refute_includes text, "sk-live-#{'b' * 24}"
    assert_includes text, "git push"
    assert_includes text, "github.com/acme/app.git"
    assert_includes text, "Done"
  end

  # CR-005 removed the CR-001/CR-004 suppression of ordinary material, and that stays removed for
  # source, shell syntax and repository-relative paths. MAPIAI-77 takes back exactly one class of
  # content: an absolute LOCAL path, which the MAPIAI-73 run proved discloses the developer's
  # username and home layout.
  def test_source_shell_syntax_and_relative_paths_survive_while_a_local_path_does_not
    feed(J.bash_call("cd /Users/operator/app && bundle exec rspec spec/models | tail -5"),
         J.bash_result("toolu_bash", stdout: "class Widget < ApplicationRecord\nend\n"))

    refute_includes transcript, "/Users/operator/app"
    assert_includes transcript, "[LOCAL_PATH]"
    assert_includes transcript, "spec/models"
    assert_includes transcript, "| tail -5"
    assert_includes transcript, "class Widget < ApplicationRecord"
  end

  # ---- bounds ------------------------------------------------------------

  def test_an_oversized_block_is_truncated_with_a_truthful_notice
    huge = (1..400).map { |n| "output line #{n}" }.join("\n")
    feed(J.bash_call("cat big.log"), J.bash_result("toolu_bash", stdout: "#{huge}\n"))

    assert_includes transcript, "output line 1"
    refute_includes transcript, "output line 400"
    assert_match(/more line/, transcript, "truncation must be announced, not silent")
  end

  # ---- one renderer, both surfaces, both lanes ---------------------------

  # The implementation lane wires the decoder to ExecutorLogStream; the terminal string and the
  # Platform envelope must be the same bytes, because there is one renderer and one redaction.
  def test_the_terminal_and_platform_receive_the_identical_transcript
    path = File.join(@tmp, "a.css")
    terminal, delivered = through_fan_out(
      J.narration("Editing the stylesheet."),
      J.edit_call(path, "color: red;", "color: green;"),
      J.edit_result("toolu_edit", path, "color: red;", "color: green;")
    )

    [ "Editing the stylesheet.", "a.css", "-color: red;", "+color: green;" ].each do |fragment|
      assert_includes terminal, fragment
      assert_includes delivered, fragment
    end
    assert_equal normalize(terminal), normalize(delivered),
                 "one renderer means one transcript on both surfaces"
  end

  # The specification lane passes a bare sink and no repository. It must get the same transcript.
  def test_the_specification_lane_receives_the_same_transcript
    lane = []
    decoder = SpecrelayRunner::ClaudeStream.new(sink: ->(_source, text) { lane << text })
    [ J.narration("Writing the specification."),
      J.bash_call("bin/graph-check", description: "Check the graph"),
      J.bash_result("toolu_bash", stdout: "freshness: FRESH\n") ].each do |message|
      decoder.accept("stdout", JSON.generate(message))
    end

    text = lane.join("\n")
    assert_includes text, "Writing the specification."
    assert_includes text, "bin/graph-check"
    assert_includes text, "freshness: FRESH"
  end

  # ---- CR-006 F1: a multiline credential must not survive line splitting ----
  #
  # review-007 reproduced a private key whose header was redacted while its body and footer stayed
  # public: the transcript split the block into lines and ExecutorLogStream redacted one line at a
  # time, so the multiline rule never saw the whole value. The fix keeps ONE pattern owner and
  # gives it contiguous text; these run through the real fan-out, which is where the leak was.

  PEM = <<~KEY
    -----BEGIN PRIVATE KEY-----
    QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7VJTUt9Us8cKj
    -----END PRIVATE KEY-----
  KEY

  def test_a_private_key_in_narration_never_reaches_either_surface
    assert_key_absent(*through_fan_out(J.narration("Here is the deploy key:\n#{PEM}")))
  end

  def test_a_private_key_in_a_file_read_never_reaches_either_surface
    assert_key_absent(*through_fan_out(
      J.read_call("/work/id_rsa"), J.read_result("toolu_read", "/work/id_rsa", PEM)
    ))
  end

  def test_a_private_key_in_command_output_never_reaches_either_surface
    assert_key_absent(*through_fan_out(
      J.bash_call("cat id_rsa"), J.bash_result("toolu_bash", stdout: PEM, stderr: PEM)
    ))
  end

  # The bound must not become a way to leak: a key sitting past the per-block line limit is still
  # a key, and clipping a long line must not hand out a surviving fragment.
  def test_ordinary_multiline_output_survives_the_same_path
    source = (1..6).map { |n| "def method_#{n}\n  :ok\nend" }.join("\n")
    terminal, delivered = through_fan_out(J.bash_call("cat lib/a.rb"),
                                          J.bash_result("toolu_bash", stdout: source))

    [ terminal, delivered ].each do |surface|
      assert_includes surface, "def method_1"
      assert_includes surface, "def method_6"
    end
  end

  # ---- CR-006 F2: otherwise-unhandled public input is rendered ------------

  # The shape below is the one the supported CLI actually emitted when asked to start a
  # background command and poll it; see the CR-006 probe.
  def test_public_tool_input_fields_reach_the_transcript_deterministically
    feed(J.tool_call("TaskOutput", "task_id" => "b8sk74npe", "block" => true, "timeout" => 15_000),
         J.task_output_result("toolu_generic", "b8sk74npe", "BACKGROUND-DONE\n"))

    assert_includes transcript, "task_id: b8sk74npe"
    assert_includes transcript, "block: true"
    assert_includes transcript, "timeout: 15000"
    assert_includes transcript, "BACKGROUND-DONE"
  end

  def test_list_and_nested_public_input_values_are_rendered_readably
    feed(J.tool_call("WebFetch", "url" => "https://example.test/spec",
                     "patterns" => %w[*.rb *.erb],
                     "options" => { "depth" => 2, "follow" => false }))

    assert_includes transcript, "url: https://example.test/spec"
    assert_includes transcript, "patterns: *.rb, *.erb"
    assert_includes transcript, "options: depth=2, follow=false"
    refute_includes transcript, "=>"
  end

  # The specialized presentation stays, and a value it already showed is not repeated.
  def test_the_specialized_presentation_is_not_duplicated_by_the_generic_renderer
    feed(J.edit_call(File.join(@tmp, "a.css"), "color: red;", "color: green;"))

    assert_equal 1, transcript.scan("a.css").length
    refute_includes transcript, "old_string:"
    refute_includes transcript, "new_string:"
  end

  def test_wrapper_only_identifiers_are_never_printed
    feed(J.read_call("/work/a.rb", id: "toolu_secret_id"))

    refute_includes transcript, "toolu_secret_id"
    refute_includes transcript, "caller"
  end

  # ---- CR-006 F3: every result states its disposition --------------------

  def test_a_successful_result_with_no_output_still_reports_completion
    feed(J.bash_call("true", description: "Check success"),
         J.bash_result("toolu_bash", stdout: "", stderr: ""))

    assert_match(/complete/i, transcript)
  end

  def test_a_failed_result_reports_failure_once
    feed(J.bash_call("false"), J.bash_result("toolu_bash", stdout: "", is_error: true))

    assert_equal 1, transcript.scan(/fail/i).length
  end

  # `interrupted` is a field the real capture carries on a Bash result; a timeout is NOT inferred
  # from anything else.
  def test_an_interrupted_result_is_distinguished_from_an_empty_success
    feed(J.bash_call("sleep 600"),
         J.result("toolu_bash", "", detail: { "stdout" => "", "stderr" => "", "interrupted" => true,
                                              "isImage" => false, "noOutputExpected" => false }))

    assert_match(/interrupt/i, transcript)
    refute_match(/completed/i, transcript)
  end

  def test_exactly_one_disposition_is_emitted_per_result
    feed(J.bash_call("echo hi"), J.bash_result("toolu_bash", stdout: "hi\n"))

    assert_equal 1, transcript.scan(/step (completed|failed|interrupted)/i).length
    assert_includes transcript, "hi"
  end

  private

  def assert_key_absent(terminal, delivered)
    [ terminal, delivered ].each do |surface|
      refute_includes surface, "BEGIN PRIVATE KEY"
      refute_includes surface, "END PRIVATE KEY"
      refute_includes surface, "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo="
      refute_includes surface, "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7VJTUt9Us8cKj"
    end
  end

  class RecordingProtocolClient
    attr_reader :accepted

    def initialize = @accepted = []

    def submit_protocol_event(claim:, event:, **)
      _ = claim
      @accepted << event
      { "lease" => { "state" => "active", "cancel_requested" => false } }
    end
  end

  # The REAL implementation-lane wiring: decoder -> ExecutorLogStream -> (terminal, Platform).
  # Returns the two surfaces' text.
  def through_fan_out(*messages)
    client = RecordingProtocolClient.new
    emitter = SpecrelayRunner::EventEmitter.new(client: client, run_id: "run_5", attempt_id: "rex_5")
    io = StringIO.new
    stream = SpecrelayRunner::ExecutorLogStream.new(emitter: emitter, io: io, provider: "claude",
                                                    task_id: "CR-005")
    decoder = SpecrelayRunner::ClaudeStream.new(sink: stream.sink, repository_path: @tmp)
    messages.each { |message| decoder.accept("stdout", JSON.generate(message)) }
    stream.send(:flush_all)

    [ io.string, client.accepted.map { |e| e["sanitized_log_chunk"].to_s }.join ]
  end

  def feed(*messages)
    stream = SpecrelayRunner::ClaudeStream.new(
      sink: ->(source, text) { @seen << [ source, text ] }, repository_path: @tmp
    )
    messages.each { |message| stream.accept("stdout", JSON.generate(message)) }
    stream
  end

  def transcript = @seen.map(&:last).join("\n")

  def normalize(text) = text.gsub(/^\s*\[claude:status\]\s?/, "").gsub(/\s+/, " ").strip
end
