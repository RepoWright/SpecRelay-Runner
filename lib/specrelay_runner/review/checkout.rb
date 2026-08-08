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

      # `stale` separates the two refusals Platform must not confuse. A generic refusal means
      # THIS MACHINE cannot review (fix the checkout and try again); a stale one means THE
      # TARGET IS GONE, and no machine should review it (CR-001 F3).
      Result = Struct.new(:ok, :reason, :roots, :stale, keyword_init: true) do
        def ok? = ok
        def stale? = !!stale
      end

      # `fetch` is attempted once per repository whose pinned head is absent, because a
      # perfectly correct checkout can simply be behind. It is a read-only network call
      # against the remote the operator already uses; nothing is checked out, reset or merged.
      def verify(assignment:, workspace_root:, git: Git)
        roots = {}
        assignment.repositories.each do |repository|
          root = File.join(workspace_root, repository["repository_key"].to_s)
          refusal = verify_repository(repository, root, git)
          return refusal if refusal

          roots[repository["repository_key"].to_s] = root
        end
        Result.new(ok: true, roots: roots)
      end

      def verify_repository(repository, root, git)
        key = repository["repository_key"]
        return refuse("no local checkout for '#{key}' at the expected workspace path") unless git.repository?(root)

        expected = identity(repository["clone_url"])
        actual = identity(git.remote_url(root))
        return refuse("'#{key}' points at a different remote than the reviewed repository") unless expected == actual && !expected.empty?

        head = repository["head_commit"].to_s
        moved = remote_refusal(repository, root, git, head)
        return moved if moved

        present_locally(repository, root, git, head)
      end

      # The pinned commit must still be the head of the pull request's BRANCH on the remote.
      #
      # Holding the object locally proves only that the commit once existed here. A push
      # advances `refs/heads/<branch>` and leaves the old object in the local store forever, so
      # a purely local check lets a reviewer read old code and attach its verdict to a pull
      # request that now shows something else (CR-001 F3).
      #
      # A remote that cannot be read is a REFUSAL, not a move: not knowing is not the same as
      # knowing it changed, and only a real mismatch may burn the assignment.
      def remote_refusal(repository, root, git, head)
        branch = repository["branch"].to_s
        key = repository["repository_key"]
        return nil if branch.empty?

        observed = git.remote_head(root, branch)
        return refuse("could not read the remote head of '#{key}'; refusing to review") if observed.nil?
        return nil if observed.casecmp?(head)
        return stale("the reviewed branch of '#{key}' no longer exists on the remote") if observed.empty?

        stale("the pull-request head of '#{key}' moved from #{head[0, 12]} to #{observed[0, 12]}")
      end

      def present_locally(repository, root, git, head)
        return nil if git.commit?(root, head)

        git.fetch(root)
        return nil if git.commit?(root, head)

        refuse("'#{repository['repository_key']}' does not contain the reviewed head " \
               "#{head[0, 12]}; it cannot be reviewed here")
      end

      def refuse(reason) = Result.new(ok: false, reason: reason, stale: false)
      def stale(reason) = Result.new(ok: false, reason: reason, stale: true)

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

        REMOTE = "origin"

        def remote_url(root)
          run(root, [ "remote", "get-url", REMOTE ])&.stdout.to_s.strip
        end

        # ONE read-only ref query. `ls-remote` asks the remote what a branch points at and
        # transfers no objects, writes nothing to the object store, and touches no working
        # tree — the whole freshness boundary is this single bounded call.
        #
        # Returns the sha, "" when the branch is gone, and nil when the question could not be
        # answered at all.
        def remote_head(root, branch)
          result = run(root, [ "ls-remote", "--heads", REMOTE, "refs/heads/#{branch}" ])
          return nil if result.nil? || !result.exit_code.to_i.zero?

          result.stdout.to_s.each_line.first.to_s.split(/\s+/).first.to_s
        end

        # `<sha>^{commit}` resolves only if the object exists AND is a commit, so a tag or a
        # truncated prefix that happens to match a tree does not pass.
        def commit?(root, sha)
          return false if sha.to_s.strip.empty?

          result = run(root, [ "cat-file", "-e", "#{sha}^{commit}" ])
          !result.nil? && result.exit_code.to_i.zero?
        end

        def fetch(root)
          run(root, [ "fetch", "--quiet", REMOTE ])
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
