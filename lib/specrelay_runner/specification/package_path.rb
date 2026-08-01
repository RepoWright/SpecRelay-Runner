# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # Where a generated specification package goes, and the proof that it goes nowhere
    # else (MVP-0026 scope 2).
    #
    # Two separate jobs, deliberately in one class because they are one guarantee:
    #
    #   1. DERIVE a deterministic folder name from the Jira issue key and summary. The
    #      same issue must always produce the same folder, on every machine, so a re-run
    #      replaces its own package instead of accumulating near-duplicates.
    #   2. CONTAIN the result. Everything that reaches this class — the issue key, the
    #      title, and the `specification_root` Platform resolved from operator
    #      configuration — is data this runner did not author. Each is treated as hostile:
    #      absolute paths, `..`, URL userinfo, shell metacharacters, control characters,
    #      and Windows-style drive/UNC prefixes are rejected rather than escaped, and the
    #      final resolved path is re-checked against the checkout root.
    #
    # Rejecting rather than sanitizing is the deliberate choice for the ROOT and the KEY.
    # A silently rewritten path is a path the operator cannot predict, and "the runner
    # quietly wrote somewhere else" is a worse failure than a refusal. The summary SLUG is
    # the one part that is sanitized, because it is free prose and has no correct
    # rejection.
    class PackagePath
      Unsafe = Class.new(StandardError)

      # The three required documents, repository-relative to the package folder. Ordered
      # as a reader meets them: the specification first, then its two analyses.
      SPEC_MD = "spec.md"
      BUSINESS_MD = "analysis/business.md"
      TECHNICAL_MD = "analysis/technical.md"
      MANIFEST_JSON = "generation-manifest.json"
      REQUIRED_FILES = [ SPEC_MD, BUSINESS_MD, TECHNICAL_MD ].freeze
      ALL_FILES = (REQUIRED_FILES + [ MANIFEST_JSON ]).freeze

      # A Jira issue key is a closed shape (PROJECT-123). Validating it as such is what
      # lets the folder name be trusted as a path segment without escaping: anything that
      # is not this shape is refused, so no traversal or metacharacter can arrive inside
      # the one component the name is built from.
      ISSUE_KEY = /\A[A-Z][A-Z0-9]*-\d+\z/

      # How much of the summary survives into the folder name. Long enough to be readable
      # in a directory listing, short enough that the whole path stays well inside every
      # filesystem's component limit once the key and separators are added.
      MAX_SLUG_LENGTH = 60

      # Characters that must never appear in a path this runner composes, whatever their
      # source. Control characters are included because a terminal-escape in a directory
      # name is an output-spoofing vector in every tool that later lists the package.
      UNSAFE_ROOT = /[\x00-\x1f\x7f`$;&|<>*?"'\\\n\r]/

      attr_reader :folder_name, :specification_root

      def self.build(**kwargs) = new(**kwargs)

      # `checkout_root` is the operator's local clone of the specification repository;
      # `specification_root` is the repository-relative folder Platform resolved from the
      # project's specification-lane configuration.
      def initialize(checkout_root:, specification_root:, issue_key:, summary:)
        @checkout_root = File.expand_path(checkout_root.to_s)
        @specification_root = validate_root!(specification_root.to_s)
        @folder_name = "#{validate_issue_key!(issue_key.to_s)}-#{slugify(summary)}"
      end

      # The package folder, RELATIVE to the specification repository root. This is the only
      # form that may appear in generated Markdown, in the manifest, or in anything sent to
      # Platform: an absolute path would carry the operator's home directory into durable
      # evidence, which criterion 11 forbids.
      def relative_package_path
        specification_root.empty? ? folder_name : "#{specification_root}/#{folder_name}"
      end

      # The absolute local destination, re-validated for containment. Recomputed rather
      # than memoized so a caller cannot hold a stale path across a changed root, and
      # checked here (not only at construction) because this is the value that is actually
      # written to.
      def absolute_package_path
        resolved = File.expand_path(File.join(checkout_root, relative_package_path))
        unless resolved.start_with?("#{checkout_root}/")
          raise Unsafe, "the resolved specification package path escapes the repository checkout"
        end

        resolved
      end

      # Repository-relative paths of every required document, for the manifest and for the
      # generated cross-references.
      def relative_file_paths = ALL_FILES.map { |name| "#{relative_package_path}/#{name}" }

      def exists? = File.directory?(absolute_package_path)

      private

      attr_reader :checkout_root

      def validate_issue_key!(key)
        raise Unsafe, "the assignment's Jira issue key is not a usable path component: #{key.inspect}" unless
          ISSUE_KEY.match?(key)

        key
      end

      # The configured specification folder, validated as a relative POSIX path. An empty
      # root is legitimate — it means "packages live at the repository root" — so it is
      # allowed rather than treated as missing configuration.
      def validate_root!(root)
        trimmed = root.strip.delete_prefix("./").gsub(%r{/+\z}, "")
        return "" if trimmed.empty?

        raise Unsafe, "the configured specification folder must be repository-relative: #{trimmed.inspect}" if
          trimmed.start_with?("/", "~") || trimmed.match?(/\A[A-Za-z]:/)
        raise Unsafe, "the configured specification folder may not traverse: #{trimmed.inspect}" if
          trimmed.split("/").include?("..")
        raise Unsafe, "the configured specification folder contains unsafe characters" if
          UNSAFE_ROOT.match?(trimmed)
        # `user:token@host` pasted into a folder field. The `@` alone is harmless in a path,
        # so the check is for the userinfo SHAPE — which is never a legitimate folder name
        # and would put a credential into every path this runner prints.
        raise Unsafe, "the configured specification folder looks like a URL with credentials" if
          trimmed.match?(%r{\A[^/]*:[^/]*@})

        trimmed
      end

      # Free prose reduced to one lowercase hyphenated token. Unlike the root and the key
      # this is sanitized rather than refused: a Jira summary is arbitrary human text, so
      # there is no shape to reject against, and refusing would make generation fail on a
      # perfectly ordinary ticket title.
      #
      # A summary that reduces to nothing (only punctuation, or only non-Latin script)
      # yields a stable literal rather than an empty component — the folder must still be
      # deterministic and still be a valid path.
      def slugify(summary)
        slug = summary.to_s.unicode_normalize(:nfkd).downcase
                      .gsub(/[^a-z0-9]+/, "-")
                      .gsub(/-+/, "-")
                      .delete_prefix("-").delete_suffix("-")
        slug = slug[0, MAX_SLUG_LENGTH].to_s.delete_suffix("-") if slug.length > MAX_SLUG_LENGTH
        slug.empty? ? "specification" : slug
      end
    end
  end
end
