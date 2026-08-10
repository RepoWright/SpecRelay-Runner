# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # Proves a resumed isolated workspace is the one this publication is authorized to publish
    # from, BEFORE any git mutation (MAPIAI-62 design 3).
    #
    # Publication used to re-resolve the operator's checkout from configuration, independently
    # of generation, and could therefore silently pick a different directory. There is nothing
    # to re-resolve now: the assignment carries an opaque id, this class looks it up in the
    # Runner's own store, and there is no second place to look and no checkout to fall back to.
    # "Fails closed" is what the absence of those branches means, not a policy applied at the end.
    #
    # It answers, in order, and stops at the first no:
    #
    #   1. does this machine hold a workspace with that id, and did generation finish in it?
    #   2. has its retention window passed?
    #   3. does its metadata name THIS run, THIS runner identity and THIS repository?
    #   4. is it still a real git worktree, at the base commit it recorded?
    #   5. is the package exactly the files, bytes and digests Platform recorded? ({PackageVerification})
    #
    # 3 is the "foreign state" question and 4 is the "altered state" one; they are separate
    # because their remedies are. A workspace belonging to another run is a Platform/runner
    # disagreement an operator resolves with `Generate again`; a worktree that no longer resolves
    # is local damage, and the same remedy applies but the sentence an operator reads must not
    # claim the wrong cause.
    class PackageWorkspaceCheck
      MISSING = "specification_workspace_missing"
      EXPIRED = "specification_workspace_expired"
      INVALID = "specification_workspace_invalid"

      Result = Struct.new(:workspace, :files, :failure_class, :message, keyword_init: true) do
        def ok? = failure_class.nil?
      end

      def self.call(**kwargs) = new(**kwargs).call

      def initialize(workspaces:, assignment:, config:, env: ENV, clock: Time)
        @workspaces = workspaces
        @assignment = assignment
        @config = config
        @env = env
        @clock = clock
      end

      def call
        workspace = workspaces.find(assignment.generated_package_workspace_id)
        return failure(MISSING, missing_message) if workspace.nil? || workspace.metadata.nil?
        return failure(MISSING, unfinished_message) unless workspace.ready?
        return failure(EXPIRED, expired_message) if workspace.expired?(clock.now.utc)

        mismatch = identity_mismatch(workspace)
        return failure(INVALID, mismatch) if mismatch

        worktree = check_worktree(workspace)
        return worktree if worktree

        verify_package(workspace)
      end

      private

      attr_reader :workspaces, :assignment, :config, :env, :clock

      # Each field is checked against the ASSIGNMENT, never against the metadata's own copy of
      # itself. The point is agreement between what Platform is asking for and what this
      # workspace was created to hold; comparing the document with itself would always pass.
      #
      # `runner_public_id` is compared only when both sides carry one. A runner configured from
      # YAML has no registered identity to record, and refusing every such runner would make the
      # check a configuration requirement rather than a safety property — Platform's SQL owner
      # filter is what makes the registered identity authoritative, and this is the local echo of it.
      def identity_mismatch(workspace)
        document = workspace.metadata
        return "it was created for a different run" unless document["run_id"] == assignment.run_id
        return "it was created by a different runner identity on this machine" unless
          document["runner_id"].to_s == assignment.runner_id
        return "it was created for a different specification repository" unless
          same_repository?(document)
        return "it holds a different package folder" unless
          document["package_path"].to_s == assignment.generated_package_path

        registered_mismatch(document)
      end

      # The slug when both sides have one, the URL otherwise. Platform parses `owner/repository`
      # from the configured target and can legitimately fail to — an enterprise host, say — and
      # in that case the canonical URL is the identity both sides do hold.
      def same_repository?(document)
        slug = assignment.publication_slug.to_s
        recorded = document["repository_slug"].to_s
        return recorded == slug unless slug.empty? || recorded.empty?

        document["repository_url"].to_s == assignment.publication_repository_url
      end

      def registered_mismatch(document)
        recorded = document["runner_public_id"].to_s
        held = config.connection&.runner_public_id.to_s
        return nil if recorded.empty? || held.empty? || recorded == held

        "it was created under a different registered runner on this machine"
      end

      # Still a real worktree, still at the recorded base. `--is-inside-work-tree` is asked
      # first because a directory whose `.git` link has been broken answers nothing useful to
      # `rev-parse HEAD`, and "this is no longer a git worktree" is the more accurate sentence.
      def check_worktree(workspace)
        commands = GitCommands.new(checkout_root: workspace.worktree_root, env: env)
        return failure(INVALID, "it is no longer a git worktree") unless
          commands.git_value(%w[rev-parse --is-inside-work-tree]) == "true"

        head = commands.git_value(%w[rev-parse HEAD])
        return nil if head.to_s == workspace.metadata["base_commit"].to_s

        failure(INVALID, "it is no longer at the commit it was created from")
      end

      def verify_package(workspace)
        result = PackageVerification.call(worktree_root: workspace.worktree_root,
                                          package_path: assignment.generated_package_path,
                                          files: assignment.generated_files)
        return Result.new(workspace: workspace, files: result.files) if result.ok?

        Result.new(failure_class: result.failure_class, message: result.message)
      end

      def missing_message
        "this runner no longer holds the isolated workspace that generated this package. " \
          "Use `Generate again` on the run page: any connected runner can then create a fresh " \
          "package for this run"
      end

      def unfinished_message
        "the isolated workspace for this package exists but no complete package was ever finished " \
          "in it. Use `Generate again` on the run page"
      end

      def expired_message
        "the isolated workspace holding this package passed its " \
          "#{PackageWorkspaceStore::RETENTION_DAYS}-day retention window and is no longer publishable. " \
          "Use `Generate again` on the run page"
      end

      def failure(failure_class, detail)
        Result.new(failure_class: failure_class,
                   message: Redaction.redact("refusing to publish: #{detail}. Nothing was committed, " \
                                             "pushed, or opened as a pull request"))
      end
    end
  end
end
