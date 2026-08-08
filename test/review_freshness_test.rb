# frozen_string_literal: true

require "test_helper"

# MVP-0033 CR-001 F3 — a pull-request head that moved on the REMOTE must stop the review.
#
# review-001: proving the pinned commit object exists locally proves nothing about the branch
# a reviewer's verdict will be attached to. A push advances `refs/heads/<branch>` while the old
# object stays in the local object store forever, so the reviewer reads the old code and the
# pull request it links to shows something else.
#
# Every example here uses a REAL bare repository as `origin` on local disk, so `git ls-remote`
# runs for real, offline, with no network and no stubbed git.
class ReviewFreshnessTest < Minitest::Test
  BASE = "1111111111111111111111111111111111111111"
  BRANCH = "DEMO-1"

  def setup
    @root = Dir.mktmpdir("review-freshness")
    @remote = File.join(@root, "origin.git")
    @repo = File.join(@root, "specrelay-platform")
    @io = StringIO.new
    @platform = FakePlatform.new(claim_payload: { "claimed" => false })
    @platform.start
    build_remote_and_checkout
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@root, true)
  end

  # The finding, reproduced end to end: the remote branch is two commits ahead, and the pinned
  # commit is still perfectly resolvable in the local object store.
  def test_refuses_when_the_remote_branch_advanced_past_the_pinned_head
    advance_remote

    assert local_commit?(@pinned_head), "the pinned commit must still exist locally"
    result = verify

    refute result.ok?, "a moved remote head must not verify"
    assert result.stale?, "a moved remote head is STALE, not a generic refusal"
    assert_includes result.reason, "moved"
  end

  def test_verifies_while_the_remote_branch_still_points_at_the_pinned_head
    result = verify

    assert result.ok?, result.reason
    refute result.stale?
  end

  # The provider is expensive and its verdict would be worthless. It must never start.
  def test_does_not_launch_the_provider_when_the_remote_head_already_moved
    advance_remote
    marker = File.join(@root, "launched.txt")

    result = run_review(command: reviewer_script(marker))

    refute File.exist?(marker), "the reviewer process must not be launched for a moved head"
    refute result.success?
    assert_equal :stale, result.outcome
  end

  # Platform must record STALE, not a verdict and not a generic failure.
  def test_reports_the_moved_head_to_platform_as_a_stale_target
    advance_remote

    run_review

    assert_equal 1, @platform.stale_reports.size
    assert_includes @platform.stale_reports.first.dig("stale", "reason"), "moved"
    assert_empty @platform.review_results
  end

  # The head can move WHILE the reviewer works. A verdict produced against the old code must
  # not be submitted.
  def test_refuses_to_submit_a_verdict_when_the_head_moved_during_the_review
    marker = File.join(@root, "launched.txt")
    script = reviewer_script(marker, body: %({"outcome":"ACCEPT","summary":"Looked fine."}), advance: true)

    result = run_review(command: script)

    assert File.exist?(marker), "the reviewer did run"
    assert_equal :stale, result.outcome
    assert_empty @platform.review_results, "no verdict may be recorded for a head that moved"
    assert_equal 1, @platform.stale_reports.size
  end

  private

  # A bare repository plus a checkout of it, both real. `origin` is the bare repository's path,
  # and the pinned clone_url is the same path, so Checkout's remote-identity comparison is
  # exercised for real rather than bypassed.
  def build_remote_and_checkout
    system("git init --quiet --bare --initial-branch=#{BRANCH} #{@remote}", out: File::NULL, err: File::NULL)
    seed = File.join(@root, "seed")
    git_clone(seed)
    write_commit(seed, "README.md", "demo\n", "first")
    system("git -C #{seed} push --quiet origin HEAD:refs/heads/#{BRANCH}", out: File::NULL, err: File::NULL)
    git_clone(@repo)
    @pinned_head = `git -C #{@repo} rev-parse HEAD`.strip
    @seed = seed
  end

  def git_clone(target)
    system("git clone --quiet #{@remote} #{target}", out: File::NULL, err: File::NULL)
    system("git -C #{target} config user.email review@example.com", out: File::NULL, err: File::NULL)
    system("git -C #{target} config user.name Reviewer", out: File::NULL, err: File::NULL)
  end

  def write_commit(dir, name, body, message)
    File.write(File.join(dir, name), body)
    system("git -C #{dir} add #{name}", out: File::NULL, err: File::NULL)
    system("git -C #{dir} -c commit.gpgsign=false commit --quiet -m #{message}", out: File::NULL, err: File::NULL)
  end

  # Someone pushes to the pull request's branch. The reviewing checkout is untouched, so the
  # pinned object is still there.
  def advance_remote
    write_commit(@seed, "LATER.md", "added later\n", "second")
    system("git -C #{@seed} push --quiet origin HEAD:refs/heads/#{BRANCH}", out: File::NULL, err: File::NULL)
  end

  def local_commit?(sha)
    system("git -C #{@repo} cat-file -e #{sha}^{commit}", out: File::NULL, err: File::NULL)
  end

  def verify
    SpecrelayRunner::Review::Checkout.verify(
      assignment: SpecrelayRunner::Review::Assignment.new(review_payload), workspace_root: @root
    )
  end

  def run_review(command: nil)
    settings = SpecrelayRunner::Review::Settings.new(
      { "provider" => "fake", "command" => command || "/usr/bin/true" }, env: {}
    )
    SpecrelayRunner::Review::Execution.call(
      config: config, client: client, payload: review_payload, settings: settings,
      env: { "PATH" => ENV["PATH"].to_s, "HOME" => @root }, io: @io
    )
  end

  def config
    SpecrelayRunner::Config.new(
      { "platform" => { "base_url" => @platform.base_url },
        "runner" => { "id" => "freshness-runner", "display_name" => "Freshness Machine" },
        "workspace_roots" => { "tiny-demo-workspace" => @root } }
    )
  end

  def client = SpecrelayRunner::PlatformClient.new(base_url: @platform.base_url, token: FakePlatform::EXPECTED_TOKEN)

  def review_payload
    {
      "contract_version" => "mvp-0033", "assignment_type" => "review",
      "claim" => { "runner_execution_id" => "rex_fake" },
      "review" => { "attempt_id" => "rvt_fake", "attempt_ordinal" => 1, "input_manifest_digest" => "digest" },
      "ticket" => { "external_id" => "DEMO-1", "task_id" => "DEMO-1" },
      "workspace" => { "key" => "tiny-demo-workspace" },
      "specification" => { "digest" => "specdigest", "documents" => [] },
      "implementation" => { "run_url" => "#{@platform.base_url}/runs/run_fake" },
      "repositories" => [ { "repository_key" => "specrelay-platform", "slug" => "SpecRelay/tiny-demo-workspace",
                            "clone_url" => @remote, "base_commit" => BASE, "branch" => BRANCH,
                            "head_commit" => @pinned_head,
                            "pull_request_url" => "https://github.com/SpecRelay/tiny-demo-workspace/pull/1" } ],
      "execution_evidence" => { "executor_summary" => "Did the work.", "files" => [] },
      "execution_policy" => { "attempt_timeout_seconds" => 30, "lease_renewal_seconds" => 0 },
      "result_contract" => { "outcomes" => %w[ACCEPT CHANGES_REQUESTED NEEDS_INPUT] }
    }
  end

  # A reviewer stand-in that records that it ran, optionally pushes to the pull request's
  # branch WHILE it works, and prints a verdict.
  def reviewer_script(marker, body: %({"outcome":"ACCEPT","summary":"ok"}), advance: false)
    path = File.join(@root, "reviewer-#{rand(1_000_000)}.rb")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      File.write(#{marker.inspect}, "ran")
      if #{advance}
        File.write(File.join(#{@seed.inspect}, "LATER.md"), "added during the review\\n")
        system("git -C #{@seed} add LATER.md", out: File::NULL, err: File::NULL)
        system("git -C #{@seed} -c commit.gpgsign=false commit --quiet -m during", out: File::NULL, err: File::NULL)
        system("git -C #{@seed} push --quiet origin HEAD:refs/heads/#{BRANCH}", out: File::NULL, err: File::NULL)
      end
      print #{body.inspect}
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end
end
