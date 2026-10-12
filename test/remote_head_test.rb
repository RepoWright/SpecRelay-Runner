# frozen_string_literal: true

require "test_helper"
require "open3"

# What `ls-remote` established about a branch: its head, "" only when a query that SUCCEEDED found
# no such branch, and nil whenever the query itself did not succeed. A remote branch that is gone
# proves a continued target invalid, so an unanswered query must never read as one.
#
# The answered cases run real `git ls-remote` against a bare repository on local disk; the
# unanswered ones replace only that query's result.
class RemoteHeadTest < Minitest::Test
  BRANCH = "DEMO-1"

  def setup
    @root = Dir.mktmpdir("remote-head-")
    remote = File.join(@root, "origin.git")
    @repo = File.join(@root, "checkout")
    system("git", "init", "-q", "--bare", remote, exception: true)
    system("git", "init", "-q", @repo, exception: true)
    git("config", "user.email", "runner@example.test")
    git("config", "user.name", "Runner Test")
    git("config", "commit.gpgsign", "false")
    git("commit", "-q", "--allow-empty", "-m", "base")
    git("remote", "add", "origin", remote)
    git("push", "-q", "origin", "HEAD:refs/heads/#{BRANCH}")
    @head = git("rev-parse", "HEAD").strip
  end

  def teardown
    FileUtils.remove_entry(@root, true)
  end

  def test_a_successful_query_returns_the_branch_head
    assert_equal @head, remote_head(BRANCH)
  end

  def test_a_successful_query_without_the_branch_reports_it_absent
    assert_equal "", remote_head("gone")
  end

  def test_a_timed_out_query_establishes_nothing
    answered(exit_code: nil, timed_out: true) { assert_nil remote_head("gone") }
  end

  def test_a_query_ended_by_a_signal_establishes_nothing
    answered(exit_code: nil, timed_out: false) { assert_nil remote_head("gone") }
  end

  def test_a_failed_query_establishes_nothing
    answered(exit_code: 128, timed_out: false) { assert_nil remote_head("gone") }
  end

  private

  def remote_head(branch) = SpecrelayRunner::Review::Checkout::Git.remote_head(@repo, branch)

  # Every `ls-remote --heads` answered with an empty result of +exit_code+ and +timed_out+, and
  # no git run for it at all; every other command runs for real.
  def answered(exit_code:, timed_out:)
    result = SpecrelayRunner::CommandRunner::Result.new(exit_code: exit_code, stdout: "", stderr: "",
                                                        duration_seconds: 0, timed_out: timed_out)
    singleton = SpecrelayRunner::CommandRunner.singleton_class
    singleton.send(:alias_method, :run_without_answer, :run)
    singleton.send(:define_method, :run) do |argv, **kwargs|
      next result if argv.include?("ls-remote") && argv.include?("--heads")

      send(:run_without_answer, argv, **kwargs)
    end
    yield
  ensure
    singleton.send(:alias_method, :run, :run_without_answer)
    singleton.send(:remove_method, :run_without_answer)
  end

  def git(*args)
    out, status = Open3.capture2e("git", "-C", @repo, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end
end
