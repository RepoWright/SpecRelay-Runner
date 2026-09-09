# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "open3"

# MAPIAI-107 scenarios S02, S03, S07, S08 and S10 — continuing the COMPLETE repository set a
# reviewed or abandoned run published, from one prepared task workspace.
#
# The subject is the round that MVP-0035 and MVP-0036 Stage 2b could not run. Publication has
# been multi-repository since MAPIAI-84, so a reviewed implementation can legitimately span a
# workspace root and one of its contained repositories — and until now the correction of such a
# round either refused outright or would have implemented part of itself.
#
# Every git fact here is real and distinct per repository. Each recorded head exists ONLY in that
# repository's own bare remote when the run starts, so "the runner materialized BOTH heads" cannot
# pass by accident: each checkout has to fetch its own. The refusals are driven by real remote
# state rather than by a stub.
class MultiRepositoryContinuationTest < Minitest::Test
  # The one directory on the child PATH that provides the approved fixture name. The PAYLOAD is
  # always the canonical fixture profile; which script that approved name resolves to on this
  # host is the test's choice, exactly as it is the operator's choice on a real machine.
  def fixture_dir = @fixture_dir ||= fixture_bin
  TASK = "MAPIAI-903"
  BRANCH = TASK
  WORKSPACE_SLUG = "SpecRelay/multi-demo-workspace"
  CHILD_SLUG = "SpecRelay/component-a"
  PR_URLS = {
    WORKSPACE_SLUG => "https://github.com/SpecRelay/multi-demo-workspace/pull/31",
    CHILD_SLUG => "https://github.com/SpecRelay/component-a/pull/32",
    "SpecRelay/component-b" => "https://github.com/SpecRelay/component-b/pull/33",
    "SpecRelay/component-c" => "https://github.com/SpecRelay/component-c/pull/34"
  }.freeze

  def setup
    @built = MultiRepositoryWorkspace.build
    @root = @built.root
    @scratch = Dir.mktmpdir("specrelay-recorded-")
    @bares = { WORKSPACE_SLUG => @built.bares["."],
               CHILD_SLUG => @built.bares["component-a"],
               "SpecRelay/component-b" => @built.bares["component-b"],
               "SpecRelay/component-c" => @built.bares["component-c"] }
    @bares.each_key { |slug| git(checkout_of(slug), "push", "-q", "origin", "HEAD:refs/heads/main") }
    # The published round the correction continues, in the two repositories it changed. The heads
    # are unrelated commits in unrelated histories, so "each repository is at ITS OWN recorded
    # head" is observable rather than a coincidence of one shared sha.
    @recorded = { WORKSPACE_SLUG => publish_round(WORKSPACE_SLUG, "workspace.txt"),
                  CHILD_SLUG => publish_round(CHILD_SLUG, "app.txt") }
  end

  def teardown
    @platform&.stop
    [ @root, @scratch ].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  # --- harness -------------------------------------------------------------

  # The first round as it exists on each remote after MAPIAI-84 published it: one commit on the
  # publication branch of that repository, written from a separate clone so the runner's own
  # checkout genuinely has to fetch it.
  def publish_round(slug, file)
    clone = File.join(@scratch, slug.tr("/", "-"))
    system("git", "clone", "-q", @bares.fetch(slug), clone, exception: true)
    git(clone, "config", "user.email", "runner@example.test")
    git(clone, "config", "user.name", "Runner Test")
    git(clone, "config", "commit.gpgsign", "false")
    File.write(File.join(clone, file), "#{File.read(File.join(clone, file))}published round one\n")
    git(clone, "commit", "-qam", "#{TASK}: published round")
    git(clone, "push", "-q", "origin", "HEAD:refs/heads/#{BRANCH}")
    git(clone, "rev-parse", "HEAD").strip
  end

  # `fixture_env` is the environment the double runs under on this host, installed behind the
  # approved bare name on the child PATH. The assignment itself is always the canonical fixture
  # profile, environment included.
  def start(rework: nil, restart: nil, executor: nil, fixture_env: {}, seed: nil)
    use_fixture(fixture_dir, executor || @built.executor,
                env: { "FAKE_EXECUTOR_EDITED" => ".,component-a" }.merge(fixture_env))
    payload = claim_payload_for(task_id: TASK,
                                publication: {}, rework: rework, restart: restart)
    @platform = FakePlatform.new(claim_payload: payload).start
    @gh_dir, @gh_log, = FakeGithub.gh_bin(urls: PR_URLS, bares: @bares, seed: seed || open_pull_requests)
    @config_path = write_config
    payload
  end

  # Both continued pull requests, already open on their own repository's branch, so publication
  # reuse is proven rather than assumed.
  def open_pull_requests
    [ WORKSPACE_SLUG, CHILD_SLUG ].map do |slug|
      { "url" => PR_URLS.fetch(slug), "state" => "OPEN", "headRefName" => BRANCH,
        "repo" => slug, "headRefOid" => "live" }
    end
  end

  # One recorded continuation target, with only the fields under test overridden.
  def recorded_repository(slug, **overrides)
    { "repository_key" => slug.split("/").last, "clone_url" => "https://github.com/#{slug}",
      "branch" => BRANCH, "head_commit" => @recorded.fetch(slug),
      "pull_request_url" => PR_URLS.fetch(slug) }.merge(overrides.transform_keys(&:to_s))
  end

  def both_targets = [ recorded_repository(WORKSPACE_SLUG), recorded_repository(CHILD_SLUG) ]

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
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => "#{fixture_dir}:#{@gh_dir}:#{ENV['PATH']}",
            "HOME" => ENV["HOME"].to_s }
    code = SpecrelayRunner::CLI.run(%W[claim-once --config #{@config_path}], out: io, err: io, env: env)
    [ code, io.string ]
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  def checkout_of(slug) = slug == WORKSPACE_SLUG ? @root : File.join(@root, slug.split("/").last)
  def task_workspace = MultiRepositoryWorkspace.task_workspace(@root, TASK)
  def workspace_checkout(slug) = slug == WORKSPACE_SLUG ? task_workspace : File.join(task_workspace, slug.split("/").last)
  def head_of(slug) = git(workspace_checkout(slug), "rev-parse", "HEAD").strip
  def remote_head(slug) = git(@bares.fetch(slug), "rev-parse", "refs/heads/#{BRANCH}").strip
  def results = @platform.last_terminal_result["repositories"]
  def ancestor?(slug, candidate, descendant) =
    system("git", "-C", @bares.fetch(slug), "merge-base", "--is-ancestor", candidate, descendant)

  # --- S02: the complete set is materialized, each at its OWN recorded head ---

  def test_the_root_and_a_contained_child_are_both_at_their_own_recorded_head_before_the_provider
    start(rework: { "repositories" => both_targets }, executor: observing_executor)
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    observed = YAML.safe_load(File.read(observed_path))
    refute_equal @recorded.fetch(WORKSPACE_SLUG), @recorded.fetch(CHILD_SLUG),
                 "the two recorded heads must be different commits for this to prove anything"
    assert_equal @recorded.fetch(WORKSPACE_SLUG), observed.fetch("workspace_head")
    assert_equal @recorded.fetch(CHILD_SLUG), observed.fetch("child_head")
    # The published bytes of each round, which exist only in that repository's own recorded head.
    assert_includes observed.fetch("workspace_file"), "published round one"
    assert_includes observed.fetch("child_file"), "published round one"
  end

  # The report's base commit still means what it always meant: the task-workspace repository's
  # own starting point. A contained child's measurement stays with Workspace#select.
  def test_the_reported_base_commit_is_the_task_workspace_repositorys_recorded_head
    start(rework: { "repositories" => both_targets }, executor: observing_executor)
    run_cli

    assert_equal @recorded.fetch(WORKSPACE_SLUG),
                 YAML.safe_load(report_file("manifest.yml")).dig("worktree_identity", "base_commit")
  end

  # --- S03: every target is proved BEFORE the first reset ------------------

  def test_a_valid_first_target_with_an_invalid_second_resets_nothing_and_starts_nothing
    before = { WORKSPACE_SLUG => nil, CHILD_SLUG => nil }
    start(rework: { "repositories" => [ recorded_repository(WORKSPACE_SLUG),
                                        recorded_repository(CHILD_SLUG, head_commit: "a" * 40) ] },
          executor: observing_executor)
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "moved"
    assert_includes output, "component-a", "the refusal must name the repository that failed"

    before.each_key do |slug|
      refute_equal @recorded.fetch(slug), head_of(slug),
                   "#{slug} must not have been reset: every target is proved before the first one moves"
    end
    assert_zero_external_effect(output)
  end

  # S04's freshness half, and S05's identity half, applied to the SECOND target so the refusal
  # can only come from the complete-set proof rather than from the first entry.
  def test_a_second_target_pointing_at_a_foreign_remote_refuses_the_whole_continuation
    git(File.join(@root, "component-a"), "remote", "set-url", "origin",
        "https://github.com/SpecRelay/component-z.git")
    start(rework: { "repositories" => both_targets }, executor: observing_executor)
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "different remote"
    refute_equal @recorded.fetch(WORKSPACE_SLUG), head_of(WORKSPACE_SLUG)
    assert_zero_external_effect(output)
  end

  def test_the_same_repository_named_twice_refuses_before_any_reset
    start(rework: { "repositories" => [ recorded_repository(CHILD_SLUG),
                                        recorded_repository(CHILD_SLUG) ] },
          executor: observing_executor)
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_match(/twice|duplicate/i, output)
    refute_equal @recorded.fetch(CHILD_SLUG), head_of(CHILD_SLUG)
    assert_zero_external_effect(output)
  end

  # Nothing broadens the checkout search. Exactly two places are ever considered — the task
  # workspace root and the one direct child the key names — so a repository that is in neither is
  # refused by {Review::Checkout}'s own identity message rather than by a wider hunt for it.
  def test_a_target_that_is_no_contained_repository_refuses_without_searching_for_it
    absent = { "repository_key" => "component-z",
               "clone_url" => "https://github.com/SpecRelay/component-z",
               "branch" => BRANCH, "head_commit" => "c" * 40,
               "pull_request_url" => "https://github.com/SpecRelay/component-z/pull/35" }
    start(rework: { "repositories" => [ recorded_repository(WORKSPACE_SLUG), absent ] },
          executor: observing_executor)
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "'component-z' points at a different remote"
    refute File.exist?(File.join(task_workspace, "component-z")), "nothing was created to satisfy the target"
    refute_equal @recorded.fetch(WORKSPACE_SLUG), head_of(WORKSPACE_SLUG)
    assert_zero_external_effect(output)
  end

  # --- MAPIAI-107 CR-001 F1: the branch each checkout is ACTUALLY on ---------
  #
  # `reset --hard <head>` moves whatever branch is checked out; it never switches to another one.
  # So the two payload branch values agreeing says nothing about where the reset would land: a
  # contained repository left on a different local branch would have THAT branch moved to the
  # reviewed head and handed to the provider, and the later `Workspace#select` check only notices
  # after the provider has already run.

  def test_a_child_on_another_local_branch_refuses_before_any_reset_or_provider
    prepare_task_workspace
    git(File.join(task_workspace, "component-a"), "checkout", "-q", "-b", "wip/side-quest")
    before = head_of(CHILD_SLUG)
    start(rework: { "repositories" => both_targets }, executor: observing_executor)
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "'component-a' is checked out on 'wip/side-quest'"
    assert_includes output, "not the reviewed branch '#{BRANCH}'"
    # Every local head survives: the wrong branch was not moved, and the valid root beside it was
    # never reset either.
    assert_equal before, head_of(CHILD_SLUG)
    refute_equal @recorded.fetch(WORKSPACE_SLUG), head_of(WORKSPACE_SLUG)
    assert_zero_external_effect(output)
  end

  def test_a_detached_child_refuses_before_any_reset_or_provider
    prepare_task_workspace
    git(File.join(task_workspace, "component-a"), "checkout", "-q", "--detach", "HEAD")
    before = head_of(CHILD_SLUG)
    start(rework: { "repositories" => both_targets }, executor: observing_executor)
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "'component-a' is not on a branch"
    assert_equal before, head_of(CHILD_SLUG)
    refute_equal @recorded.fetch(WORKSPACE_SLUG), head_of(WORKSPACE_SLUG)
    assert_zero_external_effect(output)
  end

  # The third answer the branch proof has to handle: not "wrong" and not "detached", but "this
  # machine could not be asked". Not knowing is not the same as knowing it is right, so it refuses
  # — the same fail-closed rule the freshness and reset boundaries follow.
  def test_a_branch_that_cannot_be_read_refuses_rather_than_assuming_it_is_correct
    prepare_task_workspace
    before = head_of(CHILD_SLUG)
    start(rework: { "repositories" => both_targets }, executor: observing_executor)
    code, output = with_failing_git("symbolic-ref", :unspawnable, only_under: "component-a") { run_cli }

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "could not read which branch 'component-a' is checked out on"
    assert_equal before, head_of(CHILD_SLUG)
    refute_equal @recorded.fetch(WORKSPACE_SLUG), head_of(WORKSPACE_SLUG)
    assert_zero_external_effect(output)
  end

  # The task-workspace ROOT runs through the identical proof — `plan` applies it to every resolved
  # target — but it cannot normally arrive on the wrong branch, because `Workspace` locates the
  # worktree BY the canonical branch. Moving the root off that branch therefore stops the attempt
  # one step earlier, at the existing workspace guard. That is still before any reset, provider,
  # report or external write, which is the boundary this ticket cares about; asserting the
  # continuation's own message here would be asserting an unreachable one.
  def test_a_root_moved_off_the_canonical_branch_stops_before_any_reset_or_provider
    prepare_task_workspace
    child_before = head_of(CHILD_SLUG)
    git(task_workspace, "checkout", "-q", "-b", "wip/root-side-quest")
    start(rework: { "repositories" => both_targets }, executor: observing_executor)
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "preflight_failed"
    refute File.exist?(observed_path), "the executor must never have started"
    assert_empty @platform.requests_to("/api/runner/reports"), "no report may be uploaded"
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
    assert_equal child_before, head_of(CHILD_SLUG), "no target was reset"
    @recorded.each { |slug, head| assert_equal head, remote_head(slug), "#{slug} must be untouched" }
  end

  # Restart reaches the identical proof through the identical owner — the noun is the only thing
  # that differs, which is what tells an operator no review is involved.
  def test_a_replacement_with_a_child_on_another_local_branch_refuses_at_the_same_boundary
    prepare_task_workspace
    git(File.join(task_workspace, "component-a"), "checkout", "-q", "-b", "wip/side-quest")
    start(restart: { "repositories" => both_targets }, executor: observing_executor)
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "'component-a' is checked out on 'wip/side-quest'"
    assert_includes output, "not the recorded branch '#{BRANCH}'"
    assert_zero_external_effect(output)
  end

  # S06 — a dirty CHILD is preserved byte for byte, and the clean root beside it is not reset.
  def test_a_dirty_contained_child_is_preserved_and_no_target_is_reset
    prepare_task_workspace
    File.write(File.join(task_workspace, "component-a", "app.txt"), "work in progress\n")
    start(rework: { "repositories" => both_targets }, executor: observing_executor)
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "uncommitted changes"
    assert_equal "work in progress\n", File.read(File.join(task_workspace, "component-a", "app.txt"))
    refute_equal @recorded.fetch(WORKSPACE_SLUG), head_of(WORKSPACE_SLUG)
    assert_zero_external_effect(output)
  end

  # --- MAPIAI-107 CR-001 F3: the reset itself failing --------------------------
  #
  # The last thing that can go wrong is the mutation. `reset_to` reads a `CommandRunner::Result`,
  # and an unspawnable git produces no result at all — which the predecessor of that line counted
  # as a successful reset, because `nil.to_i.zero?` is true. A workspace that was never moved
  # would then have been handed to the provider as though it held the recorded code.

  def test_a_reset_that_cannot_be_spawned_refuses_and_names_the_repository
    start(rework: { "repositories" => both_targets }, executor: observing_executor)
    code, output = with_failing_git("reset", :unspawnable) { run_cli }

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "could not check out the reviewed head of 'multi-demo-workspace'"
    assert_zero_external_effect(output)
  end

  def test_a_reset_that_exits_nonzero_refuses_and_names_the_repository
    start(rework: { "repositories" => both_targets }, executor: observing_executor)
    code, output = with_failing_git("reset", :nonzero) { run_cli }

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "could not check out the reviewed head of 'multi-demo-workspace'"
    assert_zero_external_effect(output)
  end

  # A reset that fails AFTER an earlier one succeeded leaves the workspace partly placed. That is
  # recoverable — the moved repositories are clean and at the recorded head, so a retry converges
  # — and this ticket deliberately invents no rollback for it. What must still hold absolutely is
  # that the half-built base never reaches the provider or any external write.
  def test_a_second_reset_failing_leaves_recoverable_local_state_and_still_reaches_no_provider
    start(rework: { "repositories" => both_targets }, executor: observing_executor)
    code, output = with_failing_git("reset", :nonzero, only_under: "component-a") { run_cli }

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "could not check out the reviewed head of 'component-a'"
    # The earlier repository really was placed, and is left clean at the head it was moved to.
    assert_equal @recorded.fetch(WORKSPACE_SLUG), head_of(WORKSPACE_SLUG)
    assert_empty git(task_workspace, "status", "--porcelain").strip
    refute_equal @recorded.fetch(CHILD_SLUG), head_of(CHILD_SLUG)
    assert_zero_external_effect(output)
  end

  # One git subcommand made to fail, with no production injection point added for it: the existing
  # `CommandRunner` singleton is wrapped for the duration of one CLI run, and every other command
  # — the project-owned worktree build, the fetches, the status reads, `gh` — still reaches the
  # real one.
  #
  #   :unspawnable — raises SystemCallError, which is what an absent or unexecutable git does and
  #                  what the runner's own `run` wrappers turn into the `nil` result under test
  #   :nonzero     — git ran and refused
  #
  # `only_under` narrows the interception to one checkout, so a failure can be aimed at the second
  # repository of a set rather than the first.
  def with_failing_git(subcommand, mode, only_under: nil)
    singleton = SpecrelayRunner::CommandRunner.singleton_class
    singleton.send(:alias_method, :run_without_git_stub, :run)
    singleton.send(:define_method, :run) do |argv, **kwargs|
      targeted = argv.first == "git" && argv.include?(subcommand) &&
                 (only_under.nil? || argv[argv.index("-C") + 1].to_s.end_with?(only_under))
      next send(:run_without_git_stub, argv, **kwargs) unless targeted
      raise Errno::ENOENT, "git" if mode == :unspawnable

      SpecrelayRunner::CommandRunner::Result.new(exit_code: 1, stdout: "", stderr: "fatal: #{subcommand} refused",
                                                 duration_seconds: 0, timed_out: false)
    end
    yield
  ensure
    singleton.send(:alias_method, :run, :run_without_git_stub)
    singleton.send(:remove_method, :run_without_git_stub)
  end

  # Every refusal is whole: the claim goes back, and no provider, report, remote or `gh` write
  # happens at all.
  def assert_zero_external_effect(output)
    refute File.exist?(observed_path), "the executor must never have started"
    assert_empty @platform.requests_to("/api/runner/reports"), "no report may be uploaded"
    assert_equal 1, @platform.requests_to("/api/runner/claim_releases").length,
                 "the claim must be released exactly once so another machine can try"
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
    assert_equal 0, FakeGithub.pr_lists(@gh_log)
    @recorded.each { |slug, head| assert_equal head, remote_head(slug), "#{slug} must be untouched" }
    refute_includes output, @root, "an operator-facing refusal carries no local path"
  end

  # --- S07: the executor is told about EVERY continued repository ----------

  def test_the_prompt_lists_every_repository_once_in_order_with_the_summary_and_findings_once
    start(rework: { "repositories" => both_targets }, executor: observing_executor)
    run_cli

    section = change_request_section

    [ WORKSPACE_SLUG, CHILD_SLUG ].each do |slug|
      assert_equal 1, section.scan(@recorded.fetch(slug)).length, "#{slug}'s head appears exactly once"
      assert_equal 1, section.scan(PR_URLS.fetch(slug)).length, "#{slug}'s pull request appears exactly once"
      assert_includes section, slug.split("/").last
    end
    assert_operator section.index(@recorded.fetch(WORKSPACE_SLUG)),
                    :<, section.index(@recorded.fetch(CHILD_SLUG)),
                    "the assignment's order is preserved"
    assert_equal 2, section.scan(BRANCH).length, "each repository names its own branch once"

    assert_equal 1, section.scan("The edit is not idempotent.").length
    assert_equal 1, section.scan("The heading is right, but the change is not idempotent.").length
    assert_includes section, "A second run would append a second heading."
  end

  def test_the_prompt_carries_no_review_internals_transcript_or_local_path
    start(rework: { "repositories" => both_targets }, executor: observing_executor)
    run_cli

    section = change_request_section
    refute_includes section, "rvt_rework123"
    refute_includes section, @root
    refute_includes section, task_workspace
    refute_match(/reviewer_profile|input_manifest_digest|structural_review|verification_run/, section)
  end

  # --- S08: a two-repository correction reuses both existing pull requests --

  def test_both_corrected_repositories_publish_onto_their_existing_branch_and_pull_request
    start(rework: { "repositories" => both_targets })
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    assert_equal "succeeded", @platform.last_terminal_result["outcome"]
    assert_equal [ CHILD_SLUG, WORKSPACE_SLUG ], results.map { |repo| repo["id"] }.sort

    results.each do |repo|
      slug = repo["id"]
      assert_equal BRANCH, repo["branch"]
      assert_equal PR_URLS.fetch(slug), repo["pull_request_url"], "#{slug} reuses its own pull request"
      assert_nil repo["publication_error"]
      pushed = remote_head(slug)
      assert_equal pushed, repo["head_commit"]
      refute_equal @recorded.fetch(slug), pushed, "#{slug} received the correction"
      assert ancestor?(slug, @recorded.fetch(slug), pushed),
             "#{slug}'s correction must descend from its recorded head — nothing was force-pushed"
    end
    assert_equal 0, FakeGithub.pr_creates(@gh_log), "both pull requests already existed"
  end

  # --- S10: the same proof and materialization for a REPLACEMENT run -------

  def test_a_replacement_run_materializes_every_recorded_repository_without_a_change_request
    start(restart: { "repositories" => both_targets }, executor: observing_executor)
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    observed = YAML.safe_load(File.read(observed_path))
    assert_equal @recorded.fetch(WORKSPACE_SLUG), observed.fetch("workspace_head")
    assert_equal @recorded.fetch(CHILD_SLUG), observed.fetch("child_head")
    refute_includes File.read(prompt_path), "Change request"
  end

  def test_a_replacement_whose_second_recorded_head_moved_refuses_the_whole_continuation
    start(restart: { "repositories" => [ recorded_repository(WORKSPACE_SLUG),
                                         recorded_repository(CHILD_SLUG, head_commit: "b" * 40) ] },
          executor: observing_executor)
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "moved"
    assert_includes output, "recorded", "a restart refusal names a recorded target, not a reviewed one"
    refute_equal @recorded.fetch(WORKSPACE_SLUG), head_of(WORKSPACE_SLUG)
    assert_zero_external_effect(output)
  end

  # --- probes --------------------------------------------------------------

  # Build the task workspace up front, so a test can plant local state the continuation then has
  # to refuse. The runner's own preparation finds it already on the canonical branch and
  # continues it, which is the existing retry behaviour rather than a test hook.
  def prepare_task_workspace
    out, status = Open3.capture2e(File.join(@root, "bin", "worktree"), "create", TASK)
    raise out unless status.success?
  end

  # Records what the provider was actually handed — the prompt, and each continued repository's
  # HEAD and published bytes as they were when it started. It writes OUTSIDE the task workspace,
  # so the recording never becomes part of the diff under test, and reports no selection, so an
  # observing run publishes nothing.
  def observing_executor
    path = File.join(@scratch, "observing-executor")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      require "yaml"
      File.write(#{prompt_path.inspect}, File.read(ARGV.last))
      File.write(#{observed_path.inspect}, YAML.dump(
        "workspace_head" => `git rev-parse HEAD`.strip,
        "child_head" => `git -C component-a rev-parse HEAD`.strip,
        "workspace_file" => File.read("workspace.txt"),
        "child_file" => File.read("component-a/app.txt")
      ))
      #{DemoWorkspace.selection_snippet(changed: 'false')}
      exit 0
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end

  # The `## Change request` section of the prompt the provider was handed, isolated from the rest
  # of the document so an assertion about what the change request carries cannot pass or fail on
  # the surrounding specification package.
  def change_request_section
    File.read(prompt_path).partition("## Change request").last
  end

  def report_file(path)
    Base64.strict_decode64(@platform.last_report.dig(:body, "report", "files")
      .find { |f| f["relative_path"] == path }["content_base64"])
  end

  def prompt_path = File.join(@scratch, "prompt.txt")
  def observed_path = File.join(@scratch, "observed.yml")
end
