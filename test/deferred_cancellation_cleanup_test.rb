# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# A question pause ends the provider session and frees the loop, but the Run's task environment
# stays with this machine. When Platform cancels that Run later — while the loop runs on, or
# while this machine is offline — no claim or heartbeat reaches it. So before each claim the
# connected loop offers its project's Run-owned environments to Platform, and releases the one
# Platform names through the project's own run-qualified release, before it claims anything.
#
# Driven through the real loop, the CLI's own pre-claim step and the real HTTP client against
# the fake Platform, on a real git worktree allocated and released by the project's own
# `bin/worktree`.
class DeferredCancellationCleanupTest < Minitest::Test
  CREDENTIAL = "src_deferred-cleanup-credential"
  KEY = "tiny-demo-workspace"
  RUN = "run_paused"
  TASK = "DEMO-0401"

  # Platform with nothing to hand out: every claim is answered "nothing ready", so a session ends
  # after the polls a test asks for and never executes anything.
  class IdlePlatform < FakePlatform
    def script_claim_failure_once = @claim_failure = true

    private

    def claim
      return [ 200, { claimed: false, reason: "no eligible work" } ] unless @claim_failure

      @claim_failure = false
      [ 500, { error: "internal" } ]
    end
  end

  def setup
    @root, = DemoWorkspace.build
    FileUtils.mkdir_p(File.join(@root, ".runs"))
    @platform = IdlePlatform.new(claim_payload: {}, token: CREDENTIAL).start
    @io = StringIO.new
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # ------------------------------------------------------------------- discovery

  # Scenario 1. The loop stays online after the pause; a later poll learns of the cancellation,
  # releases the environment, and only then claims. The poll after that offers nothing: the
  # project no longer lists the environment.
  def test_an_online_loop_releases_after_platform_reports_the_cancellation_and_then_claims
    allocate(TASK, RUN)
    @platform.script_cleanup_targets([ 200, { target: nil } ], target(RUN, TASK))

    assert_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 3), @io.string

    assert_equal %w[target claim target claim claim], exchanges
    assert_equal [ [ { "run_id" => RUN, "task_id" => TASK } ] ] * 2, offered_candidates
    refute File.directory?(worktree(TASK)), "the cancelled Run's environment was kept"
    assert_nil ProjectCommand.recorded_owner(@root, TASK)
  end

  # Scenario 2. A restarted loop has no claim token for the paused attempt; the project record
  # alone is enough to be offered and released before the first claim.
  def test_a_restarted_loop_releases_before_its_first_claim_without_any_claim_token
    allocate(TASK, RUN)
    @platform.script_cleanup_targets(target(RUN, TASK))

    assert_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 1), @io.string

    assert_equal %w[target claim], exchanges
    assert_empty @platform.requests_to("/api/runner/heartbeat")
    refute_includes @platform.requests_to("/api/runner/cancellation_cleanup_target").first[:body].keys, "claim"
    refute File.directory?(worktree(TASK))
  end

  # Scenario 3. Only listed Run-owned environments are offered, and only the one Platform names is
  # released; another owned one, a manual one and a shared runtime file are untouched.
  def test_only_the_named_environment_is_released
    allocate(TASK, RUN)
    allocate("DEMO-0402", "run_still_waiting")
    allocate("DEMO-0403", nil)
    shared = File.join(@root, ".runs", "shared-service.state")
    File.write(shared, "shared database handle\n")
    before = snapshot(%w[DEMO-0402 DEMO-0403], shared)
    @platform.script_cleanup_targets(target(RUN, TASK))

    assert_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 1), @io.string

    offered = offered_candidates.first.map { |pair| pair["task_id"] }.sort
    assert_equal [ TASK, "DEMO-0402" ], offered, "a manual environment was offered"
    refute File.directory?(worktree(TASK))
    assert_equal before, snapshot(%w[DEMO-0402 DEMO-0403], shared)
  end

  # Scenario 9. A release the project answers with its proof of absence completes too.
  def test_a_project_proved_absence_completes_the_cleanup
    list_also(TASK, RUN)
    @platform.script_cleanup_targets(target(RUN, TASK))

    assert_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 1), @io.string

    assert_equal %w[target claim], exchanges
  end

  # ------------------------------------------------------------------- retention

  # Scenario 4 and 7. Every answer that proves nothing keeps the environment and stops the
  # session, so no later poll claims either. Each session is given a second poll whose lookup
  # would answer "no target", which a session that only backed off would go on to claim after.
  def test_an_answer_that_proves_nothing_keeps_the_environment_and_stops_before_any_claim
    { "malformed target" => [ 200, { target: "run_paused" } ],
      "missing task" => [ 200, { target: { run_id: RUN } } ],
      "extra field" => [ 200, { target: { run_id: RUN, task_id: TASK, state: "CANCELLED" } } ],
      "oversized identity" => [ 200, { target: { run_id: "run_#{'x' * 300}", task_id: TASK } } ],
      "no target field" => [ 200, {} ],
      "refused" => [ 422, { error: "at most 90 candidates may be offered" } ],
      "failed" => [ 500, { error: "internal" } ] }.each do |name, answer|
      restart_platform
      allocate(TASK, RUN)
      @platform.script_cleanup_targets(answer, [ 200, { target: nil } ])

      refute_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 2), "#{name}: #{@io.string}"

      assert_equal %w[target], exchanges, "#{name}: a claim followed an unproved answer"
      assert File.directory?(worktree(TASK)), "#{name}: the environment was released"
      assert_equal RUN, ProjectCommand.recorded_owner(@root, TASK), name
      assert_includes @io.string, "cancelled runs could not be confirmed", name
    end
  end

  def test_an_unreachable_platform_keeps_the_environment_and_stops_before_any_claim
    allocate(TASK, RUN)
    base_url = @platform.base_url
    @platform.stop

    refute_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 2, base_url: base_url), @io.string

    assert File.directory?(worktree(TASK))
    assert_equal RUN, ProjectCommand.recorded_owner(@root, TASK)
    assert_includes @io.string, "cancelled runs could not be confirmed"
    refute_includes @io.string, "polling failed"
  end

  # The ordinary claim keeps its transport backoff: a failed claim after a completed lookup is
  # retried on the next poll, not a reason to stop.
  def test_a_failed_claim_after_a_completed_lookup_still_backs_off_and_retries
    allocate(TASK, RUN)
    @platform.script_claim_failure_once

    assert_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 2), @io.string

    assert_equal %w[target claim target claim], exchanges
    assert_includes @io.string, "polling failed"
    assert File.directory?(worktree(TASK))
  end

  # A target this machine did not list is not one it may act on: the session stops.
  def test_a_target_this_machine_did_not_list_stops_the_loop_before_a_claim
    allocate(TASK, RUN)
    @platform.script_cleanup_targets(target("run_not_listed", TASK))

    refute_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 2), @io.string

    assert_equal %w[target], exchanges
    assert File.directory?(worktree(TASK))
    assert_includes @io.string, "did not list"
  end

  # Scenario 8. An unreadable project list stops the loop before Platform is asked or a claim is
  # made.
  def test_an_unreadable_project_list_stops_the_loop_before_a_claim
    allocate(TASK, RUN)
    override_verb("list", "exit 1")

    refute_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 2), @io.string

    assert_empty exchanges
    assert_equal RUN, ProjectCommand.recorded_owner(@root, TASK)
    assert_includes @io.string, "could not be listed"
  end

  # Scenario 8. A listed row that cannot be classified is not a manual environment: the list is
  # unreadable, and nothing is asked or claimed while the owned environment stays.
  def test_a_listed_environment_that_cannot_be_classified_stops_the_loop_before_a_claim
    { "owner without a task" => %([{"owner_run_id":"#{RUN}"}]),
      "owner that is not text" => %([{"task_id":"#{TASK}","owner_run_id":7}]),
      "blank task beside an owner" => %([{"task_id":"","owner_run_id":"#{RUN}"}]),
      "row that is not an object" => %(["#{TASK}"]) }.each do |name, rows|
      restart_platform
      allocate(TASK, RUN)
      listing = File.join(@root, "listing.json")
      File.write(listing, %({"environments":#{rows}}\n))
      override_verb("list", "cat '#{listing}'; exit 0")

      refute_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 2), "#{name}: #{@io.string}"

      assert_empty exchanges, name
      assert File.directory?(worktree(TASK)), name
      assert_equal RUN, ProjectCommand.recorded_owner(@root, TASK), name
      assert_includes @io.string, "could not be listed", name
    end
  end

  # Scenario 8. A release the project refuses stops the loop, and the owner record stays for
  # repair.
  def test_a_refused_release_stops_the_loop_before_a_claim
    allocate(TASK, RUN)
    override_verb("release", "echo 'release is not available' >&2; exit 9")
    @platform.script_cleanup_targets(target(RUN, TASK))

    refute_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 2), @io.string

    assert_equal %w[target], exchanges
    assert File.directory?(worktree(TASK))
    assert_equal RUN, ProjectCommand.recorded_owner(@root, TASK)
    assert_includes @io.string, "still allocated"
  end

  # ------------------------------------------------------------------- unchanged paths

  # A project with nothing Run-owned, and a project with no run-aware command, ask Platform
  # nothing; neither can hold an environment a Run allocated.
  def test_nothing_run_owned_asks_platform_nothing
    allocate("DEMO-0403", nil)

    assert_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 1), @io.string
    FileUtils.rm_f(File.join(@root, "bin", "worktree"))
    assert_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 1), @io.string

    assert_equal %w[claim claim], exchanges
  end

  # A `--config` loop has no runner identity for Platform to prove anything against.
  def test_a_loop_without_a_connection_asks_platform_nothing
    allocate(TASK, RUN)

    assert_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 1, connected: false), @io.string

    assert_equal %w[claim], exchanges
    assert File.directory?(worktree(TASK))
  end

  private

  def run_loop(iterations:, connected: true, base_url: @platform.base_url)
    config = connected ? connected_config(base_url) : legacy_config(base_url)
    client = SpecrelayRunner::PlatformClient.new(base_url: base_url, token: CREDENTIAL)
    cli = SpecrelayRunner::CLI.new(out: @io, err: @io, env: { "PATH" => ENV.fetch("PATH", "") })
    SpecrelayRunner::LoopRunner.call(
      out: @io, err: @io, install_signals: false, max_iterations: iterations, poll_seconds: 0,
      sleeper: ->(_seconds) { }, on_failure: SpecrelayRunner::LoopRunner::ON_FAILURE_CONTINUE,
      claim: -> { cli.send(:claim_after_cancellation_cleanup, config, client) },
      execute: ->(_payload) { true }
    )
  end

  def connected_config(base_url)
    connection = SpecrelayRunner::ConnectionStore::Connection.new(
      base_url: base_url, runner_id: "deferred-runner", runner_public_id: "rnr_deferred",
      runner_display_name: "Deferred Runner", project_slug: "tiny-demo", workspace_key: KEY,
      project_key: "tiny-demo", workspace_display_name: "Tiny Demo", repository_url: "https://github.com/SpecRelay/tiny-demo",
      default_branch: "main", local_path: @root, connected_at: "2026-09-23T10:00:00Z"
    )
    SpecrelayRunner::Config.from_connection(connection, credential: CREDENTIAL)
  end

  def legacy_config(base_url)
    path = File.join(Dir.mktmpdir("cfg", @root), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{base_url}
        token_env: TEST_TOKEN
      runner:
        id: deferred-runner
        display_name: Deferred Runner
        claim_policy:
          mode: all_eligible
      workspace_roots:
        #{KEY}: #{@root}
    YAML
    SpecrelayRunner::Config.load(path, env: { "TEST_TOKEN" => CREDENTIAL })
  end

  def restart_platform
    @platform.stop
    FileUtils.remove_entry(@root)
    @root, = DemoWorkspace.build
    FileUtils.mkdir_p(File.join(@root, ".runs"))
    @platform = IdlePlatform.new(claim_payload: {}, token: CREDENTIAL).start
    @io = StringIO.new
  end

  def target(run_id, task_id) = [ 200, { target: { run_id: run_id, task_id: task_id } } ]

  def exchanges
    @platform.requests.filter_map do |request|
      case request[:path]
      when "/api/runner/cancellation_cleanup_target" then "target"
      when "/api/runner/claim" then "claim"
      end
    end
  end

  def offered_candidates
    @platform.requests_to("/api/runner/cancellation_cleanup_target").map { |request| request.dig(:body, "candidates") }
  end

  def worktree(task) = File.join(@root, ".runs", "worktrees", task)

  # An environment allocated by the project's own command, recorded for `run_id` (nil for a
  # manual one), with an edit nobody published.
  def allocate(task, run_id)
    arguments = [ File.join(@root, "bin", "worktree"), "create", task ]
    arguments += [ "--run-id", run_id ] if run_id
    out, status = Open3.capture2e(*arguments, chdir: @root)
    assert status.success?, out
    File.write(File.join(worktree(task), "unpublished.txt"), "#{task} work\n")
  end

  # The project lists `task` as `run_id`'s although it holds nothing for it — the state its
  # release answers with a proof of absence.
  def list_also(task, run_id)
    override_verb("list", %(printf '{"environments":[{"task_id":"#{task}","owner_run_id":"#{run_id}"}]}\\n'; exit 0))
  end

  # Replace one verb of the project's command, leaving the others as they are.
  def override_verb(verb, shell)
    path = File.join(@root, "bin", "worktree")
    marker = "case \"$VERB\" in\n"
    File.write(path, File.read(path).sub(marker, "#{marker}  #{verb}) #{shell} ;;\n"))
  end

  def snapshot(tasks, shared)
    tasks.to_h do |task|
      files = Dir.glob("**/*", File::FNM_DOTMATCH, base: worktree(task)).reject { |path| path.start_with?(".git") }
      [ task, { owner: ProjectCommand.recorded_owner(@root, task),
                files: files.sort.to_h { |path| [ path, File.file?(File.join(worktree(task), path)) ? File.read(File.join(worktree(task), path)) : :dir ] } } ]
    end.merge(shared => File.read(shared))
  end
end
