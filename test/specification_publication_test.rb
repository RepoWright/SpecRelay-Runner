# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "open3"

# MVP-0027 — the runner turns a claimed PUBLICATION assignment into a real commit, a real push
# to a real remote, and a draft pull request.
#
# Driven through the real `claim-once` CLI against the real fake Platform HTTP server, over a
# REAL git repository with a REAL bare remote, for the same reason the implementation lane's
# publication test is: almost everything this MVP promises is about what happens to a repository,
# and a stubbed git proves none of it. The pull request is the one part that cannot be real, so
# `gh` is a scriptable executable that records its argv — which makes "exactly one pull request
# was created" a fact about invocations rather than about a mock's expectations.
class SpecificationPublicationTest < Minitest::Test
  ISSUE = "SR-700"
  PACKAGE = "specs/SR-700-add-an-export-button"
  BRANCH = "specrelay/spec/SR-700-0123456789ab"
  PR_URL = "https://github.com/SpecRelay/SpecRelay-Specs/pull/7"

  def setup
    @temp = Dir.mktmpdir("specrelay-publication-")
    @specs = File.join(@temp, "SpecRelay-Specs")
    @source = File.join(@temp, "tiny-demo-runs")
    FileUtils.mkdir_p(@source)
    build_specification_checkout
    @io = StringIO.new
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@temp) if @temp && File.directory?(@temp)
    FileUtils.remove_entry(@gh_dir) if @gh_dir && File.directory?(@gh_dir)
  end

  # ---------------------------------------------------------------- criteria 1, 3, 4

  def test_publishes_the_generated_package_as_a_draft_pull_request
    start_platform

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    result = @platform.last_specification_publication
    assert_equal "published", result["outcome"], @io.string
    assert_equal BRANCH, result["branch"]
    assert_equal PR_URL, result["pull_request_url"]
    assert_equal true, result["pull_request_draft"]
    assert_match(/\A[0-9a-f]{40}\z/, result["head_commit"])
  end

  def test_the_pushed_branch_exists_on_the_remote_at_the_reported_commit
    start_platform
    run_cli

    reported = @platform.last_specification_publication["head_commit"]
    assert_equal reported, FakeGithub.remote_branches(@bare)[BRANCH]
  end

  # Criterion 3's "only the generated package files". The tree is the base tree plus exactly the
  # verified files, so this is a property of how the commit is built rather than of careful
  # staging — and the assertion is against the REMOTE, not the local index.
  def test_the_commit_contains_only_the_generated_package_files
    start_platform
    File.write(File.join(@specs, "unrelated.txt"), "an operator's uncommitted work\n")
    run_cli

    commit = @platform.last_specification_publication["head_commit"]
    changed = git(@bare, "diff-tree", "--no-commit-id", "--name-only", "-r", commit).split("\n")

    assert_equal @package_files.map { |f| "#{PACKAGE}/#{f['path']}" }.sort, changed.sort
  end

  # The property that makes it safe to run against a checkout an operator is using: their branch,
  # their HEAD, and their uncommitted work are untouched.
  def test_it_never_moves_the_operators_head_or_working_tree
    start_platform
    File.write(File.join(@specs, "unrelated.txt"), "an operator's uncommitted work\n")
    before_head = git(@specs, "rev-parse", "HEAD").strip
    before_branch = git(@specs, "rev-parse", "--abbrev-ref", "HEAD").strip

    run_cli

    assert_equal before_head, git(@specs, "rev-parse", "HEAD").strip
    assert_equal before_branch, git(@specs, "rev-parse", "--abbrev-ref", "HEAD").strip
    assert_equal "an operator's uncommitted work\n", File.read(File.join(@specs, "unrelated.txt"))
    assert_includes git(@specs, "status", "--porcelain"), "unrelated.txt"
  end

  def test_the_commit_message_names_the_issue_and_carries_role_trailers
    start_platform
    run_cli

    message = git(@bare, "log", "-1", "--format=%B", @platform.last_specification_publication["head_commit"])
    assert_includes message, ISSUE
    assert_includes message, "Agent-Role: runner"
    assert_includes message, "Workflow-Stage: specification-publication"
  end

  # ---------------------------------------------------------------- criterion 5

  def test_retrying_reuses_the_same_branch_commit_and_pull_request
    start_platform
    run_cli
    first = @platform.last_specification_publication

    # The operator's recovery, modelled honestly: Platform offers the same run again — which is
    # what `bin/platform runner retry-publication` produces — and the runner claims it afresh.
    @platform.offer_again!
    @io = StringIO.new
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string
    second = @platform.last_specification_publication

    assert_equal "published", second["outcome"]
    assert_equal first["head_commit"], second["head_commit"], "a retry must not create a second commit"
    assert_equal first["pull_request_url"], second["pull_request_url"]
    assert_equal true, second["reused_pull_request"]
    assert_equal true, second["reused_branch"]
    assert_equal 1, FakeGithub.pr_creates(@gh_log), "a retry must not open a second pull request"
  end

  def test_a_retry_leaves_the_remote_branch_pointing_at_the_same_commit
    start_platform
    run_cli
    before = FakeGithub.remote_branches(@bare)[BRANCH]

    @platform.offer_again!
    run_cli

    assert_equal before, FakeGithub.remote_branches(@bare)[BRANCH]
  end

  # ---------------------------------------------------------------- criterion 2

  def test_a_digest_mismatch_refuses_before_any_git_mutation
    start_platform
    File.write(File.join(@specs, PACKAGE, "spec.md"), "# edited by hand after generation\n")

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    result = @platform.last_specification_publication
    assert_equal "failed", result["outcome"]
    assert_equal "generated_package_digest_mismatch", result["failure_class"]
    refute_includes FakeGithub.remote_branches(@bare).keys, BRANCH,
                    "nothing may reach the remote on a mismatch"
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
  end

  def test_a_missing_generated_file_refuses_before_any_git_mutation
    start_platform
    FileUtils.rm(File.join(@specs, PACKAGE, "analysis/business.md"))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    result = @platform.last_specification_publication
    assert_equal "generated_package_missing", result["failure_class"]
    refute_includes FakeGithub.remote_branches(@bare).keys, BRANCH
  end

  # A stale package: the whole folder is gone, which is what a cleaned or re-cloned checkout
  # looks like. The remedy names regeneration rather than a retry.
  def test_a_stale_package_refuses_and_names_regeneration
    start_platform
    FileUtils.rm_rf(File.join(@specs, PACKAGE))

    run_cli

    result = @platform.last_specification_publication
    assert_equal "generated_package_missing", result["failure_class"]
    assert_includes result["message"], "requeue-specification"
    refute_includes FakeGithub.remote_branches(@bare).keys, BRANCH
  end

  # The message reaches Platform, is stored, and is rendered on the run page — so it must name
  # the repository-relative path and nothing about this machine.
  def test_a_refusal_message_carries_no_absolute_host_path
    start_platform
    File.write(File.join(@specs, PACKAGE, "spec.md"), "# edited\n")

    run_cli

    message = @platform.last_specification_publication["message"]
    refute_includes message, @specs
    refute_includes message, Dir.home
    assert_includes message, "#{PACKAGE}/spec.md"
  end

  # ---------------------------------------------------------------- criterion 8

  def test_missing_github_auth_fails_closed_before_pushing_anything
    start_platform(gh_mode: "unauthenticated")

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    result = @platform.last_specification_publication
    assert_equal "github_cli_unavailable", result["failure_class"]
    assert_includes result["message"], "gh auth login"
    refute_includes FakeGithub.remote_branches(@bare).keys, BRANCH,
                    "a host that cannot open a pull request must not push a branch first"
  end

  # The canonical fail-closed case: the push SUCCEEDED and the pull request did not. The branch
  # is reported as evidence, and the outcome is still a failure.
  def test_pull_request_failure_is_a_failure_that_still_reports_the_branch
    start_platform(gh_mode: "create_fails")

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    result = @platform.last_specification_publication
    assert_equal "failed", result["outcome"]
    assert_equal "pull_request_creation_failed", result["failure_class"]
    assert_equal BRANCH, result["branch"]
    assert_includes FakeGithub.remote_branches(@bare).keys, BRANCH, "the branch really did reach the remote"
    assert_nil result["pull_request_url"]
  end

  def test_a_push_failure_fails_closed_and_opens_no_pull_request
    start_platform
    # A remote that rejects every push, exactly as a permissions failure does.
    git(@specs, "remote", "set-url", "origin", File.join(@temp, "does-not-exist.git"))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    result = @platform.last_specification_publication
    assert_equal "git_push_failed", result["failure_class"]
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
  end

  def test_a_transient_pull_request_lookup_failure_never_creates_a_duplicate
    start_platform(gh_mode: "list_fails")

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    result = @platform.last_specification_publication
    assert_equal "publication_verification_failed", result["failure_class"]
    assert_equal 0, FakeGithub.pr_creates(@gh_log),
                 "SpecRelay must not create a pull request it could not first rule out"
  end

  # A checkout that is a clone of a DIFFERENT repository. Without this check a mis-set
  # repository root would commit a specification into an unrelated repository and report a
  # plausible-looking branch for it.
  def test_a_checkout_of_the_wrong_repository_is_refused
    start_platform
    git(@specs, "remote", "set-url", "origin", "https://github.com/SpecRelay/Somewhere-Else.git")

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    result = @platform.last_specification_publication
    assert_equal "specification_checkout_mismatch", result["failure_class"]
    assert_includes result["message"], "SpecRelay/Somewhere-Else"
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
  end

  # The other half of the rule, asserted so the limit is a decision rather than an accident: a
  # remote that does not resolve to a GitHub slug — this test's own bare remote, an ssh alias, an
  # internal mirror — is NOT treated as a mismatch. Refusing every one of them would refuse
  # legitimate setups on a guess, and the wrong-clone case they could hide still fails closed at
  # the pull-request step, which addresses GitHub by the assigned slug.
  def test_a_remote_that_is_not_a_github_url_is_not_treated_as_a_mismatch
    start_platform

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string
    assert_equal "published", @platform.last_specification_publication["outcome"]
  end

  def test_an_unresolved_specification_checkout_is_refused_with_the_variable_to_set
    start_platform
    @config = build_config(repository_root: nil)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    result = @platform.last_specification_publication
    assert_equal "specification_repository_unresolved", result["failure_class"]
    assert_includes result["message"], "SPECRELAY_RUNNER_SPEC_REPOSITORY_ROOT_SPECRELAY_SPECRELAY_SPECS"
  end

  def test_a_publication_assignment_missing_its_branch_is_refused
    start_platform(payload: publication_payload.tap { |p| p["publication"].delete("branch") })

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    result = @platform.last_specification_publication
    assert_equal "publication_assignment_malformed", result["failure_class"]
    assert_includes result["message"], "publication.branch"
  end

  # ---------------------------------------------------------------- criteria 9 and 12

  def test_it_touches_no_jira_endpoint_and_uploads_no_execution_report
    start_platform
    run_cli

    paths = @platform.requests.map { |request| request[:path] }
    assert_empty paths.grep(%r{/jira}i)
    assert_empty @platform.requests_to("/api/runner/reports")
    assert_empty @platform.requests_to("/api/runner/specification_generations")
    refute_empty @platform.requests_to("/api/runner/specification_publications")
  end

  def test_the_pull_request_body_links_platform_and_jira_and_says_it_is_a_draft
    start_platform
    run_cli

    body = pr_body
    # The run URL PLATFORM sent in the assignment, not one the runner composed from its own
    # endpoint. That distinction is the point: every link in the body is Platform-supplied.
    assert_includes body, "http://127.0.0.1:3200/runs/run_spec123"
    assert_includes body, "https://example.atlassian.net/browse/#{ISSUE}"
    assert_includes body, "This is a draft."
    assert_includes body, "no Jira field, status, or comment has been changed"
  end

  def test_the_pull_request_body_carries_no_secret_local_path_or_command_output
    start_platform
    run_cli

    body = pr_body
    refute_includes body, @specs
    refute_includes body, Dir.home
    refute_match(/ghp_|github_pat_|Authorization:/i, body)
  end

  # Criterion 12's redaction, proven against a REAL git failure rather than a crafted string: a
  # remote URL carrying credential userinfo is what a git error echoes back.
  def test_a_credential_bearing_remote_is_redacted_out_of_the_reported_failure
    start_platform
    git(@specs, "remote", "set-url", "origin",
        "https://x-access-token:ghp_NOTAREALTOKEN0027AAAA@github.test/SpecRelay/SpecRelay-Specs.git")

    run_cli

    result = @platform.last_specification_publication
    refute_includes result["message"].to_s, "ghp_NOTAREALTOKEN0027AAAA"
    refute_includes @io.string, "ghp_NOTAREALTOKEN0027AAAA"
  end

  # The runner must never print a token to its own console either — the whole log, not just the
  # reported message.
  def test_the_console_output_carries_no_secret_shape
    start_platform
    run_cli

    refute_match(/ghp_[A-Za-z0-9]{10,}|github_pat_|-----BEGIN [A-Z ]*PRIVATE KEY-----/, @io.string)
  end

  # ---------------------------------------------------------------- the dispatch

  # An assignment naming an action this build does not implement must STOP rather than fall
  # through to generation — which would regenerate a package an operator may already have
  # reviewed.
  def test_an_unknown_specification_action_stops_instead_of_guessing
    payload = publication_payload
    payload["assignment_boundary"]["expected_runner_action"] = "finalize_in_jira"
    start_platform(payload: payload)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli

    assert_includes @io.string, "does not implement"
    assert_empty @platform.requests_to("/api/runner/specification_publications")
    assert_empty @platform.requests_to("/api/runner/specification_generations")
  end

  private

  # A real git repository with a real bare remote and the generated package already committed
  # nowhere — the package files are UNTRACKED on disk, exactly as MVP-0026 leaves them.
  def build_specification_checkout
    FileUtils.mkdir_p(File.join(@specs, PACKAGE, "analysis"))
    git_init(@specs)
    File.write(File.join(@specs, "README.md"), "# SpecRelay specifications\n")
    git(@specs, "add", "README.md")
    commit(@specs, "initial")
    @bare = FakeGithub.add_remote(@specs, name: "SpecRelay-Specs")
    git(@specs, "push", "-q", "origin", "HEAD:refs/heads/main")
    write_package
  end

  PACKAGE_CONTENTS = {
    "spec.md" => "# SR-700: Add an export button\n\nGenerated by SpecRelay.\n",
    "analysis/business.md" => "# Business analysis\n\nThe reporter retypes rows by hand.\n",
    "analysis/technical.md" => "# Technical analysis\n\nExportReport is the seam.\n",
    "generation-manifest.json" => "{\n  \"contract_version\": \"mvp-0026\"\n}\n"
  }.freeze

  def write_package
    @package_files = PACKAGE_CONTENTS.map do |name, body|
      path = File.join(@specs, PACKAGE, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
      { "path" => name, "sha256" => Digest::SHA256.hexdigest(body), "bytes" => body.bytesize }
    end
  end

  def publication_payload
    spec_publication_payload_for(issue_key: ISSUE, files: @package_files, package_path: PACKAGE,
                                 branch: BRANCH)
  end

  def start_platform(gh_mode: "ok", payload: nil)
    @gh_dir, @gh_log, = FakeGithub.gh_bin(mode: gh_mode, pull_request_url: PR_URL, bare: @bare)
    @platform = FakePlatform.new(claim_payload: payload || publication_payload).start
    @config = build_config
  end

  def build_config(repository_root: :default)
    root = repository_root == :default ? @specs : repository_root
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
        specification:
          provider:
            kind: fake
          repository_roots:
            #{root ? "\"SpecRelay/SpecRelay-Specs\": #{root}" : "{}"}
          context_plus:
            available: true
      workspace_roots:
        tiny-demo-workspace: #{@source}
    YAML
    SpecrelayRunner::Config.load(path)
  end

  # `gh` first on PATH so the runner launches the scriptable fake rather than a real one an
  # operator may have installed. HOME is set so nothing reads this developer's git config.
  def run_cli(env_extra: {})
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
            "PATH" => "#{@gh_dir}:#{ENV['PATH']}", "HOME" => @temp }.merge(env_extra)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{@config.source_path}], out: @io, err: @io, env: env)
  end

  # The recorded `gh pr create` body. The log holds argv joined by spaces, and a pull-request
  # body is multi-line, so it is read from the RAW log between `--body ` and the trailing
  # `--draft` rather than from one line of it.
  def pr_body
    raw = File.read(@gh_log)
    raise "no `gh pr create` was recorded" unless raw.include?("pr create")

    raw.split("--body ", 2).last.to_s.split("\n--draft").first.to_s.sub(/ --draft\s*\z/, "")
  end

  def git_init(root)
    system("git", "init", "-q", root, exception: true)
    git(root, "config", "user.email", "test@specrelay.local")
    git(root, "config", "user.name", "SpecRelay Test")
    git(root, "symbolic-ref", "HEAD", "refs/heads/main")
  end

  def commit(root, message)
    git(root, "commit", "-q", "-m", message)
  end

  def git(root, *args)
    out, status = Open3.capture2e("git", "-C", root, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end
end
