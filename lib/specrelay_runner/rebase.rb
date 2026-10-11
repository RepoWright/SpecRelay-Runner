# frozen_string_literal: true

module SpecrelayRunner
  # A Rebase run: the ticket's COMPLETE accepted package moved onto each repository's current main,
  # then verified, published and reviewed through the ordinary implementation path.
  #
  # Platform marks the assignment with `rebase`; the pull requests, their branches and their
  # accepted heads are the `previous_accepted_package` block's own, so the same facts never travel
  # twice. This class owns what is different about such a run and nothing else:
  #
  #   - its preflight is {ContinuedTarget} over every accepted pull request, with GitHub's view of
  #     each one checked and EVERY blocker named before anything is refused;
  #   - the mechanical rebase onto the main commit Platform stored for the run, a clean result kept
  #     and a conflicting one aborted with its paths recorded for the executor;
  #   - the per-repository progress lines and the executor's prompt section;
  #   - the proof, before verification, that every accepted repository was reported, is on its
  #     pull-request branch and descends from its stored main commit;
  #   - the lease its publication pushes with: the accepted head, so a branch that moved after
  #     preflight is never overwritten.
  #
  # A round that follows a review of this run (`rework`) or replaces it (`restart`) continues the
  # run's own published heads and is an ordinary continuation, so the marker is inert there.
  class Rebase
    # One repository's rebase. `conflicts` is empty for a clean rebase; `dropped` counts the
    # commits main already contained.
    Outcome = Struct.new(:target, :root, :start, :main, :conflicts, :dropped, keyword_init: true)

    COMMITTER = [ "-c", "user.name=#{Publication::COMMIT_AUTHOR_NAME}",
                  "-c", "user.email=#{Publication::COMMIT_AUTHOR_EMAIL}" ].freeze

    # How many conflicting paths a progress line names; the prompt names them all.
    MAX_LINE_PATHS = 10

    def self.active?(payload)
      payload.is_a?(Hash) && payload["rebase"] == true && payload["rework"].nil? && payload["restart"].nil?
    end

    def self.for(payload, env: ENV)
      return nil unless active?(payload)

      targets = pull_requests(payload).map do |entry|
        { "repository_key" => entry["repository"], "clone_url" => entry["clone_url"], "branch" => entry["branch"],
          "head_commit" => entry["head_commit"], "pull_request_url" => entry["pull_request_url"] }
      end
      new(targets, ContinuedTarget.new(targets, payload.dig("run", "canonical_branch"),
                                       noun: ContinuedTarget::NOUNS.fetch("rebase"), pull_request_env: env,
                                       every_blocker: true))
    end

    # The accepted head a push of +branch+ in +repository+ is leased on, or nil when the push is an
    # ordinary one: not a Rebase run, or not one of the accepted package's own pull-request branches.
    def self.lease(payload, repository, branch)
      return nil unless active?(payload)

      entry = pull_requests(payload).find do |pull_request|
        pull_request["repository"].to_s.casecmp?(repository.to_s) && pull_request["branch"].to_s == branch.to_s
      end
      entry && entry["head_commit"].to_s
    end

    def self.pull_requests(payload) = Array(payload.dig("previous_accepted_package", "implementation_pull_requests"))

    # The preflight and placement: every accepted repository proved and put on its accepted head.
    attr_reader :target

    def initialize(targets, target)
      @targets = targets
      @target = target
      @outcomes = []
    end

    # Rebase every accepted repository onto its stored main commit. Returns nil, or the reason the
    # rebase could not be performed at all; a conflict is an outcome, not a reason.
    def apply(worktree_path, bases)
      @outcomes = []
      targets.each do |repository|
        located = locate(repository, worktree_path, bases)
        return located if located.is_a?(String)

        outcome = rebase(repository, *located)
        return outcome if outcome.is_a?(String)

        @outcomes << outcome
      end
      nil
    end

    # One timeline line per repository: the starting head, the main commit and the outcome.
    def progress_lines
      outcomes.map do |outcome|
        result = outcome.conflicts.empty? ? "clean" : "conflicts in #{named_paths(outcome.conflicts)}; handed to the executor"
        "#{subject(outcome)}: #{result}#{dropped_phrase(outcome.dropped)}"
      end
    end

    # The line, once the proof passed, for each repository whose conflicts the executor resolved.
    def resolved_lines
      outcomes.reject { |outcome| outcome.conflicts.empty? }.map do |outcome|
        dropped = count(outcome.root, "#{outcome.main}..#{outcome.start}").to_i - count(outcome.root, "#{outcome.main}..HEAD").to_i
        "#{subject(outcome)}: conflicting paths resolved, now at #{short(head(outcome.root))}#{dropped_phrase(dropped)}"
      end
    end

    def prompt_section
      return "" if outcomes.empty?

      [ "", "---", "", "## Rebase onto main", "",
        "This run moves the accepted pull requests below onto each repository's current main.", "",
        *outcomes.map { |outcome| prompt_row(outcome) }, "",
        "For each repository with conflicts, run `git rebase <main commit>` on its branch, resolve every",
        "conflict inside the approved specification's scope, and finish with `git rebase --continue`, so",
        "the branch descends from that commit. Never merge main into a branch, push, or open a pull request.",
        "If a resolution needs a product decision, run `git rebase --abort` first and ask through the",
        "question channel above instead of guessing.",
        "Report EVERY repository above in the repository selection with its verification, including the",
        "clean ones; a repository missing from it fails the run." ].join("\n")
    end

    # Nil when every accepted repository was selected, is on its pull-request branch and descends
    # from its stored main commit; otherwise the reason this run must not be verified or published.
    def unproven(worktree_path, bases, selected)
      targets.each do |repository|
        located = locate(repository, worktree_path, bases)
        return located if located.is_a?(String)

        reason = descent_refusal(repository, *located, selected)
        return reason if reason
      end
      nil
    end

    # The accepted repositories not yet rebased — a conflict the executor has not resolved — whose
    # base for a question's checkpoint is therefore their accepted head. A rebased repository
    # descends from main, which is already its checkpoint base.
    def unrebased_targets(worktree_path)
      targets.select do |repository|
        root = Review::Checkout.resolve(repository, worktree_path, Review::Checkout::Git).root
        root && succeeded?(git(root, [ "merge-base", "--is-ancestor", repository["head_commit"].to_s, "HEAD" ]))
      end
    end

    private

    attr_reader :targets, :outcomes

    # The checkout of +repository+ — through {Review::Checkout}, the one owner of where a
    # repository is — and its stored main commit, or the reason either is unknown.
    def locate(repository, worktree_path, bases)
      key = repository["repository_key"].to_s
      resolution = Review::Checkout.resolve(repository, worktree_path, Review::Checkout::Git)
      return "#{key}: #{resolution.refusal.reason}" if resolution.refusal

      base = Array(bases).find { |entry| entry.is_a?(Hash) && entry["repository"].to_s.casecmp?(key) }
      return "no main commit was stored for #{key}" if base.nil?

      [ resolution.root, base["commit"].to_s ]
    end

    def rebase(repository, root, main)
      key = repository["repository_key"]
      return "#{key} does not contain its main commit #{short(main)} after a fetch" unless reachable?(root, main)

      start = head(root)
      replayed = count(root, "#{main}..#{start}")
      return Outcome.new(target: repository, root: root, start: start, main: main, conflicts: [],
                         dropped: replayed.to_i - count(root, "#{main}..HEAD").to_i) if
        succeeded?(git(root, [ *COMMITTER, "rebase", "--no-verify", main ]))

      conflicted(repository, root, start, main)
    end

    # A rebase that stopped is aborted, so the branch is back on its accepted head. Stopped on
    # conflicts, it is an outcome for the executor; stopped for any other reason, it is a failure.
    def conflicted(repository, root, start, main)
      paths = git(root, %w[diff --name-only --diff-filter=U])&.stdout.to_s.lines.map(&:strip).reject(&:empty?)
      aborted = succeeded?(git(root, %w[rebase --abort]))
      key = repository["repository_key"]
      return "the rebase of #{key} onto main #{short(main)} could not be aborted" unless aborted
      return "the rebase of #{key} onto main #{short(main)} failed without a conflict" if paths.empty?

      Outcome.new(target: repository, root: root, start: start, main: main, conflicts: paths, dropped: 0)
    end

    def descent_refusal(repository, root, main, selected)
      key = repository["repository_key"]
      return "#{key} was not reported for verification; every accepted repository of a rebase must be" unless
        selected.any? { |chosen| Review::Checkout.same_directory?(chosen.path, root) }
      return "#{key} is not on its pull-request branch '#{repository['branch']}'" unless
        Review::Checkout::Git.current_branch(root) == repository["branch"].to_s
      return nil if succeeded?(git(root, [ "merge-base", "--is-ancestor", main, "HEAD" ]))

      "#{key} does not descend from main #{short(main)}; it was not rebased"
    end

    # The stored main commit is resolved by `ls-remote`, so it may not be local yet: the remote's
    # branches first, then the exact commit.
    def reachable?(root, commit)
      seam = Review::Checkout::Git
      return true if seam.commit?(root, commit)

      seam.fetch(root)
      return true if seam.commit?(root, commit)

      git(root, [ "fetch", "--quiet", seam::REMOTE, commit ])
      seam.commit?(root, commit)
    end

    def prompt_row(outcome)
      repository = outcome.target
      row = "- `#{repository['repository_key']}` (#{repository['pull_request_url']}), main commit `#{outcome.main}`: "
      return "#{row}rebased cleanly; change it only if verification requires it." if outcome.conflicts.empty?

      "#{row}conflicts in #{outcome.conflicts.map { |path| "`#{path}`" }.join(', ')}."
    end

    def subject(outcome)
      "Rebase of #{outcome.target['repository_key']} from #{short(outcome.start)} onto main #{short(outcome.main)}"
    end

    def named_paths(paths)
      named = paths.first(MAX_LINE_PATHS).join(", ")
      paths.length > MAX_LINE_PATHS ? "#{named} and #{paths.length - MAX_LINE_PATHS} more" : named
    end

    def dropped_phrase(dropped)
      return "" unless dropped.to_i.positive?

      "; #{dropped} #{dropped == 1 ? 'commit' : 'commits'} already in main dropped"
    end

    def head(root) = git(root, %w[rev-parse HEAD])&.stdout.to_s.strip

    def count(root, range)
      result = git(root, [ "rev-list", "--count", range ])
      succeeded?(result) ? result.stdout.to_s.strip.to_i : nil
    end

    # Abbreviated, because a full commit id is redacted from public text as a high-entropy string.
    def short(commit) = commit.to_s[0, 12]

    def succeeded?(result) = !result.nil? && result.success?

    def git(root, args)
      CommandRunner.run([ "git", "-C", root, *args ], chdir: root, timeout_seconds: Review::Checkout::Git::TIMEOUT_SECONDS)
    rescue SystemCallError
      nil
    end
  end
end
