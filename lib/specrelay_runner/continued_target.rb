# frozen_string_literal: true

module SpecrelayRunner
  # THE proof that this task workspace holds the exact commits Platform recorded, and the one
  # mutation that puts it there.
  #
  # Two assignments carry such a target and neither may start a provider without it: a
  # change-request round continues the reviewed pull requests (MVP-0035), and a Stage 2b
  # replacement run continues the pull requests an abandoned run had already published
  # (MVP-0036). They differ in why the target exists and in what the executor is told about it —
  # that stays with {Rework} — but "is this the repository, branch and head we were given" is one
  # question, so it has one implementation. A second copy would be a second answer, and the
  # runner would act on whichever one the payload happened to route through.
  #
  # MAPIAI-107 — the recorded set is the COMPLETE one. Publication has selected and published any
  # subset of the repositories in a prepared task workspace since MAPIAI-84, so a reviewed round
  # legitimately spans several of them; continuing only the first would submit a correction the
  # reviewer never asked for, and refusing the second stranded the round entirely. Each target is
  # located by {Review::Checkout.resolve} — the connected root itself, or one physically contained
  # direct child, chosen by remote identity and nothing else.
  #
  # Proof comes before mutation for ALL of them. Every non-destructive check runs against every
  # target first, and only a set that passes completely is reset. A workspace with one repository
  # moved to its recorded head and another refused is a half-built base no executor may start
  # from, and there is no rollback to invent: the repositories that were never touched are still
  # exactly as they were, so a retry converges.
  #
  # It fails CLOSED. A remote that cannot be read, a branch that moved or is gone, an origin that
  # is a different repository, a claim that would publish somewhere other than the recorded
  # branch, or a worktree with uncommitted work all refuse — and refusing is the right answer,
  # because SpecRelay must never guess which version of the code to continue, or where to put the
  # result.
  #
  # The read-only git queries are {Review::Checkout::Git}, the seam the REVIEWER already proves
  # its checkout with. "What does the remote say this branch points at?" is one question with one
  # implementation, and every role asks it the same way. The single MUTATION lives here, because
  # a review must never perform one.
  #
  # It holds no publication logic. The commit, the no-force push to the assigned branch and the
  # pull-request reuse decision are {Publication}'s: putting the worktree on the recorded head is
  # what makes the new commit a descendant, which is what makes that existing path do the right
  # thing. What this DOES check is that the branch Publication was assigned is the recorded one,
  # because those two facts reach the runner separately.
  class ContinuedTarget
    Result = Struct.new(:ok, :reason, :head_commit, keyword_init: true) do
      def ok? = ok
    end

    # What each caller's target is called in a refusal. It is the only thing that differs between
    # them here, and it matters: an operator reading "not to the reviewed branch" about a restart
    # would go looking for a review that does not exist.
    NOUNS = { "rework" => "reviewed", "restart" => "recorded" }.freeze

    # The recorded target this claim must continue, or nil when it carries none.
    #
    # MAPIAI-84 — the target block now carries its own `clone_url`, and the branch this claim
    # publishes to is the run's CANONICAL branch. Both used to be read from the assignment's
    # pre-execution `repositories` list, which no longer exists: which repositories a run publishes
    # is the executor's decision, so Platform declares none. Nothing about the proof changed —
    # identity and branch are still checked before any commit is checked out — only where the two
    # facts it checks against come from.
    def self.for(payload, key)
      block = payload[key]
      return nil unless block.is_a?(Hash)

      new(Array(block["repositories"]), payload.dig("run", "canonical_branch"), noun: NOUNS.fetch(key))
    end

    def initialize(targets, publication_branch = nil, noun: "recorded")
      @targets = targets
      @publication_branch = publication_branch.to_s
      @noun = noun
    end

    # Put every recorded repository in this task workspace on its own recorded head, or refuse.
    #
    # With no recorded repository there is nothing to continue from and the ordinary initial
    # checkout IS the base, so this succeeds without touching git (MVP-0035 S06).
    #
    # `head_commit` is the task-workspace REPOSITORY's recorded head, when that repository is one
    # of the targets, because that is what the report's base commit has always meant. A contained
    # child is measured independently by `Workspace#select`, so it needs no entry here.
    def materialize(worktree_path:, git: Review::Checkout::Git)
      return Result.new(ok: true) if targets.empty?

      planned = plan(worktree_path, git)
      return planned if planned.is_a?(Result)

      place(planned, worktree_path)
    end

    private

    attr_reader :targets, :publication_branch, :noun

    # Every target located and PROVED, before any of them is moved. All-or-nothing: the first
    # fact that fails refuses the whole continuation, and until this returns a plan nothing on
    # disk has changed.
    def plan(worktree_path, git)
      seen = []
      planned = []
      targets.each do |repository|
        root = resolve(repository, worktree_path, git)
        return root if root.is_a?(Result)

        refusal = duplicate_refusal(repository, seen) ||
                  verify(repository, root, repository["head_commit"].to_s, git)
        return refusal if refusal

        seen << Review::Checkout.identity(repository["clone_url"])
        planned << [ repository, root ]
      end
      planned
    end

    # The mutation, once the whole set has passed. Each repository moves to its OWN recorded head:
    # they are independent repositories with unrelated histories, and one shared commit would be
    # meaningless in the others.
    def place(planned, worktree_path)
      root_head = nil
      planned.each do |repository, root|
        refusal = reset_to(repository, root)
        return refusal if refusal

        root_head = repository["head_commit"].to_s if same_directory?(root, worktree_path)
      end
      Result.new(ok: true, head_commit: root_head)
    end

    # WHERE each recorded repository is. {Review::Checkout.resolve} is the one owner of that
    # question — the connected root itself or one physically contained direct child, matched by
    # normalized remote identity, never by directory name and never by a search — and the reviewer
    # already proves its own checkout with it. A target naming no remote leaves nothing to prove
    # identity against, and that is refused here rather than reported as a remote mismatch.
    def resolve(repository, worktree_path, git)
      key = repository["repository_key"].to_s
      return refuse("the #{noun} repository '#{key}' records no remote to prove identity against") if
        Review::Checkout.identity(repository["clone_url"]).empty?

      resolution = Review::Checkout.resolve(repository, worktree_path, git)
      resolution.refusal ? refuse(resolution.refusal.reason) : resolution.root
    end

    # One repository, twice. Two entries for the same remote cannot both be continued and cannot
    # be reconciled — they name two heads for one branch — so the set is refused rather than
    # deduplicated (MAPIAI-107 S05).
    #
    # Unique identity is also what makes the resolved ROOTS unique, so there is no second check
    # for that: {#resolve} accepts a checkout only when its own `origin` IS the target's remote,
    # so two targets sharing one checkout would have to share one identity, which this refuses.
    # Checked after resolution, where the identity is already known to be non-empty.
    def duplicate_refusal(repository, seen)
      return nil unless seen.include?(Review::Checkout.identity(repository["clone_url"]))

      refuse("this claim names the #{noun} repository '#{repository['repository_key']}' twice")
    end

    # Every uncertainty is a refusal, and each one names the fact that failed so the operator can
    # act on it. The local checks come first, so an unusable, dirty or wrongly-branched checkout is
    # refused without a network call.
    def verify(repository, root, head, git)
      key = repository["repository_key"]
      return refuse("the checkout of '#{key}' has uncommitted changes; preserve or release it before retrying") unless clean?(root)

      branch_refusal(key.to_s, repository) ||
        checkout_branch_refusal(key.to_s, repository, root, git) ||
        remote_refusal(repository, root, head, git) ||
        fetch_head(repository, root, head, git)
    end

    # WHICH branch, before which commit.
    #
    # The branch this claim will PUBLISH to must be the branch Platform recorded, because a claim
    # where they differ is one whose result would land on a branch nobody is waiting for
    # (MVP-0035 CR-002). One canonical branch is used in every repository of a task workspace, so
    # this is asked of each target against the same recorded name.
    #
    # WHICH repository is settled before this, by {#resolve}: a commit id is portable, so a fork
    # or mirror can carry the recorded branch at the byte-identical recorded sha, and the head
    # check below cannot tell a repointed origin from the real one (CR-001 F2).
    def branch_refusal(key, repository)
      return nil if publication_branch == repository["branch"].to_s

      refuse("this claim publishes '#{key}' to '#{publication_branch}', " \
             "not to the #{noun} branch '#{repository['branch']}'")
    end

    # The branch this checkout is ACTUALLY on — MAPIAI-107 CR-001 F1, and the last thing that has
    # to agree before a reset is allowed.
    #
    # `reset --hard <head>` moves whatever branch is checked out; it never switches to another.
    # The two payload values agreeing (above) therefore says nothing about where the reset would
    # land: a contained repository left on some other local branch would have THAT branch moved to
    # the recorded head and handed to the provider, and `Workspace#select` — which asks the same
    # question of its own selection, much later — would only notice after the provider had run.
    #
    # Compared against the RECORDED branch, which {#branch_refusal} has already proved equal to
    # the canonical publication branch, so passing both makes all three the same name without a
    # third comparison. `Workspace#select` keeps its own later check: it answers a different
    # question, about a repository the executor chose, at a moment this one has already passed.
    #
    # Applied to every resolved target, root included. The ROOT is additionally guaranteed by
    # `Workspace`, which locates the task worktree BY the canonical branch, so in practice only a
    # contained child can arrive here on the wrong one — but excluding the root would cost a
    # conditional and buy a hole, and one rule over one set is the smaller shape.
    def checkout_branch_refusal(key, repository, root, git)
      observed = git.current_branch(root)
      recorded = repository["branch"].to_s
      return refuse("could not read which branch '#{key}' is checked out on; refusing to " \
                    "continue a repository whose branch it cannot confirm") if observed.nil?
      return nil if observed == recorded
      return refuse("'#{key}' is not on a branch; check out the #{noun} branch " \
                    "'#{recorded}' there before retrying") if observed.empty?

      refuse("'#{key}' is checked out on '#{observed}', not the #{noun} branch '#{recorded}'")
    end

    # FRESHNESS, once identity is settled: the recorded commit must still BE the head of that
    # branch on that remote. Holding the object locally would only prove it once existed here; a
    # push moves the branch and leaves the old object behind forever, so a purely local check
    # would let this round build on code the pull request no longer shows.
    def remote_refusal(repository, root, head, git)
      key = repository["repository_key"]
      observed = git.remote_head(root, repository["branch"].to_s)
      return refuse("could not read the remote head of '#{key}'; refusing to start from a head it cannot confirm") if observed.nil?
      return nil if observed.casecmp?(head)
      return refuse("the #{noun} branch of '#{key}' no longer exists on the remote") if observed.empty?

      refuse("the pull-request head of '#{key}' moved from #{head[0, 12]} to #{observed[0, 12]}")
    end

    def fetch_head(repository, root, head, git)
      return nil if git.commit?(root, head)

      git.fetch(root)
      return nil if git.commit?(root, head)

      refuse("'#{repository['repository_key']}' does not contain the #{noun} head #{head[0, 12]} after a fetch")
    end

    # `reset --hard` onto the canonical task branch, so the branch each checkout is on — and that
    # publication pushes from — IS that repository's recorded head. A detached checkout would
    # leave the next worktree lookup unable to find the branch, and a merge would produce a commit
    # nobody reviewed. Guarded by the cleanliness proof above: this only ever discards committed
    # state the remote does not have, never an operator's uncommitted work.
    #
    # A failure here names the repository that failed and refuses the whole continuation, so a
    # partially materialized workspace never reaches a provider. Returns nil on success, because
    # the only thing a caller needs from it is the refusal.
    #
    # A `nil` result — git could not be spawned at all — is a refusal, not a pass. The predecessor
    # of this line read `result&.exit_code.to_i.zero?`, which evaluates `nil.to_i.zero?` and
    # reported an unrun reset as a successful one; `clean?` above has always answered the same
    # question the closed way, and now so does this.
    def reset_to(repository, root)
      result = run(root, [ "reset", "--hard", repository["head_commit"].to_s ])
      return nil if !result.nil? && result.exit_code.to_i.zero?

      refuse("could not check out the #{noun} head of '#{repository['repository_key']}' in this task workspace")
    end

    def clean?(root)
      result = run(root, %w[status --porcelain])
      !result.nil? && result.exit_code.to_i.zero? && result.stdout.to_s.strip.empty?
    end

    # Compared through `realpath`, because git and the configured root may spell one directory
    # differently. {Review::Checkout} answers the same question the same way.
    def same_directory?(one, other) = Review::Checkout.same_directory?(one, other)

    def run(root, args)
      CommandRunner.run([ "git", "-C", root, *args ], chdir: root,
                        timeout_seconds: Review::Checkout::Git::TIMEOUT_SECONDS)
    rescue SystemCallError
      nil
    end

    def refuse(reason) = Result.new(ok: false, reason: reason)
  end
end
