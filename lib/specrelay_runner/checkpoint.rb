# frozen_string_literal: true

require "digest"

module SpecrelayRunner
  # What this machine looked like when a provider paused on a question, and the proof that a
  # later session is landing on exactly that machine (MVP-0036 Stage 2a design 3).
  #
  # Five bounded PUBLIC facts and nothing else: which repository, which remote it really points
  # at, which branch, which commit, and a digest of the uncommitted change set. No path, no file
  # content, no credential and no transcript — the dirty work never leaves this machine, and the
  # digest is how Platform can hold a promise about it without ever seeing it.
  #
  # The measurements are the ones that already exist: {Workspace#capture_changes} for the change
  # set and {Review::Checkout.identity} for the remote, so an https remote and its scp-like ssh
  # spelling are one repository here exactly as they are for a reviewed checkout.
  #
  # It fails CLOSED, and every refusal names the term that failed. A resume onto a worktree that
  # is gone, unreadable, clean or different is refused before any provider starts, because the
  # whole point of resuming is to continue the work that is there — starting over on top of it,
  # or beside it, is the outcome this exists to prevent.
  module Checkpoint
    FIELDS = %w[repository_key origin branch head change_digest].freeze

    Result = Struct.new(:ok, :reason, keyword_init: true) do
      def ok? = ok
    end

    module_function

    # The five facts, or NIL when this machine cannot supply all of them.
    #
    # Nil is a real answer rather than an error: a machine that cannot measure its own worktree
    # still has a genuine question for the Product Owner, and refusing to ask it would trade a
    # decision away for a recovery path that was never going to be available.
    def measure(repository_key:, branch:, worktree_path:, workspace:, git: Review::Checkout::Git)
      changes = workspace.capture_changes(worktree_path)
      return nil unless changes.measured?

      origin = Review::Checkout.identity(git.remote_url(worktree_path))
      head = changes.head_commit.to_s.downcase
      return nil if origin.empty? || head.empty?

      { "repository_key" => repository_key.to_s, "origin" => origin, "branch" => branch.to_s,
        "head" => head, "change_digest" => Digest::SHA256.hexdigest(changes.diff.to_s) }
    end

    # `repository_key` and `branch` come from the CLAIM rather than from `recorded`, so they are
    # compared against what this assignment actually is instead of against themselves. The branch
    # is doubly proven: the worktree was located by it in the first place.
    def verify(recorded, repository_key:, branch:, worktree_path:, workspace:, git: Review::Checkout::Git)
      recorded = recorded.to_h
      return refuse("no checkpoint was recorded when the question was asked") if recorded.empty?
      return refuse("there is no git repository at the worktree for '#{repository_key}'") unless git.repository?(worktree_path)

      measured = measure(repository_key: repository_key, branch: branch, worktree_path: worktree_path,
                         workspace: workspace, git: git)
      return refuse("could not measure the worktree for '#{repository_key}'") if measured.nil?

      differing = FIELDS.find { |field| recorded[field].to_s != measured[field] }
      return refuse("the #{differing} of '#{repository_key}' no longer matches the recorded checkpoint") if differing

      Result.new(ok: true)
    end

    def refuse(reason) = Result.new(ok: false, reason: reason)
  end
end
