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
          resolved = resolve(repository, workspace_root, git)
          return resolved.refusal if resolved.refusal

          refusal = verify_repository(repository, resolved.root, git)
          return refusal if refusal

          roots[repository["repository_key"].to_s] = resolved.root
        end
        Result.new(ok: true, roots: roots)
      end

      Resolution = Struct.new(:root, :refusal, keyword_init: true)

      # WHERE the reviewed repository is, chosen from exactly TWO anchored candidates: the
      # configured workspace root itself, and the one direct child named by {child_name}
      # (MAPIAI-91, corrected by MAPIAI-98).
      #
      # Both shapes are real and neither is configuration trickery. A guided connection stores the
      # validated CHECKOUT as its root, so on a single-repository machine the root IS the reviewed
      # repository; in a project workspace the reviewed repositories are its direct children.
      # Appending the key unconditionally produced a duplicated, nonexistent path and refused
      # every review of the first shape (MAPIAI-82).
      #
      # Identity — not position, and never the directory's name — decides. Exactly one candidate
      # may match the assignment's remote: zero is "not here", and two is genuinely ambiguous, so
      # both refuse rather than pick. Nothing else is ever considered: no parent, no sibling, no
      # grandchild, no registry, no search, and nothing a symlink points at outside the workspace.
      def resolve(repository, workspace_root, git)
        key = repository["repository_key"].to_s
        child = child_name(key)
        checkouts = candidates(workspace_root, child).select { |root| checkout?(root, git) }
        expected = identity(repository["clone_url"])
        matching = checkouts.select { |root| !expected.empty? && identity(git.remote_url(root)) == expected }

        return Resolution.new(refusal: refuse("no local checkout for '#{key}' at " \
                                              "#{locations(child)}")) if checkouts.empty?
        return Resolution.new(refusal: refuse("'#{key}' points at a different remote than the " \
                                              "reviewed repository")) if matching.empty?
        return Resolution.new(refusal: refuse("both the connected workspace root and its " \
                                              "'#{child}' directory are the reviewed repository; " \
                                              "refusing an ambiguous checkout")) if matching.size > 1

        Resolution.new(root: matching.first)
      end

      # A key that names no usable directory: the child candidate is then simply absent, and the
      # root is the only place that was looked at.
      UNUSABLE_CHILD = [ "", ".", ".." ].freeze

      # The direct child's NAME — never a path. A pinned key is Platform's normalized GitHub
      # identity, so it is `owner/repository` and the checkout is the `repository` segment:
      # `RepoWright/tiny-demo-crm` is reviewed at `<root>/tiny-demo-crm`. Joining the whole key
      # asked for the nested `<root>/RepoWright/tiny-demo-crm`, which never exists, and the live
      # MAPIAI-95 review therefore saw only the workspace root and reported its remote as the
      # mismatch (MAPIAI-98). A single-segment key is unchanged: it IS its own repository segment.
      #
      # Because the result is one path component, `File.join` can only ever produce a LEXICALLY
      # direct child. Empty, `.` and `..` segments produce no candidate at all, so malformed key
      # material refuses instead of reaching a parent, a sibling or an arbitrary path.
      # {contained_child} proves the PHYSICAL half of the same boundary.
      def child_name(key)
        name = key.to_s.rpartition("/").last
        name unless UNUSABLE_CHILD.include?(name)
      end

      def candidates(workspace_root, child)
        roots = [ workspace_root.to_s ]
        contained = contained_child(workspace_root.to_s, child)
        roots << contained if contained
        roots.uniq
      end

      # The child candidate, but only once its PHYSICAL location is proven to still be one direct
      # child of the physical workspace root — before git is asked anything about it.
      #
      # {checkout?} compares a candidate with git's own top level through `File.realpath`, which is
      # what lets the configured ROOT be reached through a symlink. A symlinked CHILD exploited that
      # same tolerance: git resolved the repository the link pointed at, both sides then agreed, and
      # a repository physically outside the connected workspace verified as the reviewed one
      # (CR-001 F1). A lexically contained path is not a contained location.
      #
      # A candidate that resolves to nothing — absent, or a broken link — is not a location either,
      # so it is dropped and the ordinary "no local checkout" refusal follows.
      def contained_child(workspace_root, child)
        return nil if child.nil?

        path = File.join(workspace_root, child)
        return nil unless File.dirname(File.realpath(path)) == File.realpath(workspace_root)

        path
      rescue SystemCallError
        nil
      end

      # What a refusal may honestly claim was looked at.
      def locations(child)
        return "the connected workspace root" if child.nil?

        "the connected workspace root or its '#{child}' directory"
      end

      # A candidate must be the TOP LEVEL of a repository, not merely inside one. `git rev-parse`
      # answers for the nearest enclosing repository, so a plain subdirectory of a clone would
      # otherwise present that clone's remote and pinned commit as its own — reviewing a parent
      # this resolver is not allowed to consider.
      def checkout?(root, git)
        top = git.top_level(root)
        !top.nil? && same_directory?(top, root)
      end

      # Compared through `realpath`, because git answers with the physical path while the
      # configured root may reach it through a symlink.
      def same_directory?(one, other)
        File.realpath(one) == File.realpath(other)
      rescue SystemCallError
        false
      end

      def verify_repository(repository, root, git)
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

        # The working tree's own root, or nil when this path is not in a repository at all. Asked
        # of GIT for the same reason as `repository?`: in a worktree or a submodule the layout on
        # disk does not reveal it. The caller compares it to the candidate path, which is what
        # keeps a plain subdirectory of a clone from answering as that clone (MAPIAI-91).
        def top_level(root)
          result = run(root, %w[rev-parse --show-toplevel])
          return nil if result.nil? || !result.exit_code.to_i.zero?

          value = result.stdout.to_s.strip
          value.empty? ? nil : value
        end

        REMOTE = "origin"

        def remote_url(root)
          run(root, [ "remote", "get-url", REMOTE ])&.stdout.to_s.strip
        end

        # WHICH branch this checkout is on, asked of the ref HEAD points at (MAPIAI-107 CR-001 F1).
        #
        # Only git can answer it, and only this question answers "where would a write here land":
        # a `reset --hard` moves whatever branch is checked out and never switches to another, so
        # a recorded branch name being correct says nothing about the branch that would actually
        # move.
        #
        # Three-valued, the same convention as {remote_head} directly above, so a caller cannot
        # read "cannot tell" as "fine": the short branch name, "" when HEAD is detached
        # (`--quiet` makes that an ordinary empty answer rather than an error), and nil when the
        # question could not be answered at all.
        def current_branch(root)
          result = run(root, %w[symbolic-ref --quiet --short HEAD])
          return nil if result.nil?
          return "" unless result.exit_code.to_i.zero?

          result.stdout.to_s.strip
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
