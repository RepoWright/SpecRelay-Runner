# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # Reads the specification package a ticket's existing pull request already carries, straight
    # off its branch's own git history — never the local working tree, and never Platform's
    # digest record of a *different* run's generation (MVP-0028 decision D6).
    #
    # {ExistingPullRequest} already proved the branch by the time this runs; this reuses the exact
    # non-mutating pattern {GitPublisher#fetch_base} established for the same reason — `git fetch`
    # writes only FETCH_HEAD and the object database, never the working tree — so reading revision
    # context is as safe in an operator's live checkout as committing to it already was.
    #
    # It FAILS CLOSED. A pull request the ticket already has but whose previous package cannot be
    # read is not a safe base for "read the previous specification and revise it" — proceeding as
    # though this were a first generation would silently discard whatever the previous package
    # recorded, which is the opposite of a revision.
    class PreviousSpecificationPackage
      REMOTE = "origin"
      COMMIT_PATTERN = /\A[0-9a-f]{40,64}\z/

      UNREADABLE = "specification_revision_unreadable"

      # `commit` is the branch tip the files were read from — ONE moment, reported rather than
      # re-derived. The caller puts the task environment on that exact commit, so "the package the
      # provider revises" and "the history it is tracked in" cannot be two different things.
      Result = Struct.new(:files, :branch, :commit, :failure_class, :message, keyword_init: true) do
        def ok? = failure_class.nil?
      end

      def self.call(**kwargs) = new(**kwargs).call

      def initialize(commands:, branch:, package_path:)
        @commands = commands
        @branch = branch.to_s
        @package_path = package_path.to_s.delete_suffix("/")
      end

      def call
        commit = fetch_branch_tip
        return commit if commit.is_a?(Result)

        paths = list_files(commit)
        return paths if paths.is_a?(Result)

        return failure("the pull request this ticket already has does not carry a previously " \
                       "generated package at #{package_path} on #{branch}, so this run has no " \
                       "revision context to read from it") if paths.empty?

        read_files(commit, paths)
      end

      private

      attr_reader :commands, :branch, :package_path

      # Fetches only — writes FETCH_HEAD and the object database, never the working tree or
      # HEAD, exactly like {GitPublisher#fetch_base}.
      def fetch_branch_tip
        result = commands.git([ "fetch", "--quiet", REMOTE, branch ])
        return failure("git fetch failed while reading the previous specification package: " \
                       "#{commands.failure_reason(result, 'git fetch')}") unless result.success?

        commit = commands.git_value(%w[rev-parse FETCH_HEAD])
        return failure("could not resolve #{REMOTE}/#{branch} after fetching it to read the " \
                       "previous specification package") unless COMMIT_PATTERN.match?(commit.to_s)

        commit
      end

      def list_files(commit)
        result = commands.git([ "ls-tree", "-r", "--name-only", commit, "--", package_path ])
        return failure("git ls-tree failed while reading the previous specification package: " \
                       "#{commands.failure_reason(result, 'git ls-tree')}") unless result.success?

        result.stdout.to_s.each_line.map(&:strip).reject(&:empty?)
      end

      def read_files(commit, paths)
        files = {}
        paths.each do |path|
          content = commands.git_value([ "show", "#{commit}:#{path}" ])
          return failure("git show failed while reading #{path} from the previous specification " \
                         "package") if content.nil?

          files[path.delete_prefix("#{package_path}/")] = content
        end
        Result.new(files: files, branch: branch, commit: commit)
      end

      def failure(message) = Result.new(failure_class: UNREADABLE, message: Redaction.redact(message.to_s))
    end
  end
end
