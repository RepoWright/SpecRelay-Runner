# frozen_string_literal: true

require_relative "test_helper"
require "base64"

# Resuming an answered offline question — on the machine that still holds the uncommitted work,
# and on one that has to restore it first.
#
# The cases here run the whole CLI against a REAL git worktree: once to leave a dirty worktree and
# a recorded portable checkpoint behind, and again to continue from it. The package's own capture
# and restore boundaries are proven in `portable_checkpoint_test.rb`; what these prove is the
# WIRING — that the assignment's checkpoint is what a fresh session lands on, and that a claim
# refuses before any provider whenever it is not.
class QuestionResumeTest < Minitest::Test
  # The one directory on the child PATH that provides the approved fixture name. The PAYLOAD is
  # always the canonical fixture profile; which script that approved name resolves to on this
  # host is the test's choice, exactly as it is the operator's choice on a real machine.
  def fixture_dir = @fixture_dir ||= fixture_bin
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
    @second = nil
    # Every real SpecRelay workspace is a clone, and the checkpoint's normalized origin is what
    # proves a resume is landing on the same repository rather than on a look-alike, so the
    # fixture carries one. Nothing is ever pushed to it.
    git(@root, "remote", "set-url", "origin", "https://github.com/SpecRelay/tiny-demo-workspace.git")
    @platform = nil
  end

  def teardown
    @platform&.stop
    [ @root, @second ].compact.each { |root| FileUtils.remove_entry(root) if File.directory?(root) }
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

  # What the double asks and how it behaves are host-side controls installed behind the approved
  # bare name; the assignment is always the canonical fixture profile.
  def question_payload(executor)
    use_fixture(fixture_dir, executor,
                env: { "FAKE_EXECUTOR_QUESTION_JSON" => BATCH.to_json,
                       "FAKE_EXECUTOR_QUESTION_TIMEOUT_SECONDS" => "5",
                       "FAKE_EXECUTOR_QUESTION_EDIT_FIRST" => "1" })
    claim_payload_for(task_id: TASK).merge("specification_package" => approved_package)
  end

  # Committed ONCE, into the first machine, before anything clones it. Both phases and both
  # machines then name the same commit: the second machine is a clone, so re-committing the
  # package there would move its history past the base the checkpoint recorded.
  def approved_package = @approved_package ||= specification_package_block(TASK, root: @root)

  # Phase two: the same run, claimed again, carrying the answers and the recorded checkpoint —
  # metadata and the one claim-bound download path, never the bytes.
  def resume_payload(checkpoint, executor: nil, env: {}, root: @root)
    executor ||= DemoWorkspace.write_resume_executor(root)
    use_fixture(fixture_dir, executor, env: env)
    claim_payload_for(task_id: TASK).merge("specification_package" => approved_package).merge(
      "resume" => { "question_id" => "exq_fake", "checkpoint" => assigned(checkpoint),
                    "continuation_context" => BATCH["continuation_context"],
                    "questions" => BATCH["questions"], "answers" => ANSWERS }
    )
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

  # A SECOND machine: the same repository, cloned, carrying the same origin identity and the same
  # base commit, and holding no worktree for the branch at all.
  def second_machine
    @second = Dir.mktmpdir("specrelay-runner-second-")
    FileUtils.remove_entry(@second)
    system("git", "clone", "-q", @root, @second, exception: true)
    git(@second, "config", "user.email", "runner@example.test")
    git(@second, "config", "user.name", "Runner Test")
    git(@second, "remote", "set-url", "origin", "https://github.com/SpecRelay/tiny-demo-workspace.git")
    @second
  end

  def run_cli_in(root, io)
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
        tiny-demo-workspace: #{root}
    YAML
    SpecrelayRunner::CLI.run(%W[claim-once --config #{path}], out: io, err: io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
                                    "PATH" => @child_path || "#{fixture_dir}:#{ENV['PATH']}" })
  end

  # What Platform puts in the assignment: everything the runner must prove, plus where to fetch
  # the package, and NOT the package itself.
  def assigned(checkpoint)
    return checkpoint if checkpoint.empty?

    checkpoint.reject { |key, _| key == "payload" }
              .merge("download_path" => "/api/runner/executor_questions/exq_fake/checkpoint")
  end

  def request_order
    @platform.requests.map { |request| [ request[:method], request[:path] ] }
  end

  def run_cli(io) = run_cli_in(@root, io)

  # A real `codex` that exits at once without reading stdin.
  def deaf_codex_bin
    dir = Dir.mktmpdir("deaf-codex-")
    path = File.join(dir, "codex")
    File.write(path, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, path)
    dir
  end

  # Every PATH entry that does NOT hold an executable named `codex`, so this deterministic suite
  # can never reach the operator's real CLI.
  def self.path_without_codex
    @path_without_codex ||= ENV["PATH"].to_s.split(File::PATH_SEPARATOR).reject do |dir|
      dir.strip.empty? || File.executable?(File.join(dir, "codex"))
    end.join(File::PATH_SEPARATOR)
  end

  def git(dir, *args)
    system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) || raise("git #{args.join(' ')} failed")
  end

  # A04/A07 — the whole loop: measure at ask time, prove the same worktree at resume time, hand a
  # FRESH provider the complete public handoff, and tell Platform once that it arrived.
  def test_a_verified_resume_starts_a_fresh_session_with_the_answers_and_reports_them_delivered
    checkpoint = released_question_with_dirty_worktree
    assert_equal %w[byte_size digest format payload repositories], checkpoint.keys.sort
    assert_equal SpecrelayRunner::Checkpoint::FORMAT, checkpoint["format"]
    entry = checkpoint["repositories"].fetch(0)
    assert_equal ".", entry["path"]
    assert_equal "SpecRelay/tiny-demo-workspace", entry["origin"]
    assert_equal TASK, entry["branch"]
    assert_match(/\A[0-9a-f]{40}\z/, entry["base"])
    assert_match(/\A[0-9a-f]{40}\z/, entry["checkpoint_commit"])
    assert_match(/\A[0-9a-f]{64}\z/, entry["change_digest"])
    refute_includes checkpoint.reject { |key, _| key == "payload" }.to_json, @root,
                    "the checkpoint metadata carries no local path"

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
                                    env: { "FAKE_EXECUTOR_RESUME_NEXT_QUESTION" => BATCH.to_json }))
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
  # The claimed profile is the CANONICAL Codex one and `codex` is absent from the child PATH, which
  # is how a provider that cannot be launched really presents itself. A payload naming an
  # arbitrary missing path is refused before the launch and would prove nothing about this path.
  def test_a_resumed_provider_that_cannot_be_launched_acknowledges_nothing
    checkpoint = released_question_with_dirty_worktree
    restart_platform(resume_payload(checkpoint).merge("executor" => SpecrelayRunner::CodexProfile::CANONICAL))
    io = StringIO.new
    @child_path = self.class.path_without_codex

    refute_equal SpecrelayRunner::CLI::SUCCESS, run_cli(io), io.string
    assert_empty @platform.delivery_acknowledgements, "a process that never started received nothing"
    assert_empty @platform.executor_questions
    assert_path_exists File.join(@root, ".runs", "worktrees", TASK), "the dirty worktree is preserved"
  end

  # CR-005 F2 — the provider process started but never read the prompt carrying the answers. No
  # session received them, so nothing may say one did, and the run must stay retryable: no tests,
  # no report, no publication, and the claim handed straight back.
  #
  # The CANONICAL Codex profile already delivers its prompt on stdin. A `codex` double that exits
  # without ever reading its input, with a prompt larger than the pipe buffer, makes the failed
  # handoff deterministic rather than timing-dependent.
  def test_a_resume_whose_prompt_never_reaches_the_provider_acknowledges_nothing
    checkpoint = released_question_with_dirty_worktree
    payload = resume_payload(checkpoint).merge("executor" => SpecrelayRunner::CodexProfile::CANONICAL)
    payload["specification_package"]["handoff_prompt"] = "x" * 200_000
    restart_platform(payload)
    io = StringIO.new
    @child_path = "#{deaf_codex_bin}:#{self.class.path_without_codex}"

    exit_code = run_cli(io)

    refute_equal SpecrelayRunner::CLI::SUCCESS, exit_code, io.string
    assert_empty @platform.delivery_acknowledgements,
                 "a process that never received the answers is never acknowledged"
    assert_empty @platform.requests_to("/api/runner/reports"),
                 "no report follows a resume no provider ever read"
    assert_equal 1, @platform.requests_to("/api/runner/claim_releases").size
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

  # ------------------------------------------------- a machine that never saw the work

  # A01, scenario 8 — the whole point of a PORTABLE checkpoint: a second machine with no worktree
  # for this branch downloads the recorded package, builds the task workspace with the project's
  # own command, restores the work, and hands a fresh provider the answers.
  def test_a_second_machine_downloads_the_checkpoint_builds_the_workspace_and_continues
    checkpoint = released_question_with_dirty_worktree
    other = second_machine
    restart_platform(resume_payload(checkpoint, root: other))
    @platform.checkpoint_payload = checkpoint["payload"]
    io = StringIO.new

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli_in(other, io), io.string

    assert_includes io.string, "[resume-executor] resumed"
    assert_includes io.string, "Match the finance spreadsheets."
    assert_includes io.string, "[resume-executor] applied edit"
    assert_equal 1, @platform.requests_to("/api/runner/executor_questions/exq_fake/checkpoint").size
    assert_equal 1, @platform.delivery_acknowledgements.size
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
    # The restored work really was the paused work: the fresh provider could only produce this
    # heading by editing the interrupted one it was handed. Read from the change set measured into
    # the report, because a recorded result then hands the environment back.
    diff = @platform.last_report[:body].dig("report", "files").find { |f| f["relative_path"] == "evidence/diff.txt" }
    assert_includes Base64.strict_decode64(diff.fetch("content_base64")), "Hello Resumed Demo"
  end

  # Scenario 10 — the package could not be transferred. Nothing was built, no provider started,
  # the claim went straight back, and the durable checkpoint is untouched for the next attempt.
  def test_a_transfer_failure_refuses_before_a_workspace_is_built
    checkpoint = released_question_with_dirty_worktree
    other = second_machine
    restart_platform(resume_payload(checkpoint, root: other))
    @platform.checkpoint_response = [ 503, { error: "storage is unavailable" } ]
    io = StringIO.new

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli_in(other, io), io.string

    assert_includes io.string, "could not be downloaded"
    refute_includes io.string, "[resume-executor]", "no provider was started"
    assert_equal 1, @platform.requests_to("/api/runner/claim_releases").size
    assert_empty @platform.requests_to("/api/runner/reports")
    assert_empty @platform.delivery_acknowledgements
    refute_path_exists File.join(other, ".runs", "worktrees", TASK),
                       "a failed transfer must not leave a task workspace behind"
  end

  # Scenario 9 — the second machine is not at the recorded base. It refuses before the provider
  # and leaves the target exactly as it found it.
  def test_a_second_machine_that_is_not_at_the_recorded_base_refuses
    checkpoint = released_question_with_dirty_worktree
    other = second_machine
    File.write(File.join(other, "demo-app", "index.html"), "<h1>Somewhere Else</h1>\n")
    git(other, "add", "-A")
    git(other, "-c", "user.email=t@e.test", "-c", "user.name=T", "commit", "-q", "-m", "moved on")
    restart_platform(resume_payload(checkpoint, root: other))
    @platform.checkpoint_payload = checkpoint["payload"]
    io = StringIO.new

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli_in(other, io), io.string

    assert_includes io.string, "base commit"
    refute_includes io.string, "[resume-executor]", "no provider was started"
    assert_equal 1, @platform.requests_to("/api/runner/claim_releases").size
    assert_empty @platform.requests_to("/api/runner/reports")
  end
end
