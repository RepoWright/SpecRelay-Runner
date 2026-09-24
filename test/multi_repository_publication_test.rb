# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "open3"

# MAPIAI-84 proof for AI-DIRECTED multi-repository implementation publication, against a real
# project-owned task workspace, real independent git repositories, real bare remotes and a real
# `gh` argv boundary.
#
# The subject is the replacement of one Platform-declared repository input by the executor's own
# semantic selection: the assignment carries no repository list, the executor writes one bounded
# structured document naming what it changed, and the runner verifies every entry locally before
# it performs any external write.
#
# Scenarios: S01 (no declared list, independent measurement), S02 (two changed repositories),
# S03 (subset), S04 (no changes), S05 (project-owned worktree), S07 (path escape and false root),
# S08 (duplicate identity), S09 (pull-request idempotency per repository), S10 (partial
# publication failure).
class MultiRepositoryPublicationTest < Minitest::Test
  TASK = "MAPIAI-84"
  BRANCH = TASK
  WORKSPACE_SLUG = "SpecRelay/multi-demo-workspace"
  PR_URLS = {
    "SpecRelay/component-a" => "https://github.com/SpecRelay/component-a/pull/21",
    "SpecRelay/component-b" => "https://github.com/SpecRelay/component-b/pull/22",
    "SpecRelay/component-c" => "https://github.com/SpecRelay/component-c/pull/23",
    WORKSPACE_SLUG => "https://github.com/SpecRelay/multi-demo-workspace/pull/24"
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

  # The one directory on the child PATH that provides the approved fixture name. Which script it
  # points at, and what that script reads while it runs, is this HOST's choice; the PAYLOAD is
  # always the canonical fixture profile, environment included.
  def fixture_dir = @fixture_dir ||= fixture_bin

  # `fixture_env` is the environment the double runs under on this machine. It is installed behind
  # the approved bare name on the child PATH, because a payload that could name it would be
  # choosing which repositories this host edits.
  def start(publication: {}, fixture_env: {}, executor: nil)
    use_fixture(fixture_dir, executor || @built.executor,
                env: { "FAKE_EXECUTOR_EDITED" => "component-a,component-b" }.merge(fixture_env))
    payload = claim_payload_for(task_id: TASK, publication: publication,
                                root: @root, specification_repository: "component-c")
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

  def run_cli(gh_dir: @gh_dir)
    io = StringIO.new
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
            "PATH" => "#{fixture_dir}:#{gh_dir}:#{ENV['PATH']}",
            "HOME" => ENV["HOME"].to_s }
    code = SpecrelayRunner::CLI.run(%W[claim-once --config #{@config_path}], out: io, err: io, env: env)
    [ code, io.string ]
  end

  def results = @platform.last_terminal_result["repositories"]
  def result_ids = results.map { |repo| repo["id"] }.sort
  def terminal = @platform.last_terminal_result
  def branches_of(slug) = FakeGithub.remote_branches(@bares.fetch(slug))

  # --- S01 / S02: two changed repositories, measured independently ---------

  def test_the_assignment_declares_no_eligible_repository_list
    payload = start
    refute payload.key?("repositories"),
           "the executor selects repositories semantically; Platform declares none"
    assert_equal %w[access create_pull_requests pull_request_draft],
                 payload.fetch("repository_policy").keys.sort,
                 "policy may state HOW to publish, never WHICH repositories are eligible"
  end

  def test_two_changed_repositories_each_receive_one_draft_pull_request
    start
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    assert_equal "succeeded", terminal["outcome"]
    assert_equal [ "SpecRelay/component-a", "SpecRelay/component-b" ], result_ids

    results.each do |repo|
      assert repo["changed"], "#{repo['id']} is in the result only because it changed"
      assert_equal BRANCH, repo["branch"], "every repository publishes the canonical task branch"
      assert_equal "main", repo["default_branch"]
      assert_equal "https://github.com/#{repo['id']}.git", repo["clone_url"]
      assert_match(/\A[0-9a-f]{40,64}\z/, repo["base_commit"])
      assert_match(/\A[0-9a-f]{40,64}\z/, repo["head_commit"])
      refute_equal repo["base_commit"], repo["head_commit"]
      assert_equal PR_URLS.fetch(repo["id"]), repo["pull_request_url"]
      assert_nil repo["publication_error"]
      # The branch really exists in THAT repository's own remote, at its own head.
      assert_equal repo["head_commit"], branches_of(repo["id"])[BRANCH]
      refute_includes branches_of(repo["id"]).keys, "main"
    end

    # Independent measurement: two repositories with unrelated histories cannot share a base.
    assert_equal 2, results.map { |repo| repo["base_commit"] }.uniq.length
    assert_equal 2, FakeGithub.pr_creates(@gh_log)
    assert_empty branches_of("SpecRelay/component-c"), "an unselected repository is never pushed"
  end

  def test_the_workspace_repository_itself_can_be_the_selected_repository
    start(fixture_env: { "FAKE_EXECUTOR_EDITED" => "." })
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    assert_equal [ WORKSPACE_SLUG ], result_ids
    assert_equal PR_URLS.fetch(WORKSPACE_SLUG), results.first["pull_request_url"]
    assert_equal results.first["head_commit"], branches_of(WORKSPACE_SLUG)[BRANCH]
  end

  # --- S03: subset selection ----------------------------------------------

  def test_only_the_selected_subset_is_published
    start(fixture_env: { "FAKE_EXECUTOR_EDITED" => "component-a,component-c" })
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    assert_equal [ "SpecRelay/component-a", "SpecRelay/component-c" ], result_ids
    assert_empty branches_of("SpecRelay/component-b")
    assert_empty branches_of(WORKSPACE_SLUG)
    assert_equal 2, FakeGithub.pr_creates(@gh_log)
  end

  # A repository the executor changed but did NOT report is not published. The selection
  # document is the only input considered — prose and terminal output are never parsed.
  def test_an_unreported_changed_repository_is_not_published
    start(fixture_env: { "FAKE_EXECUTOR_SELECTED" => "component-a" })
    code, = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code

    assert_equal [ "SpecRelay/component-a" ], result_ids
    assert_empty branches_of("SpecRelay/component-b")
  end

  # --- S04: no changes ----------------------------------------------------

  def test_an_empty_selection_on_a_clean_workspace_succeeds_without_publishing
    start(fixture_env: { "FAKE_EXECUTOR_EDITED" => "" })
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    assert_equal "succeeded", terminal["outcome"]
    assert_empty results, "no repository changed, so no repository row may be fabricated"
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
    assert_equal 0, FakeGithub.pr_lists(@gh_log)
    @bares.each_key { |slug| assert_empty branches_of(slug) }
  end

  # An ABSENT document is not an empty selection: it means the executor never answered. Guessing
  # "nothing changed" there would publish nothing while a diff sits on disk.
  def test_a_missing_selection_document_fails_closed
    start(fixture_env: { "FAKE_EXECUTOR_SELECTION_SKIP" => "1" })
    run_cli

    assert_equal "failed", terminal["outcome"]
    assert_match(/selection/i, terminal.dig("core", "error_classification").to_s +
                               @platform.last_report[:body].to_s)
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
  end

  # --- S05: the project-owned worktree command ----------------------------

  def test_the_project_owned_worktree_command_is_invoked_once_with_create
    start(fixture_env: { "FAKE_EXECUTOR_EDITED" => "component-a" })
    run_cli

    assert_equal [ "create #{TASK} --run-id #{IMPL_RUN}", "status #{TASK} --json",
                   "release #{TASK} --run-id #{IMPL_RUN} --json" ],
                 MultiRepositoryWorkspace.worktree_invocations(@built.worktree_log),
                 "the project-owned command constructs the task environment exactly once for " \
                 "this run, proves it recorded that owner, and hands it back once the " \
                 "successful report is accepted"
    # Which workspace the runner actually USED, read from the report it uploaded rather than from
    # the disk: MAPIAI-97 releases that environment once the successful report is accepted, and
    # the recorded identity is the durable evidence of the same fact.
    assert_equal MultiRepositoryWorkspace.task_workspace(File.realpath(@root), TASK),
                 YAML.safe_load(report_file("manifest.yml")).dig("worktree", "path"),
                 "the runner must use the task workspace that command created"
  end

  # --- S06: the native single-repository fallback -------------------------

  # A checkout with no run-aware project command REFUSES the automatic run, and the assignment's
  # native worktree command is not used as a fallback.
  #
  # This replaces the native-fallback path for this lane rather than sitting beside it. That
  # command builds a worktree with no recorded owner: the run could neither prove the
  # environment was its own on a retry nor release it at the end, so an operator of such a
  # project would accumulate environments nobody can take down. Refusing before anything is
  # created is the honest answer; supporting ownerless automatic projects is separate work.
  def test_a_checkout_without_the_run_aware_project_command_refuses_the_automatic_run
    FileUtils.remove_entry(@root)
    @root, executor = DemoWorkspace.build
    use_fixture(fixture_dir, executor)
    dev_log = DemoWorkspace.without_project_command(@root)
    bare = FakeGithub.add_remote(@root)
    gh_dir, gh_log, = FakeGithub.gh_bin(bare: bare)

    payload = claim_payload_for(task_id: TASK, publication: {},
                                root: @root, specification_repository: "component-c",
                                worktree_create_command: "git worktree add .runs/worktrees/#{TASK} -b #{TASK}")
    @platform = FakePlatform.new(claim_payload: payload).start
    @config_path = write_config
    _code, output = run_cli(gh_dir: gh_dir)

    assert_match(/preflight_failed/, output)
    assert_includes output, "no run-aware"
    refute_path_exists File.join(@root, ".runs", "worktrees", TASK)
    assert_equal 0, FakeGithub.pr_creates(gh_log), "nothing may be published"
    refute File.exist?(dev_log), "bin/dev must never be used for workspace discovery or creation"
  end

  # --- S07: path escape and false roots -----------------------------------

  def test_an_absolute_path_is_refused_before_any_github_mutation
    assert_selection_refused(%([ { "path" => "/etc" } ]), /relative/i)
  end

  def test_a_traversal_path_is_refused_before_any_github_mutation
    assert_selection_refused(%([ { "path" => "../.." } ]), /inside the task workspace/i)
  end

  def test_a_symlink_escaping_the_task_workspace_is_refused
    outside = Dir.mktmpdir("outside-repo-")
    File.write(File.join(outside, "app.txt"), "outside\n")
    DemoWorkspace.git_init(outside)
    workspace = MultiRepositoryWorkspace.task_workspace(@root, TASK)
    # The link is planted by the executor itself, inside the workspace, before it reports it.
    assert_selection_refused(%([ { "path" => "escape" } ]), /inside the task workspace/i) do
      FileUtils.mkdir_p(workspace)
      File.symlink(outside, File.join(workspace, "escape"))
    end
  ensure
    FileUtils.remove_entry(outside) if outside && File.directory?(outside)
  end

  def test_a_nonexistent_path_is_refused
    assert_selection_refused(%([ { "path" => "component-z" } ]), /no git repository/i)
  end

  def test_a_directory_that_is_not_a_repository_root_is_refused
    assert_selection_refused(%([ { "path" => "component-a/nested" } ]), /repository root/i) do
      FileUtils.mkdir_p(File.join(MultiRepositoryWorkspace.task_workspace(@root, TASK),
                                  "component-a", "nested"))
    end
  end

  def test_a_repository_not_on_the_canonical_task_branch_is_refused
    assert_selection_refused(%([ { "path" => "component-a" } ]), /canonical branch/i) do
      FakeGithub.git(File.join(MultiRepositoryWorkspace.task_workspace(@root, TASK), "component-a"),
                     "checkout", "-q", "--detach", "HEAD")
    end
  end

  def test_a_reported_repository_with_no_measurable_change_is_refused
    assert_selection_refused(%([ { "path" => "component-c" } ]), /no change/i)
  end

  # --- S08: duplicate identity -------------------------------------------

  def test_two_paths_resolving_to_one_git_root_are_refused_as_duplicates
    assert_selection_refused(%([ { "path" => "component-a" }, { "path" => "./component-a" } ]),
                             /same repository|duplicate/i)
  end

  def test_two_paths_with_one_normalized_remote_are_refused_as_duplicates
    # component-b is re-pointed at component-a's GitHub identity in its scp-like spelling: two
    # different working trees, one repository as far as GitHub is concerned.
    assert_selection_refused(%([ { "path" => "component-a" }, { "path" => "component-b" } ]),
                             /same repository|duplicate/i) do
      FakeGithub.git(File.join(@root, "component-b"), "remote", "set-url", "origin",
                     "https://github.com/SpecRelay/component-a.git")
    end
  end

  # Every refusal must happen BEFORE any external write: no branch on any remote, and no `gh`
  # invocation at all.
  def assert_selection_refused(selection_ruby, reason_pattern)
    start(fixture_env: { "FAKE_EXECUTOR_SELECTION_JSON" => selection_json(selection_ruby) })
    prepare_task_workspace
    yield if block_given?
    run_cli

    assert_equal "failed", terminal["outcome"], "an unsafe selection must fail the attempt"
    assert_empty results, "a refused selection persists no partial repository set"
    @bares.each_key { |slug| assert_empty branches_of(slug), "#{slug} must not be pushed" }
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
    assert_equal 0, FakeGithub.pr_lists(@gh_log)
    assert_match reason_pattern, failure_reason, "the refusal must name the actual fact that failed"
  end

  # Build the task workspace up front, so a test can plant the unsafe state its selection then
  # reports. The runner's own preparation finds the clean workspace already on the canonical
  # branch and continues it, which is the existing retry/resume behaviour rather than a test hook.
  def prepare_task_workspace
    out, status = Open3.capture2e(File.join(@root, "bin", "worktree"), "create", TASK,
                                  "--run-id", IMPL_RUN)
    raise out unless status.success?

    File.write(@built.worktree_log, "")
  end

  # The raw document bytes, built from a Ruby literal so a test can express a shape the
  # production parser must refuse.
  #
  # An entry that names no `commands` gets an empty list, so each literal below stays about the
  # one repository fact it is testing rather than restating the MAPIAI-93 verification shape.
  def selection_json(ruby_literal)
    entries = eval(ruby_literal).map { |entry| entry.is_a?(Hash) ? { "commands" => [] }.merge(entry) : entry } # rubocop:disable Security/Eval
    JSON.generate({ "repositories" => entries })
  end

  # The operator-facing reason, read from the failed report rather than reconstructed.
  def failure_reason
    report = @platform.last_report[:body].fetch("report")
    file = report["files"].find { |f| f["relative_path"] == "manifest.yml" }
    YAML.safe_load(Base64.strict_decode64(file["content_base64"])).to_s
  end

  # --- S09: pull-request idempotency, per repository ----------------------

  def test_an_existing_open_pull_request_is_reused_per_repository
    start
    seed = [ { "url" => PR_URLS.fetch("SpecRelay/component-a"), "state" => "OPEN",
               "headRefName" => BRANCH, "repo" => "SpecRelay/component-a", "headRefOid" => "live" } ]
    gh_dir, gh_log, = FakeGithub.gh_bin(urls: PR_URLS, bares: @bares, seed: seed)

    code, output = run_cli(gh_dir: gh_dir)
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    by_id = results.to_h { |repo| [ repo["id"], repo ] }
    assert_equal PR_URLS.fetch("SpecRelay/component-a"),
                 by_id.fetch("SpecRelay/component-a")["pull_request_url"],
                 "the pull request that tracks component-a's branch must be reused"
    assert_equal PR_URLS.fetch("SpecRelay/component-b"),
                 by_id.fetch("SpecRelay/component-b")["pull_request_url"]
    assert_equal 1, FakeGithub.pr_creates(gh_log),
                 "one repository reused its pull request; only the other may create one"
    assert(FakeGithub.invocations(gh_log).any? { |line| line.include?("--repo SpecRelay/component-b") },
           "every lookup must name the repository it is about")
  end

  # One task branch exists in several repositories, so a pull request on ANOTHER repository's
  # branch of the same name is not this repository's current pull request.
  def test_a_pull_request_on_a_different_repository_is_never_reused
    start(fixture_env: { "FAKE_EXECUTOR_EDITED" => "component-a" })
    seed = [ { "url" => "https://github.com/SpecRelay/component-c/pull/99", "state" => "OPEN",
               "headRefName" => BRANCH, "repo" => "SpecRelay/component-c", "headRefOid" => "live" } ]
    gh_dir, gh_log, = FakeGithub.gh_bin(urls: PR_URLS, bares: @bares, seed: seed)

    run_cli(gh_dir: gh_dir)

    assert_equal PR_URLS.fetch("SpecRelay/component-a"), results.first["pull_request_url"]
    assert_equal 1, FakeGithub.pr_creates(gh_log)
  end

  # --- S10: partial publication failure ----------------------------------

  def test_one_failed_repository_publication_fails_the_whole_attempt
    start
    gh_dir, gh_log, = FakeGithub.gh_bin(urls: PR_URLS, bares: @bares,
                                        fail_create_for: "SpecRelay/component-b")

    run_cli(gh_dir: gh_dir)

    assert_equal "failed", terminal["outcome"], "an incomplete publication is not a success"
    assert_equal "publication_failed", terminal.dig("core", "error_classification")

    by_id = results.to_h { |repo| [ repo["id"], repo ] }
    succeeded = by_id.fetch("SpecRelay/component-a")
    failed = by_id.fetch("SpecRelay/component-b")

    assert_equal PR_URLS.fetch("SpecRelay/component-a"), succeeded["pull_request_url"],
                 "an already-published fact is retained truthfully, not rolled back"
    assert_nil succeeded["publication_error"]
    assert_nil failed["pull_request_url"]
    assert_match(/gh pr create failed/, failed["publication_error"])
    assert_equal BRANCH, failed["branch"], "the branch it did push is still reported"
    assert_equal 2, FakeGithub.pr_creates(gh_log),
                 "each repository attempted its own creation; one succeeded and one failed"
  end

  # --- S10 continued: RETRYING a partial publication ----------------------

  # The recovery half of S10, through the real CLI/Execution/selection path rather than by
  # constructing a verified repository by hand.
  #
  # After the first attempt every selected repository is already COMMITTED, so its working tree
  # is clean and worktree-versus-HEAD measurement sees nothing. The change is still there — it is
  # the task branch's own commits, ahead of the repository's default branch — and the retry has to
  # find it, or the missing pull request can never be completed on this workspace.
  #
  # The first result is LOST rather than recorded. That is the ending after which the same Run is
  # offered again with its environment still in place; a recorded failure ends the Run and hands
  # the environment back, and its recovery is a replacement Run from the pushed branches.
  def test_a_retry_recovers_the_committed_repositories_and_completes_the_missing_publication
    start
    gh_dir, first_log, state = FakeGithub.gh_bin(urls: PR_URLS, bares: @bares,
                                                 fail_create_for: "SpecRelay/component-b")
    @platform.report_response = [ 500, { error: "the response was lost" } ]
    run_cli(gh_dir: gh_dir)
    @platform.report_response = nil
    assert_equal "failed", terminal["outcome"], "the first attempt published only one of two"
    heads = { "SpecRelay/component-a" => branches_of("SpecRelay/component-a")[BRANCH],
              "SpecRelay/component-b" => branches_of("SpecRelay/component-b")[BRANCH] }

    # The retry edits NOTHING: it reports the repositories the previous attempt already
    # committed. `gh` shares the earlier state file, so component-a's pull request is still open.
    # The retry's assignment is the same canonical profile; what changed is the double behind the
    # approved name on this host.
    use_fixture(fixture_dir, @built.executor,
                env: { "FAKE_EXECUTOR_EDITED" => "", "FAKE_EXECUTOR_SELECTED" => "component-a,component-b" })
    retry_dir, retry_log, = FakeGithub.gh_bin(urls: PR_URLS, bares: @bares, state: state)
    @platform.offer_claim_again
    code, output = run_cli(gh_dir: retry_dir)

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    assert_equal "succeeded", terminal["outcome"], "the retry completed the publication"
    assert_equal [ "SpecRelay/component-a", "SpecRelay/component-b" ], result_ids,
                 "a clean but already-committed repository is still this task's output"

    results.each do |repo|
      assert repo["changed"], "the committed task work is a change to publish, not an unchanged repository"
      assert_equal PR_URLS.fetch(repo["id"]), repo["pull_request_url"]
      assert_nil repo["publication_error"]
      assert_equal heads.fetch(repo["id"]), repo["head_commit"],
                   "the existing commit is reused; the retry creates no second commit"
      assert_equal heads.fetch(repo["id"]), branches_of(repo["id"])[BRANCH],
                   "the pushed branch still points at the same commit, so nothing was force-pushed"
      refute_equal repo["base_commit"], repo["head_commit"],
                   "the recovered base is the commit the task work started from"
      assert_equal 1, commits_ahead(repo["id"]), "exactly one commit was ever made for this task"
    end

    assert_equal PR_URLS.fetch("SpecRelay/component-a"), results.find { |r| r["id"] == "SpecRelay/component-a" }["pull_request_url"]
    assert_equal 1, FakeGithub.pr_creates(retry_log),
                 "only the repository that lacked a pull request creates one"
    assert_equal 2, FakeGithub.pr_lists(retry_log), "each repository looked its own pull request up first"
    assert_equal 1, MultiRepositoryWorkspace.worktree_invocations(@built.worktree_log)
      .count { |line| line.start_with?("create") },
                 "the retry continues the same task workspace instead of building a second one"
    assert_includes report_file("manifest.yml"), "component-a/app.txt",
                    "the recovered change set is reported, not an empty diff"
  end

  # The ordinary rule survives the recovery path: a repository the executor never touched has no
  # commit of its own ahead of its default branch, so reporting it is still refused.
  def test_an_untouched_repository_is_still_refused_after_the_recovery_path_exists
    start(fixture_env: { "FAKE_EXECUTOR_EDITED" => "component-a", "FAKE_EXECUTOR_SELECTED" => "component-a,component-c" })
    run_cli

    assert_equal "failed", terminal["outcome"]
    assert_equal "repository_selection_refused", terminal.dig("core", "error_classification")
    assert_empty results
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
  end

  # --- credential safety --------------------------------------------------

  # A token-authenticated https remote puts a credential in the url `git remote get-url origin`
  # returns. It is safe to READ locally and never safe to transmit: the runner derives the
  # canonical credential-free url from the validated slug and carries only that.
  def test_a_credential_bearing_origin_never_leaves_this_host
    secret = "dummy-secret"
    url = FakeGithub.credential_remote(File.join(@root, "component-a"),
                                       @built.bares["component-a"],
                                       "https://#{secret}@github.com/SpecRelay/component-a.git")
    start(fixture_env: { "FAKE_EXECUTOR_EDITED" => "component-a" })
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    assert_equal [ "SpecRelay/component-a" ], result_ids
    assert_equal "https://github.com/SpecRelay/component-a.git", results.first["clone_url"],
                 "the transmitted url is derived from the validated slug, not the configured remote"
    assert_equal PR_URLS.fetch("SpecRelay/component-a"), results.first["pull_request_url"],
                 "the repository still publishes normally through its own origin"

    assert_includes url, secret, "the fixture's origin really carries the credential"
    refute_includes JSON.generate(@platform.requests), secret,
                    "no request Platform receives may carry the credential"
    refute_includes output, secret, "no console line may carry the credential"
    # The report's files travel base64-encoded, so a raw search over the request body would
    # not see a credential inside the generated manifest, summary or captured diff.
    decoded = @platform.last_report[:body].dig("report", "files").map { |f| report_file(f["relative_path"]) }
    assert_operator decoded.length, :>=, 5, "the report really carries its generated artifacts"
    decoded.each_with_index do |content, index|
      refute_includes content, secret,
                      "execution-report artifact #{@platform.last_report[:body].dig('report', 'files')[index]['relative_path']} carries the credential"
    end
  end

  # The same guarantee on the refusal path, where an unexpected repository state is described back
  # to an operator: a refusal names the repository, never its remote's credential.
  def test_a_credential_bearing_origin_is_absent_from_a_refusal
    secret = "dummy-secret"
    FakeGithub.credential_remote(File.join(@root, "component-c"), @built.bares["component-c"],
                                 "https://#{secret}@github.com/SpecRelay/component-c.git")
    start(fixture_env: { "FAKE_EXECUTOR_EDITED" => "component-a", "FAKE_EXECUTOR_SELECTED" => "component-a,component-c" })
    _code, output = run_cli

    assert_equal "repository_selection_refused", terminal.dig("core", "error_classification")
    refute_includes JSON.generate(@platform.requests), secret
    refute_includes output, secret
  end

  def report_file(name)
    file = @platform.last_report[:body].dig("report", "files").find { |f| f["relative_path"] == name }
    Base64.decode64(file.fetch("content_base64"))
  end

  # Commits this repository's task branch holds that its default branch does not — the retry's
  # whole recovery signal, and the proof that no duplicate commit was made.
  # Read from the component repository itself rather than from the task worktree: MAPIAI-97
  # releases the environment once the successful report is accepted, and the task branch this
  # counts is the durable half of what the attempt produced.
  def commits_ahead(slug)
    path = File.join(@root, slug.split("/").last)
    out, status = Open3.capture2e("git", "-C", path, "rev-list", "--count", "main..#{BRANCH}")
    raise out unless status.success?

    out.strip.to_i
  end
end
