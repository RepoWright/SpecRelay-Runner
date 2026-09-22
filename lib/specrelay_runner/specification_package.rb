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

    # `anchor` is WHERE the verified package lives in the prepared environment: an ordinary hash of
    # the contained repository, its checkout path, the pinned commit and the package's own
    # directory inside it. It is passed to the owner that chooses each repository's head so that
    # one authority can honour the specification and the accepted code together, rather than each
    # side guessing what the other verified.
    Result = Struct.new(:root, :paths, :anchor, :failure, keyword_init: true) do
      def ok? = failure.nil?
    end

    def self.call(**kwargs) = new(**kwargs).call

    # `task_root` is the prepared environment this package must also be VISIBLE in, and it is
    # required: the delivered copy may not be the only correct copy, so there is no mode in which
    # this writes a package it could not attribute to a commit.
    def initialize(payload:, staging_dir:, task_root:, git: Review::Checkout::Git)
      @package = payload.to_h.fetch("specification_package", {}).to_h
      @staging_dir = staging_dir.to_s
      @task_root = task_root.to_s
      @git = git
    end

    def call
      entries = Array(@package["documents"]).map(&:to_h)
      return failure("the assignment carries no specification documents") if entries.empty?

      verified = verify(entries)
      return verified if verified.is_a?(Result)

      anchored = anchor(verified)
      anchored.is_a?(Result) ? anchored : write(verified, anchored)
    end

    private

    # The pinned package, proved to BE the visible history rather than only the delivered bytes.
    #
    # A delivery copy nobody can attribute is the failure this closes: the provider could read six
    # correct documents in staging while the checkout beside it held an older round's specification,
    # and nothing in the run would disagree. So the package is resolved to one contained repository,
    # at one pinned commit, and every document is read back OUT of that commit and compared to the
    # bytes Platform pinned.
    #
    # Refusals are deliberately specific, because each one is a different operator problem: a
    # repository that is not checked out here, two checkouts claiming the same identity, a commit
    # this machine cannot obtain, and a package whose visible bytes disagree with the pin.
    def anchor(documents)
      identity = @package["repository_slug"].to_s
      head = @package["head_sha"].to_s
      package_path = @package["package_path"].to_s
      return failure("the assignment pins no specification repository") if identity.empty?
      return failure("the assignment pins no specification commit") if head.empty?
      return failure("#{package_path.inspect} is not a safe package location") unless
        package_path.empty? || safe?(package_path)

      path = locate(identity)
      return path if path.is_a?(Result)

      return failure("#{identity} does not contain the pinned specification commit " \
                     "#{head[0, 12]} after a fetch") unless obtainable?(path, head)

      mismatch = visible_mismatch(path, head, package_path, documents)
      return failure(mismatch) if mismatch

      { repository: identity, path: path, head: head, package_path: package_path }
    end

    # The one contained checkout of the pinned repository. Ambiguity is refused rather than
    # resolved: two checkouts claiming one identity is a workspace to fix, not to choose between.
    def locate(identity)
      contained = ContainedRepositories.discover(@task_root, git: @git)
      return failure("the prepared task workspace could not be inspected: #{contained.error}") unless
        contained.ok?

      found = contained.resolve(identity)
      return failure("no repository in the prepared task workspace is #{identity.inspect}; " \
                     "the approved specification cannot be made visible where it belongs") if
        found == :missing
      return failure("the prepared task workspace holds two checkouts of #{identity.inspect}") if
        found == :duplicate

      found
    end

    # Present already, or obtainable by the ordinary read-only fetch. A specification repository
    # that was just checked out legitimately does not hold the pinned commit yet.
    def obtainable?(path, head)
      return true if @git.commit?(path, head)

      @git.fetch(path)
      @git.commit?(path, head)
    end

    # Every pinned document, read back out of the pinned commit. Mode is checked before content:
    # a symlink or a submodule entry would otherwise be followed to somewhere the package does not
    # control, and "the bytes matched" would be a statement about the wrong file.
    def visible_mismatch(path, head, package_path, documents)
      documents.each do |relative, content|
        full = package_path.empty? ? relative : "#{package_path}/#{relative}"
        entry = @git.run(path, [ "ls-tree", head, "--", full ])
        return "the pinned specification commit could not be read" if entry.nil?

        mode, type, = entry.stdout.to_s.split(/\s+/)
        return "#{full} is missing from the pinned specification commit" if mode.to_s.empty?
        return "#{full} is not a regular file in the pinned specification commit" unless
          type == "blob" && %w[100644 100755].include?(mode)

        shown = @git.run(path, [ "show", "#{head}:#{full}" ])
        return "#{full} could not be read from the pinned specification commit" if
          shown.nil? || !shown.exit_code.to_i.zero?
        return "#{full} in the pinned specification commit does not match the delivered package" unless
          shown.stdout.to_s.b == content
      end
      nil
    end

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
    def write(documents, anchor = nil)
      root = File.join(@staging_dir, DIRECTORY)
      FileUtils.mkdir_p(root)
      paths = documents.map do |path, content|
        absolute = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(absolute))
        File.binwrite(absolute, content)
        File.chmod(0o444, absolute)
        path
      end
      Result.new(root: root, paths: paths, anchor: anchor)
    end

    def failure(message) = Result.new(failure: message)
  end
end
