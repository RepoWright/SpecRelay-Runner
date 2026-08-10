# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

module SpecrelayRunner
  module Specification
    # ONE Runner-owned isolated specification-package workspace (MAPIAI-62 design 1).
    #
    # A generated package lives HERE and nowhere else. The operator's specification checkout is
    # a read-only seed: it supplies the git object database, the `origin` remote, and the
    # credential helper, and it is never written to. That is not a convention this class
    # follows carefully — it is the shape of the thing. Nothing in the generation path is ever
    # handed the seed's path as a destination.
    #
    #   <state root>/<opaque id>/
    #     workspace.json   bounded metadata: whose it is, what it holds, when it expires
    #     worktree/        a DETACHED, --no-checkout git worktree of the seed at `base_commit`
    #
    # `--no-checkout` is the point of the design rather than an optimisation. The worktree
    # starts genuinely empty, so the only files in it are the ones this run generated; a
    # publication cannot pick up a stray file, and a byte-for-byte comparison of the package
    # directory against the assignment is a complete statement about the worktree's content.
    # {GitPublisher} builds its commit from the fetched remote base in a temporary index, so
    # nothing downstream needs the worktree populated.
    #
    # The id is opaque and random. It is the ONLY thing about this workspace that reaches
    # Platform — never the path, never the seed, never the machine. Two workspaces for the same
    # run are therefore possible and harmless: each generation makes a new one, and Platform's
    # single stored id decides which one is current.
    class PackageWorkspace
      Error = Class.new(StandardError)

      METADATA_FILE = "workspace.json"
      WORKTREE_DIR = "worktree"
      DOCUMENT_VERSION = 1

      # `generating` until a complete package has been written and digested; `ready`
      # afterwards. Publication resumes only a `ready` workspace, so a workspace abandoned
      # mid-generation is retained for inspection and can never be published from.
      GENERATING = "generating"
      READY = "ready"

      ID_PREFIX = "swp_"
      ID_PATTERN = /\A#{ID_PREFIX}[0-9a-f]{32}\z/

      def self.generate_id = "#{ID_PREFIX}#{SecureRandom.hex(16)}"
      def self.id?(value) = ID_PATTERN.match?(value.to_s)

      attr_reader :id, :root

      def initialize(id:, root:)
        @id = id.to_s
        @root = root.to_s
      end

      def worktree_root = File.join(root, WORKTREE_DIR)
      def metadata_path = File.join(root, METADATA_FILE)
      def exists? = File.directory?(root)

      # The stored metadata, or nil when it is absent or unreadable. Nil is a REFUSAL input,
      # never a default: a workspace whose metadata cannot be read proves nothing about what it
      # holds, and publication treats it exactly like a missing one.
      def metadata
        return @metadata if defined?(@metadata)

        document = JSON.parse(File.read(metadata_path))
        @metadata = document.is_a?(Hash) && document["version"] == DOCUMENT_VERSION ? document : nil
      rescue JSON::ParserError, SystemCallError, IOError
        @metadata = nil
      end

      def ready? = metadata.to_h["state"] == READY
      def expires_at = parse_time(metadata.to_h["expires_at"])
      def created_at = parse_time(metadata.to_h["created_at"])
      def expired?(now) = expires_at.nil? || expires_at <= now

      # The package's file set as it was digested at generation, in the wire shape
      # {PackageVerification} accepts.
      def files = Array(metadata.to_h["files"]).map { |file| file.to_h }

      # Create the directory and the detached worktree, and write the `generating` metadata.
      #
      # The worktree is created FIRST and the metadata second, because the metadata is what
      # makes a directory a workspace: a crash between the two leaves an unreferenced directory
      # the sweep removes, never a workspace that claims to hold a package it does not have.
      def create!(commands:, base_commit:, identity:, clock:, retention_days:)
        FileUtils.mkdir_p(root)
        add_worktree(commands, base_commit)
        now = clock.now.utc
        write_metadata(identity.merge(
          "version" => DOCUMENT_VERSION, "workspace_id" => id, "state" => GENERATING,
          "base_commit" => base_commit, "created_at" => now.iso8601,
          "expires_at" => (now + (retention_days * 86_400)).utc.iso8601, "files" => []
        ))
        self
      end

      # Promote a complete package to `ready`, recording the digests publication verifies
      # against. Written atomically, because a torn metadata file is indistinguishable from a
      # tampered one and would refuse a good package.
      def finalize!(files:)
        write_metadata(metadata.to_h.merge("state" => READY, "files" => files.map(&:to_h)))
        self
      end

      # Remove the worktree registration and then the directory tree.
      #
      # `git worktree remove` is attempted first so the seed's administrative record goes with
      # it; when the seed has moved or the registration is already gone, the prune below is what
      # keeps the seed tidy. Neither can fail the caller: cleanup is bookkeeping on work that
      # has already succeeded or already failed.
      def remove!(commands_for:)
        common_dir = worktree_common_dir(commands_for)
        commands_for.call(worktree_root).git([ "worktree", "remove", "--force", worktree_root ])
        FileUtils.remove_entry(root) if File.directory?(root) && !File.symlink?(root)
        prune(commands_for, common_dir)
        true
      rescue SystemCallError, IOError
        false
      end

      private

      # `--detach` so the workspace holds no branch the operator could collide with, and
      # `--no-checkout` so it starts empty. `--force` is deliberately absent: a path that
      # already exists is a bug in id generation, and overwriting it would be the one way this
      # class could destroy something.
      def add_worktree(commands, base_commit)
        result = commands.git([ "worktree", "add", "--detach", "--no-checkout", worktree_root, base_commit ])
        return if result.success?

        raise Error, "could not create the isolated specification worktree: " \
                     "#{commands.failure_reason(result, 'git worktree add')}"
      end

      def worktree_common_dir(commands_for)
        return nil unless File.directory?(worktree_root)

        value = commands_for.call(worktree_root).git_value(%w[rev-parse --git-common-dir])
        value.nil? || value.empty? ? nil : File.expand_path(value, worktree_root)
      end

      def prune(commands_for, common_dir)
        return if common_dir.nil? || !File.directory?(common_dir)

        commands_for.call(File.dirname(common_dir)).git(%w[worktree prune])
      end

      def write_metadata(document)
        temporary = "#{metadata_path}.#{Process.pid}.tmp"
        File.write(temporary, "#{JSON.pretty_generate(document)}\n")
        File.chmod(0o600, temporary)
        File.rename(temporary, metadata_path)
        @metadata = document
      rescue SystemCallError, IOError => e
        raise Error, "could not record the isolated specification workspace metadata (#{e.class})"
      end

      def parse_time(value)
        Time.parse(value.to_s).utc
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
