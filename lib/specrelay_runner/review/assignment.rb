# frozen_string_literal: true

module SpecrelayRunner
  module Review
    # A claimed REVIEW assignment, read from the closed packet Platform sent (MVP-0033
    # contract 5).
    #
    # It exists so the rest of the runner reads named accessors instead of digging through a
    # hash, and so "is this a review?" is answered in ONE place. The discriminator is the
    # explicit `assignment_type` field, never the absence of some other key: a runner that
    # identified work by what a payload was missing would execute a future assignment type as
    # if it were an implementation run.
    class Assignment
      TYPE = "review"

      def self.review?(payload)
        payload.is_a?(Hash) && payload["assignment_type"].to_s == TYPE
      end

      def initialize(payload)
        @payload = payload.to_h
      end

      def claim_token = payload.dig("claim", "runner_execution_id").to_s
      def attempt_id = payload.dig("review", "attempt_id").to_s
      def attempt_ordinal = payload.dig("review", "attempt_ordinal").to_i
      def manifest_digest = payload.dig("review", "input_manifest_digest").to_s
      def workspace_key = payload.dig("workspace", "key").to_s
      def ticket_id = payload.dig("ticket", "external_id").to_s
      def task_id = payload.dig("ticket", "task_id").to_s
      def run_url = payload.dig("implementation", "run_url").to_s
      def report_url = payload.dig("execution_evidence", "report_url").to_s

      # The pinned repositories the runner must verify before reviewing anything.
      def repositories = Array(payload["repositories"])

      # The approved specification as a DOCUMENT MANIFEST. Read as a list rather than as one
      # `content` string: today it holds a single document, because the implementation intake
      # still derives authority from the Jira `Approved Specification:` line, but a later MVP
      # that resolves a Spec PR into a complete package will add entries here and this runner
      # must keep working without a change.
      def specification_documents = Array(payload.dig("specification", "documents"))
      def specification_digest = payload.dig("specification", "digest").to_s

      def execution_evidence = payload.fetch("execution_evidence", {}).to_h

      # Present only when continuing after a Product Owner answer (S38).
      def continuation = payload["continuation"]

      def timeout_seconds = payload.dig("execution_policy", "attempt_timeout_seconds").to_i
      def lease_renewal_seconds = payload.dig("execution_policy", "lease_renewal_seconds").to_i

      def to_h = payload

      private

      attr_reader :payload
    end
  end
end
