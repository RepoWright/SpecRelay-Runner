# frozen_string_literal: true

module SpecrelayRunner
  # The optional RESUME round of an implementation assignment (MVP-0036 Stage 2a design 5).
  #
  # An ordinary claim carries no `resume` block and this is `nil`, so the first-execution path is
  # untouched. When Platform does send one, the provider that asked the question is long gone and
  # its session cannot be recreated — what survives is the recorded work, held as checkpoint refs on
  # each changed repository's own origin, and this machine has to be holding exactly it before
  # anything continues.
  #
  # ONE way that happens, on whichever machine claims the run: the manifest is downloaded and
  # proved, the task workspace is found or built, and {Checkpoint.restore} fetches every recorded
  # ref and reconstructs the work there. A worktree this machine still has is only a destination;
  # its files are never the source of what continues.
  #
  # Anything else refuses before a provider starts, with the answers, the refs and every local file
  # exactly as they were, so another eligible machine — or this one — can try again.
  #
  # The fresh session is then handed the complete public handoff: the questions, the Product
  # Owner's answers, and the continuation context. It receives nothing else, because nothing else
  # was ever stored.
  #
  # A sibling of {Rework}, and deliberately not a mode of it: that one continues a REVIEWED head,
  # and this one continues UNCOMMITTED work on top of it.
  class Resume
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

    # The claim-bound path the recorded manifest is downloaded from. Platform derives it; this
    # never constructs one.
    def download_path = block["checkpoint"].to_h["download_path"].to_s

    # The closed manifest metadata, without the download path the assignment adds to it.
    def checkpoint = block["checkpoint"].to_h.except("download_path")

    # The verified worktree, or the refusal that stops this claim before any provider starts.
    #
    # The manifest is downloaded and proved BEFORE the task workspace is built, so a transfer
    # failure or a manifest that is not the recorded one leaves this machine as it found it.
    #
    # `target` is the reviewed {Rework} when the question was asked during a change-request round.
    # It is proved after every checkpoint entry and before anything is placed: a workspace this
    # claim built is put on the reviewed heads, and one it found is proved in place, because its
    # reviewed checkouts may already hold the recorded work. Either way the recorded base of a
    # reviewed repository must BE its reviewed head.
    def prepare(measuring:, creating:, download:, branch:, target: nil)
      payload = download.call
      checked = Checkpoint.check(checkpoint, payload: payload)
      return Prepared.new(reason: checked.reason) unless checked.ok?

      worktree = measuring.existing || creating.create
      proof = nil
      restored = Checkpoint.restore(checkpoint, payload: payload, task_root: worktree.path, branch: branch,
                                                created: worktree.created?) do
        proof = target && target_proof(target, worktree)
      end
      restored.ok? ? continued(worktree, proof) : Prepared.new(reason: restored.reason)
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

    def target_proof(target, worktree)
      return target.materialize(worktree_path: worktree.path, created: true, recorded_bases: recorded_bases) if
        worktree.created?

      held = recorded_bases.keys.map { |path| File.join(worktree.path, path) }
      target.prove(worktree_path: worktree.path, held: held, recorded_bases: recorded_bases)
    end

    # Each recorded repository's path in the task workspace, with the base its work was recorded on.
    def recorded_bases = checkpoint["repositories"].to_a.to_h { |entry| [ entry["path"].to_s, entry["base_sha"].to_s ] }

    # The report's base commit is the task-workspace repository's: its reviewed head, else its
    # recorded base when the checkpoint moved it there, else where the workspace already stood.
    def continued(worktree, proof)
      base = proof&.head_commit || recorded_bases["."] || worktree.base_commit
      Prepared.new(worktree: Workspace::Info.new(path: worktree.path, created: worktree.created?, base_commit: base))
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
