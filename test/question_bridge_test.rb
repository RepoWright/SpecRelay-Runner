# frozen_string_literal: true

require_relative "test_helper"

# MVP-0036 Stage 1: the SpecRelay-owned local question bridge.
#
# Every case here runs the real CLI against the real HTTP client and a real child process, so how
# a question ends the provider session is proven by the provider's own output and Platform's
# recorded requests rather than by a stubbed return value.
class QuestionBridgeTest < Minitest::Test
  # The one directory on the child PATH that provides the approved fixture name. The PAYLOAD is
  # always the canonical fixture profile; which script that approved name resolves to on this
  # host is the test's choice, exactly as it is the operator's choice on a real machine.
  def fixture_dir = @fixture_dir ||= fixture_bin
  TASK = "DEMO-0036"

  BATCH = {
    "questions" => [
      { "prompt" => "Which storage backend should the export use?",
        "options" => [ { "key" => "s3", "label" => "Object storage", "recommended" => true },
                       { "key" => "pg", "label" => "Postgres large objects" } ] },
      { "prompt" => "What should the retention window be?" }
    ],
    "continuation_context" => {
      "progress" => "the exporter is written", "changed_areas" => "app/exports",
      "why_it_matters" => "the choice changes the schema", "next_step" => "wire the writer",
      "remaining_work" => "tests", "do_not_repeat" => "the exporter itself"
    }
  }.freeze

  ANSWERS = [ { "option" => "pg" }, { "option" => "other", "text" => "Ninety days." } ].freeze

  def setup
    @root, = DemoWorkspace.build
    @executor = DemoWorkspace.write_question_executor(@root)
    @platform = FakePlatform.new(claim_payload: payload).start
    @config = build_config
  end

  def teardown
    @platform.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # The question the double asks, and how long it waits, are host-side controls: they are installed
  # behind the approved bare name on the child PATH, not written into the assignment. The payload
  # is always the canonical fixture profile.
  def payload(request: BATCH.to_json, timeout: "20", executor: nil, env: {})
    use_fixture(fixture_dir, executor || @executor,
                env: { "FAKE_EXECUTOR_QUESTION_JSON" => request,
                       "FAKE_EXECUTOR_QUESTION_TIMEOUT_SECONDS" => timeout }.merge(env))
    claim_payload_for(task_id: TASK, root: @root)
  end

  def build_config
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{@platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: test-runner
        display_name: Test Runner
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{@root}
    YAML
    SpecrelayRunner::Config.load(path)
  end

  # The loop, driven over REAL claim-once executions: each iteration runs the whole CLI path, so
  # the loop reacts to the runner's own classification rather than to a stubbed boolean.
  #
  # `offer_again` re-offers the run each time, as Platform does for a paused one; without it the
  # run is claimed once, as Platform does for one it has stopped.
  def loop_over_real_runs(iterations:, on_failure: SpecrelayRunner::LoopRunner::ON_FAILURE_STOP, offer_again: true, io: StringIO.new)
    runs = 0
    status = SpecrelayRunner::LoopRunner.call(
      out: io, err: io, install_signals: false, max_iterations: iterations, poll_seconds: 0,
      on_failure: on_failure, sleeper: ->(_seconds) { },
      claim: -> { SpecrelayRunner::PlatformClient::ClaimResult.new(claimed: true, payload: {}) },
      execute: lambda do |_payload|
        runs += 1
        @platform.offer_again! if offer_again
        run_cli(io) == SpecrelayRunner::CLI::SUCCESS
      end
    )
    [ status, runs ]
  end

  def run_cli(io)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{@config.source_path}],
                             out: io, err: io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => "#{fixture_dir}:#{ENV['PATH']}" })
  end

  # A released answer window is an approved PAUSE, so `claim-once` reports it as
  # handled. Round 001 asserted RUN_FAILED here, which is the defect the review found: it made
  # every question look like a failed run to the loop above it.
  def test_a_released_session_is_handled_without_a_report_and_leaves_the_changes_in_place
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, io.string
    assert_equal 1, @platform.executor_questions.size
    assert_empty @platform.requests_to("/api/runner/reports"), "no report follows an unanswered pause"
    assert_empty @platform.capture_failures, "a release is not a capture failure"
    assert_match(/awaiting_input/, io.string)
    refute_includes io.string, "[question-executor] applied edit"
    assert_path_exists File.join(@root, ".runs", "worktrees", TASK), "the dirty worktree is preserved"
  end

  # The answer reaches a fresh session through the resume assignment, never through a poll: the
  # client has no way to ask Platform about a question by id.
  def test_an_asked_question_is_never_polled
    io = StringIO.new

    run_cli(io)

    refute SpecrelayRunner::PlatformClient.method_defined?(:executor_question), "the poll client is gone"
    assert_empty @platform.requests.select { |r| r[:method] == "GET" && r[:path].start_with?("/api/runner/executor_questions/") }
  end

  # Platform releases an accepted question at once, so no provider session waits for
  # an answer; one that is not released is not something this session may continue on.
  def test_an_accepted_question_that_platform_does_not_release_fails_closed
    @platform.question_response = [ 201, { question: { id: "exq_fake", state: "UNEXPECTED" } } ]
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_includes io.string, SpecrelayRunner::QuestionBridge::NOT_RELEASED
    assert_equal 1, @platform.capture_failures.size
    assert_empty @platform.requests_to("/api/runner/reports")
  end

  # A checkpoint that cannot be pushed is not a submission the provider can correct:
  # the attempt ends through the input-capture failure path and no question is stored.
  #
  # The provider changes a file but reports no repository. The checkpoint is taken from the
  # workspace, not from that report, so the edit is captured and its push is what fails.
  def test_a_checkpoint_push_failure_ends_through_the_input_capture_failure_path
    bare = FakeGithub.add_remote(@root, name: "tiny-demo-workspace")
    hook = File.join(bare, "hooks", "pre-receive")
    File.write(hook, "#!/bin/sh\necho refused >&2\nexit 1\n")
    FileUtils.chmod(0o755, hook)
    @platform.claim_payload = payload(env: { "FAKE_EXECUTOR_QUESTION_EDIT_FIRST" => "1",
                                             "FAKE_EXECUTOR_SELECTION_JSON" => %({"repositories":[]}) })
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_empty @platform.question_submissions, "no question is stored without its checkpoint"
    assert_equal 1, @platform.capture_failures.size
    refute_includes io.string, "[question-executor] refused", "a push failure is not returned to the provider"
    assert_includes io.string, "[question-executor] edited before asking"
    assert_includes @platform.capture_failures.first[:body].to_json, "could not push"
    assert_empty @platform.requests_to("/api/runner/reports")
    assert_match(/input_capture_failed/, io.string)
  end

  def checkpoint_refs(bare) =
    Open3.capture2("git", "-C", bare, "for-each-ref", "--format=%(refname)", "refs/heads/runner-checkpoints/").first

  # Platform READ the question and refused it, so nothing names the checkpoint refs this capture
  # pushed: they are removed, and the same session may correct and ask again.
  def test_a_refused_question_removes_the_checkpoint_refs_its_capture_created
    bare = FakeGithub.add_remote(@root, name: "tiny-demo-workspace")
    @platform.claim_payload = payload(env: { "FAKE_EXECUTOR_QUESTION_EDIT_FIRST" => "1" })
    @platform.question_response = [ 422, { error: "continuation_context.progress is required" } ]
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, io.string
    assert_includes io.string, "[question-executor] refused"
    assert_equal 1, @platform.question_submissions.size, "the refs were pushed before the question was sent"
    assert_empty checkpoint_refs(bare), "a refused question leaves no checkpoint ref behind"
  end

  # Platform's answer never arrived, so the question may be stored: its refs are kept with it.
  def test_an_unknown_question_outcome_keeps_the_checkpoint_refs
    bare = FakeGithub.add_remote(@root, name: "tiny-demo-workspace")
    @platform.claim_payload = payload(env: { "FAKE_EXECUTOR_QUESTION_EDIT_FIRST" => "1" })
    @platform.question_response = [ 500, { error: "platform is unwell" } ]
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_equal 1, @platform.question_submissions.size
    refute_empty checkpoint_refs(bare), "a question whose fate is unknown keeps its checkpoint refs"
  end

  def test_a_locally_invalid_request_is_refused_to_the_same_session_and_never_reaches_platform
    @platform.stop
    @platform = FakePlatform.new(claim_payload: payload(request: "{not json")).start
    @config = build_config
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, io.string
    assert_empty @platform.executor_questions, "nothing durable is attempted for an unreadable request"
    assert_includes io.string, "[question-executor] refused"
    assert_equal 1, @platform.requests_to("/api/runner/reports").size, "the session continued normally"
  end

  def test_an_oversized_request_is_refused_locally_before_it_is_sent
    oversized = BATCH.merge("questions" => [ { "prompt" => "x" * (SpecrelayRunner::QuestionBridge::MAX_REQUEST_BYTES + 1) } ])
    @platform.stop
    @platform = FakePlatform.new(claim_payload: payload(request: oversized.to_json)).start
    @config = build_config
    io = StringIO.new

    run_cli(io)

    assert_empty @platform.executor_questions
    assert_includes io.string, "must fit within #{SpecrelayRunner::QuestionBridge::MAX_REQUEST_BYTES}"
  end

  def test_a_platform_refusal_returns_to_the_same_session_without_failing_the_attempt
    @platform.question_response = [ 422, { error: "continuation_context.progress is required" } ]
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, io.string
    assert_includes io.string, "[question-executor] refused"
    assert_includes io.string, "continuation_context.progress is required"
    assert_empty @platform.capture_failures, "a correctable refusal is not a capture failure"
  end

