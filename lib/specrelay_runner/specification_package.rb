# frozen_string_literal: true

require "digest"
require "fileutils"

module SpecrelayRunner
  # The pinned specification package, re-verified and written read-only where the Executor can
  # read it (MVP-0034 contract 4; CR-001 Runner responsibility 9).
  #
  # The handoff prompt tells the Executor that every package document "is delivered read-only with
  # your assignment". This is what makes that sentence true. Without it the Executor would receive
  # a prompt naming six documents and a worktree containing none of them, and would implement from
  # the one summary it could actually read — which is the exact failure MVP-0034 exists to end.
  #
  # It verifies before it writes, and the order matters: a document whose bytes do not reproduce
  # the digest Platform pinned must reach neither the disk nor the provider (S23). Platform already
  # recomputed every digest from the bytes this same runner submitted, so this is not a second
  # opinion about authority — it is the check that the assignment which came back over the wire is
  # the package that was accepted, and it is cheap enough to be worth making before a provider
  # spends an hour on the answer.
  #
  # Documents are written OUTSIDE the worktree, into the staging directory that already holds the
  # executor prompt. Inside it they would become uncommitted changes in the task branch, and the
  # runner's own change measurement would report the specification as part of the implementation.
  class SpecificationPackage
    DIRECTORY = "specification-package"

    # The terminal-result classification for "the package did not verify, so nothing ran". Its own
    # value rather than one of the `executor_*` ones, because every one of those blames a provider
    # that was never launched.
    REFUSED = "specification_package_refused"

    # The same bounds the preflight reader enforces when it fetches from GitHub, restated here
    # because this is a separate entry point: an assignment is a wire payload, and a payload must
    # not be able to decide how much disk a runner spends.
    MAX_FILE_BYTES = 1_000_000
    MAX_PACKAGE_BYTES = 4_000_000

    # An allowlist, matching {Specification::PackageVerification}: a package path is a few
    # slash-separated segments of word characters, dots and hyphens. Every path here is joined to
    # a local directory, so "Platform validated it already" is not a boundary.
    SAFE_PATH = %r{\A[\w.\-]+(/[\w.\-]+)*\z}
    TRAVERSING_SEGMENT = %r{(\A|/)\.\.?(/|\z)}

    Result = Struct.new(:root, :paths, :failure, keyword_init: true) do
      def ok? = failure.nil?
    end

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(payload:, staging_dir:)
      @package = payload.to_h.fetch("specification_package", {}).to_h
      @staging_dir = staging_dir.to_s
    end

    def call
      entries = Array(@package["documents"]).map(&:to_h)
      return failure("the assignment carries no specification documents") if entries.empty?

      verified = verify(entries)
      verified.is_a?(Result) ? verified : write(verified)
    end

    private

    # Path, bounds, digest and byte size, in that order — cheapest and most structural first, so
    # a hostile path is rejected before its content is hashed.
    def verify(entries)
      total = 0
      seen = []
      documents = entries.map do |entry|
        path = entry["path"].to_s
        content = entry["content"].to_s.b
        return failure("#{path.inspect} is not a safe package-relative path") unless safe?(path)
        return failure("#{path} appears twice in the assignment") if seen.include?(path)
        return failure("#{path} is larger than this runner will deliver") if content.bytesize > MAX_FILE_BYTES

        total += content.bytesize
        return failure("the specification package is larger than this runner will deliver") if
          total > MAX_PACKAGE_BYTES

        mismatch = mismatch_reason(entry, path, content)
        return failure(mismatch) if mismatch

        seen << path
        [ path, content ]
      end
      documents
    end

    def mismatch_reason(entry, path, content)
      expected_size = entry["byte_size"]
      return "#{path} does not match the byte size Platform pinned" if
        expected_size && expected_size.to_i != content.bytesize
      return "#{path} does not match the digest Platform pinned" unless
        Digest::SHA256.hexdigest(content) == entry["digest"].to_s

      nil
    end

    def safe?(path)
      !path.empty? && SAFE_PATH.match?(path) && !TRAVERSING_SEGMENT.match?(path)
    end

    # Read-only on disk, because the prompt says so and because an Executor that edited its own
    # authority would break the pin the whole protocol is built on. The mode is a guard rail
    # against accident, not a security boundary — the process that wrote them can still chmod.
    def write(documents)
      root = File.join(@staging_dir, DIRECTORY)
      FileUtils.mkdir_p(root)
      paths = documents.map do |path, content|
        absolute = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(absolute))
        File.binwrite(absolute, content)
        File.chmod(0o444, absolute)
        path
      end
      Result.new(root: root, paths: paths)
    end

    def failure(message) = Result.new(failure: message)
  end
end
