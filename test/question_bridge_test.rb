# frozen_string_literal: true

require_relative "test_helper"

# MVP-0036 Stage 1: the SpecRelay-owned local question bridge.
#
# Every case here runs the real CLI against the real HTTP client and a real child process, so
# "the same provider session received the answer" is proven by the provider's own output rather
# than by a stubbed return value.
class QuestionBridgeTest < Minitest::Test
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

  def payload(request: BATCH.to_json, timeout: "20", executor: nil)
    claim_payload_for(task_id: TASK, executor_command: executor || @executor).tap do |built|
      built["executor"]["env"] = { "FAKE_QUESTION_JSON" => request,
                                   "FAKE_QUESTION_TIMEOUT_SECONDS" => timeout }
    end
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

  # Replace the running fake with one whose provider ASKS and then abandons its own question.
  # `ask_seconds` places the provider's exit before or after the parent's next answer poll.
  def use_abandoning_provider(provider_exit:, ask_seconds: nil)
    @platform.stop
    executor = DemoWorkspace.write_abandoning_executor(@root)
    @platform = FakePlatform.new(claim_payload: payload(executor: executor).tap do |built|
      built["executor"]["env"]["FAKE_QUESTION_EXIT_CODE"] = provider_exit
      built["executor"]["env"]["FAKE_QUESTION_ASK_SECONDS"] = ask_seconds if ask_seconds
    end).start
    @config = build_config
  end

  # The loop, driven over REAL claim-once executions: each iteration runs the whole CLI path, so
  # the loop reacts to the runner's own classification rather than to a stubbed boolean.
  def loop_over_real_runs(iterations:)
    io = StringIO.new
    runs = 0
    status = SpecrelayRunner::LoopRunner.call(
      out: io, err: io, install_signals: false, max_iterations: iterations, poll_seconds: 0,
      on_failure: SpecrelayRunner::LoopRunner::ON_FAILURE_STOP, sleeper: ->(_seconds) { },
      claim: -> { SpecrelayRunner::PlatformClient::ClaimResult.new(claimed: true, payload: {}) },
      execute: lambda do |_payload|
        runs += 1
        @platform.offer_again!
        run_cli(io) == SpecrelayRunner::CLI::SUCCESS
      end
    )
    [ status, runs ]
  end

  def run_cli(io)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{@config.source_path}],
                             out: io, err: io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] })
  end

  def test_answers_reach_the_same_provider_session_and_the_run_continues
    @platform.answer_question!(ANSWERS)
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, io.string
    assert_equal 1, @platform.executor_questions.size, "exactly one batch was submitted"
    assert_equal BATCH["questions"], @platform.asked_question["questions"]
    assert_equal BATCH["continuation_context"], @platform.asked_question["continuation_context"]
    # The fixed instructions the provider actually received name every field Platform requires,
    # rendered from the assignment rather than restated by the runner.
    BATCH["continuation_context"].each_key { |field| assert_includes io.string, "`#{field}`" }
    # The provider's OWN output: the same process that asked received the answers and carried on.
    assert_includes io.string, "[question-executor] answered #{ANSWERS.to_json}"
    assert_includes io.string, "[question-executor] applied edit"
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
    # CR-002 F1 — Platform learns that the answers ARRIVED only from the runner that wrote them
    # into the live session's bridge, and learns it exactly once.
    assert_equal 1, @platform.delivery_acknowledgements.size
    assert_equal "ANSWERED", @platform.question_state
  end

  # CR-002 F1 — the Product Owner's answer is durable, but the provider exits before the next
  # poll can hand it over. Nothing may report that the session received it.
  def test_an_answer_the_lost_provider_never_received_is_never_acknowledged
    use_abandoning_provider(provider_exit: "0", ask_seconds: "0.5")
    @platform.answer_question!(ANSWERS)
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_empty @platform.delivery_acknowledgements, "an undelivered answer is never acknowledged"
    assert_equal "ANSWER_READY", @platform.question_state
    assert_equal 1, @platform.capture_failures.size
    assert_includes io.string, SpecrelayRunner::QuestionBridge::PROVIDER_EXITED
    assert_empty @platform.requests_to("/api/runner/reports"), "no report follows an undelivered answer"
    assert_path_exists File.join(@root, ".runs", "worktrees", TASK), "the dirty worktree is preserved"
  end

  # CR-002 F1 — the same race one step later: the provider goes while the answer poll is still in
  # flight, so the answers are written into a bridge whose session has already ended.
  def test_a_provider_lost_while_the_answer_poll_is_in_flight_is_never_reported_as_delivered
    use_abandoning_provider(provider_exit: "0", ask_seconds: "3")
    @platform.answer_question!(ANSWERS)
    @platform.question_poll_delay = 2.0
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_empty @platform.delivery_acknowledgements
    assert_equal "ANSWER_READY", @platform.question_state
    assert_equal 1, @platform.capture_failures.size
    # The answers were written locally and then found to have nowhere to go: this is the
    # in-flight race, not the earlier one the test above covers.
    assert_includes io.string, SpecrelayRunner::QuestionBridge::ANSWER_UNDELIVERED
    assert_empty @platform.requests_to("/api/runner/reports")
  end

  # CR-002 F1 — Platform never confirmed the delivery, so the attempt must not continue as if it
  # had. Fail closed: the answers stay durable and no report is uploaded.
  def test_a_delivery_platform_never_confirms_ends_the_session_without_a_report
    @platform.answer_question!(ANSWERS)
    @platform.delivery_response = [ 500, { error: "platform is unwell" } ]
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_equal 1, @platform.capture_failures.size
    assert_equal "ANSWER_READY", @platform.question_state
    # The answers reached the live bridge first: the acknowledgement is only ever attempted
    # after that write, so it is the DURABLE claim that could not be made. (Whether the provider
    # wins the race to read the file before it is stopped is timing, not behaviour, so it is not
    # asserted here.)
    assert_equal 1, @platform.delivery_acknowledgements.size
    assert_empty @platform.requests_to("/api/runner/reports")
    assert_path_exists File.join(@root, ".runs", "worktrees", TASK), "the dirty worktree is preserved"
  end

  # CR-003 F1 — Platform answered 200, but the state that won is not this session's delivery:
  # an operator cancelled the run while the answers were in flight. A successful response is not
  # a successful delivery, so the session must not continue on the strength of it.
  def test_a_delivery_answered_with_another_winning_state_is_not_success
    @platform.answer_question!(ANSWERS)
    @platform.delivery_response = [ 200, settled_question_body("exq_fake", "OFFLINE_WAIT") ]
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_equal 1, @platform.delivery_acknowledgements.size
    refute_includes io.string, "answers delivered to the waiting provider session"
    assert_includes io.string, SpecrelayRunner::QuestionBridge::DELIVERY_UNCONFIRMED
    assert_empty @platform.requests_to("/api/runner/reports"), "no report follows an unconfirmed delivery"
    assert_equal 1, @platform.capture_failures.size
    assert_path_exists File.join(@root, ".runs", "worktrees", TASK), "the dirty worktree is preserved"
  end

  # The acknowledgement must confirm THIS batch. A verdict about another one proves nothing
  # about the answers this session just wrote.
  def test_a_delivery_answered_about_another_question_is_not_success
    @platform.answer_question!(ANSWERS)
    @platform.delivery_response = [ 200, settled_question_body("exq_someone_else", "ANSWERED") ]
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    refute_includes io.string, "answers delivered to the waiting provider session"
    assert_includes io.string, SpecrelayRunner::QuestionBridge::DELIVERY_UNCONFIRMED
    assert_empty @platform.requests_to("/api/runner/reports")
  end

  def settled_question_body(id, state)
    { contract_version: "mvp-0036",
      question: { id: id, state: state, deadline_at: "2026-08-13T12:00:00Z",
                  remaining_seconds: 0, answers: ANSWERS } }
  end

  # CR-002 F2 — Platform released the session before the provider exited. The runner reports the
  # capture failure it saw, then classifies the attempt from the state Platform returns, not from
  # the provider's exit code.
  def test_a_release_that_won_before_the_provider_exited_is_handled_rather_than_failed
    use_abandoning_provider(provider_exit: "3", ask_seconds: "0.5")
    @platform.release_question!
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, io.string
    assert_equal 1, @platform.capture_failures.size, "the runner still reports what it observed"
    assert_empty @platform.requests_to("/api/runner/reports"), "no report follows a released session"
    assert_match(/awaiting_input/, io.string)
    refute_match(/input_capture_failed/, io.string)
    assert_path_exists File.join(@root, ".runs", "worktrees", TASK), "the dirty worktree is preserved"
  end

  def test_a_release_that_won_before_the_provider_exited_keeps_a_stop_policy_loop_watching
    use_abandoning_provider(provider_exit: "3", ask_seconds: "0.5")
    @platform.release_question!

    status, runs = loop_over_real_runs(iterations: 2)

    assert_equal SpecrelayRunner::LoopRunner::OK, status
    assert_equal 2, runs, "an ordinary release must not end the session under --on-failure stop"
  end

  # CR-001 F4 — a released answer window is an approved PAUSE, so `claim-once` reports it as
  # handled. Round 001 asserted RUN_FAILED here, which is the defect the review found: it made
  # every question look like a failed run to the loop above it.
  def test_a_released_session_is_handled_without_a_report_and_leaves_the_changes_in_place
    @platform.release_question!
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

  # CR-001 F1 — the provider asked, Platform accepted, and then the process died. Whatever its
  # exit code, this is a lost question, not a failed task: no test runs, no report is uploaded,
  # and the attempt ends as a capture failure with the dirty worktree left in place.
  def test_a_provider_that_exits_while_its_question_is_live_ends_as_a_capture_failure
    use_abandoning_provider(provider_exit: "0")
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_equal 1, @platform.executor_questions.reject { |r| r[:body].to_h.key?("capture_failure") }.size
    assert_equal 1, @platform.capture_failures.size, "the lost question is reported, not left to a lapsing lease"
    assert_empty @platform.requests_to("/api/runner/reports"), "no report follows a lost question"
    assert_match(/input_capture_failed/, io.string)
    assert_path_exists File.join(@root, ".runs", "worktrees", TASK), "the dirty worktree is preserved"
  end

  def test_a_provider_that_crashes_while_its_question_is_live_still_ends_as_a_capture_failure
    use_abandoning_provider(provider_exit: "3")
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_equal 1, @platform.capture_failures.size
    assert_empty @platform.requests_to("/api/runner/reports")
  end

  def test_a_released_session_keeps_a_stop_policy_loop_watching
    @platform.release_question!

    status, runs = loop_over_real_runs(iterations: 2)

    assert_equal SpecrelayRunner::LoopRunner::OK, status
    assert_equal 2, runs, "a handled pause must not end the session under --on-failure stop"
  end

  def test_a_capture_failure_still_stops_a_stop_policy_loop
    @platform.question_response = [ 500, { error: "platform is unwell" } ]

    status, runs = loop_over_real_runs(iterations: 2)

    assert_equal SpecrelayRunner::LoopRunner::FAILED, status
    assert_equal 1, runs, "a real failure still obeys --on-failure stop"
  end

  def test_an_ordinary_provider_that_never_asks_follows_the_existing_path_unchanged
    root, executor = DemoWorkspace.build
    platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK, executor_command: executor)).start
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
                                                "PATH" => ENV["PATH"] })

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, io.string
    assert_empty platform.executor_questions, "an ordinary run never touches the question endpoint"
    assert_equal 1, platform.requests_to("/api/runner/reports").size
  ensure
    platform&.stop
    FileUtils.remove_entry(root) if root && File.directory?(root)
  end
end
