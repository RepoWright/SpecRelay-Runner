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

  def deferred_reference_payload(name: "Export flow recording", provider: nil)
    inputs = [ { "kind" => "jam_recording", "name" => name, "reference" => REFERENCE_URL,
                 "read_status" => "deferred_to_runner_mcp",
                 "reason" => "a Jam recording a later capability must analyse" } ]
    selection = provider && { "profile" => provider,
                              "executor" => SpecrelayRunner::ImplementationProfile.canonical(provider) }
    spec_creation_payload_for(issue_key: ISSUE, inputs: inputs, specification_provider: selection)
  end

  # The per-input table — kind, name, recorded read status, used?, and the note this
  # remediation makes truthful — is `spec.md`'s "Input summary" section, not business.md's.
  def spec_document
    File.read(File.join(SpecificationWorkspace.isolated_worktree(@temp),
                        "specs/SR-700-add-an-export-button", "spec.md"))
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

  # The exact defect this closes: an operator-set `available: true` was enough on its own to mark
  # a deferred reference readable, with nothing ever analysed. The flag decides nothing now — the
  # only thing that can is an analysis this runner actually performed and could use.
  def test_available_true_alone_cannot_make_a_reference_readable
    start_platform(deferred_reference_payload)

    exit_code = run_cli(config: build_config(external_references_available: true))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    generation = @platform.last_specification_generation
    assert_equal "external_reference_analysis_unavailable", generation["failure_class"]
    assert_includes generation["message"], "external_references.substitute"
  end

  # A project whose selected provider is Codex has no external-reference analyzer at all: that
  # analyzer is a separate optional capability with a Claude-only implementation, and this slice
  # adds no second one. The existing explicit refusal — and its substitute remedy — is what such a
  # runner gets, rather than a silently unanalysed reference.
  def test_a_codex_selected_project_keeps_the_explicit_refusal_for_a_deferred_reference
    start_platform(deferred_reference_payload(provider: SpecrelayRunner::CodexProfile::PROVIDER))

    exit_code = run_cli(config: build_config, provider: :codex)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    generation = @platform.last_specification_generation
    assert_equal "external_reference_analysis_unavailable", generation["failure_class"]
    assert_includes generation["message"], "external_references.substitute"
  end

  # And the approved way through it: a recorded substitute lets a Codex-selected runner generate,
  # with the gap stated rather than hidden.
  def test_a_codex_selected_project_proceeds_on_a_recorded_substitute
    start_platform(deferred_reference_payload(provider: SpecrelayRunner::CodexProfile::PROVIDER))

    exit_code = run_cli(config: build_config(external_references_substitute: "the reporter described the flow"),
                        provider: :codex)

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    assert_includes spec_document, "Export flow recording"
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
    start_platform(deferred_reference_payload)

    exit_code = run_cli(config: build_config,
                        analyzer_response: { "contributed" => true,
                                            "summary" => "Claude read the reference via its own tool access." })

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

  # ------------------------------------------------------------------ F3: a private host path must not
  # ------------------------------------------------------------------ reach the packet, payload, or logs

  # review-005 finding F3, pinned to the exact live MAPIAI-52 shape the reviewer found: a
  # contributed summary naming the analyst's own host filesystem path. Proven through the whole
  # InputEvidence/generation path, not only against `ReferenceAnalyzer.evaluate` — the private
  # path must not reach the generated document, the CLI's own stdout log, or the Platform
  # generation payload the runner reports back, and the rest of the analysis must still survive.
  LIVE_MAPIAI_52_SUMMARY =
    "The 32-second video Jam (page: SpecRelay Runner Setup Verified, at " \
    "file:///Users/hrmohsen/dev/Teal-managments/tiny-demo-workspace/demo-app/index.html) is a " \
    "voiceover-only walkthrough with no UI interactions: the reporter states they want the " \
    "heading text 'SpecRelay Runner Setup Verified' repositioned to be centered both " \
    "horizontally and vertically on the page."

  def test_a_private_host_path_in_an_analyzer_summary_never_reaches_the_packet_payload_or_logs
    analyzer = write_analyzer(File.join(@temp, "analyzer"),
                              response: { "contributed" => true, "summary" => LIVE_MAPIAI_52_SUMMARY })
    start_platform(deferred_reference_payload)

    exit_code = run_cli(config: build_config(external_reference_command: analyzer))

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    refute_includes spec_document, "/Users/hrmohsen"
    refute_includes @io.string, "/Users/hrmohsen"
    generation = @platform.last_specification_generation
    refute_includes generation.to_s, "/Users/hrmohsen"
    assert_includes spec_document, "voiceover-only walkthrough"
    assert_includes spec_document, "centered both horizontally and vertically"
  end

  def test_a_plain_absolute_local_path_in_an_analyzer_summary_is_sanitized_end_to_end
    analyzer = write_analyzer(File.join(@temp, "analyzer"),
                              response: { "contributed" => true,
                                         "summary" => "found the flow documented at /Users/operator/notes/export.md" })
    start_platform(deferred_reference_payload)

    exit_code = run_cli(config: build_config(external_reference_command: analyzer))

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    refute_includes spec_document, "/Users/operator"
    generation = @platform.last_specification_generation
    refute_includes generation.to_s, "/Users/operator"
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

  # ONE `claude` double serves both questions this profile is asked: it composes the package for
  # the generation prompt, and — when `analyzer_response` is set — answers the optional
  # external-reference analysis with that verdict. That is the production shape: a project whose
  # selected provider is Claude has the same profile available for both, and the analyzer is a
  # separate optional capability rather than a second selection.
  def provider_stub(analyzer_response = nil, provider: :claude)
    @provider_stub ||= build_provider_stub(analyzer_response, provider)
  end

  def build_provider_stub(analyzer_response, provider)
    return SpecificationWorkspace.codex_stub(@temp, compose: true) if provider == :codex

    SpecificationWorkspace.claude_stub(@temp, compose: true,
                                              analyzer_answer: analyzer_response &&
                                                JSON.generate(analyzer_response))
  end

  def run_cli(config:, analyzer_response: nil, provider: :claude)
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
            "PATH" => SpecificationWorkspace.provider_path(provider_stub(analyzer_response, provider: provider)) }
          .merge(SpecificationWorkspace.lane_env(@temp))
    SpecrelayRunner::CLI.run(%W[claim-once --config #{config.source_path}], out: @io, err: @io, env: env)
  end
end
