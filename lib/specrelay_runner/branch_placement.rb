# frozen_string_literal: true

module SpecrelayRunner
  # HOW a DETACHED, run-owned checkout gets the branch a continuation recorded — without moving
  # any ref that already exists.
  #
  # A project whose task environment is several independent repositories prepares its components
  # detached at their base, so every continuation that builds its own environment finds them that
  # way: a reviewed round continues a published head there, and an answered-question round
  # continues uncommitted work on top of a recorded base. Both ask one question — "may this
  # checkout be put on that branch at that commit, and did it land there?" — so it has one
  # implementation. A second copy would be a second answer, and a clone that happens to carry an
  # older branch of the same name would be handed to a provider by whichever copy ran.
  #
  # The branch may already exist in the clone this checkout shares with other environments.
  # Absent, it is created at the commit; present, it is selected ONLY when it is exactly there and
  # no other worktree holds it. It is never moved, reset or deleted, because the ref it would move
  # is somebody else's round.
  #
  # Proof and mutation are separate calls on purpose: a caller placing several repositories has to
  # prove all of them before it changes any, and until {#plan} returns nothing on disk has
  # changed. It fails CLOSED — a git query that could not be answered is a refusal, never a
  # default — and every refusal names the term that failed.
  #
  # `subject` is what the caller calls this repository in operator text, `noun` is what the caller
  # calls the thing it is continuing, and `target` names the commit's role ("reviewed head",
  # "recorded base"). They are the only differences between the callers.
  class BranchPlacement
    Refusal = Struct.new(:reason, keyword_init: true)

    def initialize(root:, branch:, commit:, subject:, noun:, target:)
      @root = root
      @branch = branch.to_s
      @commit = commit.to_s
      @subject = subject.to_s
      @noun = noun.to_s
      @target = target.to_s
    end

    # Self, holding the verb the proof chose, or the reason this checkout may not be placed.
    def plan
      worktrees = run(%w[worktree list --porcelain])
      # Exit 1 from a lookup that COMPLETED is "no such branch"; a timeout or any other status is
      # git failing to answer, which refuses.
      local = run([ "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}^{commit}" ])
      absent = !local.nil? && !local.timed_out? && local.exit_code == 1
      return refuse("could not read the local branch '#{branch}' of #{subject}; refusing to place it") unless
        succeeded?(worktrees) && (absent || succeeded?(local))
      return created_at_commit if absent
      return refuse("the branch '#{branch}' of #{subject} is checked out in another worktree; " \
                    "release that worktree before retrying") if
        worktrees.stdout.to_s.lines.include?("branch refs/heads/#{branch}\n")
      return selected if local.stdout.to_s.strip.casecmp?(commit)

      refuse("the local branch '#{branch}' of #{subject} is not at the #{target}; it is never moved, " \
             "so align or delete it before retrying")
    end

    # The mutation this plan proved, then the CONFIRMATION that it landed: nil on success, a
    # {Refusal} otherwise. `-b` refuses if a branch appeared since the proof, and a selected branch
    # is never moved — so either way the checkout is re-read, and a branch that changed after it
    # was proved never reaches a provider.
    def put
      return refuse("could not check out the #{target} of #{subject} in this task workspace") unless
        succeeded?(run(argv))
      return nil if placed?

      refuse("#{subject} is not on the #{noun} branch at the #{target} after placement; nothing was started")
    end

    private

    attr_reader :root, :branch, :commit, :subject, :noun, :target, :verb

    def created_at_commit
      @verb = :create
      self
    end

    def selected
      @verb = :select
      self
    end

    def argv
      verb == :create ? [ "checkout", "--quiet", "-b", branch, commit ] : [ "checkout", "--quiet", branch ]
    end

    def placed?
      on = run(%w[symbolic-ref --quiet --short HEAD])
      at = run(%w[rev-parse HEAD])
      succeeded?(on) && succeeded?(at) && on.stdout.to_s.strip == branch && at.stdout.to_s.strip.casecmp?(commit)
    end

    # Ran, finished within its timeout, and exited 0. A timed-out result has no exit status, and
    # `nil.to_i` is 0, so reading `exit_code.to_i` would count it — and whatever it printed — as a
    # success.
    def succeeded?(result) = !result.nil? && result.success?

    def run(args)
      CommandRunner.run([ "git", "-C", root, *args ], chdir: root,
                        timeout_seconds: Review::Checkout::Git::TIMEOUT_SECONDS)
    rescue SystemCallError
      nil
    end

    def refuse(reason) = Refusal.new(reason: reason)
  end
end
