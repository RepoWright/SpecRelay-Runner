# frozen_string_literal: true

module SpecrelayRunner
  # The optional CHANGE-REQUEST round of an implementation assignment (MVP-0035 design 3).
  #
  # An ordinary claim carries no `rework` block and this is `nil`, so the first-execution path is
  # untouched. When Platform does send one, two things must happen before a provider starts:
  #
  #   1. every repository the reviewed round published must hold its EXACT reviewed pull-request
  #      head — not the default branch, not a live moved head, and not whatever an old local
  #      branch happens to point at;
  #   2. the executor must be told which heads it is on and which findings it is correcting.
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

    # Put every reviewed repository on its reviewed head, or refuse.
    def materialize(worktree_path:, git: Review::Checkout::Git)
      target.materialize(worktree_path: worktree_path, git: git)
    end

    # The section the executor's prompt carries: which heads it is on, which pull requests it is
    # continuing, and every current finding — once. The previous report, the previous prompt and
    # the reviewer's own reasoning are deliberately absent: a rework prompt that concatenated
    # each round's history would grow without bound and bury the findings it exists to deliver.
    def prompt_section(round_label)
      [ "", "---", "", "## Change request — #{round_label}", "", *continuation_lines, "",
        "Reviewer summary: #{summary}", "", *finding_lines, "",
        "Correct ONLY the findings above, inside the approved specification package. Do not",
        "restate the specification, do not revisit anything else, and do not open a new pull",
        "request — your commit continues the existing one in each repository." ].join("\n")
    end

    private

    attr_reader :block, :target

    def reviewed_repositories = Array(block["repositories"])

    def findings = Array(block["findings"])
    def summary = block["summary"].to_s

    # EVERY continued repository, once, in the order the assignment states them — MAPIAI-107.
    #
    # A reviewed round may have published several repositories from this one task workspace, and
    # an executor told about only the first would correct that one and leave the others showing
    # the code the reviewer rejected. A single repository is the same sentence with one row, so
    # there is no separate one-target wording to keep true.
    #
    # Recorded facts only: the key, the head, the branch and the pull request Platform sent. No
    # local path appears — where each repository is checked out is this machine's business, and
    # the executor is already working inside it.
    def continuation_lines
      repositories = reviewed_repositories
      return [ "This task workspace is at the ordinary starting point: the reviewed execution changed no files." ] if
        repositories.empty?

      [ "This task workspace is at the exact reviewed head of every repository the reviewed " \
        "execution published:", "" ] + repositories.map { |repository| continuation_row(repository) }
    end

    def continuation_row(repository)
      "- `#{repository['repository_key']}` at `#{repository['head_commit']}` on branch " \
        "`#{repository['branch']}` (#{repository['pull_request_url']})"
    end

    def finding_lines
      findings.each_with_index.map do |finding, index|
        "#{index + 1}. [#{finding['severity']}] `#{finding['location']}` — #{finding['summary']}\n" \
        "   #{finding['reason']}"
      end
    end
  end
end
