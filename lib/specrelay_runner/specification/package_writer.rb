# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module SpecrelayRunner
  module Specification
    # Writes the generated package ATOMICALLY, at package level (MVP-0026 scope 10).
    #
    # "Atomic at package level" is a stronger property than writing each file safely, and it
    # is the one the spec asks for: at no point may the final path hold three documents where
    # one of them is from a previous generation, or two documents where a third failed to
    # write. So the sequence is:
    #
    #   stage -> redact -> verify -> digest -> manifest -> ONE rename into place
    #
    # Everything before the rename happens in a staging directory, and the rename is the only
    # operation that touches the final path. A failure at any earlier step removes the staging
    # directory and leaves the destination exactly as it was — which is also what makes the
    # "provider failure leaves no partial final package" test provable rather than hopeful.
    #
    # The staging directory is a SIBLING of the destination rather than a `Dir.mktmpdir`
    # temp. `File.rename` is only atomic within one filesystem, and /tmp is frequently a
    # different one from the operator's checkout; staging next door guarantees the rename is
    # a metadata operation that either happens or does not.
    #
    # Replacement (the configured default) is also atomic and reversible: the existing package
    # is renamed aside FIRST, the new one is moved in, and only then is the old one deleted.
    # If the second rename fails the old package is put back, so a failed replacement leaves
    # the previous package intact rather than nothing at all.
    #
    # The rename is the boundary between "nothing happened" and "it happened". Before it, a
    # failure means the destination is untouched. After it, the generation has SUCCEEDED, and
    # anything that goes wrong afterwards — deleting the set-aside copy, rewriting one
    # manifest field — is a warning on a good package, never a teardown. Every failure this
    # class raises carries which side of that boundary it is on, because the caller cannot
    # know and an operator's next move depends on it.
    class PackageWriter
      # The failure carries WHETHER THE RENAME HAPPENED, because that is the one fact an
      # operator needs before deciding whether to go and look in the specification repository
      # — and it is a fact only this class knows.
      #
      # It used to be a literal `true` in the caller ("both leave the destination untouched"),
      # which was accurate for every path but one and therefore wrong exactly when it
      # mattered: a post-rename cleanup failure reported "no output files written" over a
      # destination that had already been completely replaced.
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
      REPLACED_PREFIX = ".specrelay-replaced-"

      # One written file, as the manifest and Platform record it. `path` is
      # package-relative; the repository-relative form is composed by the caller from the
      # package path, so no absolute path is ever constructed here.
      WrittenFile = Struct.new(:path, :sha256, :bytes, keyword_init: true) do
        def to_h = { "path" => path, "sha256" => sha256, "bytes" => bytes }
      end

      Result = Struct.new(:relative_package_path, :files, :manifest, :replaced_existing, :warnings,
                          keyword_init: true) do
        def replaced_existing? = replaced_existing ? true : false
        def file_paths = files.map(&:path)
      end

      def self.call(**kwargs) = new(**kwargs).call

      def initialize(package_path:, documents:, assignment:, provider:, source:, inputs:, settings:,
                     clock: Time)
        @package_path = package_path
        @documents = documents
        @assignment = assignment
        @provider = provider
        @source = source
        @inputs = inputs
        @settings = settings
        @clock = clock
        @warnings = []
        @moved = false
      end

      def call
        parent = ::File.dirname(package_path.absolute_package_path)
        FileUtils.mkdir_p(parent)
        staging = ::File.join(parent, "#{STAGING_PREFIX}#{SecureRandom.hex(8)}")
        begin
          files = stage(staging)
          manifest = write_manifest(staging, files)
          replaced = move_into_place(staging)
          # The manifest is written BEFORE the move, because writing it after would put a
          # file write back inside the window the atomic rename protects. Whether a package
          # was replaced is only knowable after the move, so the flag is corrected in both
          # copies here — the one on disk (rewrite_manifest_replacement) and the one
          # returned to Platform. Leaving the returned copy stale would make the run page
          # and the package on disk disagree about the same generation.
          manifest = manifest.merge("replaced_existing_package" => replaced)
          Result.new(relative_package_path: package_path.relative_package_path,
                     files: files + [ manifest_digest ], manifest: manifest,
                     replaced_existing: replaced, warnings: warnings)
        rescue Error
          raise
        rescue StandardError => e
          # Anything unexpected — most plausibly an I/O error while digesting the manifest at
          # its final location — becomes an Error that still reports whether the package
          # landed. Letting a bare Errno escape would crash past Generation's rescue list and
          # leave the claim held with no recorded reason.
          raise write_error("the generated package could not be completed: #{e.class}")
        ensure
          FileUtils.remove_entry(staging) if ::File.directory?(staging)
        end
      end

      private

      attr_reader :package_path, :documents, :assignment, :provider, :source, :inputs, :settings,
                  :clock, :warnings

      # Write every document into staging, redacted, and verify the written bytes. The
      # redaction happens BEFORE the write and the verification reads what is actually on
      # disk — checking the in-memory string would prove a property of a value that is no
      # longer the one that matters.
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
      # like a token and the correct outcome is a safe document plus a warning — not a run
      # that refuses to produce anything.
      #
      # Host paths are a HARD failure, because there is no legitimate reason for the
      # operator's absolute checkout path to appear in a generated document; every path in a
      # package is repository-relative by construction, so one appearing means a provider
      # composed it from something it should not have had.
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

      # The absolute roots that must never appear in generated output. Both checkouts, plus
      # the operator's home directory, which is the one a provider is most likely to echo.
      def host_paths
        @host_paths ||= [ ::File.dirname(package_path.absolute_package_path), source.root,
                          Dir.home ].compact.map(&:to_s).reject(&:empty?).uniq
      rescue StandardError
        [ source.root.to_s ]
      end

      def digest_of(name, target)
        bytes = ::File.binread(target)
        WrittenFile.new(path: name, sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize)
      end

      # The manifest's digest, taken from the FINAL location after the move and after the
      # replacement flag was rewritten — so it describes the bytes an operator will actually
      # find on disk. Criterion 7 asks for a digest per generated file and the manifest is
      # one; it is simply the only file whose digest cannot be computed during staging,
      # because its own content is not final until the move has happened.
      #
      # It is deliberately absent from the manifest's OWN `files` list (see #write_manifest):
      # a file cannot contain its own hash, and a digest that never verifies is worse than
      # an acknowledged omission.
      def manifest_digest
        digest_of(PackagePath::MANIFEST_JSON,
                  ::File.join(package_path.absolute_package_path, PackagePath::MANIFEST_JSON))
      end

      # The machine-readable record of this generation, written INTO the package so the
      # package is self-describing on disk, and returned so Platform can persist the same
      # facts. One source, two destinations — a manifest that disagreed with the run page
      # would make both unusable as evidence.
      #
      # The manifest's own digest is deliberately absent from the file list: a file cannot
      # contain its own hash, and pretending otherwise would produce a digest that never
      # verifies.
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
          "on_existing_package" => settings.on_existing_package,
          "replaced_existing_package" => @replaced_existing ? true : false,
          "warnings" => warnings.dup,
          "publication" => publication_block
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

      def input_bundle_block
        {
          "trace_id" => assignment.bundle_trace_id,
          "url" => Redaction.redact(assignment.bundle_url),
          "recorded" => inputs.inputs.length,
          "used" => inputs.readable_inputs.length,
          "warnings" => inputs.warnings.map { |warning| Redaction.redact(warning) }
        }
      end

      # Stated in the manifest rather than only in documentation, so a later tool reading a
      # package on disk can tell — without consulting a spec — that nothing was published for
      # it. MVP-0027 is what changes these values.
      def publication_block
        { "branch" => nil, "commit" => nil, "pull_request_url" => nil,
          "note" => "generated locally by MVP-0026; no branch, commit, push, pull request, or Jira " \
                    "write-back was performed" }
      end

      # The single operation that touches the destination. Returns whether an existing
      # package was replaced.
      def move_into_place(staging)
        destination = package_path.absolute_package_path
        return finish_move(staging, destination, nil) unless ::File.exist?(destination)
        raise write_error("a package already exists at #{package_path.relative_package_path}") unless
          settings.replace_existing?

        aside = "#{::File.dirname(destination)}/#{REPLACED_PREFIX}#{SecureRandom.hex(8)}"
        ::File.rename(destination, aside)
        finish_move(staging, destination, aside)
      end

      # The rename, with the previous package restored if it fails. `aside` is nil for a
      # first generation, in which case there is nothing to restore and a failure simply
      # propagates with the destination still absent.
      #
      # ONLY the rename is inside the rescue window, and that is the fix for a real defect.
      # The window used to extend over the post-move bookkeeping too, so a failure to delete
      # the set-aside copy — pure housekeeping, after a completed replacement — tore down a
      # good generation and reported it as a failure that wrote nothing. Everything after the
      # rename is now treated the way `rewrite_manifest_replacement` on the line below always
      # was: a warning on a generation that succeeded.
      def finish_move(staging, destination, aside)
        begin
          ::File.rename(staging, destination)
        rescue SystemCallError => e
          ::File.rename(aside, destination) if aside && !::File.exist?(destination)
          raise write_error("could not move the generated package into place: #{e.class}")
        end
        @moved = true
        @replaced_existing = !aside.nil?
        return false if aside.nil?

        rewrite_manifest_replacement(destination)
        discard_replaced(aside)
        true
      end

      # The set-aside previous package, removed only after the new one is safely in place. Its
      # removal cannot fail the generation; the operator is told where it is instead, by
      # BASENAME — the containing directory is the operator's own checkout path and has no
      # business in a message Platform stores and renders.
      def discard_replaced(aside)
        FileUtils.remove_entry(aside) if ::File.directory?(aside)
      rescue StandardError
        warnings << "the package this generation replaced could not be removed; it is still beside the " \
                    "new package as `#{::File.basename(aside)}` and can be deleted by hand."
      end

      def write_error(message)
        Error.new(message, package_path: package_path.relative_package_path, wrote_package: @moved)
      end

      # `replaced_existing_package` is only knowable after the move, and scope 10 requires the
      # replacement to be recorded in the manifest. Rewriting the one field in place is
      # cheaper and less error-prone than deferring the whole manifest until after the rename,
      # which would put a write back into the window the atomicity guarantee protects.
      def rewrite_manifest_replacement(destination)
        path = ::File.join(destination, PackagePath::MANIFEST_JSON)
        document = JSON.parse(::File.read(path))
        document["replaced_existing_package"] = true
        ::File.write(path, "#{JSON.pretty_generate(document)}\n")
      rescue StandardError
        # The package is already in place and correct; a manifest field that could not be
        # updated is a reporting gap, not a reason to tear down a good generation. The
        # authoritative replacement flag also travels to Platform in the result payload.
        warnings << "the manifest's replacement flag could not be updated after the move."
      end
    end
  end
end
