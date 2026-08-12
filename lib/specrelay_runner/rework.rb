# frozen_string_literal: true

module SpecrelayRunner
  # The optional CHANGE-REQUEST round of an implementation assignment (MVP-0035 design 3).
  #
  # An ordinary claim carries no `rework` block and this is `nil`, so the first-execution path is
  # untouched. When Platform does send one, two things must happen before a provider starts:
  #
  #   1. the worktree must hold the EXACT reviewed pull-request head — not the default branch,
  #      not a live moved head, and not whatever an old local branch happens to point at;
  #   2. the executor must be told which head it is on and which findings it is correcting.
  #
  # It fails CLOSED. A remote that cannot be read, a branch that moved or is gone, an origin that
  # is a different repository, or a worktree with uncommitted work all refuse — and refusing is
  # the right answer, because SpecRelay must never guess which version of the code to fix.
  #
  # The read-only git queries are {Review::Checkout::Git}, the seam the REVIEWER already proves
  # its checkout with. "What does the remote say this branch points at?" is one question with one
  # implementation, and the two roles ask it the same way. The single MUTATION lives here,
  # because a review must never perform one.
  #
  # It holds no publication logic. The commit, the no-force push to the assigned branch and the
  # pull-request reuse decision are {Publication}'s and are unchanged by this MVP: putting the
  # worktree on the reviewed head is what makes the new commit a descendant, which is what makes
  # that existing path do the right thing.
  class Rework
    Result = Struct.new(:ok, :reason, :head_commit, keyword_init: true) do
      def ok? = ok
    end

    # The reviewed target, or nil when this claim is an ordinary first execution.
    def self.for(payload)
      block = payload["rework"]
      block.is_a?(Hash) ? new(block) : nil
    end

    def initialize(block)
      @block = block
    end

    # Put the worktree on the reviewed head, or refuse.
    #
    # With no reviewed repository there is nothing to continue from and the ordinary initial
    # checkout IS the base, so this succeeds without touching git (S06).
    def materialize(worktree_path:, git: Review::Checkout::Git)
      repository = reviewed_repository
      return Result.new(ok: true) if repository.nil?

      head = repository["head_commit"].to_s
      refusal = verify(repository, worktree_path, head, git)
      return refusal if refusal

      reset_to(worktree_path, head)
    end

    # The section the executor's prompt carries: which head it is on, which pull request it is
    # continuing, and every current finding — once. The previous report, the previous prompt and
    # the reviewer's own reasoning are deliberately absent: a rework prompt that concatenated
    # each round's history would grow without bound and bury the findings it exists to deliver.
    def prompt_section(round_label)
      [ "", "---", "", "## Change request — #{round_label}", "", continuation_line, "",
        "Reviewer summary: #{summary}", "", *finding_lines, "",
        "Correct ONLY the findings above, inside the approved specification package. Do not",
        "restate the specification, do not revisit anything else, and do not open a new pull",
        "request — your commit continues the existing one." ].join("\n")
    end

    private

    attr_reader :block

    # The one repository the implementation lane publishes, as the review pinned it, or nil when
    # the reviewed execution legitimately changed no files. Platform sends a list because the
    # shape is per-repository, but publication commits and pushes from ONE worktree, so a second
    # entry would describe a target this runner has no way to act on.
    def reviewed_repository = Array(block["repositories"]).first

    def findings = Array(block["findings"])
    def summary = block["summary"].to_s

    def continuation_line
      repository = reviewed_repository
      return "This worktree is at the ordinary starting point: the reviewed execution changed no files." if repository.nil?

      "This worktree is at the exact reviewed head `#{repository['head_commit']}` on branch " \
        "`#{repository['branch']}` (#{repository['pull_request_url']})."
    end

    def finding_lines
      findings.each_with_index.map do |finding, index|
        "#{index + 1}. [#{finding['severity']}] `#{finding['location']}` — #{finding['summary']}\n" \
        "   #{finding['reason']}"
      end
    end

    # Every uncertainty is a refusal, and each one names the fact that failed so the operator can
    # act on it. The local checks come first, so an unusable or dirty worktree is refused without
    # a network call.
    def verify(repository, worktree_path, head, git)
      key = repository["repository_key"]
      return refuse("no git repository at the worktree for '#{key}'") unless git.repository?(worktree_path)
      return refuse("the worktree for '#{key}' has uncommitted changes; preserve or release it before retrying") unless clean?(worktree_path)

      remote_refusal(repository, worktree_path, head, git) || fetch_head(repository, worktree_path, head, git)
    end

    # The pinned commit must still BE the head of the reviewed branch on the remote. Holding the
    # object locally would only prove it once existed here; a push moves the branch and leaves
    # the old object behind forever, so a purely local check would let this round build on code
    # the pull request no longer shows.
    #
    # This is also the FOREIGN-remote guard, and it is a stronger one than comparing urls: a
    # repository that is not the reviewed one cannot have the reviewed branch pointing at the
    # reviewed 40-hex commit. A worktree whose origin was repointed therefore refuses here, with
    # the branch state it actually observed rather than a url comparison the operator would then
    # have to interpret.
    def remote_refusal(repository, worktree_path, head, git)
      key = repository["repository_key"]
      observed = git.remote_head(worktree_path, repository["branch"].to_s)
      return refuse("could not read the remote head of '#{key}'; refusing to start from a head it cannot confirm") if observed.nil?
      return nil if observed.casecmp?(head)
      return refuse("the reviewed branch of '#{key}' no longer exists on the remote") if observed.empty?

      refuse("the pull-request head of '#{key}' moved from #{head[0, 12]} to #{observed[0, 12]}")
    end

    def fetch_head(repository, worktree_path, head, git)
      return nil if git.commit?(worktree_path, head)

      git.fetch(worktree_path)
      return nil if git.commit?(worktree_path, head)

      refuse("'#{repository['repository_key']}' does not contain the reviewed head #{head[0, 12]} after a fetch")
    end

    # `reset --hard` onto the canonical task branch, so the branch the worktree is on — and that
    # publication pushes from — IS the reviewed head. A detached checkout would leave the next
    # worktree lookup unable to find the branch, and a merge would produce a commit nobody
    # reviewed. Guarded by the cleanliness check above: this only ever discards committed state
    # the remote does not have, never an operator's uncommitted work.
    def reset_to(worktree_path, head)
      result = run(worktree_path, [ "reset", "--hard", head ])
      return refuse("could not check out the reviewed head in the worktree") unless result&.exit_code.to_i.zero?

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
