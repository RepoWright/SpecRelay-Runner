# frozen_string_literal: true

module SpecrelayRunner
  module PackagePreflight
    # The NON-EXECUTABLE package-preflight assignment, read off the claim payload (MVP-0034
    # CR-001).
    #
    # Recognised by its explicit `assignment_kind`, never by what it lacks — the same rule
    # MVP-0033 applied to review assignments, and for the same reason: an older runner build must
    # be unable to mistake a preflight assignment for an implementation run and launch a provider
    # on a specification nobody has verified.
    class Assignment
      KIND = "specification_package_preflight"

      Error = Class.new(StandardError)

      def self.preflight?(payload)
        payload.is_a?(Hash) && payload["assignment_kind"].to_s == KIND
      end

      def initialize(payload)
        @payload = payload.to_h
        @preflight = @payload.fetch("specification_package_preflight", {}).to_h
      end

      def validate!
        raise Error, "the preflight assignment names no pull request" if pull_request_url.empty?
        raise Error, "the preflight assignment names no repository" if repository_slug.empty?
        raise Error, "the preflight assignment names no commit to read" unless SHA.match?(head_sha)
        raise Error, "the preflight assignment names no package folder" if package_path.empty?
        raise Error, "the preflight assignment lists no documents to verify" if documents.empty?

        self
      end

      # A full 40-character object name. A short sha, a branch name, or a tag would all read as
      # "a ref", and reading a package by anything that can move is the one thing this protocol
      # exists to prevent (CR-001 Runner responsibility 4).
      SHA = /\A[0-9a-f]{40}\z/i

      def run_id = @payload.fetch("run", {}).to_h["id"].to_s
      def claim_token = @payload.fetch("claim", {}).to_h["runner_execution_id"].to_s
      def ticket_key = @preflight["ticket_key"].to_s
      def pull_request_url = @preflight["spec_pull_request_url"].to_s
      def repository_slug = @preflight["repository_slug"].to_s
      def pull_request_number = @preflight["pull_request_number"].to_i
      def base_branch = @preflight["base_branch"].to_s
      def head_sha = @preflight["head_sha"].to_s
      def package_path = @preflight["package_path"].to_s

      # Package-relative path => expected digest. The runner enforces this set locally so it
      # refuses a wrong package before spending a submission on it; Platform recomputes every
      # digest from the bytes anyway, so this is an early exit rather than the guarantee.
      def documents
        @documents ||= Array(@preflight["documents"]).each_with_object({}) do |entry, acc|
          fields = entry.to_h
          path = fields["path"].to_s
          acc[path] = fields["digest"].to_s unless path.empty?
        end
      end

      def result_endpoint = @preflight["result_endpoint"].to_s
    end
  end
end
