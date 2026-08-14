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
  # (1) is {ContinuedTarget}, because MVP-0036 Stage 2b needs the same proof for a replacement
  # run that continues a pull request nobody reviewed. This class owns (2), which is the half
  # that is genuinely about a change request: the findings, and how they reach the provider.
  class Rework
    # The reviewed target, or nil when this claim is an ordinary first execution.
    def self.for(payload)
      block = payload["rework"]
      block.is_a?(Hash) ? new(block, ContinuedTarget.for(payload, "rework")) : nil
    end

    def initialize(block, target)
      @block = block
      @target = target
    end

    # Put the worktree on the reviewed head, or refuse.
    def materialize(worktree_path:, git: Review::Checkout::Git)
      target.materialize(worktree_path: worktree_path, git: git)
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

    attr_reader :block, :target

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
  end
end
