# frozen_string_literal: true

require "yaml"
require "base64"

module SpecrelayRunner
  # Assembles the execution-report bundle the standalone runner uploads to
  # POST /api/runner/reports (MVP-0010). Report assembly is explicitly a RUNNER
  # responsibility (the runner owns diff/log/artifact collection and report
  # upload); Platform owns validation, storage, and Jira finalization on ingest.
  #
  # The manifest satisfies the Platform ExecutionReports import contract exactly
  # (the same shared boundary as contracts/runner/v1), built from the run payload
  # identity Platform handed the runner at claim time, so Platform's identity
  # cross-check passes without the runner ever touching Platform data. Executor
  # stdout/stderr are redacted client-side before upload (Platform re-redacts on
  # ingest — defense in depth).
  #
  # Files are returned base64-encoded so the bundle is a plain JSON body.
  class ReportBundle
    ROUND_NUMBER = 1
    MANIFEST_VERSION = 1
    STATUS_SUCCEEDED = "succeeded"
    STATUS_FAILED = "failed"

    def self.build(**kwargs) = new(**kwargs).build

    # executor: Executor::Result, test: { command:, exit_code:, output: },
    # changes: Workspace::Changes, base_commit:, worktree_path:.
    def initialize(payload:, status:, executor:, test:, changes:, base_commit:, worktree_path:, failure_details: nil)
      @payload = payload
      @status = status
      @executor = executor
      @test = test
      @changes = changes
      @base_commit = base_commit
      @worktree_path = worktree_path
      @failure_details = failure_details
    end

    def build
      { "round_label" => round_label, "files" => files }
    end

    private

    attr_reader :payload, :status, :executor, :test, :changes, :base_commit, :worktree_path, :failure_details

    def run = payload.fetch("run")
    def workspace = payload.fetch("workspace")
    def report_contract = payload.fetch("report_contract")
    def round_label = report_contract.fetch("round_label")
    def failed? = status == STATUS_FAILED

    def files
      contents.map { |path, body| { "relative_path" => path, "content_base64" => Base64.strict_encode64(body) } }
    end

    def contents
      {
        "README.md" => readme,
        "manifest.yml" => YAML.dump(manifest),
        "evidence/stdout.log" => Redaction.redact(executor.stdout.to_s),
        "evidence/stderr.log" => Redaction.redact(executor.stderr.to_s),
        "evidence/tests.log" => test[:output].to_s,
        "evidence/diff.txt" => changes.diff.to_s,
        "evidence/summary.md" => readme
      }
    end

    def manifest
      {
        "round_number" => ROUND_NUMBER, "round_label" => round_label, "run_id" => run.fetch("id"),
        "project_key" => workspace.fetch("project_key"), "workspace_key" => workspace.fetch("workspace_key"),
        "task_id" => run.fetch("task_id"), "canonical_branch" => run.fetch("canonical_branch"),
        "executor_summary" => executor_summary, "files_changed_summary" => files_changed_summary,
        "release_instructions" => report_contract.fetch("release_instructions"),
        "execution_status" => status, "final_jira_update_ready" => !failed?,
        "sanitized_failure_details" => (failure_details.to_s if failed?),
        "validation_commands" => [ validation_entry ],
        "evidence_files" => evidence_entries, "screenshots" => [],
        "worktree_identity" => worktree_identity,
        "version" => MANIFEST_VERSION, "executor" => executor_block,
        "worktree" => { "path" => worktree_path.to_s, "created" => true }, "git" => git_block,
        "artifacts" => {
          "stdout" => "evidence/stdout.log", "stderr" => "evidence/stderr.log",
          "tests" => "evidence/tests.log", "diff" => "evidence/diff.txt", "summary" => "evidence/summary.md"
        }
      }.compact
    end

    def executor_block
      {
        "provider" => provider, "command" => executor.argv.first.to_s, "argv" => Array(executor.argv).map(&:to_s),
        "exit_code" => executor.exit_code, "duration_seconds" => executor.duration_seconds,
        "timed_out" => executor.timed_out ? true : false
      }
    end

    def git_block
      { "changed_files" => Array(changes.changed_files).map(&:to_s), "diff_captured" => !changes.diff.to_s.empty? }
    end

    def validation_entry
      {
        "command" => test[:command].to_s,
        "result" => test[:exit_code].to_i.zero? ? "passed" : "failed",
        "exit_status" => test[:exit_code],
        "output_summary" => summarize(test[:output])
      }
    end

    def evidence_entries
      [
        { "path" => "evidence/stdout.log", "kind" => "text", "description" => "Executor stdout" },
        { "path" => "evidence/stderr.log", "kind" => "text", "description" => "Executor stderr" },
        { "path" => "evidence/tests.log", "kind" => "text", "description" => "Project test output" },
        { "path" => "evidence/diff.txt", "kind" => "text", "description" => "Git diff of the worktree changes" },
        { "path" => "evidence/summary.md", "kind" => "markdown", "description" => "Standalone runner execution summary" }
      ]
    end

    def worktree_identity
      {
        "task_id" => run.fetch("task_id"), "branch" => run.fetch("canonical_branch"),
        "base_commit" => base_commit.to_s, "head_commit" => changes.head_commit.to_s,
        "workspace_command" => workspace.fetch("worktree_create_command"), "local_path" => worktree_path.to_s
      }
    end

    def provider = payload.dig("executor", "provider").to_s

    def executor_summary
      if failed?
        "Standalone runner recorded a failed execution: #{failure_details}"
      else
        "Standalone runner executed #{provider} non-interactively (exit #{executor.exit_code}) over the API boundary, " \
          "applied #{Array(changes.changed_files).size} changed file(s), and ran the project test command."
      end
    end

    def files_changed_summary
      files = Array(changes.changed_files).map(&:to_s)
      files.empty? ? "No files changed." : files.first(20).join("\n")
    end

    def summarize(text)
      lines = text.to_s.strip.lines.map(&:chomp)
      last = lines.last(3).join(" | ")
      last.empty? ? "(no output)" : last
    end

    def readme
      <<~MD
        # Execution report — #{run.fetch('task_id')}

        Standalone runner over the Platform runner API (MVP-0010). Execution status: **#{status}**.

        - Run: `#{run.fetch('id')}`
        - Task id: `#{run.fetch('task_id')}`
        - Canonical branch: `#{run.fetch('canonical_branch')}`
        - Executor: `#{provider}` (exit #{executor.exit_code}, #{executor.duration_seconds}s)
        - Test command: `#{test[:command]}` (exit #{test[:exit_code]})
        - Changed files: #{Array(changes.changed_files).size}
        #{failure_line}
        See `manifest.yml` for the machine-readable report and `evidence/` for the
        captured stdout, stderr, test output, and diff.
      MD
    end

    def failure_line = failed? ? "- Failure: #{failure_details}\n" : ""
  end
end
