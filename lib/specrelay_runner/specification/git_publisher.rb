# frozen_string_literal: true

require "tmpdir"

module SpecrelayRunner
  module Specification
    # Commits the verified specification package onto the Platform-assigned branch and pushes it
    # (MVP-0027 scope 3), **without touching the operator's working tree or HEAD**.
    #
    # That constraint decides the whole design. The operator's specification repository is a
    # checkout they use: it may hold uncommitted work, be on any branch, and be open in an
    # editor. A publication that ran `git checkout` in it would be a background process moving
    # someone's branch under them, and a publication that ran `git add` would commit whatever
    # else happened to be staged. So this class builds the commit with plumbing instead:
    #
    #   read-tree <base> -> hash-object each verified file -> update-index -> write-tree
    #   -> commit-tree -> push <sha>:refs/heads/<branch>
    #
    # into a TEMPORARY index file. Nothing in that sequence reads or writes the working tree,
    # HEAD, or the repository's own index. It also gives criterion 3 for free: the tree is the
    # base tree plus exactly the verified package files, so the commit cannot contain anything
    # else — not because the runner was careful about staging, but because nothing else was ever
    # added.
    #
    # Idempotency is structural for the same reason. The base is the existing remote branch tip
    # when there is one, so a retry writes the SAME tree; an unchanged tree means no commit is
    # created at all and the existing tip is reused, and the push is then a no-op. A retry
    # therefore reuses the branch and the commit rather than stacking an empty commit on it.
    #
    # It fails CLOSED and reports a reason; it never raises past its caller.
    class GitPublisher
      COMMIT_AUTHOR_NAME = "SpecRelay Runner"
      COMMIT_AUTHOR_EMAIL = "runner@specrelay.local"
      REMOTE = "origin"
      FILE_MODE = "100644"
      COMMIT_PATTERN = /\A[0-9a-f]{40,64}\z/

      CHECKOUT_MISMATCH = "specification_checkout_mismatch"
      PUSH_FAILED = "git_push_failed"

      Result = Struct.new(:head_commit, :reused_branch, :failure_class, :message, keyword_init: true) do
        def ok? = failure_class.nil?
        def reused_branch? = reused_branch ? true : false
      end

      def self.call(**kwargs) = new(**kwargs).call

      # +branch+ is passed explicitly rather than read off the assignment, because MVP-0028 gave
      # it two possible sources: the branch Platform derived for a first publication, or the head
      # branch of the pull request this ticket already has. The caller resolves which; this class
      # commits and pushes to whatever it is handed, and never chooses.
      def initialize(commands:, assignment:, branch:, files:, io: $stdout)
        @commands = commands
        @assignment = assignment
        @branch = branch
        @files = files
        @io = io
      end

      def call
        mismatch = verify_remote
        return mismatch if mismatch

        base = resolve_base
        return base if base.is_a?(Result)

        commit = build_commit(base)
        # `build_commit` returns a Result on BOTH paths — the commit to push, or the failure that
        # stopped it — so this asks whether it succeeded rather than what type it is. Testing the
        # type here returned the success early and skipped the push entirely, which reported a
        # commit that never left the machine.
        return commit unless commit.ok?

        push(commit, base.reused)
      end

      private

      attr_reader :commands, :assignment, :branch, :files, :io

      Base = Struct.new(:commit, :reused, keyword_init: true)

      # The checkout must be a clone of the repository Platform assigned. Without this a runner
      # whose `SPECRELAY_RUNNER_SPEC_REPOSITORY_ROOT_*` points at the wrong clone would commit a
      # specification into an unrelated repository and report a plausible-looking branch for it.
      #
      # The comparison is made only when the remote RESOLVES to a GitHub `owner/repo`, and that
      # limit is deliberate rather than lax. A remote that does not resolve — an ssh alias, an
      # internal mirror, a `url.insteadOf` rewrite, a local path — is not evidence of a mismatch,
      # and refusing every one of them would refuse legitimate setups on a guess. The wrong-clone
      # case those setups could still hide does not escape: the pull-request step addresses
      # GitHub by the ASSIGNED slug, so a branch pushed to some other host is not there to open a
      # pull request against, and the attempt fails closed one step later with no reviewable
      # output. What is caught HERE is the case that would otherwise look successful — a clone of
      # a DIFFERENT GitHub repository.
      def verify_remote
        url = commands.git_value([ "remote", "get-url", REMOTE ])
        return failure(CHECKOUT_MISMATCH, no_remote_message) if url.nil? || url.empty?

        actual = slug_for(url)
        expected = assignment.publication_slug
        return nil if expected.empty? || actual.nil? || actual == expected

        failure(CHECKOUT_MISMATCH,
                "the configured specification checkout on this runner is a clone of #{actual}, " \
                "but this run publishes to #{expected}. " \
                "Point #{repository_root_hint} at a clone of #{expected}, then publish again")
      end

      def no_remote_message
        "the configured specification checkout on this runner has no `#{REMOTE}` remote, so there is " \
          "nowhere to push. Point #{repository_root_hint} at a clone of #{assignment.publication_slug}"
      end

      def repository_root_hint = "the runner's specification repository root"

      # Accepts the https and scp-like ssh remote forms, dropping any credential userinfo rather
      # than carrying it into a comparison, a message, or a log.
      def slug_for(url)
        slug =
          if url.start_with?("git@github.com:")
            url.delete_prefix("git@github.com:")
          else
            url.sub(%r{\Ahttps?://(?:[^@/]+@)?github\.com/}, "")
          end
        slug = slug.delete_suffix(".git")
        slug.match?(%r{\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\z}) ? slug : nil
      end

      # The commit this publication builds on: the existing remote publication branch when there
      # is one — which is what makes a retry additive rather than a fork — otherwise the base
      # branch Platform named. Both are fetched fresh, so a stale local clone cannot publish
      # against a base that no longer exists.
      def resolve_base
        existing = remote_head(branch)
        return fetch_base(branch, reused: true) if existing

        fetch_base(assignment.publication_base_branch, reused: false)
      end

      def remote_head(branch)
        output = commands.git_value([ "ls-remote", "--heads", REMOTE, "refs/heads/#{branch}" ])
        output.to_s.split(/\s+/).first&.then { |sha| COMMIT_PATTERN.match?(sha) ? sha : nil }
      end

      # `git fetch` writes only FETCH_HEAD and the object database — never the working tree — so
      # it is safe in a checkout the operator is using.
      def fetch_base(branch, reused:)
        result = commands.git([ "fetch", "--quiet", REMOTE, branch ])
        return failure(PUSH_FAILED, fetch_failure(result, branch)) unless result.success?

        commit = commands.git_value(%w[rev-parse FETCH_HEAD])
        return failure(PUSH_FAILED, "could not resolve #{REMOTE}/#{branch} after fetching it") unless
          COMMIT_PATTERN.match?(commit.to_s)

        Base.new(commit: commit, reused: reused)
      end

      def fetch_failure(result, branch)
        text = commands.failure_reason(result, "git fetch")
        return "#{text}. Check that #{branch} exists on #{assignment.publication_slug} and that this " \
               "runner host can reach GitHub" unless result.timed_out?

        text
      end

      # The plumbing sequence, in a temporary index. Returns the commit to push, which is the
      # BASE ITSELF when the resulting tree is unchanged — the retry path, and the reason a
      # second publication of the same package neither creates a commit nor moves the branch.
      def build_commit(base)
        Dir.mktmpdir("specrelay-publish-") do |dir|
          index = { "GIT_INDEX_FILE" => File.join(dir, "index") }
          staged = stage_tree(base.commit, index)
          return staged if staged.is_a?(Result)

          return Result.new(head_commit: base.commit, reused_branch: base.reused) if
            staged == base_tree(base.commit)

          commit_tree(staged, base)
        end
      end

      def stage_tree(base_commit, index)
        return failure(PUSH_FAILED, "git read-tree failed for #{base_commit}") unless
          commands.git([ "read-tree", base_commit ], extra_env: index).success?

        files.each do |file|
          blob = commands.git_value([ "hash-object", "-w", "--", file.absolute_path ])
          return failure(PUSH_FAILED, "git hash-object failed for #{file.repository_path}") unless
            COMMIT_PATTERN.match?(blob.to_s)
          return failure(PUSH_FAILED, "git update-index failed for #{file.repository_path}") unless
            commands.git([ "update-index", "--add", "--cacheinfo",
                           "#{FILE_MODE},#{blob},#{file.repository_path}" ], extra_env: index).success?
        end

        tree = commands.git_value([ "write-tree" ], extra_env: index)
        COMMIT_PATTERN.match?(tree.to_s) ? tree : failure(PUSH_FAILED, "git write-tree produced no tree")
      end

      def base_tree(commit) = commands.git_value([ "rev-parse", "#{commit}^{tree}" ])

      def commit_tree(tree, base)
        author = { "GIT_AUTHOR_NAME" => COMMIT_AUTHOR_NAME, "GIT_AUTHOR_EMAIL" => COMMIT_AUTHOR_EMAIL,
                   "GIT_COMMITTER_NAME" => COMMIT_AUTHOR_NAME, "GIT_COMMITTER_EMAIL" => COMMIT_AUTHOR_EMAIL }
        commit = commands.git_value([ "commit-tree", tree, "-p", base.commit, "-m", commit_message ],
                                    extra_env: author)
        return failure(PUSH_FAILED, "git commit-tree produced no commit") unless COMMIT_PATTERN.match?(commit.to_s)

        log("Committed the generated specification package as #{commit[0, 12]}.")
        Result.new(head_commit: commit, reused_branch: base.reused)
      end

      # Names the Jira issue and the SpecRelay run, and carries the workspace's role trailers so
      # a reader of the specification repository's history can tell what produced the commit. No
      # prompt text, no provider transcript, no local path, and no credential.
      def commit_message
        <<~MESSAGE
          #{assignment.issue_key}: SpecRelay generated specification package

          Generated and published by the SpecRelay standalone runner for run
          #{assignment.run_id}. Review the draft pull request before approving.

          Agent-Role: runner
          Workflow-Stage: specification-publication
        MESSAGE
      end

      # Never a force push, so a diverged branch fails closed instead of destroying work. An
      # explicit refspec from the commit object rather than from HEAD, because HEAD is the
      # operator's and this class never moves it.
      def push(commit, reused)
        result = commands.git([ "push", REMOTE, "#{commit.head_commit}:refs/heads/#{branch}" ])
        return Result.new(head_commit: commit.head_commit, reused_branch: reused) if result.success?

        failure(PUSH_FAILED, push_error(result))
      end

      def push_error(result)
        text = [ result.stderr, result.stdout ].join("\n")
        return diverged_refusal if !result.timed_out? && text.match?(/non-fast-forward|fetch first|rejected/i)
        if !result.timed_out? && text.match?(/authentication|permission denied|could not read Username/i)
          return "git push failed: authentication was refused on this runner host; check the git " \
                 "credential setup where the runner executes, then retry publication"
        end

        commands.failure_reason(result, "git push")
      end

      def diverged_refusal
        "git push rejected: the publication branch has diverged on the remote and SpecRelay never " \
          "force-pushes. Inspect #{branch}; if it is a stale SpecRelay attempt, " \
          "delete it and retry publication. If it holds work you need, merge or rename it first"
      end

      def failure(failure_class, message)
        Result.new(failure_class: failure_class, message: Redaction.redact(message.to_s))
      end

      def log(message) = io.puts(Redaction.redact(message.to_s))
    end
  end
end
