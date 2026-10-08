# frozen_string_literal: true

require_relative "test_helper"

# What a session does when Platform rejects an execution report it could not import.
#
# Platform answers that one rejection with a typed 422: it has already ended the attempt, so the
# run is incomplete and will not be offered again. That is an ordinary failed run, not a refusal of
# this terminal's claim — the session records it and, under the continue policy, goes on to
# different work. Every other refusal of the same endpoint keeps the ending it had.
class ReportImportRejectionTest < Minitest::Test
  Client = SpecrelayRunner::PlatformClient
  CLI = SpecrelayRunner::CLI

  REJECTION = "secret-like file name rejected: scenarios/04-example.md"
  TYPED = [ 422, { error: REJECTION, outcome: "report_failed" } ].freeze
  UNTYPED = [ 422, { error: "terminal_result rejected: final_sequence is missing" } ].freeze

  def setup
    @root, executor = DemoWorkspace.build
    @fixture_dir = fixture_bin
    use_fixture(@fixture_dir, executor)
    bare = FakeGithub.add_remote(@root)
    @gh_dir, = FakeGithub.gh_bin(bare: bare)
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # ---- the client keeps the typed outcome, and only that one is the rejection ----

  def test_only_a_typed_422_is_a_report_rejection
    assert_predicate upload_error(TYPED), :report_rejected?
    refute_predicate upload_error(UNTYPED), :report_rejected?
    refute_predicate upload_error([ 409, { error: "x", outcome: "report_failed" } ]), :report_rejected?
  end

  def test_credential_and_unknown_claim_refusals_are_unchanged
    unauthorized = upload_error([ 401, { error: "invalid_token", outcome: "report_failed" } ])
    not_found = upload_error([ 404, { error: "unknown claim" } ])

    assert_kind_of Client::Unauthorized, unauthorized
    assert_kind_of Client::NotFound, not_found
    refute_predicate unauthorized, :report_rejected?
    refute_predicate not_found, :report_rejected?
    assert_predicate not_found, :refused?
  end

  # ---- the loop: continue past the rejected run, to different work ----

  def test_a_rejected_report_is_a_failed_run_and_the_session_claims_different_work
    code, output = run_loop(policy: "continue", first_report: TYPED)

    assert_equal CLI::RUN_FAILED, code, output
    assert_includes output, "Platform rejected the execution report for DEMO-A"
    assert_includes output, REJECTION
    assert_includes output, "incomplete and was not accepted"
    assert_includes output, "Runner outcome: report_failed"
    assert_includes output, "continuing to poll (--on-failure continue)"
    refute_includes output, "Platform refused this terminal's claim"
    assert_includes output, "session totals — 2 run(s) executed"
    assert_equal 1, output.scan("run FAILED").size, "only the rejected run failed"
    assert_includes output, "Runner outcome: completed.", "the second run is processed in the same session"

    reports = @platform.requests_to("/api/runner/reports")
    assert_equal %w[rex_DEMO-A rex_DEMO-B], reports.map { |request| request.dig(:body, "claim") },
                 "the rejected report is uploaded once and never resent"
    assert_empty @platform.requests_to("/api/runner/claim_releases"), "the rejected claim is not released"
    assert_path_exists worktree("DEMO-A"), "the rejected run's task environment is kept"
    refute File.directory?(worktree("DEMO-B")), "the accepted run releases its environment as before"
  end

  def test_the_stop_policy_still_stops_after_the_rejected_run
    code, output = run_loop(policy: "stop", first_report: TYPED)

    assert_equal CLI::RUN_FAILED, code, output
    assert_includes output, "stopping after a failed run (--on-failure stop)"
    assert_equal 1, @platform.requests_to("/api/runner/claim").size
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
  end

  # Any other 422 of the report endpoint keeps the ending it has today.
  def test_an_untyped_report_refusal_still_stops_the_session
    code, output = run_loop(policy: "continue", first_report: UNTYPED)

    assert_equal CLI::RUN_FAILED, code, output
    assert_includes output, "Platform refused this terminal's claim"
    refute_includes output, "Platform rejected the execution report"
    assert_equal 1, @platform.requests_to("/api/runner/claim").size
  end

  private

  def worktree(task_id) = File.join(@root, ".runs", "worktrees", task_id)

  def upload_error(answer)
    @platform&.stop
    @platform = FakePlatform.new(claim_payload: {}).start
    @platform.report_response = answer
    client = Client.new(base_url: @platform.base_url, token: FakePlatform::EXPECTED_TOKEN)
    assert_raises(Client::Error) { client.submit_report(claim: "rex", bundle: { files: [ "x" ] }) }
  end

  def payload(task_id)
    claim_payload_for(task_id: task_id, publication: {}, root: @root)
      .merge("claim" => { "runner_execution_id" => "rex_#{task_id}", "claim_policy_mode" => "all_eligible" })
      .tap { |assignment| assignment["run"] = assignment["run"].merge("id" => "run_#{task_id}") }
  end

  # The real CLI -> LoopRunner -> Execution path. `claim_limit` bounds a session that failed to
  # stop: past it the fake answers 401, which ends any loop.
  def run_loop(policy:, first_report:)
    @platform = FakePlatform.new(claim_payload: {}, claim_limit: 2).start
    @platform.queue_claims([ payload("DEMO-A"), payload("DEMO-B") ])
    @platform.report_responses = [ first_report ]
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
    io = StringIO.new
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
            "PATH" => "#{@fixture_dir}:#{@gh_dir}:#{ENV['PATH']}", "HOME" => ENV["HOME"].to_s }
    code = CLI.run(%W[loop --config #{path} --poll-interval 5 --on-failure #{policy}], out: io, err: io, env: env)
    [ code, io.string ]
  end
end
