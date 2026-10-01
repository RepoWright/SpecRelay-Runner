# frozen_string_literal: true

require "yaml"
require "base64"
require "json"

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
    MANIFEST_VERSION = 1
    STATUS_SUCCEEDED = "succeeded"
    STATUS_FAILED = "failed"

    # Scenario evidence: the executor's record of the acceptance scenarios it actually checked,
    # written into this child of the attempt's staging directory — outside every checkout, so it
    # is never part of the measured diff — and declared in a local `index.json` that reuses the
    # manifest's own `evidence_files` and `screenshots` entry keys. Only declared files that pass
    # these checks are uploaded; Platform's import policy stays the final authority on what it
    # stores. Every refusal names the index entry by position, never by its declared value.
    SCENARIO_EVIDENCE = "scenario-evidence"
    SCENARIO_INDEX = "index.json"
    SCENARIO_PATH = %r{\Ascenarios/(\d{2}-[a-z0-9][a-z0-9-]*)\.md\z}
    SCREENSHOT_PATH = %r{\Ascreenshots/[a-z0-9][a-z0-9-]*\.(?:png|jpe?g)\z}
    IMAGE_SIGNATURES = [ "\x89PNG\r\n\x1A\n".b, "\xFF\xD8\xFF".b ].freeze
    SCENARIO_INDEX_MAX_BYTES = 32_768
    SCENARIO_MAX_ENTRIES = 40
    SCENARIO_MAX_FILE_BYTES = 5_000_000
    SCENARIO_MAX_TEXT = 200
    SCREENSHOT_FIELDS = %w[viewport scenario result].freeze

    def self.build(**kwargs) = new(**kwargs).build

    def self.scenario_evidence_path(staging_dir) = File.join(staging_dir.to_s, SCENARIO_EVIDENCE)

    # executor: Executor::Result, verifications: [RepositoryVerification::Result],
    # changes: Workspace::Changes, base_commit:, worktree_path:. `scenario_evidence_dir` is nil
    # when no executor ran, and then the report says nothing about scenario evidence.
    def initialize(payload:, status:, executor:, verifications:, changes:, base_commit:, worktree_path:,
                   failure_details: nil, scenario_evidence_dir: nil)
      @payload = payload
      @status = status
      @executor = executor
      @verifications = Array(verifications)
      @changes = changes
      @base_commit = base_commit
      @worktree_path = worktree_path
      @failure_details = failure_details
      @scenario_evidence_dir = scenario_evidence_dir
    end

    def build
      { "round_label" => round_label, "files" => files }
    end

    private

    attr_reader :payload, :status, :executor, :verifications, :changes, :base_commit, :worktree_path,
                :failure_details, :scenario_evidence_dir

    def run = payload.fetch("run")
    def workspace = payload.fetch("workspace")
    def report_contract = payload.fetch("report_contract")
    def round_label = report_contract.fetch("round_label")
    # MVP-0035 — the round is Platform's, not a constant here. Rounds are append-only across a
    # change-request cycle, and a runner that hard-coded 1 would file every corrected round under
    # the ordering of the first.
    def round_number = report_contract.fetch("round_number")
    def failed? = status == STATUS_FAILED

    def files
      contents.map { |path, body| { "relative_path" => path, "content_base64" => Base64.strict_encode64(body) } }
    end

    # MAPIAI-75 — there is no live-log file here. It used to duplicate the bounded
    # stream Platform already stores as ordered protocol events, which is now the
    # complete, pageable transcript; stdout/stderr remain the full capture taken for
    # report review, and that is a genuinely different artifact.
    def contents
      {
        "README.md" => readme,
        "manifest.yml" => YAML.dump(manifest),
        "evidence/stdout.log" => Redaction.redact(executor.stdout.to_s),
        "evidence/stderr.log" => Redaction.redact(executor.stderr.to_s),
        "evidence/verification.log" => verification_log,
        # Only this uploaded copy is redacted; the commit and pull request keep the reviewed code.
        "evidence/diff.txt" => Redaction.redact(changes.diff.to_s),
        "evidence/summary.md" => readme
      }.merge(scenario_evidence[:files])
    end

    def manifest
      {
        "round_number" => round_number, "round_label" => round_label, "run_id" => run.fetch("id"),
        "project_key" => workspace.fetch("project_key"), "workspace_key" => workspace.fetch("workspace_key"),
        "task_id" => run.fetch("task_id"), "canonical_branch" => run.fetch("canonical_branch"),
        "executor_summary" => executor_summary, "files_changed_summary" => files_changed_summary,
        "release_instructions" => report_contract.fetch("release_instructions"),
        "execution_status" => status, "final_jira_update_ready" => !failed?,
        "sanitized_failure_details" => (failure_details.to_s if failed?),
        "repository_verifications" => verifications.map { |result| verification_entry(result) },
        "evidence_files" => evidence_entries + scenario_evidence[:evidence_files],
        "screenshots" => scenario_evidence[:screenshots],
        "worktree_identity" => worktree_identity,
        "version" => MANIFEST_VERSION, "executor" => executor_block,
        "worktree" => { "path" => worktree_path.to_s, "created" => true }, "git" => git_block,
        "artifacts" => {
          "stdout" => "evidence/stdout.log", "stderr" => "evidence/stderr.log",
          "verification" => "evidence/verification.log", "diff" => "evidence/diff.txt",
          "summary" => "evidence/summary.md"
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

    # MAPIAI-93 — one closed result per changed repository. It carries only what Platform
    # validates, persists and shows: the repository, its final outcome, and the argv the runner
    # really launched with what that process did. A `not_found` repository carries no command,
    # because nothing ran.
    def verification_entry(result)
      {
        "repository_path" => result.repository_path.to_s,
        "repository_id" => result.repository_id.to_s,
        "status" => result.status,
        "commands" => result.attempts.map { |attempt| command_entry(attempt) }
      }
    end

    def command_entry(attempt)
      {
        "argv" => attempt.argv, "exit_status" => attempt.exit_code,
        "timed_out" => attempt.timed_out ? true : false,
        "launch_error" => attempt.launch_error,
        "output_summary" => summarize(attempt.output)
      }.compact
    end

    # The full bounded output of every command, kept as one readable artifact beside the
    # manifest's per-command summaries.
    def verification_log
      verifications.flat_map do |result|
        [ "## #{result.repository_path} — #{result.status}" ] +
          result.attempts.map { |attempt| "$ #{attempt.argv.join(' ')}\n#{attempt.output}" }
      end.join("\n\n")
    end

    def evidence_entries
      [
        { "path" => "evidence/stdout.log", "kind" => "text", "description" => "Executor stdout" },
        { "path" => "evidence/stderr.log", "kind" => "text", "description" => "Executor stderr" },
        { "path" => "evidence/verification.log", "kind" => "text", "description" => "Repository verification output" },
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
          "applied #{Array(changes.changed_files).size} changed file(s), and verified " \
          "#{verifications.length} changed repository(ies)."
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
        - Verification: #{verification_summary}
        - Changed files: #{Array(changes.changed_files).size}
        #{failure_line}#{scenario_lines}
        See `manifest.yml` for the machine-readable report and `evidence/` for the
        captured stdout, stderr, verification output, and diff. The live executor output the
        operator watched is the run's ordered protocol events in Platform.
      MD
    end

    def verification_summary
      return "no repository changed" if verifications.empty?

      verifications.map { |result| "`#{result.repository_path}` #{result.status}" }.join(", ")
    end

    def failure_line = failed? ? "- Failure: #{failure_details}\n" : ""

    # What was collected, and every declaration that was not. Absent when no executor ran.
    def scenario_lines
      return "" if scenario_evidence_dir.nil?

      counts = "- Scenario evidence: #{scenario_evidence[:evidence_files].size} scenario(s), " \
               "#{scenario_evidence[:screenshots].size} screenshot(s)\n"
      counts + scenario_evidence[:notes].map { |note| "- Scenario evidence limitation: #{note}\n" }.join
    end

    def scenario_evidence = @scenario_evidence ||= collect_scenario_evidence

    def collect_scenario_evidence
      evidence = { files: {}, evidence_files: [], screenshots: [], notes: [] }
      return evidence if scenario_evidence_dir.nil?

      index = scenario_index(evidence[:notes])
      return evidence if index.nil?

      scenarios = collect_scenarios(index.fetch("evidence_files"), evidence)
      collect_screenshots(index.fetch("screenshots", []), scenarios, evidence)
      evidence
    end

    def scenario_index(notes)
      path = File.join(scenario_evidence_dir, SCENARIO_INDEX)
      return scenario_note(notes, "the executor wrote no #{SCENARIO_INDEX}") unless declared_file?(path)
      if File.size(path) > SCENARIO_INDEX_MAX_BYTES
        return scenario_note(notes, "#{SCENARIO_INDEX} is larger than #{SCENARIO_INDEX_MAX_BYTES} bytes")
      end

      index = JSON.parse(File.read(path))
      unless index.is_a?(Hash) && index["evidence_files"].is_a?(Array) && index.fetch("screenshots", []).is_a?(Array)
        return scenario_note(notes, "#{SCENARIO_INDEX} must be an object with evidence_files and screenshots lists")
      end

      declared = index["evidence_files"].size + index.fetch("screenshots", []).size
      return index if declared <= SCENARIO_MAX_ENTRIES

      scenario_note(notes, "#{SCENARIO_INDEX} declares #{declared} entries; at most #{SCENARIO_MAX_ENTRIES} are read")
    rescue JSON::ParserError, EncodingError
      scenario_note(notes, "#{SCENARIO_INDEX} is not valid JSON")
    end

    # Each collected scenario's identifier: its numbered file name without `.md`.
    def collect_scenarios(entries, evidence)
      entries.each_with_index.filter_map do |entry, index|
        label = "evidence_files[#{index}]"
        path = entry.is_a?(Hash) ? entry["path"].to_s : ""
        id = path[SCENARIO_PATH, 1]
        next scenario_note(evidence[:notes], "#{label} is not a numbered scenarios/NN-name.md file") unless id
        next scenario_note(evidence[:notes], "#{label} repeats an earlier path") if evidence[:files].key?(path)
        next unless (bytes = read_declared(path, label, evidence[:notes]))

        text = bytes.force_encoding(Encoding::UTF_8)
        next scenario_note(evidence[:notes], "#{label} is not UTF-8 text") unless text.valid_encoding?

        evidence[:files][path] = Redaction.redact(text)
        evidence[:evidence_files] << { "path" => path, "kind" => "markdown",
                                       "description" => scenario_text(entry["description"]) }.compact
        id
      end
    end

    def collect_screenshots(entries, scenarios, evidence)
      entries.each_with_index do |entry, index|
        label = "screenshots[#{index}]"
        path = entry.is_a?(Hash) ? entry["path"].to_s : ""
        fields = SCREENSHOT_FIELDS.to_h { |field| [ field, entry.is_a?(Hash) ? scenario_text(entry[field]) : nil ] }
        problem = screenshot_problem(path, fields, scenarios, evidence[:files])
        next scenario_note(evidence[:notes], "#{label} #{problem}") if problem
        next unless (bytes = read_declared(path, label, evidence[:notes]))
        unless IMAGE_SIGNATURES.any? { |signature| bytes.start_with?(signature) }
          next scenario_note(evidence[:notes], "#{label} is not a PNG or JPEG image")
        end

        evidence[:files][path] = bytes
        evidence[:screenshots] << { "path" => path }.merge(fields)
      end
    end

    def screenshot_problem(path, fields, scenarios, files)
      return "is not a screenshots/name.png or .jpg file" unless path.match?(SCREENSHOT_PATH)
      return "repeats an earlier path" if files.key?(path)
      return "needs short viewport, scenario and result values" if fields.value?(nil)

      "names no collected scenario" unless scenarios.include?(fields["scenario"])
    end

    # The bytes of one declared file, or nil after recording why it was refused. The path has
    # already matched a fixed shape, so it has no `..` and no leading `/`; what remains is a
    # symlink, a non-regular file, or a directory component that resolves elsewhere.
    def read_declared(path, label, notes)
      full = File.join(scenario_evidence_dir, path)
      return scenario_note(notes, "#{label} names a file that does not exist") unless File.exist?(full) || File.symlink?(full)
      return scenario_note(notes, "#{label} is not a regular file") unless declared_file?(full)
      unless File.realpath(full).start_with?("#{File.realpath(scenario_evidence_dir)}/")
        return scenario_note(notes, "#{label} resolves outside the scenario evidence directory")
      end
      return scenario_note(notes, "#{label} is larger than #{SCENARIO_MAX_FILE_BYTES} bytes") if File.size(full) > SCENARIO_MAX_FILE_BYTES

      File.binread(full)
    end

    # A regular file that is not itself a symlink, inside a scenario directory that is not one.
    def declared_file?(path)
      File.lstat(path).file? && File.lstat(scenario_evidence_dir).directory?
    rescue SystemCallError
      false
    end

    # A short, redacted, single-line metadata value, or nil when there is none usable.
    def scenario_text(value)
      return nil unless value.is_a?(String)

      text = Redaction.redact(value.strip)
      text.empty? || text.length > SCENARIO_MAX_TEXT || text.include?("\n") ? nil : text
    end

    def scenario_note(notes, text)
      notes << text
      nil
    end
  end
end