# Platform's VALIDATION refusal is `{ accepted: false, errors: [...] }` — a different body from
# an authority refusal's `{ error: ... }` — and the provider can only correct what it is told.
def test_a_platform_validation_refusal_reaches_the_same_session_with_its_field_errors
  errors = [ "continuation_context.progress is required", "questions[0].prompt is required" ]
  @platform.question_response = [ 422, { accepted: false, errors: errors } ]
  io = StringIO.new

  exit_code = run_cli(io)

  assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, io.string
  assert_includes io.string, "[question-executor] refused"
  errors.each { |error| assert_includes io.string, error, "the field error must reach the provider" }
  assert_empty @platform.capture_failures, "a correctable refusal is not a capture failure"
end

# The bridge is the ONE owner of the refusal fact the result decoder later relies on, so the
# count is proven at the bridge: one per refusal it wrote back to the provider — Platform's or
# its own local one — and never for a fault, which ends the session instead.
def test_the_bridge_counts_each_refusal_it_returns_and_never_a_fault
  refused = direct_bridge(status: 422)
  ask(refused, BATCH.to_json)
  assert_equal SpecrelayRunner::QuestionBridge::ERROR, await_verdict(refused)
  assert_equal 1, refused.refusals
  ask(refused, "{not json")
  assert_equal SpecrelayRunner::QuestionBridge::ERROR, await_verdict(refused)
  assert_equal 2, refused.refusals
  assert_nil refused.outcome, "a refusal leaves the session and the claim live"

  faulted = direct_bridge(status: 500)
  ask(faulted, BATCH.to_json)
  assert_nil await_verdict(faulted)
  assert_predicate faulted, :failed?
  assert_equal 0, faulted.refusals
