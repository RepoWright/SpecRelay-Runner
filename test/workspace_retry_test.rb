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

  # Git keeps a worktree registration after its directory is removed by hand, and still lists the
  # branch at that path. Using it as a working directory would escape as a system error; the
  # workspace boundary must refuse it instead, name the operator's action, and leave the stale
  # registration untouched — it is the operator's to prune, never the runner's.
  def test_refuses_a_registration_whose_directory_is_missing_and_leaves_it_in_place
    FileUtils.remove_entry(@worktree)

    error = assert_raises(SpecrelayRunner::Workspace::Error) { build_workspace.create }

    assert_includes error.message, "stale worktree registration"
    assert_includes error.message, "git worktree prune"
    refute_includes error.message, @worktree, "the missing absolute path must not be printed"
    assert_includes registrations, "branch refs/heads/DEMO-1"
    assert_includes registrations, "prunable"
    refute File.exist?(@worktree), "nothing may be recreated"
  end

  # The read-only lookup a resume relies on reaches the same registration, so it must meet the
  # same refusal from the same place rather than a second copy of the rule.
  def test_reading_an_existing_worktree_refuses_a_missing_registered_directory_the_same_way
    FileUtils.remove_entry(@worktree)

    error = assert_raises(SpecrelayRunner::Workspace::Error) { build_workspace.existing }

    assert_includes error.message, "git worktree prune"
  end

  private

  def registrations = git_output("worktree", "list", "--porcelain")

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
