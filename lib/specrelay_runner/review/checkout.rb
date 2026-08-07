# frozen_string_literal: true

module SpecrelayRunner
  module Review
    # Proves the local checkout really is the pinned target before a reviewer is invoked
    # (MVP-0033 contract 5).
    #
    # This is the runner's half of pinning, and it is the half that matters locally: Platform
    # can say "review commit abc123 of owner/repo", but only this machine can confirm that the
    # directory it is about to hand a reviewer actually contains that commit, on that remote.
    #
    # It fails CLOSED on every uncertainty. A different remote, a missing commit, an
    # unresolvable repository, or a git command that did not complete all produce a refusal
    # rather than a review of whatever happened to be on disk (S23). It never reviews the
    # working tree: the pinned HEAD commit is the subject, so uncommitted local edits in an
    # unrelated worktree cannot reach a verdict.
    module Checkout
      module_function

      Result = Struct.new(:ok, :reason, :roots, keyword_init: true) do
        def ok? = ok
      end

      # `fetch` is attempted once per repository whose pinned head is absent, because a
      # perfectly correct checkout can simply be behind. It is a read-only network call
      # against the remote the operator already uses; nothing is checked out, reset or merged.
      def verify(assignment:, workspace_root:, git: Git)
        roots = {}
        assignment.repositories.each do |repository|
          root = File.join(workspace_root, repository["repository_key"].to_s)
          reason = verify_repository(repository, root, git)
          return Result.new(ok: false, reason: reason) if reason

          roots[repository["repository_key"].to_s] = root
        end
        Result.new(ok: true, roots: roots)
      end

      def verify_repository(repository, root, git)
        key = repository["repository_key"]
        return "no local checkout for '#{key}' at the expected workspace path" unless git.repository?(root)

        expected = identity(repository["clone_url"])
        actual = identity(git.remote_url(root))
        return "'#{key}' points at a different remote than the reviewed repository" unless expected == actual && !expected.empty?

        head = repository["head_commit"].to_s
        return nil if git.commit?(root, head)

        git.fetch(root)
        return nil if git.commit?(root, head)

        "'#{key}' does not contain the reviewed head #{head[0, 12]}; it cannot be reviewed here"
      end

      # `host/owner/repo`, lowercased — the same normalization Platform's connection identity
      # uses, so an https remote and an scp-like ssh remote for the same repository compare
      # equal while userinfo, port and `.git` are dropped.
      def identity(url)
        text = url.to_s.strip.sub(%r{\A[A-Za-z][A-Za-z0-9+.\-]*://}, "").sub(%r{\A[^/@\s]*@}, "")
        text = text.sub(%r{\A([^:/\s]+):(?!\d)}, '\1/')
        host, _, path = text.partition("/")
        [ host.sub(/:\d+\z/, ""), path ].reject(&:empty?).join("/").sub(/\.git\z/, "").chomp("/").downcase
      end

      # The injectable git seam. Every call is READ-ONLY except `fetch`, which writes only to
      # the local object store — this module never checks out, resets, merges or cleans, so a
      # review can never disturb work in progress on the operator's machine.
      module Git
        module_function

        TIMEOUT_SECONDS = 120

        # Ask GIT whether this is a repository, rather than inspecting the filesystem layout.
        #
        # `.git` is a DIRECTORY only in a plain clone. In a git worktree — which is exactly how
        # SpecRelay's own task environments check out every component repository — and in a
        # submodule, it is a FILE pointing elsewhere. A `File.directory?` check therefore
        # refuses the primary place a reviewer actually runs; the first real-provider execution
        # of this MVP failed on precisely that.
        def repository?(root)
          result = run(root, %w[rev-parse --git-dir])
          !result.nil? && result.exit_code.to_i.zero?
        end

        def remote_url(root)
          run(root, %w[remote get-url origin])&.stdout.to_s.strip
        end

        # `<sha>^{commit}` resolves only if the object exists AND is a commit, so a tag or a
        # truncated prefix that happens to match a tree does not pass.
        def commit?(root, sha)
          return false if sha.to_s.strip.empty?

          result = run(root, [ "cat-file", "-e", "#{sha}^{commit}" ])
          !result.nil? && result.exit_code.to_i.zero?
        end

        def fetch(root)
          run(root, %w[fetch --quiet origin])
        end

        def run(root, args)
          CommandRunner.run([ "git", "-C", root, *args ], chdir: root, timeout_seconds: TIMEOUT_SECONDS)
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
