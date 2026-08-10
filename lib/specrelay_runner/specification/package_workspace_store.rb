# frozen_string_literal: true

require "fileutils"

module SpecrelayRunner
  module Specification
    # The Runner-owned root that holds every isolated specification-package workspace, and the
    # lock that serializes work on one of them (MAPIAI-62 design 1 and 4).
    #
    # It lives under the runner's existing local state directory — never under a source or
    # specification repository checkout — so nothing it creates or removes can be inside a
    # repository an operator owns. That is enforced rather than documented: every deletion is
    # re-checked for containment in this root, and a symlinked entry is skipped instead of
    # followed, so the worst a tampered state directory can do is make the sweep skip work.
    #
    # The retention contract is FIXED, not configurable (design 4): seven days, at most twenty
    # retained workspaces. A configurable retention would be a second thing to get wrong on
    # every machine, and the spec's non-goals rule out a workspace manager.
    class PackageWorkspaceStore
      DEFAULT_RELATIVE_PATH = ".specrelay/runner/specification-packages"
      ROOT_ENV = "SPECRELAY_RUNNER_SPEC_WORKSPACE_ROOT"

      RETENTION_DAYS = 7
      MAX_RETAINED = 20

      def self.for(env: ENV, home: Dir.home) = new(root: resolve_root(env: env, home: home), env: env)

      def self.resolve_root(env: ENV, home: Dir.home)
        override = env[ROOT_ENV].to_s.strip
        override.empty? ? File.join(home, DEFAULT_RELATIVE_PATH) : override
      end

      attr_reader :root

      def initialize(root:, env: ENV)
        @root = File.expand_path(root.to_s)
        @env = env
      end

      def retention_days = RETENTION_DAYS
      def max_retained = MAX_RETAINED

      # Establish the root and prove it is usable, WITHOUT writing a probe file into it. Called
      # from preflight so "this machine cannot hold a package workspace" is a refusal before a
      # provider runs, not a failure after one.
      def prepare!
        FileUtils.mkdir_p(root)
        raise PackageWorkspace::Error, "the runner package-workspace root is not writable: #{root}" unless
          File.writable?(root)

        root
      end

      # A NEW workspace with a fresh opaque id. The id is generated here rather than derived
      # from the run, so a second generation for the same run cannot land on the first one's
      # directory — which is what makes "Generate again" leave the previous package intact and
      # merely stale.
      def create(commands:, base_commit:, identity:, clock:)
        id = PackageWorkspace.generate_id
        PackageWorkspace.new(id: id, root: File.join(root, id))
                        .create!(commands: commands, base_commit: base_commit, identity: identity,
                                 clock: clock, retention_days: RETENTION_DAYS)
      end

      # The workspace for an opaque id, or nil. The id SHAPE is validated before it is used as a
      # path component: it arrives in an assignment, so it is data this runner did not author,
      # and an id that is not the shape this store issues can never name a workspace it holds.
      def find(workspace_id)
        return nil unless PackageWorkspace.id?(workspace_id)

        workspace = PackageWorkspace.new(id: workspace_id.to_s, root: File.join(root, workspace_id.to_s))
        contained?(workspace.root) && workspace.exists? ? workspace : nil
      end

      # Every workspace this runner holds, oldest first. Symlinked entries are skipped rather
      # than resolved: a symlink in the state root is not a workspace, and following one is the
      # single way a sweep could reach outside this directory.
      def all
        return [] unless File.directory?(root)

        Dir.children(root).filter_map { |name| directory_workspace(name) }
           .sort_by { |workspace| [ workspace.created_at || Time.at(0), workspace.id ] }
      end

      # Remove expired and over-quota workspaces, oldest first (design 4).
      #
      # Every removal takes the SAME lock generation and publication take, without blocking: a
      # workspace another process is working in is skipped, so the sweep can never remove an
      # active one. `keep` is the workspace the caller is about to use, excluded even when the
      # quota says otherwise — trimming the one being created would be an immediate self-inflicted
      # failure.
      def sweep(clock:, keep: nil)
        held = all
        candidates = held.reject { |workspace| workspace.id == keep.to_s }
        expired = candidates.select { |workspace| workspace.expired?(clock.now.utc) }
        # The quota is counted over EVERYTHING this runner holds, `keep` included: twenty
        # retained workspaces means twenty on disk, not twenty plus whatever is in flight.
        surplus = [ held.length - expired.length - MAX_RETAINED, 0 ].max
        (expired + (candidates - expired).first(surplus)).count { |workspace| remove(workspace) }
      end

      # Remove ONE workspace under its own lock. Returns false when the lock is held elsewhere or
      # the directory is not contained in this root, so a caller can report what it did without
      # having to know why it could not.
      def remove(workspace)
        return false unless contained?(workspace.root)

        with_lock(workspace.id, blocking: false) do
          workspace.remove!(commands_for: commands_factory)
        end || false
      end

      # The local serialization point for one package (design "failure and concurrency
      # boundaries"). Returns the block's value, or nil when `blocking: false` and the lock is
      # held elsewhere — which is a normal outcome for the sweep and a refusal for publication.
      def with_lock(workspace_id, blocking: true)
        FileUtils.mkdir_p(root)
        File.open(lock_path(workspace_id), File::RDWR | File::CREAT, 0o600) do |file|
          mode = blocking ? File::LOCK_EX : (File::LOCK_EX | File::LOCK_NB)
          next nil unless file.flock(mode)

          begin
            yield
          ensure
            file.flock(File::LOCK_UN)
          end
        end
      end

      private

      attr_reader :env

      # Beside the workspace directory rather than inside it, so the lock outlives the removal it
      # guards and two processes racing to delete the same workspace still serialize.
      def lock_path(workspace_id) = File.join(root, "#{workspace_id}.lock")

      def directory_workspace(name)
        path = File.join(root, name)
        return nil unless PackageWorkspace.id?(name)
        return nil if File.symlink?(path) || !File.directory?(path)

        PackageWorkspace.new(id: name, root: path)
      end

      # Re-checked after expansion, on the value that is actually deleted. The shape check on the
      # id already makes traversal impossible; this is the guard that does not depend on it.
      def contained?(path)
        expanded = File.expand_path(path.to_s)
        expanded.start_with?("#{root}/") && File.dirname(expanded) == root
      end

      def commands_factory
        ->(checkout_root) { GitCommands.new(checkout_root: checkout_root, env: env) }
      end
    end
  end
end
