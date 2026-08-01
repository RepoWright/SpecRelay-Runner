# frozen_string_literal: true

require "digest"

module SpecrelayRunner
  module Specification
    # Proves that the files on this machine ARE the package Platform recorded, before anything
    # touches git (MVP-0027 criterion 2).
    #
    # This class is the load-bearing safety property of the publication step, and it holds it
    # the same way {Preflight} holds generation's: by running FIRST and performing no mutation
    # of any kind. It stats paths, reads bytes, and digests them. There is no code path from a
    # verification failure to a git command, so "refuses before Git mutation on mismatch" is a
    # property of the control flow rather than of a rollback that might itself fail.
    #
    # Why it verifies at all. The package was written by an earlier run, minutes or days ago,
    # into a checkout the operator owns and can edit. Publishing whatever is on the disk now
    # would mean Platform's recorded generation evidence — the digests it shows on the run page
    # and validates the publication against — described a different document set from the one a
    # developer is asked to review. Digest equality is what makes those two the same thing.
    #
    # Every path is treated as hostile even though Platform validated its shape on ingest: this
    # class composes a filesystem path from it, and "the control plane probably checked" is not
    # a boundary when the failure mode is reading or committing a file outside the checkout.
    class PackageVerification
      # An allowlist, not a denylist — the same rule and the same vocabulary Platform's ingest
      # validator applies. A generated package path is a few slash-separated segments of word
      # characters, dots and hyphens; enumerating what is permitted means being right once.
      SAFE_PATH = %r{\A[\w.\-]+(/[\w.\-]+)*\z}
      TRAVERSING_SEGMENT = %r{(\A|/)\.\.?(/|\z)}

      MISSING = "generated_package_missing"
      MISMATCH = "generated_package_digest_mismatch"

      # `files` is the verified set, each entry carrying the package-relative `path`, the
      # repository-relative `repository_path` the commit uses, and the absolute local path the
      # bytes came from. The absolute path never leaves this process.
      VerifiedFile = Struct.new(:path, :repository_path, :absolute_path, :sha256, keyword_init: true)

      Result = Struct.new(:files, :failure_class, :message, keyword_init: true) do
        def ok? = failure_class.nil?
      end

      def self.call(**kwargs) = new(**kwargs).call

      def initialize(checkout_root:, package_path:, files:)
        @checkout_root = File.expand_path(checkout_root.to_s)
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
        Result.new(files: verified)
      end

      private

      attr_reader :checkout_root, :package_path

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
        return failure(MISSING, "the generated package escapes the specification repository checkout") if
          absolute.nil?
        return failure(MISSING, missing_message(relative)) unless File.file?(absolute)

        digest = Digest::SHA256.hexdigest(File.binread(absolute))
        return failure(MISMATCH, mismatch_message(relative, entry["sha256"].to_s, digest)) unless
          digest == entry["sha256"].to_s

        VerifiedFile.new(path: entry["path"].to_s, repository_path: relative,
                         absolute_path: absolute, sha256: digest)
      rescue SystemCallError => e
        failure(MISSING, "the generated file #{relative} could not be read: #{e.class}")
      end

      # Re-checked against the checkout root after expansion, not only before it: this is the
      # value that is actually opened, and a symlinked or otherwise surprising path is caught
      # here rather than trusted from the shape check above.
      def contained(relative)
        resolved = File.expand_path(File.join(checkout_root, relative))
        resolved.start_with?("#{checkout_root}/") ? resolved : nil
      end

      # Names the repository-relative path and the remedy, never the absolute local path: this
      # message is reported to Platform, stored, and rendered on the run page, and the
      # operator's home directory has no business in any of those.
      def missing_message(relative)
        "the generated file #{relative} is not in the specification repository checkout on this " \
          "runner. Regenerate the package (`bin/platform runner requeue-specification <run>`) or " \
          "restore the checkout, then publish again"
      end

      def mismatch_message(relative, expected, actual)
        "#{relative} does not match the generated package SpecRelay recorded " \
          "(expected sha256 #{expected[0, 16]}…, found #{actual[0, 16]}…). The file was changed after " \
          "generation, so publishing it would put a document on GitHub that Platform's evidence does " \
          "not describe. Regenerate the package, then publish again"
      end

      def failure(failure_class, message)
        Result.new(files: [], failure_class: failure_class, message: Redaction.redact(message))
      end
    end
  end
end
