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

  # ------------------------------------------------------------------ F1: a blank/missing/wrong-typed
  # ------------------------------------------------------------------ summary must not be readable

  # review-005 finding F1, reproduced at the integration level: an analyzer that claims success
  # with nothing behind it used to be accepted as though the reference had genuinely been read.
  def test_a_contributed_claim_with_a_blank_summary_refuses_rather_than_being_readable
    analyzer = write_analyzer(File.join(@temp, "analyzer"), response: { "contributed" => true, "summary" => "" })
    start_platform(deferred_reference_payload)

    exit_code = run_cli(config: build_config(external_reference_command: analyzer))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    generation = @platform.last_specification_generation
    assert_equal "external_reference_analysis_unavailable", generation["failure_class"]
    assert_includes generation["message"], "no usable summary"
  end

  def test_a_contributed_claim_with_a_missing_summary_key_refuses
    analyzer = write_analyzer(File.join(@temp, "analyzer"), response: { "contributed" => true })
    start_platform(deferred_reference_payload)

    exit_code = run_cli(config: build_config(external_reference_command: analyzer))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    assert_equal "external_reference_analysis_unavailable", @platform.last_specification_generation["failure_class"]
  end

  def test_a_contributed_claim_with_a_non_string_summary_refuses
    analyzer = write_analyzer(File.join(@temp, "analyzer"), response: { "contributed" => true, "summary" => 42 })
    start_platform(deferred_reference_payload)

    exit_code = run_cli(config: build_config(external_reference_command: analyzer))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    assert_equal "external_reference_analysis_unavailable", @platform.last_specification_generation["failure_class"]
  end

  # A recorded substitute is the existing approved policy and must still apply even to THIS
  # failure mode — F1 item 3.
  def test_a_contributed_claim_with_a_blank_summary_and_a_recorded_substitute_still_only_warns
    analyzer = write_analyzer(File.join(@temp, "analyzer"), response: { "contributed" => true, "summary" => "" })
    start_platform(deferred_reference_payload)

    exit_code = run_cli(config: build_config(external_reference_command: analyzer,
                                             external_references_substitute: "the reporter described it in the ticket"))

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
  end

  # ------------------------------------------------------------------ F2: the ordinary Claude path

  # review-005 finding F2 — the ordinary connected Runner, with a real Claude profile already
  # configured for generation and NO analyzer command, must be able to analyse a reference with
  # nothing further to install or configure.
  def test_the_ordinary_configured_claude_profile_analyses_the_reference_with_no_extra_configuration
    claude = write_fake_claude(File.join(@temp, "claude"),
                               response: { "contributed" => true,
                                          "summary" => "Claude read the reference via its own tool access." })
    start_platform(deferred_reference_payload)

    exit_code = run_cli(config: build_config(claude_command: claude))

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    assert_includes spec_document, "Claude read the reference via its own tool access."
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

  # A minimal double for the real Claude Code CLI: it must be literally named `claude` for
  # {SpecrelayRunner::ClaudeProfile} validation, and it ignores its prompt argument entirely —
  # this test's only Claude invocation is the reference analysis, since generation is configured
  # to use the deterministic `fake` provider explicitly.
  def write_fake_claude(path, response:)
    File.write(path, <<~SH)
      #!/bin/sh
      cat <<'SPECRELAY_FAKE_CLAUDE_EOF'
      #{JSON.generate(response)}
      SPECRELAY_FAKE_CLAUDE_EOF
      exit 0
    SH
    FileUtils.chmod(0o755, path)
    path
  end

  def start_platform(payload)
    @platform = FakePlatform.new(claim_payload: payload).start
  end

  def build_config(external_reference_command: nil, external_references_available: nil,
                   external_references_substitute: nil, claude_command: nil)
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
        #{executor_block(claude_command)}
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

  # The SAME real Claude profile a fixed D1 would use for generation — configured here purely so
  # the reference analyzer can be offered it, with `specification.provider.kind: fake` above
  # keeping generation itself on the deterministic composer.
  def executor_block(claude_command)
    return "" if claude_command.nil?

    <<~YAML.strip
      executor:
          provider: claude
          command: #{claude_command}
          args: ["--print", "--dangerously-skip-permissions"]
    YAML
  end

  def run_cli(config:)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{config.source_path}], out: @io, err: @io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] })
  end
end
