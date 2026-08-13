# frozen_string_literal: true

require_relative "test_helper"

# MVP-0036 Stage 2a: resuming an answered offline question on the machine that still holds the
# uncommitted work.
#
# The end-to-end cases run the whole CLI twice against a REAL git worktree: once to leave a dirty
# worktree and a recorded checkpoint behind, and once to resume onto it. The checkpoint proof
# itself is exercised directly, because a refusal has to name the term that failed and running a
# child process five times to learn that would prove nothing extra.
class QuestionResumeTest < Minitest::Test
  TASK = "DEMO-0036"

  BATCH = {
    "questions" => [
      { "prompt" => "How should the totals row round a half cent?",
        "options" => [ { "key" => "half_up", "label" => "Round half up", "recommended" => true },
                       { "key" => "bankers", "label" => "Round half to even" } ] }
    ],
    "continuation_context" => {
      "progress" => "the totals row renders", "changed_areas" => "demo-app/index.html",
      "why_it_matters" => "rounding changes what the report claims", "next_step" => "apply the rule",
      "remaining_work" => "the rounding rule and its tests", "do_not_repeat" => "the totals row"
    }
  }.freeze

  ANSWERS = [ { "option" => "half_up", "text" => "Match the finance spreadsheets." } ].freeze

  def setup
    @root, = DemoWorkspace.build
    # Every real SpecRelay workspace is a clone, and the checkpoint's normalized origin is what
    # proves a resume is landing on the same repository rather than on a look-alike, so the
    # fixture carries one. Nothing is ever pushed to it.
    git(@root, "remote", "add", "origin", "https://github.com/SpecRelay/tiny-demo-workspace.git")
    @platform = nil
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # ---------------------------------------------------------------- end to end

  # Phase one: a provider that CHANGES files and then asks. The session is released, so the run
  # ends with real uncommitted work on this machine and a checkpoint describing it.
  def released_question_with_dirty_worktree
    executor = DemoWorkspace.write_question_executor(@root)
    @platform = FakePlatform.new(claim_payload: question_payload(executor)).start
    @platform.release_question!
    io = StringIO.new
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli(io), io.string
    assert_includes io.string, "[question-executor] edited before asking"
    @platform.executor_questions.first[:body]["checkpoint"]
  end

  def question_payload(executor)
    claim_payload_for(task_id: TASK, executor_command: executor).tap do |built|
      built["executor"]["env"] = { "FAKE_QUESTION_JSON" => BATCH.to_json,
                                   "FAKE_QUESTION_TIMEOUT_SECONDS" => "5",
                                   "FAKE_QUESTION_EDIT_FIRST" => "1" }
    end
  end

  # Phase two: the same run, claimed again by the same machine, carrying the answers.
  def resume_payload(checkpoint, executor: nil, env: nil)
    executor ||= DemoWorkspace.write_resume_executor(@root)
    payload = claim_payload_for(task_id: TASK, executor_command: executor).merge(
      "resume" => { "question_id" => "exq_fake", "checkpoint" => checkpoint,
                    "continuation_context" => BATCH["continuation_context"],
                    "questions" => BATCH["questions"], "answers" => ANSWERS }
    )
    payload["executor"]["env"] = env if env
    payload
  end

  def restart_platform(payload, delivery: settled_resume("RESUMED"))
    @platform.stop
    @platform = FakePlatform.new(claim_payload: payload).start
    @platform.delivery_response = delivery
  end

  def settled_resume(state)
    [ 200, { contract_version: "mvp-0036",
             question: { id: "exq_fake", state: state, deadline_at: "2026-08-13T12:00:00Z",
                         remaining_seconds: 0, answers: ANSWERS } } ]
  end

  def request_order
    @platform.requests.map { |request| [ request[:method], request[:path] ] }
  end

  def run_cli(io)
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
    SpecrelayRunner::CLI.run(%W[claim-once --config #{path}], out: io, err: io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] })
  end

  # A04/A07 — the whole loop: measure at ask time, prove the same worktree at resume time, hand a
  # FRESH provider the complete public handoff, and tell Platform once that it arrived.
  def test_a_verified_resume_starts_a_fresh_session_with_the_answers_and_reports_them_delivered
    checkpoint = released_question_with_dirty_worktree
    assert_equal %w[branch change_digest head origin repository_key], checkpoint.keys.sort
    assert_match(/\A[0-9a-f]{40}\z/, checkpoint["head"])
    assert_match(/\A[0-9a-f]{64}\z/, checkpoint["change_digest"])
    assert_equal "tiny-demo-workspace", checkpoint["repository_key"]
    assert_equal "github.com/specrelay/tiny-demo-workspace", checkpoint["origin"]
    refute_includes checkpoint.to_json, @root, "the checkpoint carries no local path"

    restart_platform(resume_payload(checkpoint))
    io = StringIO.new

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli(io), io.string
    # The fresh provider's OWN output: it received the questions, the answers and the public
    # continuation context, and nothing from the previous session's reasoning.
    assert_includes io.string, "[resume-executor] resumed"
    assert_includes io.string, "How should the totals row round a half cent?"
    assert_includes io.string, "Match the finance spreadsheets."
    assert_includes io.string, "do_not_repeat: the totals row"
    assert_includes io.string, "[resume-executor] applied edit"
    assert_equal 1, @platform.delivery_acknowledgements.size, "the resume is acknowledged exactly once"
    assert_empty @platform.executor_questions, "a resume asks no new batch"
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
  end

  # A05/A06 — the machine no longer holds what it recorded. No provider starts, only the fresh
  # claim is handed back, and the worktree is left exactly as it is.
  def test_a_changed_worktree_refuses_before_the_provider_and_releases_only_the_fresh_claim
    checkpoint = released_question_with_dirty_worktree
    File.write(File.join(@root, ".runs", "worktrees", TASK, "demo-app", "index.html"), "Hello Someone Else\n")
    restart_platform(resume_payload(checkpoint))
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_includes io.string, "change_digest"
    refute_includes io.string, "[resume-executor]", "no provider was started"
    assert_equal 1, @platform.requests_to("/api/runner/claim_releases").size
    assert_empty @platform.delivery_acknowledgements, "an unproven resume is never acknowledged"
    assert_empty @platform.requests_to("/api/runner/reports")
    assert_path_exists File.join(@root, ".runs", "worktrees", TASK), "the dirty worktree is preserved"
  end

  def test_a_resume_with_no_recorded_checkpoint_refuses_before_the_provider
    released_question_with_dirty_worktree
    restart_platform(resume_payload({}))
    io = StringIO.new

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(io), io.string
    refute_includes io.string, "[resume-executor]"
    assert_equal 1, @platform.requests_to("/api/runner/claim_releases").size
    assert_empty @platform.requests_to("/api/runner/reports")
  end

  # ----------------------------------------------- acknowledging before the next question

  # CR-004 F3 — the provider's FIRST action is ordinal N+1, before it has printed anything. The
  # batch it is continuing must already be settled by then, or Platform's one-open-batch index
  # refuses a perfectly valid question and the provider is told its request was a duplicate.
  def test_a_silent_resumed_provider_may_ask_its_next_question_as_its_first_action
    checkpoint = released_question_with_dirty_worktree
    restart_platform(resume_payload(checkpoint,
                                    executor: DemoWorkspace.write_silent_resume_executor(@root),
                                    env: { "FAKE_RESUME_NEXT_QUESTION" => BATCH.to_json }))
    @platform.release_question!
    io = StringIO.new

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli(io), io.string

    acknowledged = request_order.index { |method, path| method == "PATCH" && path.start_with?("/api/runner/executor_questions/") }
    asked = request_order.index { |method, path| method == "POST" && path == "/api/runner/executor_questions" }
    refute_nil acknowledged, "the resume was never acknowledged"
    refute_nil asked, "the next question never reached Platform"
    assert_operator acknowledged, :<, asked, "batch N must be RESUMED before ordinal N+1 is submitted"
    assert_equal 1, @platform.delivery_acknowledgements.size
    assert_equal 1, @platform.executor_questions.size
  end

  # CR-004 F3.3 — no output at all, and the work simply finishes. The handoff still happened, so
  # it is still acknowledged, exactly once.
  def test_a_resumed_provider_that_never_prints_is_acknowledged_exactly_once
    checkpoint = released_question_with_dirty_worktree
    restart_platform(resume_payload(checkpoint, executor: DemoWorkspace.write_silent_resume_executor(@root)))
    io = StringIO.new

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli(io), io.string
    assert_equal 1, @platform.delivery_acknowledgements.size
    assert_empty @platform.executor_questions
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
  end

  # CR-004 F3.3 — the process never started, so nothing received the answers and nothing may say
  # it did. The offline batch stays exactly as it was, for the owner to retry.
  def test_a_resumed_provider_that_cannot_be_launched_acknowledges_nothing
    checkpoint = released_question_with_dirty_worktree
    restart_platform(resume_payload(checkpoint, executor: File.join(@root, "bin", "not-installed")))
    io = StringIO.new

    refute_equal SpecrelayRunner::CLI::SUCCESS, run_cli(io), io.string
    assert_empty @platform.delivery_acknowledgements, "a process that never started received nothing"
    assert_empty @platform.executor_questions
    assert_path_exists File.join(@root, ".runs", "worktrees", TASK), "the dirty worktree is preserved"
  end

  # CR-004 F3.4 — Platform answered, but the state that won is not this session's resume: an
  # operator cancelled the run while the fresh process was starting. It is stopped through the
  # existing bounded shutdown before any report, test or publication.
  def test_a_resume_platform_will_not_confirm_stops_the_fresh_process_before_any_report
    checkpoint = released_question_with_dirty_worktree
    restart_platform(resume_payload(checkpoint, executor: DemoWorkspace.write_silent_resume_executor(@root)),
                     delivery: settled_resume("OFFLINE_WAIT"))
    io = StringIO.new

    exit_code = run_cli(io)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_includes io.string, SpecrelayRunner::QuestionBridge::DELIVERY_UNCONFIRMED
    assert_equal 1, @platform.delivery_acknowledgements.size
    assert_empty @platform.requests_to("/api/runner/reports"), "no report follows an unconfirmed resume"
    assert_path_exists File.join(@root, ".runs", "worktrees", TASK), "the dirty worktree is preserved"
  end

  # ------------------------------------------------------------ the proof itself

  def measuring_workspace(dir)
    SpecrelayRunner::Workspace.new(root: dir, canonical_branch: TASK, create_command: "")
  end

  def measure(dir)
    SpecrelayRunner::Checkpoint.measure(repository_key: "tiny-demo-workspace", branch: TASK,
                                        worktree_path: dir, workspace: measuring_workspace(dir))
  end

  def verify(dir, recorded)
    SpecrelayRunner::Checkpoint.verify(recorded, repository_key: "tiny-demo-workspace", branch: TASK,
                                                 worktree_path: dir, workspace: measuring_workspace(dir))
  end

  def git(dir, *args)
    system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) || raise("git #{args.join(' ')} failed")
  end

  def dirty_repository
    dir = Dir.mktmpdir("checkpoint")
    git(dir, "init", "-q", "-b", TASK)
    File.write(File.join(dir, "index.html"), "Hello Demo\n")
    git(dir, "add", "-A")
    git(dir, "-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-qm", "initial")
    git(dir, "remote", "add", "origin", "https://github.com/SpecRelay/tiny-demo-workspace.git")
    File.write(File.join(dir, "index.html"), "Hello Changed Demo\n")
    dir
  end

  # A06 — every term is compared, and each mismatch names itself so an operator knows which fact
  # about their machine stopped the resume.
  def test_every_recorded_term_must_match_the_machine
    dir = dirty_repository
    recorded = measure(dir)

    assert verify(dir, recorded).ok?, verify(dir, recorded).reason
    SpecrelayRunner::Checkpoint::FIELDS.each do |field|
      result = verify(dir, recorded.merge(field => "#{recorded[field]}x"))

      refute result.ok?, "a differing #{field} must refuse"
      assert_includes result.reason, field
    end
    assert_equal "github.com/specrelay/tiny-demo-workspace", recorded["origin"],
                 "the origin travels as a normalized identity, never a URL"
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  # A05 — the three ways the machine has nothing left to prove: it was never measured, the
  # changes are gone, and the checkout is not there at all.
  def test_a_missing_clean_or_absent_worktree_refuses
    dir = dirty_repository
    recorded = measure(dir)

    assert_includes verify(dir, {}).reason, "no checkpoint"

    git(dir, "checkout", "--", "index.html")
    assert_includes verify(dir, recorded).reason, "change_digest"

    empty = Dir.mktmpdir("not-a-repository")
    refute verify(empty, recorded).ok?
    assert_includes verify(empty, recorded).reason, "no git repository"
  ensure
    FileUtils.remove_entry(dir) if dir
    FileUtils.remove_entry(empty) if empty
  end

  def test_an_unmeasurable_worktree_records_no_checkpoint_at_all
    assert_nil measure(File.join(Dir.mktmpdir("gone"), "missing"))
  end
end
