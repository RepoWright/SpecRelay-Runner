# frozen_string_literal: true

require "test_helper"
require_relative "support/claude_stream_json"

# MAPIAI-103 — a real automated review is READ WHILE IT RUNS.
#
# `Review::Execution` used to launch the reviewer with no output consumer and parse its buffered
# stdout, so the live MAPIAI-95 attempt showed a start line, minutes of silence, and a verdict.
# The reviewer now runs in the supported structured mode and the SAME {ClaudeStream} the
# implementation and specification lanes use decodes it: safe public activity reaches this
# machine's own terminal as it arrives, and the review document is that decoder's ONE terminal
# result.
#
# Every example drives the real CommandRunner against a real script on disk, the real decoder, the
# real TerminalPresenter and a real HTTP FakePlatform — so the process boundary, the privacy rules
# and the terminal writer are exercised rather than described.
class ReviewStreamTest < Minitest::Test
  BASE = "1111111111111111111111111111111111111111"
  BRANCH = "DEMO-1"

  # One marker per privacy rule, so a leak names the rule it broke.
  PRIVATE_REASONING = "PRIVATE-REASONING-MARKER"
  CREDENTIAL = "ghp_AAAAAAAAAAAAAAAAAAAAAAAA"
  OUTSIDE_PATH = "/Users/someone-else/private-project/notes.md"
  STDERR_BYTES = "operator@example.com used /Users/operator/Library/Caches/claude"
  VERDICT_MARKER = "VERDICT-BODY-MARKER"
  VERDICT_BODY = %({"outcome":"ACCEPT","summary":"#{VERDICT_MARKER}"})

  # A recording terminal that is also a SIGNAL: it creates `sentinel` the instant `marker` is
  # written to it. The reviewer waits for that file before it finishes, which turns "displayed
  # while the provider was still running" into a fact about causality rather than about timing.
  class SignallingTerminal < RecordingTerminal
    def initialize(sentinel:, marker:)
      super()
      @sentinel = sentinel
      @marker = marker
    end

    def print(bytes)
      super
      File.write(@sentinel, "seen") if bytes.include?(@marker)
    end
  end

  # Every Platform call this review makes, recorded WITH its arguments at the injected client
  # boundary. Live review progress reaching Platform would show up here as a call or as progress
  # text inside one — neither can be argued away from the implementation's shape.
  class RecordingClient
    attr_reader :calls

    def initialize(inner)
      @inner = inner
      @calls = []
    end

    def method_missing(name, *args, **kwargs, &block)
      @calls << [ name, args, kwargs ]
      @inner.public_send(name, *args, **kwargs, &block)
    end

    def respond_to_missing?(name, include_private = false)
      @inner.respond_to?(name, include_private) || super
    end

    def method_names = calls.map(&:first)
    def recorded_payloads = calls.map { |name, args, kwargs| [ name, args, kwargs ].inspect }.join("\n")
  end

  def setup
    @root = Dir.mktmpdir("review-stream")
    @remote = File.join(@root, "origin.git")
    @repo = File.join(@root, "specrelay-platform")
    @platform = FakePlatform.new(claim_payload: { "claimed" => false })
    @platform.start
    @terminal = RecordingTerminal.new
    build_remote_and_checkout
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@root, true)
  end

  # --- S01: public activity arrives BEFORE the process ends -----------------

  # The reviewer BLOCKS before its terminal result until the parent has printed its Bash call, so
  # a runner that buffered until exit would drive the child into its own abort. This cannot pass
  # by accident of scheduling.
  def test_narration_and_a_bash_call_reach_the_terminal_in_order_while_the_reviewer_runs
    sentinel = File.join(@root, "displayed.txt")
    @terminal = SignallingTerminal.new(sentinel: sentinel, marker: "> Bash")
    script = reviewer_stream([ ClaudeStreamJson.init,
                               ClaudeStreamJson.narration("Reading the approved specification"),
                               ClaudeStreamJson.bash_call("bin/test", description: "Run the suite"),
                               ClaudeStreamJson.bash_result("toolu_bash", stdout: "42 runs, 0 failures"),
                               ClaudeStreamJson.terminal(VERDICT_BODY) ], await: sentinel)

    result = run_review(command: script)

    assert result.success?, result.message
    assert_includes lines, "  [reviewer:status] Provider started"
    assert_operator index("Reading the approved specification"), :<, index("> Bash bin/test")
    assert_includes lines, "  [reviewer:status]   Run the suite"
    assert_includes lines, "  [reviewer:status] < step completed"
    assert_includes lines, "  [reviewer:status]   42 runs, 0 failures"
  end

  # --- S02: the existing decoder renders every public item ------------------

  def test_read_edit_test_and_delegated_task_activity_render_without_a_json_wrapper
    script = reviewer_stream([ ClaudeStreamJson.init,
                               ClaudeStreamJson.read_call(File.join(@repo, "app/models/lead.rb")),
                               ClaudeStreamJson.read_result("toolu_read", File.join(@repo, "app/models/lead.rb"),
                                                            "class Lead\nend\n"),
                               ClaudeStreamJson.edit_call(File.join(@repo, "README.md"), "old line", "new line"),
                               ClaudeStreamJson.bash_call("bundle exec rspec", description: "Run the suite"),
                               ClaudeStreamJson.bash_result("toolu_bash", stdout: "3 examples, 0 failures"),
                               ClaudeStreamJson.task_call("Check the contract", "Read the schema and report"),
                               ClaudeStreamJson.task_output_result("toolu_task", "b8sk74npe", "the contract holds"),
                               ClaudeStreamJson.terminal(VERDICT_BODY) ])

    result = run_review(command: script)

    assert result.success?, result.message
    [ "> Read specrelay-platform/app/models/lead.rb", "  class Lead", "> Edit specrelay-platform/README.md",
      "  -old line", "  +new line", "> Bash bundle exec rspec", "  3 examples, 0 failures",
      "> Task Check the contract", "  Read the schema and report", "  the contract holds" ].each do |fragment|
      assert_includes lines, "  [reviewer:status] #{fragment}"
    end
    refute_match(/"type"\s*:|\{"/, @terminal.string, "a raw JSONL wrapper must never be displayed")
  end

  # --- S03: the terminal result is the parser's input, not progress ---------

  def test_the_terminal_result_becomes_one_accepted_review_and_is_never_echoed_as_progress
    script = reviewer_stream([ ClaudeStreamJson.init,
                               ClaudeStreamJson.narration("Checked the diff"),
                               ClaudeStreamJson.terminal(VERDICT_BODY) ])

    result = run_review(command: script)

    assert result.success?, result.message
    assert_equal 1, @platform.review_results.size
    assert_equal "ACCEPT", @platform.last_review["outcome"]
    assert_equal VERDICT_MARKER, @platform.last_review["summary"]
    refute_includes @terminal.string, VERDICT_MARKER, "the verdict body is not live progress"
    assert_includes lines, "  [reviewer:status] Provider completed in 43.7s, 8 turns"
  end

  # --- S04: what the decoder withholds stays withheld -----------------------

  def test_private_reasoning_credentials_outside_paths_and_stderr_never_reach_the_terminal
    script = reviewer_stream([ ClaudeStreamJson.init,
                               ClaudeStreamJson.thinking(PRIVATE_REASONING),
                               ClaudeStreamJson.narration("Authenticating with #{CREDENTIAL}"),
                               ClaudeStreamJson.read_call(OUTSIDE_PATH),
                               ClaudeStreamJson.read_call(File.join(@repo, "README.md"), id: "toolu_inside"),
                               ClaudeStreamJson.terminal(VERDICT_BODY) ],
                             stderr: "#{STDERR_BYTES}\n")

    result = run_review(command: script)

    assert result.success?, result.message
    [ PRIVATE_REASONING, CREDENTIAL, "/Users/someone-else", STDERR_BYTES, "operator@example.com" ].each do |secret|
      refute_includes @terminal.string, secret
    end
    assert_includes lines, "  [reviewer:status] > Read [LOCAL_PATH]"
    assert_includes lines, "  [reviewer:status] > Read specrelay-platform/README.md"
    assert_includes lines, "  [reviewer:stderr] Provider wrote diagnostic output"
  end

  # --- S05: every unusable stream fails closed ------------------------------

  # Named by SHAPE, because each one is a different way the runner can lose the ability to prove
  # which bytes are the authoritative result — and all of them must end the same way: no verdict.
  FAIL_CLOSED_STREAMS = {
    "output that is not structured at all" => [ "I reviewed it and it seemed fine to me." ],
    "valid JSON that is not a message object" => [ "[1, 2, 3]" ],
    "a truncated final message" => [ :init, %({"type":"result","subtype":"success","result":"{\\"outcome\\") ],
    "no terminal result at all" => [ :init, :narration ],
    "two terminal results" => [ :init, :terminal, :terminal ],
    "a result beyond the decoder's bounds" => [ :init, :oversized_terminal ]
  }.freeze

  FAIL_CLOSED_STREAMS.each do |shape, frames|
    define_method(:"test_#{shape.tr(' ', '_')}_submits_no_verdict") do
      result = run_review(command: reviewer_stream(frames.map { |frame| frame_for(frame) }))

      refute result.success?, "an unusable stream must never produce a verdict"
      assert_empty @platform.review_results
      assert_equal "provider_execution_failure", @platform.last_review_failure["kind"]
      reason = @platform.last_review_failure["reason"]
      refute_includes reason, VERDICT_MARKER, "a refusal must not carry the provider's own bytes"
      refute_includes reason, "outcome"
    end
  end

  # --- S06: failure classification survives the new live view ---------------

  def test_a_non_zero_exit_stays_a_provider_failure_after_progress_was_displayed
    script = reviewer_stream([ ClaudeStreamJson.init, ClaudeStreamJson.narration("Started reviewing"),
                               ClaudeStreamJson.terminal(VERDICT_BODY) ], exit_code: 3)

    result = run_review(command: script)

    refute result.success?
    assert_includes result.message, "the reviewer exited 3"
    assert_empty @platform.review_results
    assert_includes lines, "  [reviewer:status] Started reviewing"
  end

  def test_a_timeout_stays_a_provider_failure_after_progress_was_displayed
    script = reviewer_stream([ ClaudeStreamJson.init, ClaudeStreamJson.narration("Started reviewing") ],
                             sleep_seconds: 30)

    result = run_review(command: script, timeout_seconds: 1)

    refute result.success?
    assert_includes result.message, "the reviewer timed out"
    assert_empty @platform.review_results
    assert_includes lines, "  [reviewer:status] Started reviewing"
  end

  # --- S07: the deterministic fake reviewer is unchanged --------------------

  def test_the_fake_reviewer_remains_direct_text_and_streams_nothing
    script = reviewer_text(VERDICT_BODY)

    result = run_review(command: script, provider: "fake")

    assert result.success?, result.message
    assert_equal "ACCEPT", @platform.last_review["outcome"]
    refute_includes @terminal.string, "[reviewer:", "the fake provider emits no structured frames"
  end

  # --- S08: no live review byte is submitted to Platform --------------------

  def test_a_recording_client_observes_no_protocol_or_log_submission_from_review_progress
    client = RecordingClient.new(platform_client)
    script = reviewer_stream([ ClaudeStreamJson.init,
                               ClaudeStreamJson.narration("Reading the approved specification"),
                               ClaudeStreamJson.bash_call("bin/test"),
                               ClaudeStreamJson.terminal(VERDICT_BODY) ])

    result = run_review(command: script, client: client)

    assert result.success?, result.message
    assert_equal [ :submit_review_result ], client.method_names
    [ "Provider started", "Reading the approved specification", "bin/test" ].each do |progress|
      refute_includes client.recorded_payloads, progress
    end
  end

  # --- S09: a head that moves during the streamed review still refuses ------

  def test_a_head_that_moved_during_the_streamed_review_refuses_the_verdict
    script = reviewer_stream([ ClaudeStreamJson.init, ClaudeStreamJson.narration("Reviewing the diff"),
                               ClaudeStreamJson.terminal(VERDICT_BODY) ], advance: true)

    result = run_review(command: script)

    assert_equal :stale, result.outcome
    assert_empty @platform.review_results
    assert_equal 1, @platform.stale_reports.size
    assert_includes lines, "  [reviewer:status] Reviewing the diff"
  end

  # --- S10: durable history in a terminal and in a capture ------------------

  def test_a_non_tty_capture_keeps_the_same_durable_activity_with_no_cursor_control
    capture = StringIO.new
    script = reviewer_stream([ ClaudeStreamJson.init, ClaudeStreamJson.narration("Reviewing the diff"),
                               ClaudeStreamJson.bash_call("bin/test"),
                               ClaudeStreamJson.terminal(VERDICT_BODY) ])

    result = run_review(command: script, io: SpecrelayRunner::TerminalPresenter.wrap(capture))

    assert result.success?, result.message
    refute_includes capture.string, "\r", "a capture must carry no cursor control"
    [ "  [reviewer:status] Provider started", "  [reviewer:status] Reviewing the diff",
      "  [reviewer:status] > Bash bin/test" ].each do |line|
      assert_includes capture.string.split("\n"), line
    end
  end

  # --- acceptance 5: the lease heartbeat is unaffected by the live stream ---

  # The heartbeater thread and the decoder's sink write to ONE presenter while the reviewer runs.
  # Both facts have to hold: the lease is still renewed, and no durable line is split by the other
  # writer.
  def test_the_lease_heartbeat_still_renews_while_public_activity_streams
    payload = review_payload
    payload["execution_policy"] = { "attempt_timeout_seconds" => 30, "lease_renewal_seconds" => 1 }
    script = reviewer_stream([ ClaudeStreamJson.init, ClaudeStreamJson.narration("Reviewing the diff"),
                               ClaudeStreamJson.terminal(VERDICT_BODY) ], sleep_seconds: 2.5)

    result = run_review(command: script, payload: payload)

    assert result.success?, result.message
    refute_empty @platform.requests_to("/api/runner/heartbeat"), "the lease must still be renewed"
    assert_includes lines, "  [reviewer:status] Reviewing the diff"
    assert(lines.none? { |line| line.include?("[reviewer:") && !line.start_with?("  [reviewer:") },
           "a concurrent heartbeat must not split a streamed line: #{lines.inspect}")
  end

  private

  # --- assertions over the terminal ----------------------------------------

  def lines = @terminal.durable_lines
  def index(fragment) = lines.index { |line| line.include?(fragment) } || -1

  # --- the reviewer stand-ins ----------------------------------------------

  # A real reviewer: an on-disk executable that writes the given stream-json frames, one per
  # line, and exits. A Hash is generated as JSON; a String is written verbatim, which is how a
  # malformed or truncated stream is reproduced.
  #
  # `await` makes it BLOCK before its last line until that file exists; `advance` pushes to the
  # reviewed branch while it works.
  def reviewer_stream(frames, exit_code: 0, await: nil, stderr: nil, sleep_seconds: nil, advance: false)
    lines = frames.map { |frame| frame.is_a?(String) ? frame : JSON.generate(frame) }
    write_script(<<~RUBY)
      $stdout.sync = true
      $stderr.print(#{stderr.inspect}) if #{stderr.inspect}
      #{advance_source if advance}
      lines = #{lines.inspect}
      lines.each_with_index do |line, position|
        if (sentinel = #{await.inspect}) && position == lines.length - 1
          deadline = Time.now + 15
          until File.exist?(sentinel)
            abort "the parent displayed nothing while this reviewer was still running" if Time.now > deadline
            sleep 0.02
          end
        end
        puts line
      end
      sleep #{sleep_seconds.inspect} if #{sleep_seconds.inspect}
      exit #{exit_code}
    RUBY
  end

  # The deterministic fake reviewer: its stdout IS its review document.
  def reviewer_text(body) = write_script("print #{body.inspect}\n")

  def write_script(body)
    path = File.join(@root, "reviewer-#{rand(1_000_000)}.rb")
    File.write(path, "#!/usr/bin/env ruby\n#{body}")
    FileUtils.chmod(0o755, path)
    path
  end

  # Someone pushes to the reviewed branch while the reviewer works. The reviewing checkout is
  # untouched, so the pinned object is still resolvable locally.
  def advance_source
    <<~RUBY
      File.write(File.join(#{@seed.inspect}, "LATER.md"), "added during the review\\n")
      system("git -C #{@seed} add LATER.md", out: File::NULL, err: File::NULL)
      system("git -C #{@seed} -c commit.gpgsign=false commit --quiet -m during", out: File::NULL, err: File::NULL)
      system("git -C #{@seed} push --quiet origin HEAD:refs/heads/#{BRANCH}", out: File::NULL, err: File::NULL)
    RUBY
  end

  # The named frames the fail-closed table uses, kept out of the table so each row states only
  # the SHAPE under test.
  def frame_for(frame)
    case frame
    when :init then ClaudeStreamJson.init
    when :narration then ClaudeStreamJson.narration("Reviewing the diff")
    when :terminal then ClaudeStreamJson.terminal(VERDICT_BODY)
    when :oversized_terminal
      ClaudeStreamJson.terminal("x" * (SpecrelayRunner::ClaudeStream::MAX_PENDING_BYTES + 1_000))
    else frame
    end
  end

  # --- the review itself ---------------------------------------------------

  def run_review(command:, provider: "claude", args: nil, io: nil, timeout_seconds: nil, client: nil,
                 payload: nil)
    document = { "provider" => provider, "command" => command }
    document["args"] = args if args
    document["timeout_seconds"] = timeout_seconds if timeout_seconds
    SpecrelayRunner::Review::Execution.call(
      config: config, client: client || platform_client, payload: payload || review_payload,
      settings: SpecrelayRunner::Review::Settings.new(document, env: {}),
      env: { "PATH" => ENV["PATH"].to_s, "HOME" => @root }, io: io || presenter
    )
  end

  def presenter
    @presenter ||= SpecrelayRunner::TerminalPresenter.new(out: @terminal, transient: true, columns: 200)
  end

  def config
    SpecrelayRunner::Config.new(
      { "platform" => { "base_url" => @platform.base_url },
        "runner" => { "id" => "stream-runner", "display_name" => "Stream Machine" },
        "workspace_roots" => { "tiny-demo-workspace" => @root } }
    )
  end

  def platform_client
    SpecrelayRunner::PlatformClient.new(base_url: @platform.base_url, token: FakePlatform::EXPECTED_TOKEN)
  end

  # A real bare repository plus a real checkout of it, so Checkout's remote identity, pinned
  # commit and remote-head freshness checks all run for real, offline.
  def build_remote_and_checkout
    system("git init --quiet --bare --initial-branch=#{BRANCH} #{@remote}", out: File::NULL, err: File::NULL)
    @seed = File.join(@root, "seed")
    git_clone(@seed)
    File.write(File.join(@seed, "README.md"), "demo\n")
    system("git -C #{@seed} add README.md", out: File::NULL, err: File::NULL)
    system("git -C #{@seed} -c commit.gpgsign=false commit --quiet -m first", out: File::NULL, err: File::NULL)
    system("git -C #{@seed} push --quiet origin HEAD:refs/heads/#{BRANCH}", out: File::NULL, err: File::NULL)
    git_clone(@repo)
    @pinned_head = `git -C #{@repo} rev-parse HEAD`.strip
  end

  def git_clone(target)
    system("git clone --quiet #{@remote} #{target}", out: File::NULL, err: File::NULL)
    system("git -C #{target} config user.email review@example.com", out: File::NULL, err: File::NULL)
    system("git -C #{target} config user.name Reviewer", out: File::NULL, err: File::NULL)
  end

  def review_payload
    {
      "contract_version" => "mvp-0033", "assignment_type" => "review",
      "claim" => { "runner_execution_id" => "rex_fake" },
      "review" => { "attempt_id" => "rvt_fake", "attempt_ordinal" => 1, "input_manifest_digest" => "digest" },
      "ticket" => { "external_id" => "DEMO-1", "task_id" => "DEMO-1" },
      "workspace" => { "key" => "tiny-demo-workspace" },
      "specification" => { "digest" => "specdigest", "documents" => [] },
      "implementation" => { "run_url" => "#{@platform.base_url}/runs/run_fake" },
      "repositories" => [ { "repository_key" => "specrelay-platform", "slug" => "SpecRelay/tiny-demo-workspace",
                            "clone_url" => @remote, "base_commit" => BASE, "branch" => BRANCH,
                            "head_commit" => @pinned_head,
                            "pull_request_url" => "https://github.com/SpecRelay/tiny-demo-workspace/pull/1" } ],
      "execution_evidence" => { "executor_summary" => "Did the work.", "files" => [] },
      "execution_policy" => { "attempt_timeout_seconds" => 30, "lease_renewal_seconds" => 0 },
      "result_contract" => { "outcomes" => %w[ACCEPT CHANGES_REQUESTED NEEDS_INPUT] }
    }
  end
end
