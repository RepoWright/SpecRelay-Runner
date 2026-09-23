# frozen_string_literal: true

require_relative "test_helper"

# End-to-end proof that the standalone runner drives one Tiny Demo execution over
# the HTTP API boundary (MVP-0010): claim -> events/heartbeat -> real worktree +
# real fake executor + real tests -> report upload. The runner talks to a real
# fake Platform HTTP server on loopback; there is no in-process Platform.
class RunnerFlowTest < Minitest::Test
  TASK = "DEMO-0001"

  def setup
    @root, @executor = DemoWorkspace.build
    # The approved fixture name resolves to this test's own script on the CHILD PATH. The payload
    # stays canonical; only the host decides which file the approved name is.
    @executor_path = fixture_path(@executor)
    @platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK, root: @root)).start
    @config = build_config
    @io = StringIO.new
  end

  def teardown
    @platform.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
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

  def run_cli
    SpecrelayRunner::CLI.run(%W[claim-once --config #{@config.source_path}],
                             out: @io, err: @io, env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => @executor_path })
  end

  def worktree = File.join(@root, ".runs", "worktrees", TASK)

  def test_full_claim_execute_report_flow_over_http
    exit_code = run_cli

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string

    # The executor really edited the worktree and the tests really passed. The edit is read from
    # the uploaded report rather than from disk, because a successful implementation now releases
    # its environment before this call returns — see the cleanup examples below.
    diff = decode_file(@platform.last_report[:body].fetch("report"), "evidence/diff.txt")

    assert_includes diff, "Hello SpecRelay Demo"

    # The runner called every API endpoint over real HTTP.
    assert_equal 1, @platform.requests_to("/api/runner/claim").size
    assert_operator @platform.requests_to("/api/runner/events").size, :>=, 3
    assert_operator @platform.requests_to("/api/runner/heartbeat").size, :>=, 3
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
  end


  # ---- CR-005 F3: cleanup on the shared Implementation completion path ---------------------

  # `claim-once` releases too. It used to be deliberately exempt, on the reasoning that a single
  # controlled shot hands the machine back to its operator — but the approved rule is that a
  # successfully reported implementation is released immediately, and a one-shot invocation is
  # not permission to keep the environment. The preview lane addresses this same task id.
  def test_a_successful_claim_once_releases_its_own_task_environment
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string
    assert_includes @io.string, "Released the task environment #{TASK}"
    refute File.directory?(worktree), "the task environment outlived the claim that created it"
  end

  # A release the project refused does NOT retract the accepted report — it is already uploaded —
  # but it does stop this machine, because it is now holding something nobody has accounted for.
  def test_a_refused_release_blocks_the_machine_without_rewriting_the_accepted_report
    # Only the release verb is replaced. Allocation and the ownership proof still run through
    # the project's real command, so the environment this run is refused the release of is one
    # it genuinely owns — which is the situation the rule is about.
    path = File.join(@root, "bin", "worktree")
    FileUtils.mv(path, "#{path}-real")
    File.write(path, <<~SH)
      #!/usr/bin/env sh
      set -u
      if [ "${1:-}" = "release" ]; then
        echo "refusing to release ${2:-}" >&2
        exit 1
      fi
      exec "$(dirname "$0")/worktree-real" "$@"
    SH
    FileUtils.chmod(0o755, path)

    exit_code = run_cli

    refute_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    assert_equal 1, @platform.requests_to("/api/runner/reports").size,
                 "the accepted implementation report was rewritten or re-sent"
    assert_equal "succeeded", decode_manifest(@platform.last_report[:body].fetch("report"))["execution_status"]
    assert_includes @io.string, "still allocated"
    assert_equal 1, @platform.requests_to("/api/runner/claim").size, "the machine claimed again"
  end

  def test_uploaded_report_bundle_matches_the_run_identity
    run_cli
    report = @platform.last_report[:body].fetch("report")

    assert_equal "001-initial", report["round_label"]
    manifest = decode_manifest(report)
    assert_equal "run_test123", manifest["run_id"]
    assert_equal TASK, manifest["task_id"]
    assert_equal "tiny-demo", manifest["project_key"]
    assert_equal "succeeded", manifest["execution_status"]
    assert_equal "./bin/worktree release #{TASK}", manifest["release_instructions"]
    assert_includes manifest["git"]["changed_files"], "demo-app/index.html"
  end

  def test_client_side_transcript_redaction_before_upload
    run_cli
    report = @platform.last_report[:body].fetch("report")
    stdout_log = decode_file(report, "evidence/stdout.log")

    refute_includes stdout_log, "sk-live-DO-NOT-LEAK"
    assert_includes stdout_log, "[REDACTED]"
    # The bearer token is never echoed into any request body.
    @platform.requests.each { |r| refute_includes JSON.generate(r[:body]), FakePlatform::EXPECTED_TOKEN }
  end

  def test_authorization_header_carries_the_bearer_token
    run_cli
    @platform.requests.each do |request|
      assert_equal "Bearer #{FakePlatform::EXPECTED_TOKEN}", request[:headers]["authorization"]
    end
  end

  def test_no_eligible_work_exits_zero
    # Second claim returns claimed:false from the fake platform.
    run_cli
    io2 = StringIO.new
    exit_code = SpecrelayRunner::CLI.run(%W[claim-once --config #{@config.source_path}],
                                         out: io2, err: io2,
                                         env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => @executor_path })
    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code
    # MVP-0017: the runner prints the reason PLATFORM returned rather than one generic idle
    # line, so an unconnected runner is told to run `connect` instead of reading a refusal as a
    # healthy poll. The fake Platform's reason here is its own "already claimed".
    assert_match(/no work claimed: already claimed/, io2.string)
  end

  def test_invalid_token_fails_without_claiming
    io = StringIO.new
    exit_code = SpecrelayRunner::CLI.run(%W[claim-once --config #{@config.source_path}],
                                         out: io, err: io,
                                         env: { "TEST_TOKEN" => "wrong", "PATH" => @executor_path })
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code
    assert_match(/rejected the runner token|401/, io.string)
  end

  # QUALITY-0002: a claim succeeds but the local workspace root is missing. The
  # runner must NOT crash and leave the run silently stuck — it must surface
  # precise, secret-safe recovery guidance (the env var to set and the release
  # command) and exit non-zero, uploading no report for the unexecuted claim.
  def test_missing_workspace_root_reports_recovery_without_crashing
    path = File.join(Dir.mktmpdir("cfg-badroot"), "runner.yml")
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
        tiny-demo-workspace: #{File.join(@root, "does-not-exist")}
    YAML

    io = StringIO.new
    exit_code = SpecrelayRunner::CLI.run(%W[claim-once --config #{path}],
                                         out: io, err: io,
                                         env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => @executor_path })

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, io.string
    assert_equal 1, @platform.requests_to("/api/runner/claim").size
    assert_equal 0, @platform.requests_to("/api/runner/reports").size
    assert_match(/preflight_failed/, io.string)
    assert_match(/SPECRELAY_RUNNER_WORKSPACE_ROOT_TINY_DEMO_WORKSPACE/, io.string)
    assert_match(%r{bin/platform runner release #{TASK}}, io.string)
    # MVP-0035 automatic release is scoped to a refused change-request target. A missing
    # workspace root is a misconfiguration of THIS machine, and releasing it would let the
    # default loop policy reclaim and re-refuse the same run instead of stopping (CR-001 F3).
    assert_equal 0, @platform.requests_to("/api/runner/claim_releases").size
  end

  # A failing executor must still produce a durable FAILED attempt on Platform.
  # This previously crashed: the failure path built its Workspace with root: ""
  # so capture_changes hit Process.spawn(chdir: "") -> Errno::ENOENT, and the
  # runner died BEFORE uploading anything, leaving the run stuck with no reason
  # recorded. Asserting the report upload (not just the exit code) is what makes
  # the regression impossible to reintroduce.
  def test_failing_executor_uploads_a_failed_report_without_crashing
    File.write(@executor, <<~RUBY)
      #!/usr/bin/env ruby
      warn "[fake-executor] provider call failed"
      exit 3
    RUBY
    FileUtils.chmod(0o755, @executor)

    exit_code = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    assert_equal 1, @platform.requests_to("/api/runner/reports").size, "the failed attempt must be reported"

    terminal = @platform.last_terminal_result
    assert_equal "failed", terminal["outcome"]
    assert_equal "executor_failed", terminal.dig("core", "error_classification")
    assert_equal 3, terminal.dig("core", "exit_code")
    # MAPIAI-84 — an attempt that never reached publication reports NO repositories. It has no
    # verified selection, so it has no repository identity or base commit it could honestly assert;
    # the cause is the error classification above, not a fabricated repository row.
    assert_empty terminal.fetch("repositories"), "an executor failure must publish nothing and claim nothing"
    manifest = decode_manifest(@platform.last_report)
    assert_equal "failed", manifest["execution_status"]
    refute manifest["final_jira_update_ready"], "a failed attempt must not mark Jira ready"
  end

  # ---------------------------------------------------------------- exact inputs

  # A provider must never be started against inputs that are not the ones this run was given.
  #
  # Everything up to here proves what each input SHOULD be: the package is verified against the
  # commit it was pinned to, and placement puts a created environment on it. None of that looks at
  # the tree — and a REUSED environment skips placement entirely, which is exactly where a
  # different specification can be standing in the checkout while the pinned object sits in the
  # history, intact and irrelevant.

  # Records whether the provider ran, and from where, without disturbing what it does.
  def observe_provider
    @observed = File.join(@root, ".runs", "provider-ran.json")
    code = File.read(@executor)
    marker = "require 'json'\nFile.write(#{@observed.inspect}, " \
             "JSON.generate({cwd: Dir.pwd, spec: File.read('specs/#{TASK}/spec.md')}))\n"
    File.write(@executor, code.sub('puts "leaking', marker + 'puts "leaking'))
  end

  def provider_ran = File.exist?(@observed) ? JSON.parse(File.read(@observed)) : nil

  # The assignment, re-pinned to the repository as it stands now. A test that commits to the
  # fixture after `setup` has moved the history the original block named.
  def repin
    @platform.instance_variable_get(:@claim_payload)["specification_package"] =
      specification_package_block(TASK, root: @root)
  end

  # The project's own command builds the environment, so the run REUSES one rather than creating
  # it — which is the case where nothing else looks at the visible package.
  def allocate_environment
    out, status = Open3.capture2e(File.join(@root, "bin", "worktree"), "create", TASK,
                                  "--run-id", "run_test123")
    assert status.success?, out
  end

  def test_a_reused_environment_showing_a_different_specification_refuses_before_the_provider
    observe_provider
    repin
    allocate_environment
    visible = File.join(worktree, "specs", TASK, "spec.md")
    File.write(visible, "# A LATER round's specification\n")
    DemoWorkspace.git(worktree, "add", "specs")
    DemoWorkspace.git(worktree, "commit", "-qm", "a later round replaced the package")

    code = run_cli

    refute_equal SpecrelayRunner::CLI::SUCCESS, code, @io.string
    assert_nil provider_ran, "a mismatched visible package must not reach a provider"
    # The recorded refusal ends the Run, so its checkout is released afterwards; the work it held
    # is committed on the task branch, which the release keeps. That is where "not reset" is read.
    assert_equal "# A LATER round's specification\n",
                 DemoWorkspace.git(@root, "show", "#{TASK}:specs/#{TASK}/spec.md"),
                 "the environment's own work may not be reset to make the check pass"
  end

  # The control for the test above: the same REUSED environment, showing the package it was given,
  # runs normally. Without it, a version that simply refused every reused environment would pass.
  def test_a_reused_environment_showing_the_assigned_specification_still_runs
    observe_provider
    repin
    allocate_environment

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string
    assert provider_ran, "an environment showing the right package must not be blocked"
  end

  # The ancestor case, through the whole flow: a clean, same-owner, reused allocation whose
  # committed `specs` is a link to matching documents outside it. Every byte agrees, and none of
  # them is the package this run was given.
  def test_a_reused_environment_whose_package_links_outside_it_refuses_before_the_provider
    observe_provider
    repin
    allocate_environment
    outside = File.join(@root, ".runs", "outside-specs")
    FileUtils.mv(File.join(worktree, "specs"), outside)
    File.symlink(outside, File.join(worktree, "specs"))
    DemoWorkspace.git(worktree, "add", "specs")
    DemoWorkspace.git(worktree, "commit", "-qm", "linked specification directory")

    code = run_cli

    refute_equal SpecrelayRunner::CLI::SUCCESS, code, @io.string
    assert_nil provider_ran, "a package reached through an escaping link must not be launched against"
    # Read from the task branch the released checkout was on: the link is still what it holds.
    assert_equal "120000", DemoWorkspace.git(@root, "ls-tree", TASK, "specs").split.first,
                 "and the environment is left as it was"
  end

  # ---------------------------------------------------------------- final analysis

  # The checkout's own analysis has to describe the tree as it FINALLY stands. Inputs are placed
  # in stages, so a graph built while the environment was being assembled answers questions about
  # code that has since been replaced — worse than no graph, because it looks like an answer.
  #
  # The wrappers are COMMITTED: the environment is a real worktree at the branch head, so
  # uncommitted ones would never be in it, and preparation would correctly find none.
  def install_analysis_wrappers(check_exit)
    @analysis_log = File.join(@root, ".runs", "analysis-called")
    FileUtils.mkdir_p(File.dirname(@analysis_log))
    %w[graph-check graph-build graph-query].each do |name|
      code = name == "graph-check" ? check_exit : 0
      File.write(File.join(@root, "bin", name), "#!/bin/sh\npwd >> #{@analysis_log}\nexit #{code}\n")
      FileUtils.chmod(0o755, File.join(@root, "bin", name))
    end
    DemoWorkspace.git(@root, "add", "bin")
    DemoWorkspace.git(@root, "commit", "-qm", "analysis wrappers")
  end

  # Outside the environment, because a successful run releases it.
  def prepared_the_task_environment?
    File.exist?(@analysis_log) && File.read(@analysis_log).include?(worktree)
  end

  def test_analysis_that_cannot_be_made_fresh_stops_before_the_provider
    observe_provider
    install_analysis_wrappers(3)
    repin

    code = run_cli

    assert prepared_the_task_environment?, "preparation must run against the final tree"
    refute_equal SpecrelayRunner::CLI::SUCCESS, code, @io.string
    assert_nil provider_ran, "stale analysis must not be carried into a provider"
  end

  def test_a_fresh_analysis_graph_lets_the_run_proceed
    observe_provider
    install_analysis_wrappers(0)
    repin

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string
    assert prepared_the_task_environment?
    assert provider_ran
  end

  # ---------------------------------------------------------------- effective heads

  # Announcing a prepared environment over a failed inspection states the one thing the
  # measurement exists to establish, on the strength of having failed to establish it.
  def test_inputs_that_cannot_be_measured_refuse_rather_than_reporting_preparation
    observe_provider
    repin

    preflight = SpecrelayRunner::Specification::Preflight
    original = preflight.method(:repository_state)
    preflight.define_singleton_method(:repository_state) { |**| nil }
    code = begin
      run_cli
    ensure
      preflight.define_singleton_method(:repository_state, original)
    end

    refute_equal SpecrelayRunner::CLI::SUCCESS, code, @io.string
    assert_nil provider_ran, "unmeasurable inputs must refuse before the provider"
    refute_includes @io.string, "Prepared #{TASK} at",
                    "nothing may be announced as prepared when it could not be inspected"
  end

  # Exact commits, because they are the identity of what the provider is about to work on and what
  # publication is later judged against — and an abbreviation cannot be pasted back into git.
  def test_the_effective_inputs_are_reported_as_full_commits_without_host_paths
    repin

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    reported = @io.string[/Prepared #{TASK} at ([^\n]*)/, 1].to_s
    refute_empty reported, @io.string
    assert_match(/\.@[0-9a-f]{40}/, reported, "the task root's own head, in full")
    assert_includes reported, DemoWorkspace.git(@root, "rev-parse", "HEAD").strip
    refute_includes reported, @root, "no host path may appear in the report"
  end

  private

  def decode_manifest(report)
    require "yaml"
    YAML.safe_load(decode_file(report, "manifest.yml"))
  end

  def decode_file(_report, relative)
    files = @platform.last_report[:body].dig("report", "files")
    entry = files.find { |f| f["relative_path"] == relative }
    Base64.strict_decode64(entry.fetch("content_base64"))
  end
end
