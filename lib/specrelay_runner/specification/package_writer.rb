# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module SpecrelayRunner
  module Specification
    # Writes the generated package ATOMICALLY, at package level, into the Runner-owned isolated
    # worktree (MVP-0026 scope 10; MAPIAI-62 design 1).
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
    # MAPIAI-62 removed the REPLACEMENT half of this class rather than repointing it. It existed
    # to protect a package an operator might have hand-edited in their own checkout, and to make
    # a re-run overwrite its own previous output there. Neither is a thing any more: every
    # generation gets a fresh isolated workspace with a fresh opaque id, so the destination is
    # always absent, and an existing one would be an id collision rather than a policy question.
    # Keeping the branch would have meant keeping `on_existing_package`, a replaced-package flag
    # on the wire, and a rollback path — all of them dead code describing a path this ticket
    # deletes.
    #
    # The rename is still the boundary between "nothing happened" and "it happened". Before it, a
    # failure means the destination is untouched. After it, the generation has SUCCEEDED, and
    # anything that goes wrong afterwards is a warning on a good package, never a teardown. Every
    # failure this class raises carries which side of that boundary it is on, because the caller
    # cannot know and an operator's next move depends on it.
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

      # `destination_root` is the Runner-owned isolated worktree. It is passed rather than held
      # by {PackagePath} so this class cannot be handed an operator checkout by accident: the
      # only caller that can supply it is the one that created the workspace.
      def initialize(package_path:, destination_root:, documents:, assignment:, provider:, source:,
                     inputs:, clock: Time)
        @package_path = package_path
        @destination_root = destination_root.to_s
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
          Result.new(relative_package_path: package_path.relative_package_path,
                     files: files + [ manifest_digest(destination) ], manifest: manifest,
                     warnings: warnings)
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

      attr_reader :package_path, :destination_root, :documents, :assignment, :provider, :source,
                  :inputs, :clock, :warnings

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
      def host_paths
        @host_paths ||= [ destination_root, source.root, Dir.home ]
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

      # The single operation that touches the destination. The workspace is fresh and
      # `--no-checkout`, so the destination cannot already exist; if it does, something has
      # written into a Runner-owned workspace and refusing is the only safe answer.
      def move_into_place(staging, destination)
        raise write_error("the isolated workspace already holds a package at " \
                          "#{package_path.relative_package_path}") if ::File.exist?(destination)

        begin
          ::File.rename(staging, destination)
        rescue SystemCallError => e
          raise write_error("could not move the generated package into place: #{e.class}")
        end
        @moved = true
      end

      def write_error(message)
        Error.new(message, package_path: package_path.relative_package_path, wrote_package: @moved)
      end
    end
  end
end
