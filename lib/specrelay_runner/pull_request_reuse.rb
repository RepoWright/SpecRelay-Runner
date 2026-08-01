# frozen_string_literal: true

module SpecrelayRunner
  # THE decision about whether an existing open pull request may be reported as THIS run's
  # output — extracted from {Publication} in MVP-0027 so both publication lanes hold one copy.
  #
  # This is the single piece of the implementation lane's publication logic that the
  # specification lane genuinely shares. The rest of {Publication} is about an executor's
  # worktree, a diff, a test result and a repository policy, none of which exist here; but "does
  # this open pull request contain the commit I just pushed?" is the same question in both
  # lanes, it is pure, and it took four review rounds to get right. Re-deriving it for a second
  # lane would be re-deriving the four fail-open defects with it.
  #
  # The table below is the whole contract. Every row is asserted by a table-driven test against a
  # REAL commit chain, and a newly discovered input class becomes a new row HERE rather than a
  # new branch in a caller.
  #
  #   reported vs pushed                     decision                 outcome
  #   -------------------------------------  -----------------------  -------
  #   pushed empty (ours unknown)            :pushed_head_unknown     refuse
  #   both empty                             :pushed_head_unknown     refuse
  #   reported empty or absent               :reported_head_unknown   refuse
  #   equal                                  :head_matches            REUSE
  #   reported is an ancestor of pushed      :reported_is_ancestor    REUSE
  #   pushed is an ancestor of reported      :reported_head_ahead     refuse
  #   divergent sibling                      :heads_diverged          refuse
  #   reported is an unknown object          :heads_diverged          refuse
  #
  # `ancestor` is injected rather than performed here, and that is the boundary that makes this
  # module shareable: the decision is policy, and reaching a git repository to answer "is A an
  # ancestor of B?" is the caller's, because the two lanes hold different checkouts.
  module PullRequestReuse
    # The only decisions that permit reuse, in preference order: an exact match is preferred over
    # a lagging GitHub snapshot. This constant is the SINGLE source of truth — callers derive
    # their behaviour from it rather than restating the set.
    REUSABLE_DECISIONS = %i[head_matches reported_is_ancestor].freeze

    module_function

    # `reported` is the head GitHub says the pull request is on; `pushed` is the commit THIS run
    # committed and pushed — never a pre-commit worktree head. `ancestor` is a callable taking
    # (candidate, descendant) and returning whether candidate is an ancestor of descendant.
    def decide(reported:, pushed:, ancestor:)
      reported = reported.to_s
      pushed = pushed.to_s
      return :pushed_head_unknown if pushed.empty?
      return :reported_head_unknown if reported.empty?
      return :head_matches if reported == pushed
      return :reported_is_ancestor if ancestor.call(reported, pushed)
      return :reported_head_ahead if ancestor.call(pushed, reported)

      :heads_diverged
    end

    def reusable?(decision) = REUSABLE_DECISIONS.include?(decision)
  end
end
