# frozen_string_literal: true

module SpecrelayRunner
  # MVP-0013 — builds the runner terminal-result envelope
  # (contracts/runner/v1/terminal-result.schema.json) the runner submits WITH its
  # report bundle. It carries the durable terminal facts Platform validates before
  # finalization: the outcome, the final sequence, Core exit info with a sanitized
  # error classification, a repository result for every relevant repository
  # (including unchanged ones), artifact references, and the cleanup result.
  #
  # It is a pure builder over values the Execution already computed; it makes no
  # decisions and holds no Platform authority. Free-text fields are redacted
  # client-side (Platform re-redacts on ingest — defense in depth).
  class TerminalResult
    CONTRACT_VERSION = "1"
    SUCCEEDED = "succeeded"
    FAILED = "failed"

    def self.build(**kwargs) = new(**kwargs).build

    def initialize(run_id:, attempt_id:, outcome:, final_sequence:, exit_code:,
                   repositories:, artifacts:, error_classification: nil, cleanup_error: nil)
      @run_id = run_id
      @attempt_id = attempt_id
      @outcome = outcome
      @final_sequence = final_sequence
      @exit_code = exit_code
      @repositories = Array(repositories)
      @artifacts = artifacts
      @error_classification = error_classification
      @cleanup_error = cleanup_error
    end

    def build
      {
        "contract_version" => CONTRACT_VERSION,
        "run_id" => run_id,
        "attempt_id" => attempt_id,
        "outcome" => outcome,
        "final_sequence" => final_sequence,
        "core" => {
          "exit_code" => exit_code,
          "error_classification" => error_classification && Redaction.redact(error_classification.to_s)
        },
        "repositories" => repositories.map { |repository| repository_result(repository) },
        "artifacts" => Array(artifacts).map(&:to_s),
        "cleanup" => { "succeeded" => cleanup_error.nil?, "error" => cleanup_error && Redaction.redact(cleanup_error.to_s) }
      }
    end

    private

    attr_reader :run_id, :attempt_id, :outcome, :final_sequence, :exit_code,
                :repositories, :artifacts, :error_classification, :cleanup_error

    # One repository publication result (MVP-0014). `changed` is reported truthfully
    # even when false so Platform records an unchanged repository, `head_commit` is
    # omitted (null) when nothing changed, and `branch`/`pull_request_url` are present
    # only when publication actually succeeded — Platform validates all of this before
    # it will call the run successful. `publication_error` is redacted client-side too
    # (Platform re-redacts on ingest).
    def repository_result(repository)
      # review-003 finding 2 wants an unmeasured change set reported as unknown rather
      # than as `false`. NOT DONE, deliberately: Platform's terminal-envelope validator
      # rejects a non-boolean here ("repositories[0].changed must be a boolean"), so
      # honouring it needs a Platform change, which CR-002 declares a non-goal. The
      # untruth is contained — the repository carries a "change detection failed" reason
      # and the attempt is terminal-failed — and the blocker is recorded for the next
      # round rather than worked around here.
      changed = !!repository[:changed]
      error = repository[:publication_error]
      skipped = repository[:publication_skipped_reason]
      {
        "id" => repository[:id].to_s,
        "changed" => changed,
        "base_commit" => repository[:base_commit].to_s,
        "head_commit" => changed ? nilify(repository[:head_commit]) : nil,
        "branch" => nilify(repository[:branch]),
        "pull_request_url" => nilify(repository[:pull_request_url]),
        "publication_error" => error && Redaction.redact(error.to_s),
        # Publication not attempted by policy. Reported separately from
        # publication_error so Platform does not treat a read-only repository as a
        # failed publication (review-001 finding 3).
        "publication_skipped_reason" => skipped && Redaction.redact(skipped.to_s)
      }
    end

    def nilify(value)
      string = value.to_s
      string.empty? ? nil : string
    end
  end
end
