# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # Returns the ticket's task environment once Platform has ACCEPTED a specification
    # publication, by asking the project to release the environment this run owns.
    #
    # It exists because the specification lane LEAVES ITS ENVIRONMENT BEHIND. Generation
    # deliberately materializes the package into the ticket's canonical task worktree, beside the
    # code it describes, and nothing took that worktree back — so a ticket whose specification is
    # published and reviewable still held one, and the preview lane addresses the same task id.
    #
    # It used to clear the package folder itself first, and to refuse an environment holding
    # uncommitted work. Both are gone, and ownership is why. An environment this run allocated is
    # this run's: once the required publication has been accepted, every unpublished edit in it
    # is disposable, including one a person made by hand. And an environment this run does NOT
    # own is refused by the project before anything is removed — so there is nothing left for a
    # Runner-side protection rule to add except a second opinion that could disagree with the
    # authority that actually performs the removal.
    #
    # What it keeps is the ORDER. Nothing is asked for until the publication has succeeded and
    # Platform has accepted the result; see {Publication#clean_up}. And a refusal is never a
    # publication failure: the pull request exists and Platform's run has advanced, so reporting
    # the run as failed because a worktree could not be returned would tell an operator their
    # specification was not published while a reviewer was already reading it.
    class TaskEnvironmentCleanup
      # `released` is the only success, and it is the project's own proof of one. A result with a
      # reason is an environment still allocated; it deliberately says nothing about which files
      # or resources survived, because only the project knows that and it has recorded it.
      Result = Struct.new(:released, :reason, keyword_init: true) do
        def released? = released ? true : false
      end

      def self.call(**kwargs) = new(**kwargs).call

      def initialize(assignment:, config:, env: ENV)
        @assignment = assignment
        @config = config
        @env = env
      end

      # No local inventory of its own, deliberately. An environment whose directory is gone may
      # still hold metadata, a registration or an isolated runtime resource, and a runner that
      # decided for itself that there was "nothing to do" would report cleanup for an environment
      # the project can still see. The project proves absence; this asks it to.
      def call
        root = config.workspace_root(assignment.workspace_key, env: env)
        result = TaskEnvironment.release(root: root, task_id: assignment.task_id,
                                         run_id: assignment.run_id)
        return Result.new(released: true) if result.released?

        Result.new(reason: result.reason)
      rescue Config::Error => e
        Result.new(reason: "the task environment #{assignment.task_id} could not be released: " \
                           "#{PrivatePaths.sanitize(e.message)}")
      end

      private

      attr_reader :assignment, :config, :env
    end
  end
end
