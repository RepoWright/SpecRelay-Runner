# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# A Run can end while its task environment stays with this machine: Platform cancels it after a
# question pause had already ended the provider session, or the release after its recorded result
# failed. No claim or heartbeat reaches that environment again. So before each claim a connected
# `loop` or `claim-once` offers its project's Run-owned environments to Platform, and releases
# every one Platform names through the project's own run-qualified release, before it claims
# anything.
#
# Driven through the real loop, the CLI's own pre-claim step and `claim-once` itself, with the
# real HTTP client against the fake Platform, on a real git worktree allocated and released by the
# project's own `bin/worktree`.
class DeferredCancellationCleanupTest < Minitest::Test
  SESSION_ID = "session-deferred-0001"
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
    assert_equal [ SESSION_ID, SESSION_ID ], %w[cancellation_cleanup_target claim].map { |path|
      @platform.requests_to("/api/runner/#{path}").first.dig(:body, "session_id")
    }, "the cleanup read and the claim must both name this terminal's admitted session"
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

  # Every environment Platform names is released before the claim, and one already released is not
  # offered again, so the same target cannot be named twice.
  def test_every_named_environment_is_released_before_the_claim
    allocate(TASK, RUN)
    allocate("DEMO-0402", "run_ended_too")
    @platform.script_cleanup_targets(target(RUN, TASK), target("run_ended_too", "DEMO-0402"))

    assert_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 1), @io.string

    assert_equal %w[target target claim], exchanges
    assert_equal [ [ TASK, "DEMO-0402" ], [ "DEMO-0402" ] ],
                 offered_candidates.map { |pairs| pairs.map { |pair| pair["task_id"] }.sort }
    refute File.directory?(worktree(TASK))
    refute File.directory?(worktree("DEMO-0402"))
  end

  # A release the project could not complete stops the session with the project's own reason and
  # claims nothing. The next start offers the environment again and, once the project can release
  # it, releases it and then claims — the unpublished edit in it does not stand in the way.
  def test_a_failed_release_stops_with_the_projects_reason_and_the_next_start_releases_then_claims
    allocate(TASK, RUN)
    working = File.read(File.join(@root, "bin", "worktree"))
    block_release
    @platform.script_cleanup_targets(target(RUN, TASK))

    refute_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 2), @io.string

    assert_equal %w[target], exchanges
    assert File.directory?(worktree(TASK))
    assert_includes @io.string, "docker is not reachable at [PRIVATE_PATH_REDACTED]"
    refute_includes @io.string, "/Users/someone"

    File.write(File.join(@root, "bin", "worktree"), working)
    @platform.script_cleanup_targets(target(RUN, TASK))

    assert_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 1), @io.string

    assert_equal %w[target target claim], exchanges
    refute File.directory?(worktree(TASK))
    assert_nil ProjectCommand.recorded_owner(@root, TASK)
  end

  # ------------------------------------------------------------------- claim-once

  # `claim-once` runs the same recovery before its one claim.
  def test_claim_once_releases_a_named_environment_before_its_claim
    allocate(TASK, RUN)
    @platform.script_cleanup_targets(target(RUN, TASK))

    assert_equal SpecrelayRunner::CLI::SUCCESS, claim_once, @io.string

    assert_equal %w[target claim], exchanges
    refute File.directory?(worktree(TASK))
  end

  # A returning machine still holds an ended earlier run's environment of the same task, with an
  # edit nobody published. It is released before the claim, so the next run of the task is given
  # a fresh environment of its own instead of being refused by, or starting from, the leftover.
  def test_a_dirty_ended_leftover_is_released_before_the_claim_and_the_next_run_starts_fresh
    allocate(TASK, "run_earlier")
    @platform.script_cleanup_targets(target("run_earlier", TASK))

    assert_equal SpecrelayRunner::CLI::SUCCESS, claim_once, @io.string

    assert_equal %w[target claim], exchanges
    out, status = Open3.capture2e(File.join(@root, "bin", "worktree"), "create", TASK, "--run-id", "run_next",
                                  chdir: @root)
    assert status.success?, out
    assert_equal "run_next", ProjectCommand.recorded_owner(@root, TASK)
    refute File.exist?(File.join(worktree(TASK), "unpublished.txt")), "the leftover edit reached the next run"
  end

  # A release that failed sends no claim and says what to resolve, not to release by hand; the
  # next `claim-once` releases and then claims.
  def test_claim_once_stops_on_a_failed_release_and_the_next_one_releases_then_claims
    allocate(TASK, RUN)
    working = File.read(File.join(@root, "bin", "worktree"))
    block_release
    @platform.script_cleanup_targets(target(RUN, TASK))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, claim_once, @io.string

    assert_equal %w[target], exchanges
    assert File.directory?(worktree(TASK))
    assert_includes @io.string, "docker is not reachable at [PRIVATE_PATH_REDACTED]"
    assert_includes @io.string, "Resolve the reason above, then run this runner again."
    refute_includes @io.string, "Release it by hand"

    File.write(File.join(@root, "bin", "worktree"), working)
    @platform.script_cleanup_targets(target(RUN, TASK))

    assert_equal SpecrelayRunner::CLI::SUCCESS, claim_once, @io.string
    assert_equal %w[target target claim], exchanges
    refute File.directory?(worktree(TASK))
  end

  # A confirmation whose fate is unknown keeps the environment and fails the single shot without
  # a claim.
  def test_claim_once_keeps_the_environment_and_claims_nothing_when_platform_cannot_confirm
    allocate(TASK, RUN)
    @platform.script_cleanup_targets([ 502, {} ])

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, claim_once, @io.string

    assert_equal %w[target], exchanges
    assert File.directory?(worktree(TASK))
    assert_equal RUN, ProjectCommand.recorded_owner(@root, TASK)
    assert_includes @io.string, "could not be confirmed"
  end

  # Scenario 9. A release the project answers with its proof of absence completes too.
  def test_a_project_proved_absence_completes_the_cleanup
    list_also(TASK, RUN)
    @platform.script_cleanup_targets(target(RUN, TASK))

    assert_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 1), @io.string

    assert_equal %w[target claim], exchanges
  end

  # ------------------------------------------------------------------- retention

  # A rejected credential is the one confirmation failure with a remedy of its own: it is never
  # waited on, and it asks the operator to reconnect rather than to release anything.
  def test_a_rejected_credential_stops_the_loop_before_a_claim_with_its_reconnect_remedy
    allocate(TASK, RUN)
    @platform.script_cleanup_targets([ 401, { error: "invalid_credential" } ], [ 200, { target: nil } ])

    refute_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 2), @io.string

    assert_equal %w[target], exchanges
    assert File.directory?(worktree(TASK))
    assert_equal RUN, ProjectCommand.recorded_owner(@root, TASK)
    assert_includes @io.string, "credential was rejected by Platform"
    assert_includes @io.string, "Reconnect this machine"
  end

  # Scenario 4 and 7. Every answer that proves nothing keeps the environment and stops the
  # session, so no later poll claims either. Each session is given a second poll whose lookup
  # would answer "no target", which a session that only backed off would go on to claim after.
  def test_an_answer_that_proves_nothing_keeps_the_environment_and_stops_before_any_claim
    { "malformed target" => [ 200, { target: "run_paused" } ],
      "missing task" => [ 200, { target: { run_id: RUN } } ],
      "extra field" => [ 200, { target: { run_id: RUN, task_id: TASK, state: "CANCELLED" } } ],
      "oversized identity" => [ 200, { target: { run_id: "run_#{'x' * 300}", task_id: TASK } } ],
      "no target field" => [ 200, {} ],
      "refused" => [ 422, { error: "at most 90 candidates may be offered" } ] }.each do |name, answer|
      restart_platform
      allocate(TASK, RUN)
      @platform.script_cleanup_targets(answer, [ 200, { target: nil } ])

      refute_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 2), "#{name}: #{@io.string}"

      assert_equal %w[target], exchanges, "#{name}: a claim followed an unproved answer"
      assert File.directory?(worktree(TASK)), "#{name}: the environment was released"
      assert_equal RUN, ProjectCommand.recorded_owner(@root, TASK), name
      assert_includes @io.string, "ended runs could not be confirmed", name
    end
  end

  # ------------------------------------------------------------------- waiting

  # A failure that proves nothing AND leaves the read's fate unknown — Platform never answered, or
  # answered that it could not process the request — keeps the environment like every other
  # unproved answer, but waits on the loop's own backoff instead of ending the session. The poll
  # after the wait asks again, and a valid answer lets the claim through with no operator action.
  def test_a_server_failure_keeps_the_environment_and_claims_after_a_later_poll_confirms
    allocate(TASK, RUN)
    @platform.script_cleanup_targets([ 502, {} ], [ 200, { target: nil } ])

    assert_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 2), @io.string

    assert_equal %w[target target claim], exchanges
    assert File.directory?(worktree(TASK)), "the unconfirmed environment was released"
    assert_equal RUN, ProjectCommand.recorded_owner(@root, TASK)
    assert_includes @io.string, "polling failed — whether any task environment belongs to an ended run " \
                                "could not be confirmed (Platform request failed (502)); they were kept"
    assert_includes @io.string, "recovered — Platform answered again after 1 failed poll(s)"
    refute_includes @io.string, "Release it by hand"
  end

  # The release the confirmation authorizes is only delayed, not lost: it still precedes the claim
  # that follows it.
  def test_a_server_failure_delays_an_authorized_release_until_a_later_poll_confirms_it
    allocate(TASK, RUN)
    @platform.script_cleanup_targets([ 502, {} ], target(RUN, TASK))

    assert_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 2), @io.string

    assert_equal %w[target target claim], exchanges
    refute File.directory?(worktree(TASK))
    assert_nil ProjectCommand.recorded_owner(@root, TASK)
  end

  # A Platform that is unreachable leaves the request's fate just as unknown as one that answered
  # it could not process it, so it waits on the same path rather than ending the session.
  def test_an_unreachable_platform_keeps_the_environment_and_waits_instead_of_claiming
    allocate(TASK, RUN)
    base_url = @platform.base_url
    @platform.stop

    assert_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 2, base_url: base_url), @io.string

    assert File.directory?(worktree(TASK))
    assert_equal RUN, ProjectCommand.recorded_owner(@root, TASK)
    assert_includes @io.string, "could not be confirmed"
    assert_includes @io.string, "polling failed"
    refute_includes @io.string, "Release it by hand"
  end

  # The gate stays closed for as long as confirmation is unavailable: every poll asks again and
  # none of them claims, releases or stops, and the backoff grows rather than spinning.
  def test_a_server_failure_on_every_poll_claims_nothing_and_keeps_the_environment
    allocate(TASK, RUN)
    @platform.script_cleanup_targets(*Array.new(3) { [ 502, {} ] })

    assert_equal SpecrelayRunner::LoopRunner::OK, run_loop(iterations: 3), @io.string

    assert_equal %w[target target target], exchanges
    assert File.directory?(worktree(TASK))
    assert_equal RUN, ProjectCommand.recorded_owner(@root, TASK)
    assert_includes @io.string, "until retry #3"
  end

  # An operator's interrupt during the wait ends the session from the wait itself, so the poll it
  # was waiting for never happens and nothing is claimed while confirmation is still pending.
  def test_a_stop_during_the_wait_ends_the_session_without_claiming
    allocate(TASK, RUN)
    @platform.script_cleanup_targets([ 502, {} ], [ 200, { target: nil } ])
    pending_interrupt = -> { Process.kill("INT", Process.pid) }

    status = run_loop(iterations: 2, poll_seconds: 1, install_signals: true,
                      sleeper: lambda { |_slice|
                        interrupt = pending_interrupt
                        pending_interrupt = nil
                        interrupt&.call
                      })

    assert_equal SpecrelayRunner::LoopRunner::OK, status, @io.string
    assert_equal %w[target], exchanges
    assert File.directory?(worktree(TASK))
    assert_includes @io.string, "nothing was claimed"
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
  # unreadable, and nothing is asked or claimed while the owned environment stays. Only an owner
  # the project states as null is manual; a missing or empty owner proves nothing.
  def test_a_listed_environment_that_cannot_be_classified_stops_the_loop_before_a_claim
    { "owner without a task" => %([{"owner_run_id":"#{RUN}"}]),
      "owner that is not text" => %([{"task_id":"#{TASK}","owner_run_id":7}]),
      "blank task beside an owner" => %([{"task_id":"","owner_run_id":"#{RUN}"}]),
      "row that is not an object" => %(["#{TASK}"]),
      "owner field missing" => %([{"task_id":"#{TASK}"}]),
      "empty owner" => %([{"task_id":"#{TASK}","owner_run_id":""}]) }.each do |name, rows|
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

  def run_loop(iterations:, connected: true, base_url: @platform.base_url, poll_seconds: 0,
               install_signals: false, sleeper: ->(_seconds) { })
    config = connected ? connected_config(base_url) : legacy_config(base_url)
    client = SpecrelayRunner::PlatformClient.new(base_url: base_url, token: CREDENTIAL)
    cli = SpecrelayRunner::CLI.new(out: @io, err: @io, env: { "PATH" => ENV.fetch("PATH", "") })
    SpecrelayRunner::LoopRunner.call(
      out: @io, err: @io, install_signals: install_signals, max_iterations: iterations,
      poll_seconds: poll_seconds,
      sleeper: sleeper, on_failure: SpecrelayRunner::LoopRunner::ON_FAILURE_CONTINUE,
      claim: -> { cli.send(:claim_after_cleanup, config, client, SESSION_ID) },
      execute: ->(_payload) { true }
    )
  end

  # `claim-once` itself, selecting this machine's saved connection.
  def claim_once
    home = Dir.mktmpdir("home", @root)
    store = SpecrelayRunner::ConnectionStore.new(File.join(home, "connections.json"))
    store.save(connected_config(@platform.base_url).connection)
    secrets = FakeSecretStore.new(entries: { SpecrelayRunner::SecretStore.account_for_runner("rnr_deferred") => CREDENTIAL })
    SpecrelayRunner::CLI.new(out: @io, err: @io, secret_store: secrets,
                             env: { "PATH" => ENV.fetch("PATH", ""), "HOME" => home,
                                    "SPECRELAY_RUNNER_STATE_FILE" => store.path })
                        .run([ "claim-once", "--workspace", KEY ])
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

  # The project cannot inspect its runtime, so its owner release stops before removing anything and
  # says why on stdout, naming a host path.
  def block_release
    document = { task_id: TASK, outcome: "blocked", owner_run_id: RUN, recoverable: true,
                 failures: [ "docker is not reachable at /Users/someone/.docker/run/docker.sock" ] }
    override_verb("release", "printf '%s\\n' '#{JSON.generate(document)}'; exit 1")
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
