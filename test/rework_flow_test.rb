# frozen_string_literal: true

require_relative "test_helper"

# MVP-0035 scenarios S05-S09 for the STANDALONE runner: continuing a change request from the
# exact reviewed pull-request head.
#
# Every git fact here is real. The reviewed head is a commit that exists ONLY in a bare remote
# when the run starts, so "the runner materialized the reviewed head" cannot pass by accident:
# the workspace has to fetch it. The refusals are driven by real remote state — a moved branch,
# a deleted branch, an unreadable remote, a foreign origin, a dirty worktree — never by a stub.
class ReworkFlowTest < Minitest::Test
  # The one directory on the child PATH that provides the approved fixture name. The PAYLOAD is
  # always the canonical fixture profile; which script that approved name resolves to on this
  # host is the test's choice, exactly as it is the operator's choice on a real machine.
  # The approved fixture name resolves to the recording double these tests exist to observe.
  def fixture_dir = @fixture_dir ||= fixture_bin(recording_executor)
  TASK = "MAPIAI-902"
  # MAPIAI-84 — the publication branch is the run's canonical branch, so the reviewed round's
  # branch is that one too.
  BRANCH = TASK
  PR_URL = "https://github.com/SpecRelay/tiny-demo-workspace/pull/9"
  # The ssh form of the https `clone_url` the assignment carries, so the identity check is
  # proven against the two remote spellings of one repository rather than one literal string.
  ORIGIN_URL = "git@github.com:SpecRelay/tiny-demo-workspace.git"

  def setup
    @root, = DemoWorkspace.build
    # Addressed by the url the assignment carries, so the reviewed-repository identity these
    # tests turn on is the real one rather than a local path no `clone_url` could name.
    @bare = FakeGithub.add_remote(@root, url: ORIGIN_URL)
    git(@root, "push", "-q", "origin", "HEAD:refs/heads/main")
    @reviewed_head = publish_reviewed_round
  end

  def teardown
    @platform&.stop
    [ @root, @scratch ].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  # --- harness -------------------------------------------------------------

  # The first round, as it exists on GitHub after MVP-0014 published it: one commit on the
  # publication branch that the local workspace has never seen. Written from a separate clone so
  # the runner's own checkout genuinely has to fetch it.
  def publish_reviewed_round
    @scratch = Dir.mktmpdir("specrelay-reviewed-")
    clone = File.join(@scratch, "clone")
    system("git", "clone", "-q", @bare, clone, exception: true)
    git(clone, "config", "user.email", "runner@example.test")
    git(clone, "config", "user.name", "Runner Test")
    git(clone, "config", "commit.gpgsign", "false")
    File.write(File.join(clone, "demo-app", "index.html"), "<h1>Hello SpecRelay Demo</h1>\n<p>round one</p>\n")
    git(clone, "commit", "-qam", "#{TASK}: reviewed round")
    git(clone, "push", "-q", "origin", "HEAD:refs/heads/#{BRANCH}")
    git(clone, "rev-parse", "HEAD").strip
  end

  def start(rework: nil, restart: nil, seed: nil, gh_mode: "ok")
    payload = claim_payload_for(task_id: TASK,
                                publication: {}, rework: rework, restart: restart)
    @platform = FakePlatform.new(claim_payload: payload).start
    @gh_dir, @gh_log, = FakeGithub.gh_bin(mode: gh_mode, pull_request_url: PR_URL, bare: @bare,
                                          seed: seed || [ { "url" => PR_URL, "state" => "OPEN",
                                                            "headRefName" => BRANCH, "headRefOid" => "live" } ])
    @config_path = write_config
  end

  # The reviewed target Platform pins, with only the fields under test overridden.
  def reviewed_repository(**overrides)
    { "repository_key" => "tiny-demo-workspace", "clone_url" => ORIGIN_URL, "branch" => BRANCH,
      "head_commit" => @reviewed_head, "pull_request_url" => PR_URL }.merge(overrides.transform_keys(&:to_s))
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

  def run_cli(extra_env = {})
    io = StringIO.new
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => "#{fixture_dir}:#{@gh_dir}:#{ENV['PATH']}",
            "HOME" => ENV["HOME"].to_s }.merge(extra_env)
    code = SpecrelayRunner::CLI.run(%W[claim-once --config #{@config_path}], out: io, err: io, env: env)
    [ code, io.string ]
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  def worktree_path = File.join(@root, ".runs/worktrees", TASK)
  def remote_head(branch = BRANCH) = git(@bare, "rev-parse", "refs/heads/#{branch}").strip
  def ancestor?(candidate, descendant) = system("git", "-C", @bare, "merge-base", "--is-ancestor", candidate, descendant)
  def manifest = YAML.safe_load(Base64.strict_decode64(report_file("manifest.yml")), permitted_classes: [], aliases: false)

  def report_file(path)
    @platform.last_report.dig(:body, "report", "files").find { |f| f["relative_path"] == path }["content_base64"]
  end

  # --- S05 continue from the reviewed head ---------------------------------

  def test_the_worktree_is_materialized_at_the_exact_reviewed_head_before_the_executor_runs
    start(rework: { "repositories" => [ reviewed_repository ] })
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    # The executor observed the reviewed round's file, which exists only in that commit.
    assert_includes File.read(observed_path), "round one"
    assert_equal @reviewed_head, File.read(observed_head_path).strip
  end

  def test_the_prompt_names_the_reviewed_head_the_pull_request_and_every_current_finding
    start(rework: { "repositories" => [ reviewed_repository ] })
    run_cli

    prompt = File.read(prompt_path)
    assert_includes prompt, @reviewed_head
    assert_includes prompt, PR_URL
    assert_includes prompt, "The edit is not idempotent."
    assert_includes prompt, "A second run would append a second heading."
    assert_includes prompt, "demo-app/index.html:1"
    # Bounded: the change request appears once, and no review internals travel with it.
    assert_equal 1, prompt.scan("The edit is not idempotent.").length
    refute_includes prompt, "rvt_rework123"
    refute_match(/reviewer_profile|structural_review|verification_run/, prompt)
  end

  # --- S06 a legitimate no-change review has no reviewed head --------------

  def test_a_rework_with_no_reviewed_repository_uses_the_ordinary_checkout_and_still_supplies_findings
    start(rework: { "repositories" => [] })
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    # The workspace HEAD, not the reviewed round — there was nothing published to continue from.
    refute_includes File.read(observed_path), "round one"
    assert_includes File.read(prompt_path), "The edit is not idempotent."
  end

  # --- S07 refuse before the provider, and release capacity ----------------

  def assert_refused(output, reason)
    assert_includes output, reason
    assert_empty @platform.requests_to("/api/runner/reports"), "no report may be uploaded"
    releases = @platform.requests_to("/api/runner/claim_releases")
    assert_equal 1, releases.length, "the claim must be released so the run stays claimable"
    assert_includes releases.first[:body]["reason"].to_s, reason
    refute File.exist?(observed_path), "the executor must never have started"
  end

  def test_a_moved_remote_head_refuses_before_the_executor_and_releases_the_claim
    start(rework: { "repositories" => [ reviewed_repository(head_commit: "a" * 40) ] })
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_refused(output, "moved")
  end

  def test_a_deleted_remote_branch_refuses_before_the_executor
    git(@bare, "update-ref", "-d", "refs/heads/#{BRANCH}")
    start(rework: { "repositories" => [ reviewed_repository ] })
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_refused(output, "no longer exists on the remote")
  end

  def test_an_unreadable_remote_refuses_rather_than_guessing_the_head_did_not_move
    FileUtils.remove_entry(@bare)
    start(rework: { "repositories" => [ reviewed_repository ] })
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_refused(output, "could not read the remote")
  end

  # CR-001 F2. A commit id is portable, so branch-plus-sha is not repository identity: this
  # mirror is a real clone, and its reviewed branch is at the byte-identical reviewed commit.
  # Only the remote it points at differs, and the assignment already states which remote that
  # must be. Resetting onto it would publish the correction into someone else's repository.
  def test_a_foreign_mirror_at_the_exact_reviewed_commit_refuses_rather_than_publishing_into_it
    mirror = File.join(@scratch, "mirror.git")
    system("git", "clone", "-q", "--bare", @bare, mirror, exception: true)
    git(@root, "remote", "set-url", "origin", mirror)
    start(rework: { "repositories" => [ reviewed_repository ] })
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_refused(output, "different remote")
    assert_equal @reviewed_head, git(mirror, "rev-parse", "refs/heads/#{BRANCH}").strip
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
  end

  # CR-002. The change request pins the branch the reviewed pull request is on; the top-level
  # assignment names the branch publication will actually push to. Verifying one and pushing the
  # other would put the correction on a branch nobody reviewed, on a pull request nobody is
  # waiting for — and the reviewed branch would keep showing the code that was rejected.
  # MVP-0035 CR-002, under MAPIAI-84. The branch this claim publishes to is the run's canonical
  # branch, so the redirect this refuses is a RECORDED branch that is not it — a review settled on
  # a branch the current claim would not push to. Continuing there would land the correction on a
  # branch nobody is waiting for.
  def test_a_recorded_branch_other_than_the_publication_branch_refuses_before_the_executor
    start(rework: { "repositories" => [ reviewed_repository(branch: "specrelay/redirected") ] })
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_refused(output, "not to the reviewed branch")
    assert_equal @reviewed_head, remote_head, "the reviewed branch must be exactly as the review left it"
    refute_includes FakeGithub.remote_branches(@bare).keys, "specrelay/redirected"
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
  end

  # MAPIAI-107 replaced CR-001 F2's refusal: publication has been multi-repository since
  # MAPIAI-84, so the complete reviewed set is now materialized rather than rejected. This file
  # stays the SINGLE-repository proof — the shape most rework rounds are — and
  # `multi_repository_continuation_test.rb` proves the complete-set path against a workspace that
  # genuinely has several remotes. A second target here would be one repository counted twice.

  # --- MVP-0036 Stage 2b B02/B04: the same proof, for a REPLACEMENT run -----
  #
  # A restart continues a published pull request that no reviewer ever looked at, so it carries
  # no findings and no change request — but the question it asks of this worktree is identical:
  # is this the exact repository, branch and head Platform recorded. These run against the same
  # real remote as the rework cases above, because the point is that one implementation answers
  # it for both callers.

  def test_a_replacement_run_is_materialized_at_the_exact_recorded_head_before_the_executor_runs
    start(restart: { "repositories" => [ reviewed_repository ] })
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    assert_includes File.read(observed_path), "round one"
    assert_equal @reviewed_head, File.read(observed_head_path).strip
    # A replacement has not been reviewed, so nothing about a change request reaches the provider.
    refute_includes File.read(prompt_path), "Change request"
  end

  def test_a_replacement_whose_recorded_head_moved_refuses_before_the_executor_and_releases_the_claim
    start(restart: { "repositories" => [ reviewed_repository(head_commit: "a" * 40) ] })
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_refused(output, "moved")
    assert_equal @reviewed_head, remote_head, "the recorded branch must be exactly as it was left"
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
  end

  # The abandoned checkpoint belongs to the machine that made it. A replacement claimed on that
  # same machine finds the dirty worktree and refuses; it never resets over the work the operator
  # was told to release themselves.
  def test_a_replacement_never_discards_the_abandoned_uncommitted_work
    git(@root, "worktree", "add", "-q", "-b", TASK, worktree_path, "HEAD")
    # Recorded as THIS run's environment, so what the attempt refuses below is its own dirty
    # worktree rather than somebody else's ownership.
    ProjectCommand.own!(@root, TASK, IMPL_RUN)
    File.write(File.join(worktree_path, "demo-app", "index.html"), "<h1>abandoned checkpoint</h1>\n")
    start(restart: { "repositories" => [ reviewed_repository ] })
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "uncommitted changes"
    assert_empty @platform.requests_to("/api/runner/reports"), "no report may be uploaded"
    refute File.exist?(observed_path), "the executor must never have started"
    assert_includes File.read(File.join(worktree_path, "demo-app", "index.html")), "abandoned checkpoint"
  end

  # Uncommitted local work is never discarded to make room for the reviewed head. The refusal
  # comes from the shared workspace guard, which inspects a reused worktree before any round
  # begins — so this is a preflight failure with its manual recovery step, not a rework refusal,
  # and no claim is released (CR-001 F3). `Rework` repeats the check immediately before its own
  # `reset --hard`, which is the only destructive git operation in the runner.
  def test_a_dirty_worktree_refuses_before_the_change_request_round_and_keeps_the_local_edit
    git(@root, "worktree", "add", "-q", "-b", TASK, worktree_path, "HEAD")
    # Recorded as THIS run's environment, so what the attempt refuses below is its own dirty
    # worktree rather than somebody else's ownership.
    ProjectCommand.own!(@root, TASK, IMPL_RUN)
    File.write(File.join(worktree_path, "demo-app", "index.html"), "<h1>local edit in progress</h1>\n")
    start(rework: { "repositories" => [ reviewed_repository ] })
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "uncommitted changes"
    assert_empty @platform.requests_to("/api/runner/reports"), "no report may be uploaded"
    refute File.exist?(observed_path), "the executor must never have started"
    assert_includes File.read(File.join(worktree_path, "demo-app", "index.html")), "local edit in progress"
  end

  # --- S09 publish the correction on the same branch and pull request ------

  def test_the_correction_is_pushed_without_force_to_the_same_branch_and_reuses_the_pull_request
    start(rework: { "repositories" => [ reviewed_repository ] })
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    pushed = remote_head
    refute_equal @reviewed_head, pushed
    assert ancestor?(@reviewed_head, pushed), "the pushed commit must be a descendant of the reviewed head"
    assert_equal 0, FakeGithub.pr_creates(@gh_log), "the existing pull request must be reused"
    assert_equal PR_URL, @platform.last_terminal_result["repositories"].first["pull_request_url"]
  end

  def test_the_corrected_round_is_reported_under_the_round_platform_assigned
    start(rework: { "repositories" => [ reviewed_repository ] })
    run_cli

    assert_equal "002-review-fixes", @platform.last_report[:body]["report"]["round_label"]
    assert_equal "002-review-fixes", manifest["round_label"]
    assert_equal 2, manifest["round_number"]
  end

  def test_a_first_execution_still_reports_the_initial_round
    start(rework: nil)
    run_cli

    assert_equal "001-initial", manifest["round_label"]
    assert_equal 1, manifest["round_number"]
  end

  # --- probes --------------------------------------------------------------

  # The only executor these tests use. It records exactly what it was handed — the prompt, the
  # worktree HEAD it was started at, and the file it can see — writing OUTSIDE the worktree so the
  # recording never becomes part of the diff under test, and then makes one idempotent change so
  # the publication path has something real to push.
  def recording_executor
    path = File.join(@scratch, "recording-executor")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      File.write(#{prompt_path.inspect}, File.read(ARGV.last))
      File.write(#{observed_head_path.inspect}, `git rev-parse HEAD`)
      File.write(#{observed_path.inspect}, File.read("demo-app/index.html"))
      content = File.read("demo-app/index.html")
      File.write("demo-app/index.html", content.sub("Hello Demo", "Hello SpecRelay Demo")) unless content.include?("SpecRelay")
      File.write("demo-app/fix.txt", "corrected\\n")
      #{DemoWorkspace.selection_snippet}
      exit 0
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end

  def prompt_path = File.join(@scratch, "prompt.txt")
  def observed_path = File.join(@scratch, "observed.html")
  def observed_head_path = File.join(@scratch, "observed-head.txt")
end
