# frozen_string_literal: true

require "json"

module SpecrelayRunner
  # The project-owned task environment this run allocated, asked about and handed back.
  #
  # It exists because a completed run LEAVES ITS ENVIRONMENT BEHIND. That was harmless while a
  # person released it at their own pace; it is not harmless now, because the preview lane
  # addresses the same task id, and a stale environment is the difference between a preview that
  # starts and one that fails on a worktree it did not create.
  #
  # Two questions, one adapter, because they are the same contract read from two sides: WHO owns
  # this environment, and RELEASE the one this run owns. The project command answers both, and it
  # is the only thing that can: ownership is recorded where the environment is allocated, and a
  # runner that decided ownership for itself would be keeping a second copy of a record it does
  # not write.
  #
  # Nothing here removes anything. No Docker, no Compose, no git worktree removal, no directory
  # this runner did not create — the project's own authority does all of it, including its
  # locking, containment proof, retained refs and remaining-resource accounting.
  #
  # The rule that shapes every method below is that a command which did not PROVE what it did is
  # a failure. A timeout, a nonzero exit, an unparseable document, an answer about a different
  # task and an outcome the contract does not name are each reported as the environment still
  # being allocated. Reading any of them as success is how a run comes to report a released
  # environment that is still on disk.
  module TaskEnvironment
    RELEASE_TIMEOUT = 600
    # Status is a read. It gets its own, much shorter budget because it runs BEFORE the provider
    # on every automatic attempt, and an unanswerable project command must refuse the attempt
    # quickly rather than hold a claim open for ten minutes.
    STATUS_TIMEOUT = 120

    # The only two outcomes that are completion. `released` is this run's environment taken down;
    # `absent` is the project's own proof that there is nothing left to take down — which it makes
    # by inventorying the workspace and every registered component repository, and which this
    # runner therefore must not recreate.
    RELEASED = "released"
    ABSENT = "absent"

    Result = Struct.new(:released, :reason, keyword_init: true) do
      def released? = released ? true : false
    end

    # `owned` is a PROOF, never an absence of evidence. Every path that could not establish the
    # owner answers false with the reason, so a caller cannot mistake an unanswered question for
    # permission.
    Ownership = Struct.new(:owned, :reason, keyword_init: true) do
      def owned? = owned ? true : false
    end

    module_function

    # Does `run_id` own the environment `task_id`, provably, right now?
    #
    # Cleanliness is not ownership and neither is the canonical branch being checked out
    # somewhere: both are true of an environment a person made by hand, and adopting one would
    # delete their work at the end of this run. So the recorded owner is read from the project,
    # compared exactly, and anything else is a refusal.
    #
    # `canonical_branch` is compared when the caller knows it, because the answer must be about
    # the environment this run is actually going to use.
    def ownership(root:, task_id:, run_id:, canonical_branch: nil)
      unavailable = unavailable_reason(root, task_id, run_id)
      return unproved(task_id, "cannot be claimed: #{unavailable}") if unavailable

      result = invoke(root, [ "status", task_id.to_s, "--json" ], STATUS_TIMEOUT)
      document = document_of(result)
      return unproved(task_id, "could not be inspected: #{detail(result, 'status', task_id)}") if
        document.nil?

      mismatch = identity_mismatch(document, task_id, canonical_branch)
      return unproved(task_id, mismatch) if mismatch

      owner = document["owner_run_id"].to_s
      return unproved(task_id, "records no run owner, so it is a manual environment") if owner.empty?
      return unproved(task_id, "is owned by a different run") unless owner == run_id.to_s

      Ownership.new(owned: true)
    end

    # Hand back the environment this run owns, or say why it is still allocated.
    #
    # The owner is passed to the project rather than checked here first: it is the project that
    # holds the record, takes the lock and removes the resources, so asking it separately would
    # leave a window between the answer and the removal in which the record could change.
    def release(root:, task_id:, run_id:)
      unavailable = unavailable_reason(root, task_id, run_id)
      return still_allocated(task_id, "cannot be released: #{unavailable}") if unavailable

      result = invoke(root, [ "release", task_id.to_s, "--run-id", run_id.to_s, "--json" ],
                      RELEASE_TIMEOUT)
      document = document_of(result)
      return still_allocated(task_id, "is still allocated: #{detail(result, 'release', task_id)}") if
        document.nil?

      incomplete = incompletion(document, task_id, run_id)
      return still_allocated(task_id, incomplete) if incomplete

      Result.new(released: true)
    end

    # Release, or refuse to continue. The raise lives here rather than at the call site so the
    # rule — a machine that could not release must not claim again — is stated once.
    def release!(root:, task_id:, run_id:, io: nil)
      result = release(root: root, task_id: task_id, run_id: run_id)
      raise CleanupRequired, result.reason unless result.released?

      io&.puts("Released the task environment #{task_id}.")
      true
    end

    # The conditions under which the question cannot even be ASKED, cheapest first.
    #
    # A project that owns no lifecycle command is refused rather than worked around. It is the
    # one authority that records ownership, so without it an automatic run could only allocate an
    # environment nobody owns — and an unowned environment is exactly the one this lane must
    # never take down at the end.
    def unavailable_reason(root, task_id, run_id)
      return "this assignment carries no run identity" if run_id.to_s.strip.empty?
      return "this assignment carries no task id" if task_id.to_s.empty?
      return nil if File.executable?(File.join(root.to_s, Workspace::PROJECT_COMMAND))

      "this project owns no run-aware `#{Workspace::PROJECT_COMMAND}` command"
    end

    # The document a successful command printed, or nil. A failed command has no document by
    # definition — its stdout in JSON mode carries the project's own error object, which is a
    # description of a refusal rather than an answer to the question that was asked.
    def document_of(result)
      return nil unless result&.success?

      parsed = JSON.parse(result.stdout.to_s)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    # An answer about a DIFFERENT environment. The command is addressed by task id, so this is
    # not a theoretical shape: a project whose command ignored its argument, or answered from a
    # stale cache, would otherwise hand this run somebody else's ownership record.
    def identity_mismatch(document, task_id, canonical_branch)
      return "reported a different task id" unless document["task_id"].to_s == task_id.to_s
      return nil if canonical_branch.to_s.empty?
      return nil if document["branch"].to_s == canonical_branch.to_s

      "is on a different branch from this run's canonical #{canonical_branch}"
    end

    # Why this release is not completion, or nil when it is.
    #
    # `released` must also name the owner it released for. The project proves that already; it is
    # re-read here because this is the value the runner acted on, and a run that reported cleanup
    # for an environment released under another identity would have recorded something it cannot
    # support.
    def incompletion(document, task_id, run_id)
      return "reported a different task id" unless document["task_id"].to_s == task_id.to_s

      case document["outcome"].to_s
      when ABSENT then nil
      when RELEASED
        return nil if document["owner_run_id"].to_s == run_id.to_s

        "was released for a different run"
      else
        "is still allocated: `#{Workspace::PROJECT_COMMAND} release #{task_id}` " \
          "reported no completed release"
      end
    end

    # What the command did, in the operator's terms. Deliberately silent about which files or
    # resources survived: only the project knows that, it has recorded it, and a runner guessing
    # at it is how an incomplete teardown comes to be described as a partial success.
    def detail(result, verb, task_id)
      command = "`#{Workspace::PROJECT_COMMAND} #{verb} #{task_id}`"
      return "#{command} could not be started" if result.nil?
      return "#{command} timed out" if result.timed_out?
      return "#{command} exited #{result.exit_code}" unless result.success?

      "#{command} returned output this runner could not read"
    end

    def invoke(root, arguments, timeout)
      CommandRunner.run([ File.join(root.to_s, Workspace::PROJECT_COMMAND), *arguments ],
                        chdir: root.to_s, env: {}, timeout_seconds: timeout)
    rescue SystemCallError
      nil
    end

    def unproved(task_id, reason) = Ownership.new(owned: false, reason: sentence(task_id, reason))

    def still_allocated(task_id, reason) = Result.new(released: false,
                                                      reason: sentence(task_id, reason))

    def sentence(task_id, reason) = "the task environment #{task_id} #{reason}"
  end
end
