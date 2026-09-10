# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module SpecrelayRunner
  module Specification
    # Writes the generated package ATOMICALLY, at package level, into the ticket's canonical task
    # workspace, and snapshots the same bytes for publication.
    #
    # "Atomic at package level" is a stronger property than writing each file safely, and it is
    # the one the spec asks for: at no point may the final path hold three documents where one
    # of them is from a previous generation, or two documents where a third failed to write. So
    # the sequence is:
    #
    #   stage -> redact -> verify -> digest -> manifest -> ONE rename into place
    #
    # Everything before the rename happens in a staging directory, and the rename is the only
    # operation that touches the final path. A failure at any earlier step removes the staging
    # directory and leaves the destination exactly as it was.
    #
    # The staging directory is a SIBLING of the destination rather than a `Dir.mktmpdir` temp.
    # `File.rename` is only atomic within one filesystem, and /tmp is frequently a different one
    # from the runner's state root; staging next door guarantees the rename is a metadata
    # operation that either happens or does not.
    #
    # Workspace-grounded generation changed WHERE that rename lands, and gave the class a second
    # destination.
    #
    # The package is materialized into the ticket's canonical TASK WORKSPACE, because that is the
    # prepared source state the provider worked in and the one place a reviewer can read the
    # package beside the code it describes. The same verified bytes are then SNAPSHOTTED into the
    # Runner-owned isolated worktree, which publication still reads: that workspace is a
    # publication snapshot only, never a working directory.
    #
    # The task-workspace destination may already hold a package — the ticket's committed one, or
    # the previous pull request's package a revision read in — so the single rename REPLACES the
    # directory whole. Replacing rather than merging is what makes "a document the new package
    # does not carry is gone" a property of the write instead of a cleanup step.
    #
    # The rename is the boundary between "nothing happened" and "it happened", and it is no longer
    # the boundary of SUCCESS. Before it, a failure means the destination is untouched. After it,
    # the ticket package is in place, but the snapshot still has to be taken and verified: a copy
    # that fails, or bytes that do not reproduce the digests just validated, raise from
    # {#snapshot!} and fail the generation. That is deliberate — publication reads the snapshot, so
    # a package Platform could not be given is not a generated package.
    #
    # Every failure this class raises therefore carries which side of the rename it fell on, in
    # `wrote_package`, because the caller cannot know and an operator's next move depends on it: a
    # post-rename failure leaves a complete package in the task workspace to inspect.
    class PackageWriter
      # The failure carries WHETHER THE RENAME HAPPENED, because that is the one fact an operator
      # needs before deciding whether the retained workspace holds a package worth inspecting —
      # and it is a fact only this class knows.
      class Error < StandardError
        attr_reader :package_path

        def initialize(message, package_path: nil, wrote_package: false)
          super(message)
          @package_path = package_path
          @wrote_package = wrote_package
        end

        def wrote_package? = @wrote_package ? true : false
      end

      MANIFEST_CONTRACT_VERSION = "mvp-0026"
      STAGING_PREFIX = ".specrelay-generating-"
      # Where a package being replaced is held between the two renames, so a failed second rename
      # can put the previous one back rather than leaving the ticket with no package at all.
      REPLACED_PREFIX = ".specrelay-replaced-"

      # One written file, as the manifest and Platform record it. `path` is package-relative;
      # the repository-relative form is composed by the caller from the package path, so no
      # absolute path is ever constructed here.
      WrittenFile = Struct.new(:path, :sha256, :bytes, keyword_init: true) do
        def to_h = { "path" => path, "sha256" => sha256, "bytes" => bytes }
      end

      Result = Struct.new(:relative_package_path, :files, :manifest, :warnings, keyword_init: true) do
        def file_paths = files.map(&:path)
      end

      def self.call(**kwargs) = new(**kwargs).call

      # `destination_root` is the ticket's canonical task workspace and `snapshot_root` the
      # Runner-owned isolated worktree publication reads. Both are passed rather than held by
      # {PackagePath} so this class cannot be handed a root by accident: the only caller that can
      # supply them is the one that prepared them.
      def initialize(package_path:, destination_root:, snapshot_root:, workspace_root:, documents:,
                     assignment:, provider:, source:, inputs:, clock: Time)
        @package_path = package_path
        @destination_root = destination_root.to_s
        @snapshot_root = snapshot_root.to_s
        @workspace_root = workspace_root.to_s
        @documents = documents
        @assignment = assignment
        @provider = provider
        @source = source
        @inputs = inputs
        @clock = clock
        @warnings = []
        @moved = false
      end

      def call
        destination = package_path.absolute_in(destination_root)
        FileUtils.mkdir_p(::File.dirname(destination))
        staging = ::File.join(::File.dirname(destination), "#{STAGING_PREFIX}#{SecureRandom.hex(8)}")
        begin
          files = stage(staging)
          manifest = write_manifest(staging, files)
          move_into_place(staging, destination)
          written = files + [ manifest_digest(destination) ]
          snapshot!(destination, written)
          Result.new(relative_package_path: package_path.relative_package_path,
                     files: written, manifest: manifest, warnings: warnings)
        rescue Error
          raise
        rescue StandardError => e
          # Anything unexpected — most plausibly an I/O error while digesting the manifest at
          # its final location — becomes an Error that still reports whether the package landed.
          # Letting a bare Errno escape would crash past Generation's rescue list and leave the
          # claim held with no recorded reason.
          raise write_error("the generated package could not be completed: #{e.class}")
        ensure
          FileUtils.remove_entry(staging) if ::File.directory?(staging)
        end
      end

      private

      attr_reader :package_path, :destination_root, :snapshot_root, :workspace_root, :documents,
                  :assignment, :provider, :source, :inputs, :clock, :warnings

      # Write every document into staging, redacted, and verify the written bytes. The redaction
      # happens BEFORE the write and the verification reads what is actually on disk — checking
      # the in-memory string would prove a property of a value that is no longer the one that
      # matters.
      def stage(staging)
        FileUtils.mkdir_p(staging)
        documents.each_file.map do |name|
          content = redact(name, documents.files.fetch(name))
          target = ::File.join(staging, name)
          FileUtils.mkdir_p(::File.dirname(target))
          ::File.write(target, content)
          verify!(name, target)
          digest_of(name, target)
        end
      end

      # Two different guards, and they fail differently on purpose.
      #
      # Secret shapes are REDACTED, because a bundle can legitimately quote a line that looks
      # like a token and the correct outcome is a safe document plus a warning — not a run that
      # refuses to produce anything.
      #
      # Host paths are a HARD failure, because there is no legitimate reason for an absolute
      # local path to appear in a generated document; every path in a package is
      # repository-relative by construction, so one appearing means a provider composed it from
      # something it should not have had.
      def redact(name, content)
        redacted = Redaction.redact(content.to_s)
        warnings << "#{name}: a secret-shaped value in the generated text was redacted before writing." if
          redacted != content.to_s
        redacted
      end

      def verify!(name, target)
        written = ::File.read(target)
        raise Error, "#{name} still contains a secret-shaped value after redaction" if
          Redaction.redact(written) != written

        host_path = host_paths.find { |path| written.include?(path) }
        raise Error, "#{name} contains a private host filesystem path" if host_path
      end

      # The absolute roots that must never appear in generated output: the Runner-owned
      # workspace this package is being written into, the source checkout it was written about,
      # and the operator's home directory, which is the one a provider is most likely to echo.
      #
      # `workspace_root` is listed SEPARATELY from the task workspace even though the second is
      # built inside the first. The provider now works in the task workspace, so `source.root` is
      # that path and no longer the operator's main checkout — and a document echoing the main
      # checkout would have passed this guard while naming exactly the layout it exists to hide.
      def host_paths
        @host_paths ||= [ destination_root, snapshot_root, workspace_root, source.root, Dir.home ]
                        .compact.map(&:to_s).reject(&:empty?).uniq
      rescue StandardError
        [ source.root.to_s ]
      end

      def digest_of(name, target)
        bytes = ::File.binread(target)
        WrittenFile.new(path: name, sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize)
      end

      # The manifest's digest, taken from the FINAL location after the move — so it describes
      # the bytes an operator will actually find on disk. Criterion 7 asks for a digest per
      # generated file and the manifest is one; it is simply the only file whose digest cannot
      # be computed during staging, because a file cannot contain its own hash and it is
      # therefore deliberately absent from the manifest's own `files` list.
      def manifest_digest(destination)
        digest_of(PackagePath::MANIFEST_JSON, ::File.join(destination, PackagePath::MANIFEST_JSON))
      end

      # The machine-readable record of this generation, written INTO the package so the package
      # is self-describing on disk, and returned so Platform can persist the same facts. One
      # source, two destinations — a manifest that disagreed with the run page would make both
      # unusable as evidence.
      #
      # It carries no `publication` block and no local path. Publication state belongs to
      # Platform's run record and the runner's own console log, which are read AT the time they
      # describe; this manifest is read for as long as the package exists, including after the
      # package has been committed to a shared repository.
      def write_manifest(staging, files)
        manifest = manifest_document(files)
        ::File.write(::File.join(staging, PackagePath::MANIFEST_JSON), "#{JSON.pretty_generate(manifest)}\n")
        manifest
      end

      def manifest_document(files)
        {
          "contract_version" => MANIFEST_CONTRACT_VERSION,
          "generated_at" => clock.now.utc.iso8601,
          "issue_key" => assignment.issue_key,
          "issue_url" => Redaction.redact(assignment.issue_url),
          "run_id" => assignment.run_id,
          "runner_execution_id" => assignment.runner_execution_id,
          "package_path" => package_path.relative_package_path,
          "repository_url" => Redaction.redact(assignment.repository_url),
          "default_branch" => assignment.default_branch,
          "files" => files.map(&:to_h),
          "provider" => { "kind" => provider.kind, "description" => provider.describe },
          "source_evidence" => source_evidence_block,
          "input_bundle" => input_bundle_block,
          # Source-inspection warnings belong in the package on disk too. A reader who opens
          # only the manifest must be able to see that nothing was read from the checkout.
          "warnings" => (warnings + Array(source.warnings)).uniq
        }
      end

      def source_evidence_block
        {
          "repository" => source.repository_name,
          "entry_points_inspected" => source.entry_point_paths.length,
          "tools" => [ source.graphify, source.context_plus ].map do |tool|
            { "name" => tool.name, "usable" => tool.usable?, "contributed" => tool.contributed?,
              "summary" => Redaction.redact(tool.summary.to_s) }
          end
        }
      end

      # No `url`. Platform's artifact address is machine-local — `http://127.0.0.1:3200/…` for
      # every local operator — and this manifest is committed to a shared specification
      # repository, where it would point at a different machine for every reader. The trace id
      # identifies the bundle unambiguously to whoever holds the Platform instance.
      def input_bundle_block
        {
          "trace_id" => assignment.bundle_trace_id,
          "recorded" => inputs.inputs.length,
          "used" => inputs.readable_inputs.length,
          "warnings" => inputs.warnings.map { |warning| Redaction.redact(warning) }
        }
      end

      # The single operation that touches the ticket package directory, and the only one in this
      # class that is not reversible by doing nothing.
      #
      # A package already there is moved aside first and removed only after the new one is in
      # place, so the failure window holds either the old package or the new one and never
      # neither. Nothing outside the package directory is touched: both temporaries are siblings
      # of it and both are gone before the run reports anything.
      def move_into_place(staging, destination)
        previous = ::File.exist?(destination) ? move_aside(destination) : nil
        begin
          ::File.rename(staging, destination)
        rescue SystemCallError => e
          restore(previous, destination)
          raise write_error("could not move the generated package into place: #{e.class}")
        end
        @moved = true
        FileUtils.remove_entry(previous) if previous && ::File.exist?(previous)
      end

      def move_aside(destination)
        aside = "#{destination}#{REPLACED_PREFIX}#{SecureRandom.hex(8)}"
        ::File.rename(destination, aside)
        aside
      rescue SystemCallError => e
        raise write_error("could not replace the existing package at " \
                          "#{package_path.relative_package_path}: #{e.class}")
      end

      def restore(previous, destination)
        ::File.rename(previous, destination) if previous && !::File.exist?(destination)
      rescue SystemCallError
        # The original is still on disk under its held-aside name and the failure below names the
        # package, which is all an operator needs to find it. Raising here would replace a precise
        # cause with a rename error.
        nil
      end

      # The PUBLICATION snapshot: the same bytes, in the retained no-checkout workspace publication
      # resolves by opaque id. It is copied from the package that was just validated and then
      # RE-DIGESTED from its new location, because "the copy succeeded" is a claim about an
      # operation while the digests Platform records are a claim about the files.
      def snapshot!(destination, written)
        target = package_path.absolute_in(snapshot_root)
        raise write_error("the isolated workspace already holds a package at " \
                          "#{package_path.relative_package_path}") if ::File.exist?(target)

        FileUtils.mkdir_p(::File.dirname(target))
        FileUtils.cp_r(destination, target)
        drifted = written.reject { |file| digest_of(file.path, ::File.join(target, file.path)).sha256 == file.sha256 }
        raise write_error("the publication snapshot does not match the validated package: " \
                          "#{drifted.map(&:path).sort.join(', ')}") if drifted.any?
      rescue SystemCallError, IOError => e
        raise write_error("the generated package could not be snapshotted for publication: #{e.class}")
      end

      def write_error(message)
        Error.new(message, package_path: package_path.relative_package_path, wrote_package: @moved)
      end
    end
  end
end
