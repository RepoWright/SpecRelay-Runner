# frozen_string_literal: true

require "digest"

module SpecrelayRunner
  module Specification
    # Proves that the files in the resumed isolated worktree ARE the package Platform recorded,
    # before anything touches git (MVP-0027 criterion 2; MAPIAI-62 design 3).
    #
    # This class is the load-bearing safety property of the publication step, and it holds it
    # the same way {Preflight} holds generation's: by running FIRST and performing no mutation
    # of any kind. It stats paths, reads bytes, and digests them. There is no code path from a
    # verification failure to a git command, so "refuses before Git mutation on mismatch" is a
    # property of the control flow rather than of a rollback that might itself fail.
    #
    # It answers three questions, and all three are required:
    #
    #   1. is every recorded file present, and are its bytes the recorded bytes? (digest)
    #   2. is the package EXACTLY those files, with nothing else in it? (file set)
    #   3. is every path a real file this runner wrote, reached without following a link?
    #
    # Question 2 is MAPIAI-62's addition and it is not pedantry. The worktree is created
    # `--no-checkout`, so the package directory starts empty and everything in it was put there
    # by one generation. A file that is present but unrecorded is therefore something that
    # arrived afterwards, and committing it would put a document on GitHub that Platform's
    # evidence does not describe — the same failure a changed digest represents, arriving from
    # the other direction.
    #
    # Every path is treated as hostile even though Platform validated its shape on ingest: this
    # class composes a filesystem path from it, and "the control plane probably checked" is not
    # a boundary when the failure mode is reading or committing a file outside the workspace.
    class PackageVerification
      # An allowlist, not a denylist — the same rule and the same vocabulary Platform's ingest
      # validator applies. A generated package path is a few slash-separated segments of word
      # characters, dots and hyphens; enumerating what is permitted means being right once.
      SAFE_PATH = %r{\A[\w.\-]+(/[\w.\-]+)*\z}
      TRAVERSING_SEGMENT = %r{(\A|/)\.\.?(/|\z)}

      MISSING = "generated_package_missing"
      MISMATCH = "generated_package_digest_mismatch"
      # Present but not what was recorded: an extra file, or a path reached through a symlink.
      ALTERED = "generated_package_altered"

      # `files` is the verified set, each entry carrying the package-relative `path`, the
      # repository-relative `repository_path` the commit uses, and the absolute local path the
      # bytes came from. The absolute path never leaves this process.
      VerifiedFile = Struct.new(:path, :repository_path, :absolute_path, :sha256, keyword_init: true)

      Result = Struct.new(:files, :failure_class, :message, keyword_init: true) do
        def ok? = failure_class.nil?
      end

      def self.call(**kwargs) = new(**kwargs).call

      def initialize(worktree_root:, package_path:, files:)
        @worktree_root = File.expand_path(worktree_root.to_s)
        @package_path = package_path.to_s
        @files = Array(files)
      end

      def call
        unsafe = unsafe_paths
        return failure(MISSING, "the recorded package path is not a safe repository-relative path: " \
                                "#{unsafe.join(', ')}") if unsafe.any?

        verified = []
        @files.each do |file|
          outcome = verify(file)
          return outcome if outcome.is_a?(Result)

          verified << outcome
        end
        check_file_set || Result.new(files: verified)
      end

      private

      attr_reader :worktree_root, :package_path

      # The package path and every file path, checked as a set before any of them is opened.
      # Reported together so an operator sees the whole problem rather than fixing one path and
      # meeting the next.
      def unsafe_paths
        candidates = [ package_path ] + @files.map { |file| file.to_h["path"].to_s }
        candidates.reject { |path| safe?(path) }
      end

      def safe?(path) = SAFE_PATH.match?(path) && !TRAVERSING_SEGMENT.match?(path)

      def verify(file)
        entry = file.to_h
        relative = "#{package_path}/#{entry['path']}"
        absolute = contained(relative)
        return failure(MISSING, "the generated package escapes its isolated worktree") if absolute.nil?
        return failure(ALTERED, symlink_message(relative)) if linked?(relative)
        return failure(MISSING, missing_message(relative)) unless File.file?(absolute)

        digest = Digest::SHA256.hexdigest(File.binread(absolute))
        return failure(MISMATCH, mismatch_message(relative, entry["sha256"].to_s, digest)) unless
          digest == entry["sha256"].to_s

        VerifiedFile.new(path: entry["path"].to_s, repository_path: relative,
                         absolute_path: absolute, sha256: digest)
      rescue SystemCallError => e
        failure(MISSING, "the generated file #{relative} could not be read: #{e.class}")
      end

      # EXACTLY the recorded files, and nothing else. Enumerated with `File::FNM_DOTMATCH` so a
      # dotfile added beside the package is caught rather than skipped by a glob that quietly
      # ignores it.
      def check_file_set
        root = contained(package_path)
        return failure(MISSING, "the recorded package folder is not in this workspace") if root.nil?

        recorded = @files.map { |file| file.to_h["path"].to_s }
        extra = Dir.glob("**/*", File::FNM_DOTMATCH, base: root)
                   .reject { |name| name.end_with?(".", "..") || File.directory?(File.join(root, name)) }
                   .reject { |name| recorded.include?(name) }
        return nil if extra.empty?

        failure(ALTERED, extra_message(extra))
      end

      # Re-checked against the worktree root after expansion, not only before it: this is the
      # value that is actually opened, and a surprising path is caught here rather than trusted
      # from the shape check above.
      def contained(relative)
        resolved = File.expand_path(File.join(worktree_root, relative))
        resolved.start_with?("#{worktree_root}/") ? resolved : nil
      end

      # Every segment from the worktree root down, `lstat`-ed. `File.expand_path` does not
      # resolve symlinks, so containment alone would accept `<package>/spec.md` when `spec.md`
      # — or any directory above it — is a link to somewhere else entirely.
      def linked?(relative)
        path = worktree_root
        relative.split("/").any? do |segment|
          path = File.join(path, segment)
          File.symlink?(path)
        end
      end

      # Names the repository-relative path and the remedy, never the absolute local path: this
      # message is reported to Platform, stored, and rendered on the run page, and the
      # operator's home directory has no business in any of those.
      def missing_message(relative)
        "the generated file #{relative} is not in this runner's retained package workspace. " \
          "Generate the package again from the run page, then publish"
      end

      def mismatch_message(relative, expected, actual)
        "#{relative} does not match the generated package SpecRelay recorded " \
          "(expected sha256 #{expected[0, 16]}…, found #{actual[0, 16]}…). The file was changed after " \
          "generation, so publishing it would put a document on GitHub that Platform's evidence does " \
          "not describe. Generate the package again, then publish"
      end

      def extra_message(extra)
        "the retained package holds #{extra.length} file(s) SpecRelay did not record " \
          "(#{extra.sort.first(5).join(', ')}). Publishing would commit content Platform's evidence " \
          "does not describe. Generate the package again, then publish"
      end

      def symlink_message(relative)
        "#{relative} is reached through a symbolic link inside the package workspace, so its bytes " \
          "are not provably the ones this runner generated. Generate the package again, then publish"
      end

      def failure(failure_class, message)
        Result.new(files: [], failure_class: failure_class, message: Redaction.redact(message))
      end
    end
  end
end