ensure
  [ refused, faulted ].compact.each(&:stop)
end

# A client that answers every submission with one scripted status, so the bridge's own
# classification of refusal against fault is what is under test.
ScriptedClient = Struct.new(:status) do
  def submit_executor_question(**)
    raise SpecrelayRunner::PlatformClient::RequestFailed.new("Platform request failed (#{status}): scripted", status: status)
  end
end

def direct_bridge(status:)
  captured = SpecrelayRunner::Checkpoint::Captured.new(checkpoint: { "recorded" => true }, error: nil)
  SpecrelayRunner::QuestionBridge.new(client: ScriptedClient.new(status), claim: "rex_direct",
                                      staging_dir: Dir.mktmpdir("bridge"), capture: -> { captured },
                                      io: StringIO.new).start
end

def ask(bridge, body)
  request = File.join(bridge.path, SpecrelayRunner::QuestionBridge::REQUEST)
  File.write("#{request}.partial", body)
  File.rename("#{request}.partial", request)
end

# The bridge's verdict file for the request just asked, or nil once the bridge ended instead.
# The verdict is CONSUMED, as a provider consumes it: the bridge clears an earlier verdict only
# when it picks up the next request, so an unread one would be mistaken for the new answer.
def await_verdict(bridge, deadline: 5)
  finish = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
  verdict = File.join(bridge.path, SpecrelayRunner::QuestionBridge::ERROR)
  loop do
    return File.delete(verdict) && SpecrelayRunner::QuestionBridge::ERROR if File.file?(verdict)
    return nil if bridge.outcome
    raise "the bridge produced no verdict within #{deadline}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > finish

    sleep 0.05
  end
