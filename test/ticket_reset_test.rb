# frozen_string_literal: true

require_relative "test_helper"

# The ticket-reset lane, driven through the real CLI against a real FakePlatform, a real bare git
# remote reached through an ssh shim, and a fake `gh` whose invocation log is the primary
# assertion: what matters is not only what was retired but that nothing else was touched.
class TicketResetTest < Minitest::Test
  SLUG = "SpecRelay/reset-demo"
  REPO_URL = "git@github.com:#{SLUG}.git"
  PR_URL = "https://github.com/#{SLUG}/pull/7"
  BRANCH = "DEMO-1-reset-demo"

  def setup
    @remote_dir = Dir.mktmpdir("reset-remote")
    @bare = File.join(@remote_dir, "reset-demo.git")
    @shim = ssh_shim
    @head = seed_remote
    @io = StringIO.new
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@remote_dir, true)
  end

  # --- retiring owned resources -----------------------------------------------------------

  def test_an_owned_open_pull_request_is_closed_and_its_branch_deleted
    log = fake_gh(seed: [ pr(PR_URL, "OPEN") ])

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_reset(assignment), @io.string

    assert_equal [ { "url" => PR_URL, "classification" => "retired" } ], reported["pull_requests"]
    assert_equal [ branch_row("retired") ], reported["branches"]
    assert_equal [ "pr close #{PR_URL} --repo #{SLUG}" ], FakeGithub.pr_closes(log)
    assert_nil remote_sha(BRANCH)
    assert_equal @head, remote_sha("main"), "the default branch was touched"
  end

  def test_a_retry_counts_already_retired_resources_and_repeats_no_close_or_delete
    log = fake_gh(seed: [ pr(PR_URL, "CLOSED") ])
    git(@bare, "update-ref", "-d", "refs/heads/#{BRANCH}")

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_reset(assignment), @io.string

    assert_equal "already_retired", reported["pull_requests"].first["classification"]
    assert_equal "already_retired", reported["branches"].first["classification"]
    assert_empty FakeGithub.pr_closes(log)
  end

  # --- preserving what the reset does not own or must not touch ---------------------------

  def test_merged_default_and_unverifiable_resources_are_preserved
    merged_branch = "merged-work"
    git(@bare, "update-ref", "refs/heads/#{merged_branch}", @head)
    log = fake_gh(seed: [ pr(PR_URL, "MERGED"), pr("https://github.com/#{SLUG}/pull/8", "MERGED", head: merged_branch) ])
    plan = assignment(branches: [ row("main"), row(merged_branch),
                                  row(BRANCH, url: "https://gitlab.example/#{SLUG}.git"),
                                  row(BRANCH, head: nil) ],
                      pull_requests: [ PR_URL, "https://example.com/#{SLUG}/pull/7" ])

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_reset(plan), @io.string

    assert_equal %w[merged unverifiable], reported["pull_requests"].map { |entry| entry["classification"] }
    assert_equal %w[default merged unverifiable unverifiable], reported["branches"].map { |entry| entry["classification"] }
    assert_empty FakeGithub.pr_closes(log)
    assert_equal @head, remote_sha(merged_branch)
    assert_equal @head, remote_sha(BRANCH)
  end

  def test_a_branch_whose_head_moved_is_refused_and_kept
    fake_gh(seed: [])
    moved = commit_on_remote(BRANCH)

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_reset(assignment(pull_requests: [])), @io.string

    assert_equal "moved", reported["branches"].first["classification"]
    assert_equal moved, remote_sha(BRANCH)
  end

  # --- authority ---------------------------------------------------------------------------

  def test_a_claim_platform_already_ended_touches_nothing_and_reports_nothing
    log = fake_gh(seed: [ pr(PR_URL, "OPEN") ])
    start_platform(assignment)
    @platform.signal_expired!

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_empty FakeGithub.invocations(log)
    assert_empty @platform.reset_results
    assert_equal @head, remote_sha(BRANCH)
  end

  def test_the_claim_request_declares_the_reset_capability
    start_platform({ "claimed" => false })
    @platform.offer_no_work!

    run_cli

    assert_equal [ "ticket_reset" ], @platform.requests_to("/api/runner/claim").first[:body]["capabilities"]
  end

  # --- dispatch ----------------------------------------------------------------------------

  def test_an_unknown_assignment_kind_is_refused_and_never_reaches_execution
    start_platform({ "assignment_kind" => "ticket_rename", "claim" => { "execution_id" => "rex_x" },
                     "run" => { "id" => "run_x", "type" => "implementation", "task_id" => "DEMO-9" } })

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_includes @io.string, "Refusing an assignment this runner does not implement (\"ticket_rename\")"
    %w[events heartbeat reports initial_repository_bases].each do |endpoint|
      assert_empty @platform.requests_to("/api/runner/#{endpoint}"), endpoint
    end
  end

  def test_an_assignment_that_is_not_an_executable_implementation_is_refused
    start_platform({ "claim" => { "runner_execution_id" => "rex_x" }, "run" => { "id" => "run_x", "task_id" => "DEMO-9" } })

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_includes @io.string, "Refusing an assignment this runner does not implement (nil)"
    assert_empty @platform.requests_to("/api/runner/reports")
  end

  private

  def assignment(pull_requests: [ PR_URL ], branches: [ row(BRANCH) ])
    { "contract_version" => "1", "assignment_kind" => "ticket_reset",
      "claim" => { "execution_id" => "rex_reset", "lease_expires_at" => "2026-10-07T12:00:00Z" },
      "reset" => { "ticket_key" => "DEMO-1", "canonical_branch" => BRANCH },
      "pull_requests" => pull_requests, "branches" => branches }
  end

  def row(branch, url: REPO_URL, head: :seeded)
    { "repository_url" => url, "branch" => branch, "head_commit" => head == :seeded ? @head : head }
  end

  def branch_row(classification) = { "repository_url" => REPO_URL, "branch" => BRANCH, "classification" => classification }
  def reported = @platform.reset_results.last.fetch("result")

  def run_reset(plan)
    start_platform(plan)
    run_cli
  end

  def start_platform(payload)
    @platform = FakePlatform.new(claim_payload: payload).start
  end

  def run_cli
    config = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(config, <<~YAML)
      platform:
        base_url: #{@platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: test-runner
        display_name: Test Runner
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{@remote_dir}
    YAML
    SpecrelayRunner::CLI.run(%W[claim-once --config #{config}], out: @io, err: @io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "HOME" => ENV["HOME"],
                                    "PATH" => [ @gh_bin, ENV["PATH"] ].compact.join(File::PATH_SEPARATOR),
                                    "GIT_SSH_COMMAND" => @shim })
  end

  def pr(url, state, head: BRANCH) = { "url" => url, "state" => state, "headRefName" => head, "headRefOid" => "" }

  def fake_gh(seed:)
    @gh_bin, log, = FakeGithub.gh_bin(seed: seed)
    log
  end

  # Git runs `<ssh> <host> '<service> <path>'`; this serves the bare remote for any ssh url.
  def ssh_shim
    shim = File.join(@remote_dir, "ssh")
    File.write(shim, <<~RUBY)
      #!/usr/bin/env ruby
      service = ARGV.last.to_s.split(" ").first.to_s.sub(/\\Agit-/, "")
      exec("git", service, #{@bare.inspect})
    RUBY
    FileUtils.chmod(0o755, shim)
    shim
  end

  def seed_remote
    git(@remote_dir, "init", "-q", "--bare", @bare)
    work = File.join(@remote_dir, "work")
    git(@remote_dir, "init", "-q", work)
    git(work, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "base")
    git(work, "push", "-q", @bare, "HEAD:refs/heads/main", "HEAD:refs/heads/#{BRANCH}")
    git(@bare, "symbolic-ref", "HEAD", "refs/heads/main")
    git(work, "rev-parse", "HEAD")
  end

  def commit_on_remote(branch)
    work = File.join(@remote_dir, "work")
    git(work, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "moved")
    git(work, "push", "-q", "-f", @bare, "HEAD:refs/heads/#{branch}")
    git(work, "rev-parse", "HEAD")
  end

  def remote_sha(branch)
    out, status = Open3.capture2e("git", "-C", @bare, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}")
    status.success? ? out.strip : nil
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out.strip
  end
end
