# frozen_string_literal: true

module SpecrelayRunner
  # THE proof that this worktree holds the exact commit Platform recorded, and the one mutation
  # that puts it there.
  #
  # Two assignments carry such a target and neither may start a provider without it: a
  # change-request round continues the reviewed pull request (MVP-0035), and a Stage 2b
  # replacement run continues the pull request an abandoned run had already published
  # (MVP-0036). They differ in why the target exists and in what the executor is told about it —
  # that stays with {Rework} — but "is this the repository, branch and head we were given" is one
  # question, so it has one implementation. A second copy would be a second answer, and the
  # runner would act on whichever one the payload happened to route through.
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

    # Put the worktree on the recorded head, or refuse.
    #
    # With no recorded repository there is nothing to continue from and the ordinary initial
    # checkout IS the base, so this succeeds without touching git (MVP-0035 S06).
    def materialize(worktree_path:, git: Review::Checkout::Git)
      return too_many if targets.length > 1

      repository = targets.first
      return Result.new(ok: true) if repository.nil?

      head = repository["head_commit"].to_s
      refusal = verify(repository, worktree_path, head, git)
      return refusal if refusal

      reset_to(worktree_path, head)
    end

    private

    attr_reader :targets, :publication_branch, :noun

    # Publication commits and pushes from ONE worktree, so a second target names something this
    # runner cannot act on. Implementing the first and dropping the rest would answer half the
    # work and report it as done, so the whole claim is refused instead (MVP-0035 CR-001 F2).
    # Widening this belongs to a specification that adds multi-repository publication, not to a
    # target reader.
    def too_many
      refuse("this claim names #{targets.length} #{noun} repositories; " \
             "this runner publishes from one worktree and will not implement part of it")
    end

    # Every uncertainty is a refusal, and each one names the fact that failed so the operator can
    # act on it. The local checks come first, so an unusable or dirty worktree is refused without
    # a network call.
    def verify(repository, worktree_path, head, git)
      key = repository["repository_key"]
      return refuse("no git repository at the worktree for '#{key}'") unless git.repository?(worktree_path)
      return refuse("the worktree for '#{key}' has uncommitted changes; preserve or release it before retrying") unless clean?(worktree_path)

      target_refusal(repository, worktree_path, git) ||
        remote_refusal(repository, worktree_path, head, git) ||
        fetch_head(repository, worktree_path, head, git)
    end

    # WHICH repository and WHICH branch, before which commit.
    #
    # Two facts have to agree before anything is checked out. The branch this claim will PUBLISH to
    # must be the branch Platform recorded, because a claim where they differ is one whose result
    # would land on a branch nobody is waiting for (MVP-0035 CR-002). And the worktree's `origin`
    # must be the recorded repository: a commit id is portable, so a fork or mirror can carry the
    # recorded branch at the byte-identical recorded sha, and the head check below cannot tell a
    # repointed origin from the real one (CR-001 F2).
    #
    # The comparison is {Review::Checkout.identity}, the normalizer the reviewer's own checkout
    # proof uses, so an https remote and its scp-like ssh spelling are one repository here too. A
    # recorded target that names no remote leaves nothing to prove identity against, and that is a
    # refusal rather than a pass.
    def target_refusal(repository, worktree_path, git)
      key = repository["repository_key"].to_s
      expected = Review::Checkout.identity(repository["clone_url"])
      return refuse("the #{noun} repository '#{key}' records no remote to prove identity against") if expected.empty?

      branch_refusal(key, repository) ||
        remote_identity_refusal(key, expected, worktree_path, git)
    end

    def branch_refusal(key, repository)
      return nil if publication_branch == repository["branch"].to_s

      refuse("this claim publishes '#{key}' to '#{publication_branch}', " \
             "not to the #{noun} branch '#{repository['branch']}'")
    end

    def remote_identity_refusal(key, expected, worktree_path, git)
      return nil if expected == Review::Checkout.identity(git.remote_url(worktree_path))

      refuse("the worktree for '#{key}' points at a different remote than the #{noun} repository")
    end

    # FRESHNESS, once identity is settled: the recorded commit must still BE the head of that
    # branch on that remote. Holding the object locally would only prove it once existed here; a
    # push moves the branch and leaves the old object behind forever, so a purely local check
    # would let this round build on code the pull request no longer shows.
    def remote_refusal(repository, worktree_path, head, git)
      key = repository["repository_key"]
      observed = git.remote_head(worktree_path, repository["branch"].to_s)
      return refuse("could not read the remote head of '#{key}'; refusing to start from a head it cannot confirm") if observed.nil?
      return nil if observed.casecmp?(head)
      return refuse("the #{noun} branch of '#{key}' no longer exists on the remote") if observed.empty?

      refuse("the pull-request head of '#{key}' moved from #{head[0, 12]} to #{observed[0, 12]}")
    end

    def fetch_head(repository, worktree_path, head, git)
      return nil if git.commit?(worktree_path, head)

      git.fetch(worktree_path)
      return nil if git.commit?(worktree_path, head)

      refuse("'#{repository['repository_key']}' does not contain the #{noun} head #{head[0, 12]} after a fetch")
    end

    # `reset --hard` onto the canonical task branch, so the branch the worktree is on — and that
    # publication pushes from — IS the recorded head. A detached checkout would leave the next
    # worktree lookup unable to find the branch, and a merge would produce a commit nobody
    # reviewed. Guarded by the cleanliness check above: this only ever discards committed state
    # the remote does not have, never an operator's uncommitted work.
    def reset_to(worktree_path, head)
      result = run(worktree_path, [ "reset", "--hard", head ])
      return refuse("could not check out the #{noun} head in the worktree") unless result&.exit_code.to_i.zero?

      Result.new(ok: true, head_commit: head)
    end

    def clean?(worktree_path)
      result = run(worktree_path, %w[status --porcelain])
      !result.nil? && result.exit_code.to_i.zero? && result.stdout.to_s.strip.empty?
    end

    def run(worktree_path, args)
      CommandRunner.run([ "git", "-C", worktree_path, *args ], chdir: worktree_path,
                        timeout_seconds: Review::Checkout::Git::TIMEOUT_SECONDS)
    rescue SystemCallError
      nil
    end

    def refuse(reason) = Result.new(ok: false, reason: reason)
  end
end
