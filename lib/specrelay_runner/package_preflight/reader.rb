# frozen_string_literal: true

require "base64"
require "digest"
require "json"

module SpecrelayRunner
  module PackagePreflight
    # Reads one published specification package from GitHub AT AN EXACT COMMIT, with the
    # operator's own authenticated `gh` (MVP-0034 CR-001 Runner responsibilities 4 and 5).
    #
    # Every read is pinned to a 40-character object name rather than to the pull request's branch.
    # That is the difference between a package and a snapshot of whatever the branch happened to
    # hold: a branch can move between the listing and the third file, and a package assembled from
    # two heads would be internally inconsistent while every individual read looked fine.
    #
    # It goes through `gh` rather than a clone because the specification repository is not the
    # runner's workspace checkout — cloning a whole repository to read six Markdown files would
    # cost far more than it proves — and because `gh` is the boundary that already holds the
    # operator's credential. Nothing here ever sees or logs a token.
    class Reader
      # Per file and for the package as a whole. A repository must not be able to decide how much
      # memory a preflight spends, and the bound is enforced BEFORE the bytes are digested or
      # sent (CR-001 Runner responsibility 5).
      MAX_FILE_BYTES = 1_000_000
      MAX_PACKAGE_BYTES = 4_000_000

      Failure = Struct.new(:classification, :message, keyword_init: true)
      Document = Struct.new(:path, :digest, :bytes, keyword_init: true)

      # The blocker classifications Platform accepts from a runner. Named here so a refusal this
      # class produces is one the server will recognise rather than a free-text reason.
      UNREADABLE = "github_unreadable"
      FILE_SET_MISMATCH = "package_file_set_mismatch"
      DIGEST_MISMATCH = "package_digest_mismatch"

      def initialize(commands:, assignment:)
        @commands = commands
        @assignment = assignment
      end

      # Package-relative path => {digest, bytes}, or one Failure. Returns the CONTENT; whether it
      # is the right content is Platform's to decide, and this deliberately makes only the checks
      # that let it refuse early and cheaply.
      def read
        listed = listing
        return listed if listed.is_a?(Failure)

        expected = assignment.documents.keys.sort
        return Failure.new(classification: FILE_SET_MISMATCH,
                           message: "the package folder at #{short_sha} does not contain exactly the " \
                                    "files this ticket's specification publication recorded") unless
          listed.sort == expected

        fetch(expected)
      end

      # The final remote-head read, immediately before submission (CR-001 Runner responsibility 6).
      # A separate, deliberately last call: everything above was read at the pinned sha, so this
      # answers the one remaining question — did the pull request move while we were reading it?
      def head_moved?
        current = commands.gh([ "pr", "view", assignment.pull_request_url, "--repo",
                                assignment.repository_slug, "--json", "headRefOid" ])
        return true unless current.success?

        parsed = JSON.parse(current.stdout.to_s)
        !parsed["headRefOid"].to_s.casecmp?(assignment.head_sha)
      rescue JSON::ParserError
        true
      end

      private

      attr_reader :commands, :assignment

      # The package folder as GitHub has it at the pinned commit, flattened to package-relative
      # paths. `analysis` is the one subdirectory a package may contain; any other directory makes
      # the listing not-the-package rather than something to walk into.
      def listing
        entries = contents(assignment.package_path)
        return entries if entries.is_a?(Failure)

        files = entries.select { |entry| entry["type"] == "file" }.map { |entry| entry["name"].to_s }
        directories = entries.select { |entry| entry["type"] == "dir" }.map { |entry| entry["name"].to_s }
        return files if directories.empty?
        return Failure.new(classification: FILE_SET_MISMATCH,
                           message: "the package folder at #{short_sha} contains an unexpected " \
                                    "subdirectory") unless directories == [ ANALYSIS ]

        nested = contents("#{assignment.package_path}/#{ANALYSIS}")
        return nested if nested.is_a?(Failure)

        files + nested.select { |entry| entry["type"] == "file" }.map { |entry| "#{ANALYSIS}/#{entry['name']}" }
      end

      ANALYSIS = "analysis"

      def fetch(paths)
        total = 0
        documents = {}
        paths.each do |path|
          bytes = file_bytes(path)
          return bytes if bytes.is_a?(Failure)

          total += bytes.bytesize
          return Failure.new(classification: DIGEST_MISMATCH,
                             message: "the published package exceeds the size this runner will " \
                                      "submit") if total > MAX_PACKAGE_BYTES

          documents[path] = Document.new(path: path, digest: Digest::SHA256.hexdigest(bytes), bytes: bytes)
        end
        documents
      end

      def file_bytes(path)
        response = api("#{assignment.package_path}/#{path}")
        return response if response.is_a?(Failure)
        return unreadable("#{path} is not a readable file at #{short_sha}") unless
          response.is_a?(Hash) && response["encoding"].to_s == "base64"

        decoded = Base64.decode64(response["content"].to_s).b
        return Failure.new(classification: DIGEST_MISMATCH,
                           message: "#{path} is larger than this runner will submit") if
          decoded.bytesize > MAX_FILE_BYTES

        decoded
      end

      def contents(path)
        response = api(path)
        return response if response.is_a?(Failure)
        return unreadable("#{path} is not a folder at #{short_sha}") unless response.is_a?(Array)

        response.map(&:to_h)
      end

      # One `gh api` call, pinned to the commit. A failure is a REASON, never an exception: a
      # missing repository, a permissions problem and an unreachable API look alike from here, and
      # every one of them must leave the run retryable with Jira untouched (S19).
      def api(path)
        result = commands.gh([ "api", "repos/#{assignment.repository_slug}/contents/#{path}",
                               "-X", "GET", "-f", "ref=#{assignment.head_sha}" ])
        return unreadable(commands.failure_reason(result, "gh api")) unless result.success?

        JSON.parse(result.stdout.to_s)
      rescue JSON::ParserError
        unreadable("GitHub's answer for #{path} could not be read")
      end

      def unreadable(message) = Failure.new(classification: UNREADABLE, message: Redaction.redact(message.to_s))
      def short_sha = assignment.head_sha[0, 12]
    end
  end
end
