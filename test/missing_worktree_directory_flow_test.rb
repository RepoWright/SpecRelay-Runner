# frozen_string_literal: true

require_relative "test_helper"

# A git worktree registration can outlive its directory: the directory was removed by hand while
# git still lists the canonical branch at that path. Through the whole claim flow, the runner must
# refuse that registration with its ordinary pre-execution failure — not let the missing working
# directory escape as a system error — and must leave the stale registration exactly as it found it.
class MissingWorktreeDirectoryFlowTest < Minitest::Test
  TASK = "DEMO-0002"

  def setup
    @root, @executor = DemoWorkspace.build
    @platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK)).start
    @io = StringIO.new
    system(File.join(@root, "bin", "worktree"), "create", TASK, out: File::NULL, err: File::NULL, exception: true)
    FileUtils.remove_entry(worktree)
  end

  def teardown
    @platform.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_a_registration_without_its_directory_is_refused_before_the_provider_and_left_in_place
    exit_code = SpecrelayRunner::CLI.run(%W[claim-once --config #{config_path}], out: @io, err: @io,
                                         env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] })

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    assert_match(/preflight_failed/, @io.string)
    assert_match(/stale worktree registration/, @io.string)
    assert_match(/git worktree prune/, @io.string)
    refute_includes @io.string, worktree, "the missing absolute path must not be printed"
    refute_match(/Errno::|\.rb:\d+:in /, @io.string, "no stack trace may reach the operator")

    # Nothing ran and nothing was written: no provider, no report, no claim release.
    refute_match(/\[fake-executor\]/, @io.string)
    refute_match(/core\.started/, posted_event_bodies)
    assert_equal 1, @platform.requests_to("/api/runner/claim").size
    assert_equal 0, @platform.requests_to("/api/runner/reports").size
    assert_equal 0, @platform.requests_to("/api/runner/claim_releases").size

    # The stale registration is the operator's to prune: still listed, still prunable, not recreated.
    listing = IO.popen([ "git", "-C", @root, "worktree", "list", "--porcelain" ], &:read)
    assert_includes listing, "branch refs/heads/#{TASK}"
    assert_includes listing, "prunable"
    refute File.exist?(worktree)
  end

  private

  def worktree = File.join(@root, ".runs", "worktrees", TASK)

  def posted_event_bodies = @platform.requests_to("/api/runner/events").map { |request| request[:body].to_s }.join("\n")

  def config_path
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
end
