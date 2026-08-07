# frozen_string_literal: true

require "test_helper"

# MVP-0033 — the REVIEWER role on the runner side.
#
# The properties under test are the ones that make a review independent and safe on this
# machine: the checkout really is the pinned target (S23), the provider is a FRESH process
# carrying no executor context (S24), and whatever it prints is treated as untrusted input
# (S25-S27). Every example drives the real CommandRunner against a real script on disk and a
# real HTTP FakePlatform, so the process boundary is exercised rather than stubbed.
class ReviewFlowTest < Minitest::Test
  BASE = "1111111111111111111111111111111111111111"
  HEAD = "2222222222222222222222222222222222222222"

  def setup
    @root = Dir.mktmpdir("review-workspace")
    @repo = File.join(@root, "specrelay-platform")
    @io = StringIO.new
    # A review is never obtained through the claim payload in these tests — it is handed to
    # Execution directly — so the fake's claim script is irrelevant and deliberately minimal.
    @platform = FakePlatform.new(claim_payload: { "claimed" => false })
    @platform.start
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@root, true)
  end

  # --- the pinned checkout -------------------------------------------------

  def test_refuses_a_checkout_whose_remote_differs
    build_repo(remote: "https://github.com/someone-else/other.git")

    result = run_review

    refute result.success?
    assert_includes result.message, "different remote"
    assert_empty @platform.review_results.reject { |request| refusal?(request) }
  end

  def test_refuses_when_the_pinned_head_is_absent
    build_repo(head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

    result = run_review

    refute result.success?
    assert_includes result.message, "does not contain the reviewed head"
  end

  def test_refuses_when_there_is_no_local_checkout_at_all
    result = run_review

    refute result.success?
    assert_includes result.message, "no local checkout"
  end

  # A refusal is REPORTED, not merely printed: Platform must record the failed attempt so the
  # run page can explain why no verdict exists.
  def test_a_refusal_is_reported_to_platform_without_a_verdict
    build_repo(remote: "https://github.com/someone-else/other.git")

    run_review

    assert_equal 1, @platform.review_results.size
    assert_nil @platform.last_review["outcome"]
    assert_includes @platform.last_review["summary"], "different remote"
  end

  # --- the fresh reviewer process ------------------------------------------

  def test_submits_the_parsed_verdict_from_a_fresh_process
    build_repo
    script = reviewer_script(<<~JSON)
      {"outcome":"ACCEPT","summary":"Read the diff and ran the suite.",
       "evidence":{"structural_review":true,"verification_run":true,"browser_review":true}}
    JSON

    result = run_review(command: script)

    assert result.success?, result.message
    assert_equal "ACCEPT", @platform.last_review["outcome"]
    assert_equal true, @platform.last_review.dig("evidence", "structural_review")
  end

  # The prompt is the reviewer's ENTIRE input. It must name the pinned commits and must carry
  # no session id, resume flag or executor context.
  def test_the_prompt_pins_the_commits_and_carries_no_executor_context
    build_repo
    capture = File.join(@root, "prompt.txt")
    run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"ok"}), capture: capture))

    prompt = File.read(capture)
    assert_includes prompt, "#{BASE}..#{pinned_head}"
    assert_includes prompt, "You are a FRESH process"
    refute_includes prompt, "--resume"
    refute_includes prompt, "session"
  end

  # The specification arrives as a DOCUMENT MANIFEST. MVP-0033 preserves the single approved
  # specification the product durably provides today; the manifest shape is what lets a later
  # MVP add a resolved Spec PR package without changing this runner.
  def test_the_prompt_renders_every_specification_document_in_the_manifest
    build_repo
    capture = File.join(@root, "prompt.txt")
    packet = review_payload
    packet["specification"]["documents"] << {
      "role" => "technical_analysis", "digest" => "cafebabe0000", "byte_size" => 5, "content" => "EXTRA-DOC"
    }

    run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"ok"}), capture: capture), payload: packet)

    prompt = File.read(capture)
    assert_includes prompt, "approved_specification_source"
    assert_includes prompt, "technical_analysis"
    assert_includes prompt, "EXTRA-DOC"
  end

  def test_a_continuation_carries_the_answer_and_prior_findings
    build_repo
    capture = File.join(@root, "prompt.txt")
    packet = review_payload.merge(
      "continuation" => {
        "previous_attempt_ordinal" => 1, "previous_outcome" => "NEEDS_INPUT",
        "previous_findings" => [ { "severity" => "major", "location" => "a.rb:1", "summary" => "Unbounded scan" } ],
        "question" => { "prompt" => "Which bound?" }, "answer" => { "option" => "other", "text" => "Cap at 50" }
      }
    )

    run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"ok"}), capture: capture), payload: packet)

    prompt = File.read(capture)
    assert_includes prompt, "Cap at 50"
    assert_includes prompt, "Unbounded scan"
    assert_includes prompt, "Which bound?"
  end

  # --- untrusted provider output -------------------------------------------

  def test_malformed_json_fails_without_a_verdict
    build_repo

    result = run_review(command: reviewer_script("I reviewed it and it seemed fine to me."))

    refute result.success?
    assert_includes result.message, "did not return one JSON object"
    assert_nil @platform.last_review["outcome"]
  end

  def test_an_unknown_outcome_is_refused
    build_repo

    result = run_review(command: reviewer_script(%({"outcome":"LOOKS_GOOD","summary":"ok"})))

    refute result.success?
    assert_includes result.message, "outcome must be one of"
  end

  def test_a_non_zero_exit_is_a_failure_rather_than_a_result
    build_repo

    result = run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"ok"}), exit_code: 3))

    refute result.success?
    assert_includes result.message, "exited 3"
    assert_nil @platform.last_review["outcome"]
  end

  def test_oversized_output_is_refused_before_it_is_parsed
    build_repo
    huge = "x" * (SpecrelayRunner::Review::Result::MAX_OUTPUT_BYTES + 10)

    result = run_review(command: reviewer_script(huge))

    refute result.success?
    assert_includes result.message, "more than"
  end

  # JSON wrapped in a fence or a sentence is the normal shape of model output, so the outermost
  # balanced object is taken — while anything that does not parse is still refused.
  def test_json_inside_a_fence_is_accepted
    build_repo
    fenced = "Here is my review:\n```json\n{\"outcome\":\"ACCEPT\",\"summary\":\"Fine.\"}\n```\n"

    assert run_review(command: reviewer_script(fenced)).success?
    assert_equal "ACCEPT", @platform.last_review["outcome"]
  end

  def test_a_credential_in_the_provider_output_is_redacted_before_it_leaves_the_machine
    build_repo
    body = %({"outcome":"ACCEPT","summary":"Fine. Token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 seen."})

    run_review(command: reviewer_script(body))

    assert_includes @platform.last_review["summary"], "[REDACTED]"
    refute_includes @platform.last_review["summary"], "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
  end

  # --- configuration -------------------------------------------------------

  def test_a_machine_with_no_reviewer_provider_refuses_rather_than_guessing
    build_repo
    settings = SpecrelayRunner::Review::Settings.new({}, env: {})

    result = SpecrelayRunner::Review::Execution.call(
      config: config, client: client, payload: review_payload, settings: settings,
      env: workspace_env, io: @io
    )

    refute result.success?
    assert_includes result.message, "no reviewer provider is configured"
  end

  def test_the_public_identity_carries_no_command_or_path
    settings = SpecrelayRunner::Review::Settings.new(
      { "provider" => "fake", "command" => "/Users/someone/bin/review", "args" => [ "--secret" ] }, env: {}
    )

    identity = settings.public_identity(version: "1.2.3")

    assert_equal %w[role name provider version config_digest], identity.keys
    refute_includes identity.values.join(" "), "/Users/someone"
    refute_includes identity.values.join(" "), "--secret"
    assert_match(/\A[0-9a-f]{32}\z/, identity["config_digest"])
  end

  private

  def refusal?(request) = request.dig(:body, "review", "outcome").nil?

  def run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"ok"})), payload: review_payload)
    settings = SpecrelayRunner::Review::Settings.new({ "provider" => "fake", "command" => command }, env: {})
    SpecrelayRunner::Review::Execution.call(
      config: config, client: client, payload: payload, settings: settings,
      env: workspace_env, io: @io
    )
  end

  def workspace_env = { "PATH" => ENV["PATH"], "HOME" => @root }

  def config
    SpecrelayRunner::Config.new(
      { "platform" => { "base_url" => @platform.base_url },
        "runner" => { "id" => "review-runner", "display_name" => "Review Machine" },
        "workspace_roots" => { "tiny-demo-workspace" => @root } }
    )
  end

  def client = SpecrelayRunner::PlatformClient.new(base_url: @platform.base_url, token: FakePlatform::EXPECTED_TOKEN)

  # A real git repository with a real commit, so Checkout's `git cat-file` runs for real.
  def build_repo(remote: "https://github.com/SpecRelay/tiny-demo-workspace.git", head: nil)
    FileUtils.mkdir_p(@repo)
    git "init --quiet --initial-branch=main"
    git "config user.email review@example.com"
    git "config user.name Reviewer"
    git "remote add origin #{remote}"
    File.write(File.join(@repo, "README.md"), "demo\n")
    git "add README.md"
    git "-c commit.gpgsign=false commit --quiet -m first"
    @actual_head = head || `git -C #{@repo} rev-parse HEAD`.strip
  end

  def git(args) = system("git -C #{@repo} #{args}", out: File::NULL, err: File::NULL)

  def review_payload
    {
      "contract_version" => "mvp-0033", "assignment_type" => "review",
      "claim" => { "runner_execution_id" => "rex_fake" },
      "review" => { "attempt_id" => "rvt_fake", "attempt_ordinal" => 1,
                    "input_manifest_digest" => "digest" },
      "ticket" => { "external_id" => "DEMO-1", "task_id" => "DEMO-1" },
      "workspace" => { "key" => "tiny-demo-workspace" },
      "specification" => { "digest" => "specdigest", "documents" => [
        { "role" => "approved_specification_source", "digest" => "abc123", "byte_size" => 9,
          "content" => "# Approved" }
      ] },
      "implementation" => { "run_url" => "#{@platform.base_url}/runs/run_fake" },
      "repositories" => [ { "repository_key" => "specrelay-platform",
                            "slug" => "SpecRelay/tiny-demo-workspace",
                            "clone_url" => "https://github.com/SpecRelay/tiny-demo-workspace.git",
                            "base_commit" => BASE, "head_commit" => pinned_head,
                            "pull_request_url" => "https://github.com/SpecRelay/tiny-demo-workspace/pull/1" } ],
      "execution_evidence" => { "executor_summary" => "Did the work.", "files_changed_summary" => "a.rb",
                                "validation_commands" => [ "rspec" ], "files" => [] },
      "execution_policy" => { "attempt_timeout_seconds" => 30, "lease_renewal_seconds" => 0 },
      "result_contract" => { "outcomes" => %w[ACCEPT CHANGES_REQUESTED NEEDS_INPUT] }
    }
  end

  # The real commit when the repository was built with one, otherwise the deliberately absent
  # sha a refusal test wants.
  def pinned_head = @actual_head || HEAD

  # A reviewer stand-in that prints `body` and exits. It is a real executable launched as a
  # real child process, so the runner's argv, timeout and capture behaviour are all exercised.
  def reviewer_script(body, exit_code: 0, capture: nil)
    path = File.join(@root, "reviewer-#{rand(1_000_000)}.rb")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      File.write(#{capture.inspect}, ARGV.last) if #{capture.inspect}
      print #{body.inspect}
      exit #{exit_code}
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end
end
