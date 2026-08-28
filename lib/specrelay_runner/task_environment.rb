# frozen_string_literal: true

module SpecrelayRunner
  # MAPIAI-97 — releasing the project-owned task environment this machine finished with.
  #
  # It exists because a completed implementation run LEAVES ITS ENVIRONMENT BEHIND. That was
  # harmless while a person released it at their own pace; it is not harmless now, because the
  # preview lane addresses the same task id, and a stale environment is the difference between a
  # preview that starts and one that fails on a worktree it did not create.
  #
  # So the runner releases what it created, before it polls again. Nothing else changes: the
  # report is already uploaded and accepted, and a release that fails does not retract it.
  #
  # It is the same project-owned authority the preview lane uses, and it invokes nothing else:
  # no Docker, no Compose, no removal of a directory this runner did not create.
  module TaskEnvironment
    RELEASE_TIMEOUT = 600

    Result = Struct.new(:released, :reason, keyword_init: true) do
      def released? = released
    end

    module_function

    # Release, or refuse to continue. The raise lives here rather than at the call site so the
    # rule — a machine that could not release must not claim again — is stated once.
    def release!(root:, task_id:, io: nil)
      result = release(root: root, task_id: task_id)
      raise CleanupRequired, result.reason unless result.released?

      io&.puts("Released the task environment #{task_id}.")
      true
    end

    # Releases `task_id` in the connected checkout, or says why it could not. A project that owns
    # no `bin/worktree` releases nothing and reports nothing to clean up: this runner did not
    # build that environment through a project command and must not guess how to take it down.
    def release(root:, task_id:)
      command = File.join(root.to_s, PreviewExecution::PROJECT_COMMAND)
      return Result.new(released: true) unless File.executable?(command) && !task_id.to_s.empty?

      result = CommandRunner.run([ command, "release", task_id.to_s ], chdir: root.to_s, env: {},
                                                                       timeout_seconds: RELEASE_TIMEOUT)
      return Result.new(released: true) if released?(result)

      Result.new(released: false, reason: reason(result, task_id))
    rescue SystemCallError
      Result.new(released: false, reason: "`#{PreviewExecution::PROJECT_COMMAND} release " \
                                          "#{task_id}` could not be started")
    end

    # The project's own "unknown task environment" answer counts as released, for the same reason
    # it does in the preview lane: an environment that does not exist needs no cleanup.
    def released?(result)
      result.success? || result.exit_code == PreviewExecution::UNKNOWN_ENVIRONMENT
    end

    def reason(result, task_id)
      detail = result.timed_out? ? "timed out" : "exited #{result.exit_code}"
      "the task environment #{task_id} is still allocated: " \
        "`#{PreviewExecution::PROJECT_COMMAND} release #{task_id}` #{detail}"
    end
  end
end
