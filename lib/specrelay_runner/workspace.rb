# frozen_string_literal: true

require "shellwords"

module SpecrelayRunner
  # Local worktree operations for the standalone runner (MVP-0010) — a runner/
  # operator responsibility, not Platform's. It runs the workspace's configured
  # `worktree_create_command` (received in the run payload) verbatim as an argv
  # array in the operator's local workspace root, locates the created worktree by
  # matching the run's canonical branch, and captures the git diff/changed files
  # the executor produced.
  #
  # Platform never learns or depends on these physical paths; they travel only in
  # the report's worktree_identity audit evidence.
  class Workspace
    Error = Class.new(StandardError)

    Info = Struct.new(:path, :base_commit, keyword_init: true)

    # `measurement_error` is set when the change set could not be established at all.
    # It is NOT the same as "no files changed", and callers must not conflate them:
    # on the success path an unmeasurable worktree has to fail the run, because
    # reporting `changed: false` would tell Jira "no code changes" while the
    # executor's diff sits on disk (review-002 finding N1).
    Changes = Struct.new(:changed_files, :diff, :head_commit, :measurement_error, keyword_init: true) do
      def measured? = measurement_error.nil?
    end

    def initialize(root:, canonical_branch:, create_command:, env: {})
      @root = root.to_s
      @canonical_branch = canonical_branch.to_s
      @create_command = create_command.to_s
      @env = { "PATH" => ENV["PATH"].to_s }.merge(env)
    end

    def create
      result = run(Shellwords.split(create_command))
      unless result.success?
        raise Error, "worktree create failed (exit #{result.exit_code}): #{first_line(result.stderr, result.stdout)}"
      end

      path = locate
      Info.new(path: path, base_commit: rev_parse(path, "HEAD"))
    end

    # Capture changed files (tracked + untracked via intent-to-add) and a unified
    # diff vs HEAD.
    #
    # Never raises — that is load-bearing, not a convenience: the executor-failure
    # path calls this to describe a broken attempt before uploading a FAILED report,
    # and raising there crashed the runner and left the run stuck (QUALITY-0002).
    #
    # But "did not raise" must never be confused with "measured zero changes". When
    # the change set cannot be established the result carries a `measurement_error`
    # and an EMPTY file list, and the caller decides: truthful on the failure path,
    # fatal on the success path. Returning a bare empty list here is what let a
    # single transient spawn error be announced to Jira as "no code changes"
    # (review-002 finding N1).
    def capture_changes(path)
      status = git(path, %w[status --porcelain])
      return unmeasured("git status failed: #{first_line(status.stderr, status.stdout)}") unless status.success?

      git(path, %w[add -A -N])
      diff = git(path, %w[diff HEAD]).stdout.to_s
      Changes.new(changed_files: parse_changed(status.stdout), diff: diff,
                  head_commit: rev_parse(path, "HEAD"), measurement_error: nil)
    rescue SystemCallError => e
      # Process.spawn failures only: Errno::ENOENT/ENOTDIR for an unusable directory,
      # but also transient conditions such as EMFILE/EAGAIN/ENOMEM. None of them tells
      # us anything about the diff, so none may be reported as "unchanged".
      unmeasured("could not run git in the worktree: #{e.class}")
    end

    private

    attr_reader :root, :canonical_branch, :create_command, :env

    def unmeasured(reason)
      Changes.new(changed_files: [], diff: "", head_commit: nil, measurement_error: reason)
    end

    def locate
      listing = git(root, %w[worktree list --porcelain])
      raise Error, "could not list git worktrees in #{root}" unless listing.success?

      path = parse_worktree_for_branch(listing.stdout)
      raise Error, "no worktree found for branch #{canonical_branch} after create" if path.to_s.empty?

      path
    end

    def parse_worktree_for_branch(porcelain)
      current = {}
      porcelain.to_s.each_line do |line|
        line = line.chomp
        if line.empty?
          return current[:worktree] if current[:branch] == "refs/heads/#{canonical_branch}"

          current = {}
        elsif line.start_with?("worktree ")
          current[:worktree] = line.delete_prefix("worktree ")
        elsif line.start_with?("branch ")
          current[:branch] = line.delete_prefix("branch ")
        end
      end
      current[:branch] == "refs/heads/#{canonical_branch}" ? current[:worktree] : nil
    end

    def parse_changed(porcelain)
      porcelain.to_s.each_line.filter_map do |line|
        line = line.chomp
        next if line.empty?

        path = line[3..].to_s
        path.include?(" -> ") ? path.split(" -> ").last : path
      end.uniq.first(500)
    end

    def rev_parse(path, ref)
      result = git(path, [ "rev-parse", ref ])
      result.success? ? result.stdout.to_s.strip : nil
    end

    # Runs in `dir` as well as targeting it with `-C`, so a git query about a
    # worktree never depends on the workspace root being usable.
    def git(dir, args) = run([ "git", "-C", dir.to_s, *args ], chdir: dir)

    def run(argv, chdir: root) = CommandRunner.run(argv, chdir: chdir, env: env, timeout_seconds: 300)

    def first_line(*candidates)
      candidates.map { |c| c.to_s.strip }.find { |s| !s.empty? }.to_s.each_line.first.to_s.strip
    end
  end
end
