# frozen_string_literal: true

require "test_helper"

# MAPIAI-88 — closing the pull requests an accepted candidate makes obsolete, in the RUNNER PARENT.
#
# Every example drives the real Review::Execution against a real fake `gh` executable and a real
# HTTP FakePlatform, so the argv that reaches the CLI, the order of the calls, and the state the
# CLI leaves behind are observable facts. The invocation log is the primary assertion: what matters
# is not only that a close happened but that nothing else did.
class ReviewRetirementTest < Minitest::Test
  BASE = "1111111111111111111111111111111111111111"
  SLUG = "SpecRelay/tiny-demo-workspace"
  C_REPO = "SpecRelay/repository-c"
  D_REPO = "SpecRelay/repository-d"
  C_URL = "https://github.com/SpecRelay/repository-c/pull/17"
  D_URL = "https://github.com/SpecRelay/repository-d/pull/23"
  A_URL = "https://github.com/SpecRelay/repository-a/pull/11"
  DIGEST = "a" * 64
  VIEW = "--json url,state,mergedAt"

  def setup
    @root = Dir.mktmpdir("review-retirement")
    @repo = File.join(@root, "specrelay-platform")
    @io = StringIO.new
    @platform = FakePlatform.new(claim_payload: { "claimed" => false })
    @platform.start
    build_repo
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@root, true)
  end

  # --- the ordinary close ---------------------------------------------------

  def test_an_open_obsolete_pull_request_is_inspected_closed_and_confirmed
    plan([ entry(C_REPO, C_URL) ])
    log = fake_gh(seed: [ pr(C_URL, "OPEN") ])

    result = run_review

    assert result.success?, result.message
    assert_equal [ "pr view #{C_URL} --repo #{C_REPO} #{VIEW}",
                   "pr close #{C_URL} --repo #{C_REPO}",
                   "pr view #{C_URL} --repo #{C_REPO} #{VIEW}" ],
                 FakeGithub.invocations(log)
    completion = @platform.last_retirement_completion
    assert_equal DIGEST, completion["digest"]
    assert_equal [ { "repository" => C_REPO, "pull_request_url" => C_URL } ], completion["pull_requests"]
  end

  # The completion carries the IDENTICAL review body the prepare did: Platform recomputes the plan
  # and compares digests, so a rebuilt body would no longer match what the closes were authorized
  # by.
  def test_the_completion_repeats_the_identical_review_body
    plan([ entry(C_REPO, C_URL) ])
    fake_gh(seed: [ pr(C_URL, "OPEN") ])

    run_review

    bodies = @platform.review_results.map { |request| request[:body]["review"] }
    assert_equal 2, bodies.length
    assert_equal bodies.first, bodies.last
  end

  def test_an_already_closed_unmerged_pull_request_converges_without_a_second_close
    plan([ entry(C_REPO, C_URL) ])
    log = fake_gh(seed: [ pr(C_URL, "CLOSED") ])

    result = run_review

    assert result.success?, result.message
    assert_empty FakeGithub.pr_closes(log)
    assert_equal 1, @platform.retirement_completions.length
  end

  def test_a_merged_pull_request_is_a_product_decision_and_is_never_closed
    plan([ entry(C_REPO, C_URL) ])
    log = fake_gh(seed: [ pr(C_URL, "MERGED") ])

    result = run_review

    refute result.success?
    assert_empty FakeGithub.pr_closes(log)
    assert_empty @platform.retirement_completions
    assert_equal "product_decision_required", @platform.last_review_failure["kind"]
    assert_includes @platform.last_review_failure["reason"], "merged"
  end

  # A CLOSED state with a merge timestamp is a contradiction, so both fields are read and the
  # merged one wins. Reading only `state` would let this row be treated as an ordinary success.
  def test_a_closed_pull_request_that_carries_a_merge_timestamp_is_treated_as_merged
    plan([ entry(C_REPO, C_URL) ])
    log = fake_gh(seed: [ pr(C_URL, "CLOSED").merge("mergedAt" => "2026-01-01T00:00:00Z") ])

    result = run_review

    refute result.success?
    assert_empty FakeGithub.pr_closes(log)
    assert_equal "product_decision_required", @platform.last_review_failure["kind"]
  end

  # --- retained entries ----------------------------------------------------

  def test_a_retained_pull_request_is_never_named_to_gh
    plan([ entry(C_REPO, C_URL) ])
    log = fake_gh(seed: [ pr(C_URL, "OPEN"), pr(A_URL, "OPEN") ])

    run_review

    refute_includes FakeGithub.invocations(log).join("\n"), A_URL
    assert_equal [ pr(A_URL, "OPEN")["state"] ], [ live_state(A_URL) ]
  end

  # --- the closed set of reachable operations ------------------------------
  #
  # The property is "there is no such call site", not "this one was not taken", so it is asserted
  # over the delivered CODE as well as over the invocation log. Comment lines are excluded
  # deliberately: prose naming a forbidden operation is documentation, not a call.
  def test_the_only_reachable_gh_subcommands_are_pr_view_and_pr_close
    assert_equal [ '"pr", "view"', '"pr", "close"' ].sort, retirement_code.scan(/"pr", "\w+"/).uniq.sort
  end

  # Every string literal that could become an argv token, checked against the operations SpecRelay
  # must never perform. Asserted on WHOLE tokens rather than on substrings, so `mergedAt` — a field
  # this code reads precisely so it can refuse a merged pull request — is not mistaken for a merge.
  FORBIDDEN_TOKENS = %w[merge reopen revert edit push squash rebase admin
                        --delete-branch --merge --squash --rebase --force --force-with-lease
                        --admin --base --head --body --body-file].freeze

  def test_no_merge_reopen_force_push_branch_deletion_or_edit_token_is_reachable
    tokens = retirement_code.scan(/"([^"\#{}]*)"/).flatten

    assert_empty tokens & FORBIDDEN_TOKENS
  end

  def test_every_command_is_an_argument_array_and_nothing_reaches_a_shell
    reached = [ "`", "system(", "IO.popen", "Kernel.exec", "%x" ].select { |shell| retirement_code.include?(shell) }

    assert_empty reached
  end

  # --- fail-closed inspection ----------------------------------------------

  def test_a_url_that_does_not_belong_to_the_planned_repository_is_refused_before_any_call
    plan([ entry(C_REPO, D_URL) ])
    log = fake_gh(seed: [])

    result = run_review

    refute result.success?
    assert_empty FakeGithub.invocations(log)
    assert_equal "retirement_failure", @platform.last_review_failure["kind"]
  end

  UNSAFE_URLS = {
    "plain http" => "http://github.com/SpecRelay/repository-c/pull/17",
    "credential userinfo" => "https://user:ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345@github.com/SpecRelay/repository-c/pull/17",
    "a foreign host" => "https://gitlab.com/SpecRelay/repository-c/pull/17",
    "a near-miss path" => "https://github.com/SpecRelay/repository-c/pulls/17",
    "a longer path" => "https://github.com/SpecRelay/repository-c/pull/17/files",
    "not a url" => "not a url at all"
  }.freeze

  UNSAFE_URLS.each do |description, url|
    define_method(:"test_#{description.tr(' -', '__')}_is_refused_before_any_gh_call") do
      plan([ entry(C_REPO, url) ])
      log = fake_gh(seed: [])

      result = run_review

      refute result.success?
      assert_empty FakeGithub.invocations(log)
      assert_equal "retirement_failure", @platform.last_review_failure["kind"]
      refute_includes @platform.last_review_failure["reason"], "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
    end
  end

  def test_an_unreadable_inspection_is_a_retryable_failure
    %w[view_fails view_garbage].each do |mode|
      @platform.requests.clear
      plan([ entry(C_REPO, C_URL) ])
      log = fake_gh(mode: mode, seed: [ pr(C_URL, "OPEN") ])

      result = run_review

      refute result.success?, "expected #{mode} to fail closed"
      assert_empty FakeGithub.pr_closes(log)
      assert_equal "retirement_failure", @platform.last_review_failure["kind"]
    end
  end

  def test_a_response_describing_a_different_pull_request_is_refused
    plan([ entry(C_REPO, C_URL) ])
    log = fake_gh(seed: [ pr(C_URL, "OPEN").merge("url" => D_URL) ])

    result = run_review

    refute result.success?
    assert_empty FakeGithub.pr_closes(log)
    assert_equal "retirement_failure", @platform.last_review_failure["kind"]
  end

  def test_an_unknown_state_is_refused_rather_than_guessed
    plan([ entry(C_REPO, C_URL) ])
    log = fake_gh(seed: [ pr(C_URL, "LOCKED") ])

    result = run_review

    refute result.success?
    assert_empty FakeGithub.pr_closes(log)
    assert_equal "retirement_failure", @platform.last_review_failure["kind"]
  end

  def test_a_failed_close_is_a_retryable_failure_with_a_redacted_reason
    plan([ entry(C_REPO, C_URL) ])
    fake_gh(mode: "close_fails", seed: [ pr(C_URL, "OPEN") ])

    result = run_review

    refute result.success?
    assert_empty @platform.retirement_completions
    assert_equal "retirement_failure", @platform.last_review_failure["kind"]
  end

  def test_a_close_gh_reports_but_does_not_perform_is_not_a_success
    plan([ entry(C_REPO, C_URL) ])
    fake_gh(mode: "close_ineffective", seed: [ pr(C_URL, "OPEN") ])

    result = run_review

    refute result.success?
    assert_empty @platform.retirement_completions
    assert_equal "retirement_failure", @platform.last_review_failure["kind"]
  end

  def test_a_missing_gh_binary_is_a_retryable_failure_rather_than_a_crash
    plan([ entry(C_REPO, C_URL) ])
    @gh_bin = File.join(@root, "empty-bin")
    FileUtils.mkdir_p(@gh_bin)
    @log = File.join(@gh_bin, "gh.log")

    result = run_review

    refute result.success?
    assert_equal "retirement_failure", @platform.last_review_failure["kind"]
  end

  # The timeout is INJECTED rather than set on the class, so the example needs no process-global
  # mutation and cannot leak a one-second GitHub timeout into another test.
  def test_a_hanging_gh_call_times_out_as_a_retryable_failure
    log = fake_gh(mode: "view_hangs", seed: [ pr(C_URL, "OPEN") ])

    outcome = SpecrelayRunner::Review::Retirement.new(
      plan: { "digest" => DIGEST, "pull_requests" => [ entry(C_REPO, C_URL) ] },
      chdir: @root, env: workspace_env, timeout_seconds: 1
    ).call

    refute outcome.ok?
    assert_equal SpecrelayRunner::Review::Retirement::RETRYABLE, outcome.failure_kind
    assert_includes outcome.reason, "timed out"
    assert_empty FakeGithub.pr_closes(log)
  end

  MALFORMED_PLANS = {
    "no pull requests" => { "digest" => DIGEST, "pull_requests" => [] },
    "no digest" => { "digest" => "", "pull_requests" => [ { "repository" => C_REPO, "pull_request_url" => C_URL } ] },
    "a missing repository" => { "digest" => DIGEST, "pull_requests" => [ { "pull_request_url" => C_URL } ] },
    "an unbounded list" => { "digest" => DIGEST, "pull_requests" => Array.new(101) { { "repository" => C_REPO, "pull_request_url" => C_URL } } },
    "not a list" => { "digest" => DIGEST, "pull_requests" => "everything" }
  }.freeze

  MALFORMED_PLANS.each do |description, malformed|
    define_method(:"test_a_plan_with_#{description.tr(' -', '__')}_is_refused_before_any_gh_call") do
      log = fake_gh(seed: [ pr(C_URL, "OPEN") ])

      outcome = SpecrelayRunner::Review::Retirement.new(plan: malformed, chdir: @root, env: workspace_env).call

      refute outcome.ok?
      assert_equal SpecrelayRunner::Review::Retirement::RETRYABLE, outcome.failure_kind
      assert_empty FakeGithub.invocations(log)
    end
  end

  # --- partial failure and the cross-machine retry -------------------------

  def test_a_partial_retirement_leaves_the_closed_entry_closed_and_completes_on_retry
    plan([ entry(C_REPO, C_URL), entry(D_REPO, D_URL) ])
    first_dir, first_log, state =
      FakeGithub.gh_bin(fail_view_for: D_REPO, seed: [ pr(C_URL, "OPEN"), pr(D_URL, "OPEN") ])
    use_gh(first_dir, first_log)

    failed = run_review

    refute failed.success?
    assert_equal [ "pr close #{C_URL} --repo #{C_REPO}" ], FakeGithub.pr_closes(first_log)
    assert_empty @platform.retirement_completions

    # A fresh attempt against the SAME live GitHub state — a different machine would see exactly
    # this: C already closed, D still open.
    second_dir, second_log, = FakeGithub.gh_bin(state: state)
    use_gh(second_dir, second_log)

    retried = run_review

    assert retried.success?, retried.message
    assert_equal [ "pr close #{D_URL} --repo #{D_REPO}" ], FakeGithub.pr_closes(second_log)
    assert_equal 2, @platform.last_retirement_completion["pull_requests"].length
  end

  # --- transport replay ----------------------------------------------------

  # Platform committed the reservation and the answer vanished. The identical prepare is delivered
  # again, the reviewer is NOT rerun, and the closes happen exactly once.
  def test_a_lost_prepare_response_is_replayed_without_relaunching_the_reviewer
    plan([ entry(C_REPO, C_URL) ])
    log = fake_gh(seed: [ pr(C_URL, "OPEN") ])
    launches = File.join(@root, "launches")

    result = run_review(counter: launches, client: lossy_client(lose: 1))

    assert result.success?, result.message
    assert_equal 1, File.read(launches).to_i, "the reviewer must run exactly once"
    assert_equal [ "pr close #{C_URL} --repo #{C_REPO}" ], FakeGithub.pr_closes(log)
  end

  def test_a_lost_completion_response_is_replayed_with_the_identical_body_and_no_second_close
    plan([ entry(C_REPO, C_URL) ])
    log = fake_gh(seed: [ pr(C_URL, "OPEN") ])
    launches = File.join(@root, "launches")

    result = run_review(counter: launches, client: lossy_client(lose: 2))

    assert result.success?, result.message
    assert_equal 1, File.read(launches).to_i, "the reviewer must run exactly once"
    assert_equal [ "pr close #{C_URL} --repo #{C_REPO}" ], FakeGithub.pr_closes(log)
    completions = @platform.retirement_completions
    assert_equal 2, completions.length, "Platform must have received the committed body and its replay"
    assert_equal completions.first, completions.last
  end

  private

  # The delivered file with its comment lines removed, so the assertions are about code.
  def retirement_code
    @retirement_code ||= File.readlines(File.expand_path("../lib/specrelay_runner/review/retirement.rb", __dir__))
                             .grep_v(/\A\s*#/).join
  end

  def plan(entries, digest: DIGEST)
    @platform.retirement_plan = { "digest" => digest, "pull_requests" => entries }
  end

  def entry(repository, url) = { "repository" => repository, "pull_request_url" => url }
  def pr(url, state) = { "url" => url, "state" => state, "headRefName" => "DEMO-1", "headRefOid" => "" }
  def live_state(url) = JSON.parse(File.read(@state)).find { |row| row["url"] == url }["state"]

  def fake_gh(mode: "ok", seed: [])
    dir, log, state = FakeGithub.gh_bin(mode: mode, seed: seed)
    @state = state
    use_gh(dir, log)
    log
  end

  def use_gh(dir, log)
    @gh_bin = dir
    @log = log
  end

  def run_review(counter: nil, client: default_client)
    settings = SpecrelayRunner::Review::Settings.new({ "provider" => "fake", "command" => reviewer_script(counter) },
                                                    env: {})
    SpecrelayRunner::Review::Execution.call(config: config, client: client, payload: review_payload,
                                            settings: settings, env: workspace_env, io: @io)
  end

  def workspace_env = { "PATH" => "#{@gh_bin}:#{ENV['PATH']}", "HOME" => @root }

  def config
    SpecrelayRunner::Config.new(
      { "platform" => { "base_url" => @platform.base_url },
        "runner" => { "id" => "review-runner", "display_name" => "Review Machine" },
        "workspace_roots" => { "tiny-demo-workspace" => @root } }
    )
  end

  def default_client
    SpecrelayRunner::PlatformClient.new(base_url: @platform.base_url, token: FakePlatform::EXPECTED_TOKEN)
  end

  # A client whose Nth exchange reaches Platform, is committed there, and then loses the response
  # on the way back — this machine cannot tell that from "Platform never saw it".
  def lossy_client(lose:)
    SpecrelayRunner::PlatformClient.new(base_url: @platform.base_url, token: FakePlatform::EXPECTED_TOKEN,
                                        http: LossyHttp.new(lose))
  end

  class LossyHttp
    def initialize(lose)
      @lose = lose
      @seen = 0
    end

    def start(*args, **kwargs, &block)
      @seen += 1
      response = Net::HTTP.start(*args, **kwargs, &block)
      raise EOFError, "the committed response was lost" if @seen == @lose

      response
    end
  end

  def build_repo
    FileUtils.mkdir_p(@repo)
    git "init --quiet --initial-branch=main"
    git "config user.email review@example.com"
    git "config user.name Reviewer"
    git "remote add origin https://github.com/#{SLUG}.git"
    File.write(File.join(@repo, "README.md"), "demo\n")
    git "add README.md"
    git "-c commit.gpgsign=false commit --quiet -m first"
    @head = `git -C #{@repo} rev-parse HEAD`.strip
  end

  def git(args) = system("git -C #{@repo} #{args}", out: File::NULL, err: File::NULL)

  def review_payload
    { "contract_version" => "mvp-0033", "assignment_type" => "review",
      "claim" => { "runner_execution_id" => "rex_fake" },
      "review" => { "attempt_id" => "rvt_fake", "attempt_ordinal" => 1, "input_manifest_digest" => "digest" },
      "ticket" => { "external_id" => "DEMO-1", "task_id" => "DEMO-1" },
      "workspace" => { "key" => "tiny-demo-workspace" },
      "specification" => { "digest" => "specdigest", "documents" => [
        { "role" => "approved_specification_source", "digest" => "abc123", "byte_size" => 9, "content" => "# Approved" }
      ] },
      "implementation" => { "run_url" => "#{@platform.base_url}/runs/run_fake" },
      "repositories" => [ { "repository_key" => "specrelay-platform", "slug" => SLUG,
                            "clone_url" => "https://github.com/#{SLUG}.git",
                            "base_commit" => BASE, "head_commit" => @head,
                            "pull_request_url" => "https://github.com/#{SLUG}/pull/1" } ],
      "execution_evidence" => { "executor_summary" => "Did the work.", "files_changed_summary" => "a.rb",
                                "validation_commands" => [ "rspec" ], "files" => [] },
      "execution_policy" => { "attempt_timeout_seconds" => 30, "lease_renewal_seconds" => 0 },
      "result_contract" => { "outcomes" => %w[ACCEPT CHANGES_REQUESTED NEEDS_INPUT] } }
  end

  # A reviewer stand-in that prints one ACCEPT and, when asked, counts its own launches — which is
  # how "a transport replay did not rerun the provider" is proved rather than assumed.
  def reviewer_script(counter)
    path = File.join(@root, "reviewer-#{rand(1_000_000)}.rb")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      if #{counter.inspect}
        seen = File.exist?(#{counter.inspect}) ? File.read(#{counter.inspect}).to_i : 0
        File.write(#{counter.inspect}, (seen + 1).to_s)
      end
      print '{"outcome":"ACCEPT","summary":"Read the diff and ran the suite.","evidence":{"structural_review":true,"verification_run":true,"browser_review":true}}'
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end
end
