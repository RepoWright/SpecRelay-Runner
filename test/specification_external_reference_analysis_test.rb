# frozen_string_literal: true

require_relative "test_helper"

# MVP-0028 remediation slice 2, defect 2 — external references become REAL evidence.
#
# Before this, an operator-set `external_references.available: true` alone made a deferred Jam
# link or Confluence page `readable`, with nothing ever fetched or analysed: the URL was copied
# into the generated package and the specification read as though the reference had been read.
#
# Every test here runs the real CLI against a real fake Platform, exactly like
# specification_preflight_test.rb, because "the generated document contains this text" and "the
# run refused with this message" are facts about what actually happened — not statements about
# what a private method returned.
class SpecificationExternalReferenceAnalysisTest < Minitest::Test
  ISSUE = "SR-700"
  REFERENCE_URL = "https://jam.dev/c/abc123-export-flow"

  def setup
    @source, @specs, @temp = SpecificationWorkspace.build
    @io = StringIO.new
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@temp) if @temp && File.directory?(@temp)
  end

  def deferred_reference_payload(name: "Export flow recording")
    inputs = [ { "kind" => "jam_recording", "name" => name, "reference" => REFERENCE_URL,
                 "read_status" => "deferred_to_runner_mcp",
                 "reason" => "a Jam recording a later capability must analyse" } ]
    spec_creation_payload_for(issue_key: ISSUE, inputs: inputs)
  end

  # The per-input table — kind, name, recorded read status, used?, and the note this
  # remediation makes truthful — is `spec.md`'s "Input summary" section, not business.md's.
  def spec_document
    File.read(File.join(@specs, "specs", "SR-700-add-an-export-button", "spec.md"))
  end

  # ------------------------------------------------------------------ successful analysis

  def test_a_successfully_analysed_reference_contributes_real_evidence
    analyzer = write_analyzer(File.join(@temp, "analyzer"),
                              response: { "contributed" => true,
                                         "summary" => "Jam recording shows: click Export, a CSV downloads." })
    start_platform(deferred_reference_payload)

    exit_code = run_cli(config: build_config(external_reference_command: analyzer))

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    assert_includes spec_document, "click Export, a CSV downloads"
    assert_includes spec_document, "used"
  end

  # ------------------------------------------------------------------ unavailable tooling

  # The exact defect this closes: an operator-set `available: true` with no analyzer configured
  # used to be enough on its own. It must now refuse exactly as if nothing had been declared.
  def test_available_true_with_no_command_configured_still_refuses
    start_platform(deferred_reference_payload)

    exit_code = run_cli(config: build_config(external_references_available: true))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    generation = @platform.last_specification_generation
    assert_equal "external_reference_analysis_unavailable", generation["failure_class"]
    assert_includes generation["message"], "external_references.substitute"
  end

  # ------------------------------------------------------------------ unreadable required reference

  def test_an_analyzer_that_fails_refuses_with_the_concrete_reason
    analyzer = write_analyzer(File.join(@temp, "analyzer"), response: "not JSON at all", exit_code: 1)
    start_platform(deferred_reference_payload)

    exit_code = run_cli(config: build_config(external_reference_command: analyzer))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    generation = @platform.last_specification_generation
    assert_equal "external_reference_analysis_unavailable", generation["failure_class"]
    assert_includes generation["message"], "exited 1"
  end

  # A substitute is still the approved way to proceed without a working analyzer — unchanged
  # from the existing policy, and it must still apply when a configured analyzer fails.
  def test_an_analyzer_that_fails_with_a_recorded_substitute_still_only_warns
    analyzer = write_analyzer(File.join(@temp, "analyzer"), response: "not JSON at all", exit_code: 1)
    start_platform(deferred_reference_payload)

    exit_code = run_cli(config: build_config(external_reference_command: analyzer,
                                             external_references_substitute: "the reporter described it in the ticket"))

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    warnings = @platform.last_specification_generation["warnings"]
    assert warnings.any? { |warning| warning.include?("Export flow recording") }, warnings.inspect
  end

  # ------------------------------------------------------------------ sanitized evidence

  def test_a_secret_shaped_analyzer_summary_is_redacted
    analyzer = write_analyzer(File.join(@temp, "analyzer"),
                              response: { "contributed" => true,
                                         "summary" => "Authorization: Bearer abcdefgh12345678" })
    start_platform(deferred_reference_payload)

    exit_code = run_cli(config: build_config(external_reference_command: analyzer))

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    refute_includes spec_document, "abcdefgh12345678"
  end

  # ------------------------------------------------------------------ no raw payload / secret persistence

  def test_only_the_summary_field_reaches_generated_output_never_the_full_analyzer_response
    analyzer = write_analyzer(File.join(@temp, "analyzer"),
                              response: { "contributed" => true, "summary" => "a short, real summary",
                                         "raw_transcript" => "SPECRELAY_RAW_MARKER_SHOULD_NEVER_APPEAR" })
    start_platform(deferred_reference_payload)

    exit_code = run_cli(config: build_config(external_reference_command: analyzer))

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    refute_includes spec_document, "SPECRELAY_RAW_MARKER_SHOULD_NEVER_APPEAR"
    generation = @platform.last_specification_generation
    refute_includes generation.to_s, "SPECRELAY_RAW_MARKER_SHOULD_NEVER_APPEAR"
  end

  # ------------------------------------------------------------------------- helpers

  def write_analyzer(path, response:, exit_code: 0)
    body = response.is_a?(String) ? response : JSON.generate(response)
    File.write(path, <<~SH)
      #!/bin/sh
      cat <<'SPECRELAY_ANALYZER_EOF'
      #{body}
      SPECRELAY_ANALYZER_EOF
      exit #{exit_code}
    SH
    FileUtils.chmod(0o755, path)
    path
  end

  def start_platform(payload)
    @platform = FakePlatform.new(claim_payload: payload).start
  end

  def build_config(external_reference_command: nil, external_references_available: nil,
                   external_references_substitute: nil)
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{@platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: test-runner
        display_name: Test Runner
        claim_policy:
          mode: all_eligible
        specification:
          provider:
            kind: fake
          repository_roots:
            "SpecRelay/SpecRelay-Specs": #{@specs}
          context_plus:
            available: true
          external_references:
            command: #{external_reference_command || '~'}
            available: #{external_references_available.nil? ? '~' : external_references_available}
            substitute: #{external_references_substitute.nil? ? '~' : external_references_substitute.to_json}
      workspace_roots:
        tiny-demo-workspace: #{@source}
    YAML
    SpecrelayRunner::Config.load(path)
  end

  def run_cli(config:)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{config.source_path}], out: @io, err: @io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] })
  end
end
