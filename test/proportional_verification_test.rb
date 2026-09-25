# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "open3"

# MAPIAI-93 proof for AI-DIRECTED PROPORTIONAL verification, end to end over the real HTTP
# boundary, against real independent git repositories with their own verification.
#
# The subject is the replacement of ONE configured workspace test command by per-changed-
# repository verification the executor selects and the runner independently replays. The
# assignment carries no test command at all; a repository with no verification is a valid,
# non-blocking `not_found`; and a repository whose verification fails publishes nothing.
#
# Scenarios: S01/S12 (no configured command anywhere), S02 (no verification found), S03 (focused
# verification passes), S04 (mixed multi-repository result), S05 (the executor repairs before it
# exits), S06 (unresolved failure blocks publication), S08 (repository-local cwd and final
# files), S10 (clean no-change run).
#
# CR-001 F1 adds the state-stability boundary: a command that SUCCEEDS may still leave the
# repository in a different publishable state than the one that was measured and verified, and
# publishing that would commit files the report's own diff does not describe.
class ProportionalVerificationTest < Minitest::Test
  # The one directory on the child PATH that provides the approved fixture name. The PAYLOAD is
  # always the canonical fixture profile; which script that approved name resolves to on this
  # host is the test's choice, exactly as it is the operator's choice on a real machine.
  def fixture_dir = @fixture_dir ||= fixture_bin
  TASK = "MAPIAI-93"
  BRANCH = TASK
  WORKSPACE_SLUG = "SpecRelay/multi-demo-workspace"
  PR_URLS = {
    "SpecRelay/component-a" => "https://github.com/SpecRelay/component-a/pull/31",
    "SpecRelay/component-b" => "https://github.com/SpecRelay/component-b/pull/32",
    "SpecRelay/component-c" => "https://github.com/SpecRelay/component-c/pull/33",
    WORKSPACE_SLUG => "https://github.com/SpecRelay/multi-demo-workspace/pull/34"
  }.freeze

  def setup
    @built = MultiRepositoryWorkspace.build
    @root = @built.root
    @bares = { "SpecRelay/component-a" => @built.bares["component-a"],
               "SpecRelay/component-b" => @built.bares["component-b"],
               "SpecRelay/component-c" => @built.bares["component-c"],
               WORKSPACE_SLUG => @built.bares["."] }
    @gh_dir, @gh_log, = FakeGithub.gh_bin(urls: PR_URLS, bares: @bares)
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # --- harness -------------------------------------------------------------

  # `fixture_env` is the environment the double runs under on this host, installed behind the
  # approved bare name on the child PATH. A nil value REMOVES a default, which is how a test says
  # "this executor did not run its own selection" — the case that isolates the runner's
  # independent replay.
  def start(fixture_env: {})
    use_fixture(fixture_dir, @built.executor,
                env: { "FAKE_EXECUTOR_EDITED" => "component-a,component-b",
                       "FAKE_EXECUTOR_RUN_SELECTED" => "1" }.merge(fixture_env).compact)
    payload = claim_payload_for(task_id: TASK, publication: {}, root: @root,
                                specification_repository: "component-c")
    @platform = FakePlatform.new(claim_payload: payload).start
    @config_path = write_config
    payload
  end

  def write_config
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
    path
  end

  def run_cli
    io = StringIO.new
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
            "PATH" => "#{fixture_dir}:#{@gh_dir}:#{ENV['PATH']}", "HOME" => ENV["HOME"].to_s }
    code = SpecrelayRunner::CLI.run(%W[claim-once --config #{@config_path}], out: io, err: io, env: env)
    [ code, io.string ]
  end

  def terminal = @platform.last_terminal_result
  def branches_of(slug) = FakeGithub.remote_branches(@bares.fetch(slug))
  def manifest = YAML.safe_load(report_file("manifest.yml"))
  def verifications = Array(manifest["repository_verifications"])
  def verification_for(path) = verifications.find { |entry| entry["repository_path"] == path }
  def statuses = verifications.to_h { |entry| [ entry["repository_path"], entry["status"] ] }

  def report_file(relative)
    report = @platform.last_report[:body].fetch("report")
    file = report["files"].find { |candidate| candidate["relative_path"] == relative }
    file && Base64.strict_decode64(file["content_base64"])
  end

  # --- S01 / S12: no configured test command exists anywhere ---------------

  def test_the_assignment_carries_no_configured_test_command
    payload = start

    refute payload.fetch("workspace").key?("test_command"),
           "verification is selected per changed repository; the project configures none"
    assert_equal %w[default_branch display_name project_key repository_url workspace_key
                    worktree_create_command worktree_release_command],
                 payload.fetch("workspace").keys.sort
  end

  # AC-5 — the instruction and the act, separately. The prompt is the ONE channel that can tell
  # the executor to repair before it returns, so the instruction reaching it is a fact worth
  # asserting rather than assuming from a passing replay.
  def test_the_executor_is_instructed_to_run_diagnose_repair_and_rerun_before_it_exits
    start
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    stdout = report_file("evidence/stdout.log")
    assert_match(/instructions - Run what you select, diagnose any failure/, stdout)
    # And it really ran what it selected, in the repository that owns it.
    assert_match(/ran bin\/verify in component-a: passed/, stdout)
    assert_match(/ran bin\/verify in component-b: passed/, stdout)
  end

  # The replay starts each reported argv in a fresh process, so the executor has to be told that
  # session-only activation does not carry over and that the project's own entrypoint selects its
  # runtime — otherwise it passes in its shell and fails, or silently falls back, on replay.
  def test_the_executor_is_instructed_to_report_complete_project_owned_commands
    start
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    stdout = report_file("evidence/stdout.log")
    assert_match(/entrypoint - Run installation, build and tests through the repository's own complete entrypoint/,
                 stdout)
  end

  # --- S03 / S08: focused verification, replayed where it belongs ----------

  def test_a_selected_command_is_replayed_from_the_repository_against_the_final_files
    start
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    assert_equal "succeeded", terminal["outcome"]
    assert_equal({ "component-a" => "passed", "component-b" => "passed" }, statuses)

    entry = verification_for("component-a")
    # CR-001 F2 — the EXACT keys this runner emits. Platform enforces the same closed set
    # (ExecutionReports::VerificationResults), and the two codebases share no code, so each side
    # pins its own half: a key added here without adding it there fails at import instead of
    # silently widening a durable contract.
    assert_equal %w[commands repository_id repository_path status], entry.keys.sort
    assert_equal %w[argv exit_status output_summary timed_out], entry.fetch("commands").first.keys.sort
    assert_equal [ %w[bin/verify] ], entry.fetch("commands").map { |command| command.fetch("argv") }
    assert_equal [ 0 ], entry.fetch("commands").map { |command| command.fetch("exit_status") }
    # `bin/verify` reads `app.txt` relatively and demands the executor's final marker, so it can
    # only pass when the runner launched it in that repository, after the edit.
    assert_includes entry.fetch("commands").first.fetch("output_summary"), "verify passed"
    assert_includes entry.fetch("commands").first.fetch("output_summary"), "component-a"

    # Verification is a gate BEFORE publication, and publication still happened.
    assert_equal PR_URLS.fetch("SpecRelay/component-a"),
                 terminal["repositories"].find { |r| r["id"] == "SpecRelay/component-a" }["pull_request_url"]
  end

  def test_an_untouched_repository_never_appears_in_the_verification_result
    start
    run_cli

    refute verification_for("component-c"), "component-c was not changed, so it has no outcome"
    refute verification_for("."), "the workspace repository was not changed either"
  end

  # --- S02 / S04: no verification found, and a mixed result ----------------

  def test_a_changed_repository_with_no_verification_is_not_found_and_still_publishes
    start(fixture_env: { "FAKE_EXECUTOR_COMMANDS" => JSON.generate({ "component-b" => [] }) })
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    assert_equal "succeeded", terminal["outcome"], "no verification found never blocks a run"
    assert_equal({ "component-a" => "passed", "component-b" => "not_found" }, statuses)

    assert_empty verification_for("component-b").fetch("commands"),
                 "not_found must never be dressed up as a fabricated passing command"
    assert_equal PR_URLS.fetch("SpecRelay/component-b"),
                 terminal["repositories"].find { |r| r["id"] == "SpecRelay/component-b" }["pull_request_url"]
  end

  def test_each_repository_uses_its_own_independent_plan
    start(fixture_env: { "FAKE_EXECUTOR_COMMANDS" => JSON.generate(
      { "component-a" => [ %w[bin/verify], [ "sh", "-c", "exit 0" ] ], "component-b" => [] }
    ) })
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    assert_equal 2, verification_for("component-a").fetch("commands").length
    assert_empty verification_for("component-b").fetch("commands")
  end

  # --- S05: the executor repairs before it returns -------------------------

  def test_the_executor_repairs_a_failure_and_the_runner_replay_observes_the_final_pass
    start(fixture_env: { "FAKE_EXECUTOR_BREAK" => "component-b", "FAKE_EXECUTOR_REPAIR" => "1" })
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    stdout = report_file("evidence/stdout.log")
    assert_match(/ran bin\/verify in component-b: failed/, stdout, "the executor saw its own failure")
    assert_match(/repaired component-b and reran bin\/verify: passed/, stdout)

    assert_equal({ "component-a" => "passed", "component-b" => "passed" }, statuses)
    assert_equal "succeeded", terminal["outcome"]
  end

  # --- S06: an unresolved failure publishes nothing ------------------------

  def test_an_unresolved_failure_is_failed_and_prevents_every_external_write
    start(fixture_env: { "FAKE_EXECUTOR_BREAK" => "component-b" })
    run_cli

    assert_equal "failed", terminal["outcome"]
    assert_equal "verification_failed", terminal.dig("core", "error_classification")
    assert_equal({ "component-a" => "passed", "component-b" => "failed" }, statuses)

    # The report still carries the bounded, redacted diagnostics for the repository that failed.
    failed = verification_for("component-b").fetch("commands").first
    assert_equal 1, failed.fetch("exit_status")
    assert_includes failed.fetch("output_summary"), "verify failed"

    # Nothing was pushed, no pull request was created, and no repository result was asserted.
    @bares.each_key { |slug| assert_empty branches_of(slug), "#{slug} must not be pushed" }
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
    assert_equal "failed", manifest["execution_status"]
    refute manifest["final_jira_update_ready"], "a failed verification never finalizes the ticket"
  end

  # A passing repository beside a failing one is NOT published either: publication is all-or-fail,
  # so a partially verified run must not leave a half-published output for review.
  def test_a_passing_repository_beside_a_failing_one_is_not_published
    start(fixture_env: { "FAKE_EXECUTOR_BREAK" => "component-b" })
    run_cli

    assert_empty branches_of("SpecRelay/component-a")
    assert_empty Array(terminal["repositories"]).map { |repo| repo["pull_request_url"] }.compact
  end

  # --- CR-001 F1: verification must not change the publishable state -------

  def failure_reason
    YAML.safe_load(report_file("manifest.yml")).to_s
  end

  def assert_no_external_write
    @bares.each_key { |slug| assert_empty branches_of(slug), "#{slug} must not be pushed" }
    assert_equal 0, FakeGithub.pr_creates(@gh_log), "a refused attempt creates no pull request"
    assert_equal "failed", manifest["execution_status"]
    refute manifest["final_jira_update_ready"]
    assert_empty Array(terminal["repositories"]).map { |repo| repo["pull_request_url"] }.compact
  end

  # The formatter/snapshot case: exit zero, but a tracked file is no longer what was measured.
  # Publication runs `git add -A`, so committing here would publish content absent from the
  # report's own diff.
  def test_a_zero_exit_command_that_rewrites_a_tracked_file_fails_before_any_external_write
    start(fixture_env: { "FAKE_EXECUTOR_COMMANDS" => JSON.generate({ "component-a" => [ %w[bin/mutate] ] }),
                          "FAKE_EXECUTOR_RUN_SELECTED" => nil })
    run_cli

    assert_equal "failed", terminal["outcome"]
    assert_equal "verification_changed_publishable_state", terminal.dig("core", "error_classification")
    assert_match(/component-a/, failure_reason, "the refusal must name the repository that drifted")
    refute_match(/rewritten by the verification command/, failure_reason,
                 "the reason is bounded: it names the repository, never the content")
    assert_no_external_write
  end

  # HEAD moved out from under the measurement. The tree is clean afterwards, so a run that
  # accepted this would publish a commit nobody measured.
  def test_a_command_that_commits_moves_head_and_fails_closed
    start(fixture_env: { "FAKE_EXECUTOR_COMMANDS" => JSON.generate({ "component-b" => [ %w[bin/commit-it] ] }),
                          "FAKE_EXECUTOR_RUN_SELECTED" => nil })
    run_cli

    assert_equal "failed", terminal["outcome"]
    assert_equal "verification_changed_publishable_state", terminal.dig("core", "error_classification")
    assert_no_external_write
  end

  # A selected repository that becomes clean has nothing left to publish. The re-verification
  # refuses it by the same rule the first selection would have, and that refusal is the drift.
  def test_a_command_that_reverts_the_change_leaves_nothing_to_publish_and_fails_closed
    start(fixture_env: { "FAKE_EXECUTOR_COMMANDS" => JSON.generate({ "component-a" => [ %w[bin/revert-it] ] }),
                          "FAKE_EXECUTOR_RUN_SELECTED" => nil })
    run_cli

    assert_equal "failed", terminal["outcome"]
    assert_equal "verification_changed_publishable_state", terminal.dig("core", "error_classification")
    assert_no_external_write
  end

  # Ignored scratch output is not publishable state, so it must NOT fail the run. Without this the
  # fail-closed rule would break every real test command that writes a log or a coverage report.
  def test_a_command_writing_only_git_ignored_output_still_passes_and_publishes
    start(fixture_env: { "FAKE_EXECUTOR_COMMANDS" => JSON.generate(
      { "component-a" => [ %w[bin/verify], %w[bin/verify-ignored] ], "component-b" => [ %w[bin/verify] ] }
    ) })
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    assert_equal "succeeded", terminal["outcome"]
    assert_equal({ "component-a" => "passed", "component-b" => "passed" }, statuses)
    assert_equal PR_URLS.fetch("SpecRelay/component-a"),
                 terminal["repositories"].find { |r| r["id"] == "SpecRelay/component-a" }["pull_request_url"]
  end

  # The stability gate belongs only to the path that would otherwise publish. An ordinary command
  # failure already blocks publication, and its own reason must not be replaced by a drift reason.
  def test_an_ordinary_command_failure_still_reports_its_own_cause
    start(fixture_env: { "FAKE_EXECUTOR_BREAK" => "component-b" })
    run_cli

    assert_equal "failed", terminal["outcome"]
    assert_equal "verification_failed", terminal.dig("core", "error_classification")
    assert_equal({ "component-a" => "passed", "component-b" => "failed" }, statuses)
  end

  # --- S10: a clean run with nothing to verify -----------------------------

  # An empty collection and a `not_found` repository are different facts: nothing changed, versus
  # something changed and had no verification. The clean run must state the first without
  # borrowing the second's vocabulary.
  def test_a_clean_no_change_run_reports_an_empty_verification_collection
    start(fixture_env: { "FAKE_EXECUTOR_EDITED" => "" })
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    assert_equal "succeeded", terminal["outcome"]
    assert_equal [], verifications,
                 "no repository changed, so there is no repository to report an outcome for"
    refute_includes report_file("manifest.yml"), "not_found"
    assert_empty Array(terminal["repositories"])
  end
end
