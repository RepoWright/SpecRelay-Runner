# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # Returns the ticket's task environment once Platform has ACCEPTED a specification
    # publication: the accepted package is removed from it, and then the project's own release
    # authority takes the environment down.
    #
    # It exists because the specification lane LEAVES ITS ENVIRONMENT BEHIND. Generation
    # deliberately materializes the package into the ticket's canonical task worktree, beside the
    # code it describes, and nothing took that worktree back — so a ticket whose specification is
    # published and reviewable still held one, and the preview lane addresses the same task id.
    #
    # Two things make that safe to automate, and both are borrowed rather than reinvented:
    #
    #   1. {Preflight.changes_outside} — the same authority that decides whether an existing
    #      environment may be REUSED decides whether it may be taken down. An environment holding
    #      work outside this ticket's package directory is somebody's own, and a second rule for
    #      the same question is how reuse and cleanup would come to disagree.
    #   2. {PackageVerification} — the same digest, file-set and symbolic-link proof publication
    #      runs against its snapshot, run here against the environment. Bytes that are not the
    #      accepted ones are EVIDENCE of an edit, not a duplicate of committed history.
    #
    # It fails CLOSED, and closed means NOTHING: no file is deleted and the release command is
    # never invoked. Every check runs before the first deletion, so "it refuses before removing
    # anything" is a property of this order rather than of a rollback.
    #
    # A refusal is never a publication failure. The pull request exists and Platform's run has
    # advanced; reporting the run as failed because a worktree could not be returned would tell an
    # operator their specification was not published while a reviewer was already reading it.
    class TaskEnvironmentCleanup
      # `released` is the only success. `removed` says whether the accepted package is still the
      # environment's own uncommitted work, which is the one fact an operator reading a refusal
      # needs and cannot infer from the reason. Both nil with no reason means there was no
      # environment to return.
      Result = Struct.new(:released, :removed, :reason, keyword_init: true) do
        def released? = released ? true : false
        def removed? = removed ? true : false
      end

      def self.call(**kwargs) = new(**kwargs).call

      def initialize(assignment:, config:, env: ENV)
        @assignment = assignment
        @config = config
        @env = env
      end

      def call
        located = locate
        return located if located.is_a?(Result)
        return Result.new if located.nil?

        refusal = protected_reason(located)
        return refusal if refusal
        return refuse("still holds the accepted package, which could not be removed") unless
          remove_package(located)

        release
      end

      private

      attr_reader :assignment, :config, :env

      # The package folder, repository-relative, exactly as Platform RECORDED it at generation.
      # Read from the assignment rather than re-derived from the issue key and title, because a
      # renamed ticket derives a different folder name and this is the one value that is provably
      # the folder the accepted files are in.
      def package_path = assignment.generated_package_path

      # The ticket's task environment, located the way every other caller locates it: by asking
      # git which worktree holds the run's canonical branch. Nil when there is none — an
      # environment an operator already released needs nothing done to it.
      def locate
        @root = config.workspace_root(assignment.workspace_key, env: env)
        Workspace.new(root: @root, canonical_branch: assignment.canonical_branch,
                      task_id: assignment.task_id,
                      create_command: assignment.worktree_create_command,
                      env: { "PATH" => env["PATH"].to_s }).existing&.path
      rescue Workspace::Error, Config::Error => e
        refuse("could not be located: #{PrivatePaths.sanitize(e.message)}")
      end

      # The two facts that must hold before anything is deleted, cheapest first.
      #
      # The order matters for the MESSAGE as well as for the cost: an environment holding a
      # person's own work is a different situation from one holding an edited package, and naming
      # the wrong one sends an operator to look in the wrong place.
      def protected_reason(task)
        outside = Preflight.changes_outside(task_root: task, allowed: package_path, env: env)
        return refuse("could not be inspected") if outside.nil?
        return refuse(dirty_reason(outside)) if outside.any?

        verified = PackageVerification.call(worktree_root: task, package_path: package_path,
                                            files: assignment.generated_files)
        return nil if verified.ok?

        refuse("holds a package that is not the one SpecRelay accepted (#{verified.failure_class})")
      end

      def dirty_reason(outside)
        "holds #{outside.length} uncommitted change(s) outside #{package_path}: " \
          "#{outside.sort.first(5).join(', ')}"
      end

      # ONLY the recorded package folder, and only once {PackageVerification} has proved it holds
      # exactly the accepted files and is reached without following a link. The environment's own
      # repositories and working trees are the project's to take down, which is what the release
      # command below is for.
      #
      # What must be true afterwards is that the folder holds NO UNCOMMITTED WORK, and that is not
      # the same as holding no files. The accepted package arrives in the environment two ways: as
      # output lying beside the branch on a first round, and as the branch's OWN HISTORY on a round
      # that continued a published specification, whose files are tracked at the head the
      # environment was put on. Deleting the second kind would leave four deleted tracked files —
      # an uncommitted change, which is precisely the state the project's release authority refuses
      # — so a cleanup that removed it would make the environment unreleasable.
      #
      # So the folder is returned to what the branch records: untracked files in it are cleaned
      # away, tracked ones are restored from HEAD. A first round's package is untracked in full and
      # is therefore simply gone, exactly as before; a continued round's is left as the committed
      # evidence it already was. Both are scoped to the recorded path, so nothing outside the one
      # folder this run is allowed to touch is read or written.
      def remove_package(task)
        directory = File.join(task, package_path)
        return false if File.symlink?(directory) || !File.directory?(directory)

        commands = GitCommands.new(checkout_root: task, env: env)
        return false unless commands.success?([ "clean", "--quiet", "-fd", "--", package_path ])
        return true unless commands.success?([ "rev-parse", "--verify", "--quiet",
                                               "HEAD:#{package_path}" ])

        commands.success?([ "checkout", "--quiet", "HEAD", "--", package_path ])
      end

      # The project's own task-environment authority, invoked exactly as the implementation lane
      # invokes it. Nothing here knows how to take an environment down itself.
      def release
        result = TaskEnvironment.release(root: @root, task_id: assignment.task_id)
        return Result.new(released: true, removed: true) if result.released?

        Result.new(removed: true, reason: result.reason)
      end

      def refuse(reason) = Result.new(reason: "the task environment #{assignment.task_id} #{reason}")
    end
  end
end
