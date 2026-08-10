# frozen_string_literal: true

require_relative "test_helper"

class WorkspaceRetryTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("workspace-retry-")
    run_git("init", "-b", "main")
    run_git("config", "user.email", "runner@specrelay.test")
    run_git("config", "user.name", "SpecRelay Runner Test")
    File.write(File.join(@root, "README.md"), "base\n")
    run_git("add", "README.md")
    run_git("commit", "-m", "base")
    @worktree = File.join(@root, ".worktrees", "DEMO-1")
    run_git("worktree", "add", "-b", "DEMO-1", @worktree, "main")
  end

  def teardown
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  def test_reuses_an_existing_clean_worktree_for_the_same_run
    workspace = build_workspace

    result = workspace.create

    assert_equal File.realpath(@worktree), File.realpath(result.path)
    assert_equal git_output("rev-parse", "HEAD", chdir: @worktree), result.base_commit
  end

  def test_preserves_and_refuses_an_existing_dirty_worktree
    File.write(File.join(@worktree, "unfinished.txt"), "keep me\n")

    error = assert_raises(SpecrelayRunner::Workspace::Error) { build_workspace.create }

    assert_includes error.message, "uncommitted changes"
    assert_equal "keep me\n", File.read(File.join(@worktree, "unfinished.txt"))
  end

  private

  def build_workspace
    SpecrelayRunner::Workspace.new(
      root: @root, canonical_branch: "DEMO-1",
      create_command: "git worktree add -b DEMO-1 .worktrees/DEMO-1 main"
    )
  end

  def run_git(*args) = system("git", "-C", @root, *args, out: File::NULL, err: File::NULL, exception: true)

  def git_output(*args, chdir: @root)
    IO.popen([ "git", "-C", chdir, *args ], &:read).strip
  end
end
