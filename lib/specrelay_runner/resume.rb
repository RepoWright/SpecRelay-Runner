# frozen_string_literal: true

module SpecrelayRunner
  # The optional RESUME round of an implementation assignment (MVP-0036 Stage 2a design 5).
  #
  # An ordinary claim carries no `resume` block and this is `nil`, so the first-execution path is
  # untouched. When Platform does send one, the provider that asked the question is long gone and
  # its session cannot be recreated — what survives is the recorded work, and this machine has to
  # be holding exactly it before anything continues.
  #
  # Two ways that happens, and only two:
  #
  #   1. this machine still has the worktree the question was asked from, and it REMEASURES to
  #      the recorded checkpoint. Nothing is downloaded and nothing is reapplied — the files are
  #      already the recorded ones;
  #   2. this machine has no worktree for the branch, so it downloads the recorded package,
  #      builds the task workspace through the project's own command, restores every recorded
  #      repository into it, and remeasures.
  #
  # Anything else refuses before a provider starts: a worktree that is not what was recorded, a
  # package that is not the recorded one, a target that is not clean at the recorded base. The
  # answers, the package and every local file stay exactly as they are, so another eligible
  # machine — or this one, once its worktree is released — can try again.
  #
  # The fresh session is then handed the complete public handoff: the questions, the Product
  # Owner's answers, and the continuation context. It receives nothing else, because nothing else
  # was ever stored.
  #
  # A sibling of {Rework}, and deliberately not a mode of it: that one continues a REVIEWED head
  # by resetting a clean worktree onto it, and this one continues UNCOMMITTED work.
  class Resume
    NO_CHECKPOINT = "no portable checkpoint was recorded when the question was asked"

    Prepared = Struct.new(:worktree, :reason, keyword_init: true) do
      def ok? = !worktree.nil?
    end

    def self.for(payload)
      block = payload["resume"]
      block.is_a?(Hash) ? new(block) : nil
    end

    def initialize(block)
      @block = block
    end

    # The batch Platform settles once the fresh session has it.
    def question_id = block["question_id"].to_s

    # The claim-bound path the recorded package is downloaded from. Platform derives it; this
    # never constructs one.
    def download_path = checkpoint["download_path"].to_s

    # The verified worktree, or the refusal that stops this claim before any provider starts.
    #
    # `download` is called only on the path that needs bytes, and BEFORE the task workspace is
    # built, so a transfer failure leaves this machine exactly as it found it.
    def prepare(measuring:, creating:, download:)
      return Prepared.new(reason: NO_CHECKPOINT) if Array(checkpoint["repositories"]).empty?

      found = measuring.existing
      return reuse(found, measuring) if found

      payload = download.call
      restore(payload, creating: creating, measuring: measuring)
    rescue PlatformClient::Error => e
      Prepared.new(reason: "the recorded checkpoint could not be downloaded: #{Redaction.redact(e.message)}")
    rescue Workspace::Error => e
      Prepared.new(reason: Redaction.redact(e.message))
    end

    # The section the executor's prompt carries. It states what a session that never asked cannot
    # know — that the files under it are half-finished work and which decisions have since been
    # made — and it is the ONLY thing carried over: the previous session's reasoning, its output
    # and its provider session are not stored anywhere and are not reconstructed here.
    def prompt_section
      [ "", "---", "", "## Answers to your earlier questions", "",
        "A previous session changed the files you are looking at, paused on the questions below,",
        "and was released before they were answered. You have its changed files and this handoff,",
        "and nothing else from it.", "",
        *context_lines, "", *answer_lines, "",
        "Continue from `next_step`. Do not start again from the beginning and do not redo",
        "anything under `do_not_repeat`." ].join("\n")
    end

    private

    attr_reader :block

    def checkpoint = block["checkpoint"].to_h

    # This machine still holds the work. `create` deliberately refuses an existing worktree with
    # uncommitted changes, which is the one state this path requires, so the worktree is READ and
    # remeasured rather than rebuilt.
    def reuse(found, measuring)
      proof = Checkpoint.verify(checkpoint, task_root: found.path, workspace: measuring)
      proof.ok? ? Prepared.new(worktree: found) : Prepared.new(reason: proof.reason)
    end

    # This machine has never seen the work. The task workspace is built by the PROJECT's own
    # command — the same one an ordinary first execution uses — and the recorded repositories are
    # restored into it, each proven clean at its recorded base first.
    def restore(payload, creating:, measuring:)
      created = creating.create
      restored = Checkpoint.restore(checkpoint, payload: payload, task_root: created.path,
                                                workspace: measuring)
      restored.ok? ? Prepared.new(worktree: created) : Prepared.new(reason: restored.reason)
    end

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
