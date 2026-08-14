# frozen_string_literal: true

module SpecrelayRunner
  # The optional RESUME round of an implementation assignment (MVP-0036 Stage 2a design 5).
  #
  # An ordinary claim carries no `resume` block and this is `nil`, so the first-execution path is
  # untouched. When Platform does send one, the provider that asked the question is long gone and
  # its session cannot be recreated — what survives is on this machine's disk, and that is the
  # whole reason only this machine may take the claim.
  #
  # Two things therefore have to happen before a provider starts:
  #
  #   1. the worktree must be READ, not created, and proven to be the exact one the question was
  #      asked from — {Workspace#create} deliberately refuses an existing worktree with
  #      uncommitted changes, which is the one state this path requires;
  #   2. the fresh session must be handed the complete public handoff: the questions, the Product
  #      Owner's answers, and the continuation context. It receives nothing else, because nothing
  #      else was ever stored.
  #
  # A sibling of {Rework}, and deliberately not a mode of it: that one continues a REVIEWED head
  # by resetting a clean worktree onto it, and this one continues UNCOMMITTED work by refusing to
  # touch it at all.
  class Resume
    Prepared = Struct.new(:worktree, :reason, keyword_init: true) do
      def ok? = !worktree.nil?
    end

    def self.for(payload)
      block = payload["resume"]
      block.is_a?(Hash) ? new(block, payload) : nil
    end

    def initialize(block, payload)
      @block = block
      @repository_key = payload.dig("workspace", "workspace_key").to_s
      @branch = payload.dig("run", "canonical_branch").to_s
    end

    # The batch Platform settles once the fresh session has it.
    def question_id = block["question_id"].to_s

    # The verified worktree, or the refusal that stops this claim before any provider starts.
    def prepare(workspace:, git: Review::Checkout::Git)
      found = workspace.existing
      return Prepared.new(reason: "this machine no longer has a worktree for '#{branch}'") if found.nil?

      proof = Checkpoint.verify(block["checkpoint"], repository_key: repository_key, branch: branch,
                                                     worktree_path: found.path, workspace: workspace, git: git)
      proof.ok? ? Prepared.new(worktree: found) : Prepared.new(reason: proof.reason)
    end

    # The section the executor's prompt carries. It states what a session that never asked cannot
    # know — that the files under it are half-finished work and which decisions have since been
    # made — and it is the ONLY thing carried over: the previous session's reasoning, its output
    # and its provider session are not stored anywhere and are not reconstructed here.
    def prompt_section
      [ "", "---", "", "## Answers to your earlier questions", "",
        "A previous session on this machine changed the files you are looking at, paused on the",
        "questions below, and was released before they were answered. You have its changed files",
        "and this handoff, and nothing else from it.", "",
        *context_lines, "", *answer_lines, "",
        "Continue from `next_step`. Do not start again from the beginning and do not redo",
        "anything under `do_not_repeat`." ].join("\n")
    end

    private

    attr_reader :block, :repository_key, :branch

    def context_lines
      [ "Where it had got to:" ] +
        block["continuation_context"].to_h.map { |field, value| "- #{field}: #{value}" }
    end

    # Ordered and parallel: answer N belongs to question N, which is the only reason a session
    # that never asked can read this batch at all.
    def answer_lines
      answers = Array(block["answers"])
      [ "The Product Owner's decisions:" ] +
        Array(block["questions"]).each_with_index.map do |asked, index|
          answer = answers[index].to_h
          "#{index + 1}. #{asked['prompt']}\n   Answer: #{decision(answer)}"
        end
    end

    def decision(answer)
      [ answer["option"], answer["text"] ].map(&:to_s).reject(&:empty?).join(" — ")
    end
  end
end