end

  def test_an_unrecoverable_bridge_fault_reports_input_capture_failed_and_uploads_no_report
    @platform.question_response = [ 500, { error: "platform is unwell" } ]
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_equal 1, @platform.capture_failures.size
    assert_empty @platform.requests_to("/api/runner/reports"), "no report follows a lost question"
    assert_match(/input_capture_failed/, io.string)
    assert_path_exists File.join(@root, ".runs", "worktrees", TASK), "the dirty worktree is preserved"
  end

  def test_a_released_session_keeps_a_stop_policy_loop_watching
    status, runs = loop_over_real_runs(iterations: 2)

    assert_equal SpecrelayRunner::LoopRunner::OK, status
    assert_equal 2, runs, "a handled pause must not end the session under --on-failure stop"
  end

  STOPPED = "Platform stopped #{TASK} as failed; it is not retried automatically."
  KEPT = "The provider's unsaved changes stay in the task workspace; preserve them before releasing it."
  def worktree_file = File.join(@root, ".runs", "worktrees", TASK, "demo-app", "index.html")

  # Scenario 12 — a capture failure Platform recorded is stated as what it is: the attempt failed,
  # the run is stopped rather than retried, and the unsaved work is still on this machine. Later
  # polls and a restarted runner leave that work exactly where it is.
  def test_a_recorded_capture_failure_says_the_run_stopped_and_the_work_is_kept
    @platform.claim_payload = payload(env: { "FAKE_EXECUTOR_QUESTION_EDIT_FIRST" => "1" })
    @platform.question_response = [ 500, { error: "platform is unwell" } ]
    io = StringIO.new

    exit_code = run_cli(io)
    @platform.offer_no_work!
    later = Array.new(2) { StringIO.new.then { |out| [ run_cli(out), out.string ] } }

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_includes io.string, STOPPED
    assert_includes io.string, KEPT
    assert_includes io.string, "Nothing was tested, reported, published, or written to Jira."
    assert_equal [ SpecrelayRunner::CLI::SUCCESS ] * 2, later.map(&:first)
    later.each { |_code, out| refute_includes out, "Claimed run", "the stopped run was claimed again" }
    assert_includes File.read(worktree_file), "Hello Interrupted Demo", "the unsaved work was discarded"
    assert_empty @platform.requests_to("/api/runner/reports")
  end

  # A failure Platform did not record proves nothing about the run, so nothing is promised about it.
  def test_an_unrecorded_capture_failure_promises_nothing_about_the_run
    @platform.question_response = [ 500, { error: "platform is unwell" } ]
    original = @platform.method(:executor_question)
    @platform.define_singleton_method(:executor_question) do |request|
      request[:body].to_h.key?("capture_failure") ? [ 503, { error: "unavailable" } ] : original.call(request)
    end
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_includes io.string, "Platform did not record this failure."
    refute_includes io.string, STOPPED
    assert_includes io.string, KEPT
  end

  # `--on-failure continue` polls on after the failure, and the stopped run is not handed out again.
  def test_a_capture_failure_lets_a_continue_policy_loop_poll_on_without_the_stopped_run
    @platform.question_response = [ 500, { error: "platform is unwell" } ]
    io = StringIO.new

    status, runs = loop_over_real_runs(iterations: 2, on_failure: SpecrelayRunner::LoopRunner::ON_FAILURE_CONTINUE,
                                       offer_again: false, io: io)

    assert_equal SpecrelayRunner::LoopRunner::FAILED, status, "the session still reports the failure it saw"
    assert_equal 2, runs, io.string
    assert_includes io.string, "continuing to poll (--on-failure continue)"
    assert_equal 1, @platform.capture_failures.size
    assert_equal 1, io.string.scan("Claimed run #{TASK}").size, "the stopped run was claimed again"
  end

  def test_a_capture_failure_still_stops_a_stop_policy_loop
    @platform.question_response = [ 500, { error: "platform is unwell" } ]

    status, runs = loop_over_real_runs(iterations: 2)

    assert_equal SpecrelayRunner::LoopRunner::FAILED, status
    assert_equal 1, runs, "a real failure still obeys --on-failure stop"
  end

  def test_an_ordinary_provider_that_never_asks_follows_the_existing_path_unchanged
    root, executor = DemoWorkspace.build
    use_fixture(fixture_dir, executor)
    platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK, root: root)).start
    config_path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(config_path, <<~YAML)
      platform:
        base_url: #{platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: test-runner
        display_name: Test Runner
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{root}
    YAML
    io = StringIO.new

    exit_code = SpecrelayRunner::CLI.run(%W[claim-once --config #{config_path}], out: io, err: io,
                                         env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
                                                "PATH" => "#{fixture_dir}:#{ENV['PATH']}" })

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, io.string
    assert_empty platform.executor_questions, "an ordinary run never touches the question endpoint"
    assert_equal 1, platform.requests_to("/api/runner/reports").size
  ensure
    platform&.stop
    FileUtils.remove_entry(root) if root && File.directory?(root)
  end
end
