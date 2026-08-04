# frozen_string_literal: true

require_relative "test_helper"

# MVP-0026 scope 9 — the generation-provider boundary.
#
# Exercised through the CONFIGURED COMMAND provider rather than the built-in composer,
# because the properties under test are properties of the boundary, not of the writer behind
# it: what crosses it going in, what is accepted coming back, and what happens to the
# destination when a provider misbehaves. The built-in composer can never return malformed
# output, so a test that used it would prove the validation runs, not that it works.
class SpecificationProviderTest < Minitest::Test
  ISSUE = "SR-700"
  PACKAGE_DIR = "SR-700-add-an-export-button"

  def setup
    @source, @specs, @temp = SpecificationWorkspace.build
    @platform = FakePlatform.new(claim_payload: spec_creation_payload_for(issue_key: ISSUE)).start
    @io = StringIO.new
  end

  def teardown
    @platform.stop
    FileUtils.remove_entry(@temp) if @temp && File.directory?(@temp)
  end

  # ------------------------------------------------------- the operator-facing vocabulary

  # CR-001 should-fix 6. The default provider was CONFIGURED as `fake` and REPORTED itself as
  # `composed`, so the diagnostics Platform persists told an operator that the intended
  # production path was a fake. One vocabulary, and this asserts the two halves agree rather
  # than trusting that they happen to.
  # EVERY kind, including `command`. CR-002 should-fix 6.2: this test used to `next` past
  # `command`, so "asserts it for every kind" was true of two kinds out of three — and
  # `command` is the one whose resolution can actually fail, because it builds an executable.
  def test_the_configured_provider_kind_and_the_resolved_provider_agree
    command = SpecificationWorkspace.write_provider(File.join(@temp, "agreement-provider"),
                                                    files: valid_documents)

    { "composed" => "composed", "fake" => "composed", "command" => "command" }.each do |configured, resolved|
      settings = settings_for(configured, command: command)

      assert_equal resolved, settings.provider_kind, "configured #{configured.inspect}"
      assert_equal settings.provider_kind,
                   SpecrelayRunner::Specification::Provider.resolve(settings: settings).kind,
                   "resolved provider disagrees with the configured kind for #{configured.inspect}"
    end
  end

  # `fake` stays accepted so an operator's existing config keeps working; it normalizes on the
  # way in, so nothing downstream ever sees the old word.
  def test_the_legacy_fake_alias_is_accepted_and_normalized
    assert_equal "composed", settings_for("fake").provider_kind
    assert settings_for("fake").composed_provider?
  end

  # The ENVIRONMENT path had no coverage at all, and it is the one a guided connection uses —
  # a guided connection writes no YAML, so `SPECRELAY_RUNNER_SPEC_PROVIDER` is the only way it
  # can name a provider.
  def test_the_provider_kind_environment_override_is_read_and_normalized
    env = { SpecrelayRunner::Specification::Settings::PROVIDER_KIND_ENV => "fake" }
    settings = SpecrelayRunner::Specification::Settings.new({}, env: env)

    assert_equal "composed", settings.provider_kind
    assert_equal "composed", SpecrelayRunner::Specification::Provider.resolve(settings: settings).kind
  end

  def test_the_environment_override_wins_over_the_config_file
    env = { SpecrelayRunner::Specification::Settings::PROVIDER_KIND_ENV => "composed" }
    settings = SpecrelayRunner::Specification::Settings.new({ "provider" => { "kind" => "command" } }, env: env)

    assert_equal "composed", settings.provider_kind
  end

  def test_an_unknown_provider_kind_in_the_environment_is_refused_by_name
    env = { SpecrelayRunner::Specification::Settings::PROVIDER_KIND_ENV => "magic" }
    error = assert_raises(SpecrelayRunner::Specification::Settings::Error) do
      SpecrelayRunner::Specification::Settings.new({}, env: env)
    end

    assert_includes error.message, "composed, command"
  end

  def test_an_unknown_provider_kind_is_refused_by_name
    error = assert_raises(SpecrelayRunner::Specification::Settings::Error) { settings_for("magic") }

    assert_includes error.message, "composed, command"
  end

  def settings_for(kind, command: nil)
    provider = { "kind" => kind }
    provider["command"] = command if command
    SpecrelayRunner::Specification::Settings.new({ "provider" => provider }, env: {})
  end

  # ------------------------------------------------------------------ what goes in

  def test_the_packet_carries_sanitized_bundle_and_source_evidence
    capture = File.join(@temp, "packet.json")
    provider = SpecificationWorkspace.write_recording_provider(
      File.join(@temp, "provider"), capture_to: capture, files: valid_documents
    )

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_with(provider), @io.string

    packet = JSON.parse(File.read(capture))
    assert_equal ISSUE, packet.dig("issue", "key")
    assert_includes packet.dig("input_bundle", "content_markdown"), "retype it by hand"
    assert_includes packet.dig("source", "entry_points"), "app/services/export_report.rb"
    assert_equal "specs/#{PACKAGE_DIR}", packet.dig("package", "relative_path")
    assert packet["tool_evidence"].any? { |tool| tool["name"] == "graphify" && tool["contributed"] }
  end

  # Criterion 11, asserted at the point it matters most: the boundary is where content leaves
  # this process for something the operator configured and SpecRelay did not write.
  def test_no_secret_or_host_path_crosses_the_boundary
    capture = File.join(@temp, "packet.json")
    payload = spec_creation_payload_for(
      issue_key: ISSUE,
      content: "# Bundle\n\nThe integration uses api_key=sk-live-abcdef1234567890 and " \
               "https://user:s3cr3t@internal.example.com/reports for the nightly pull.\n"
    )
    restart_platform(payload)
    provider = SpecificationWorkspace.write_recording_provider(
      File.join(@temp, "provider"), capture_to: capture, files: valid_documents
    )
    run_with(provider)

    packet = File.read(capture)
    refute_includes packet, "sk-live-abcdef1234567890"
    refute_includes packet, "s3cr3t"
    assert_includes packet, "[REDACTED]"
    # And no absolute path describing this machine.
    [ @specs, @source, Dir.home ].each { |path| refute_includes packet, path }
  end

  # ---------------------------------------------------------------- what comes back

  def test_a_provider_failure_leaves_no_partial_package
    provider = SpecificationWorkspace.write_provider(File.join(@temp, "provider"),
                                                     files: {}, exit_code: 1, stdout: "boom")

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_with(provider), @io.string
    assert_empty Dir.children(File.join(@specs, "specs")), "no package, and no staging leftovers"
    assert_equal "generation_provider_failed", @platform.last_specification_generation["failure_class"]
    assert_equal "failed", @platform.last_specification_generation["outcome"]
  end

  def test_output_missing_a_required_section_is_rejected_before_anything_is_written
    documents = valid_documents
    documents["spec.md"] = documents["spec.md"].sub(/^## Acceptance criteria$.*?(?=^## )/m, "")
    provider = SpecificationWorkspace.write_provider(File.join(@temp, "provider"), files: documents)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_with(provider), @io.string
    assert_empty Dir.children(File.join(@specs, "specs"))
    assert_equal "generated_output_invalid", @platform.last_specification_generation["failure_class"]
    assert_includes @io.string, "## Acceptance criteria"
  end

  def test_output_missing_a_required_file_is_rejected
    documents = valid_documents
    documents.delete("analysis/technical.md")
    provider = SpecificationWorkspace.write_provider(File.join(@temp, "provider"), files: documents)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_with(provider), @io.string
    assert_empty Dir.children(File.join(@specs, "specs"))
    assert_includes @io.string, "analysis/technical.md"
  end

  # MVP-0028 remediation, defect 10 — the live MAPIAI-53 revision, at the real boundary.
  #
  # The provider returned a `technical.md` whose title was its own first section name, with its
  # instructions narrated underneath. Every required `##` section was present, so the package was
  # written, digested, reported to Platform, and became publishable. These prove the whole chain
  # now stops at the same place a missing section stops it: before anything reaches disk.
  def test_a_document_titled_with_a_section_name_is_rejected_before_anything_is_written
    documents = valid_documents
    documents["analysis/technical.md"] = documents["analysis/technical.md"]
      .sub(/\A# .*$/, "# Source entry points inspected\n\n(placeholder-free content follows)")
    provider = SpecificationWorkspace.write_provider(File.join(@temp, "provider"), files: documents)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_with(provider), @io.string
    assert_empty Dir.children(File.join(@specs, "specs")), "no package, and no staging leftovers"
    assert_equal "generated_output_invalid", @platform.last_specification_generation["failure_class"]
    assert_includes @io.string, "analysis/technical.md"
  end

  # The refusal must reach Platform as a REFUSAL, not as a generation that produced something.
  # A package Platform believes exists is a package Platform will offer for publication.
  def test_a_malformed_document_never_becomes_publishable
    documents = valid_documents
    documents["analysis/technical.md"] = documents["analysis/technical.md"]
      .sub(/\A# .*$/, "# Source entry points inspected")
    provider = SpecificationWorkspace.write_provider(File.join(@temp, "provider"), files: documents)

    run_with(provider)

    generation = @platform.last_specification_generation
    assert_equal "failed", generation["outcome"]
    assert generation["zero_output_files_written"], generation.inspect
    assert_nil generation["package"], "a refused generation must record no package to publish"
  end

  def test_provider_scaffolding_in_a_document_is_rejected_before_anything_is_written
    documents = valid_documents
    documents["analysis/business.md"] = documents["analysis/business.md"]
      .sub("\n\n##", "\n\n(placeholder-free content follows)\n\n##")
    provider = SpecificationWorkspace.write_provider(File.join(@temp, "provider"), files: documents)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_with(provider), @io.string
    assert_empty Dir.children(File.join(@specs, "specs"))
    assert_includes @io.string, "scaffolding"
  end

  # MVP-0028 remediation, defect 3 — the input-evidence file is REQUIRED, not conditional; only
  # the open-questions file is optional.
  def test_missing_input_evidence_is_rejected
    documents = valid_documents
    documents.delete("analysis/input-evidence.md")
    provider = SpecificationWorkspace.write_provider(File.join(@temp, "provider"), files: documents)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_with(provider), @io.string
    assert_empty Dir.children(File.join(@specs, "specs"))
    assert_includes @io.string, "analysis/input-evidence.md"
  end

  # The optional file is accepted when present and structurally valid, and its digest is
  # written alongside the required four.
  def test_a_present_and_valid_open_questions_file_is_accepted
    documents = valid_documents.merge(
      "analysis/open-questions.md" => "# Open questions\n\n## OQ-001\n\n- Why it blocks: the ticket " \
                                       "does not say.\n- Decision required: confirm the scope.\n" \
                                       "- Consequence: an implementer would guess.\n"
    )
    provider = SpecificationWorkspace.write_provider(File.join(@temp, "provider"), files: documents)

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_with(provider), @io.string
    assert File.exist?(File.join(@specs, "specs", PACKAGE_DIR, "analysis", "open-questions.md"))
    generation = @platform.last_specification_generation
    assert generation.dig("package", "files").any? { |file| file["path"] == "analysis/open-questions.md" },
          generation.inspect
  end

  # A present `open-questions.md` with no "## OQ-nnn" heading contradicts its own existence and
  # is rejected before anything is written — the same fail-closed standard every other
  # structural gap in this boundary gets.
  def test_an_open_questions_file_with_no_question_heading_is_rejected
    documents = valid_documents.merge(
      "analysis/open-questions.md" => "# Open questions\n\nNothing here names a question, but this " \
                                       "text is long enough to clear the minimum length floor.\n"
    )
    provider = SpecificationWorkspace.write_provider(File.join(@temp, "provider"), files: documents)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_with(provider), @io.string
    assert_empty Dir.children(File.join(@specs, "specs"))
    assert_includes @io.string, "names no open question"
  end

  # Review 006 finding F1, at the boundary rather than in the DocumentSet unit tests: a question
  # missing "Decision required" used to pass this same CLI path and reach Platform with an
  # arbitrary bullet standing in for the decision. It is rejected before anything is written now,
  # exactly like every other structural gap this boundary already refuses.
  def test_an_open_questions_file_missing_decision_required_is_rejected
    documents = valid_documents.merge(
      "analysis/open-questions.md" => "# Open questions\n\n## OQ-001\n\n- Why it blocks: the ticket " \
                                       "does not say.\n- Consequence: an implementer would guess.\n"
    )
    provider = SpecificationWorkspace.write_provider(File.join(@temp, "provider"), files: documents)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_with(provider), @io.string
    assert_empty Dir.children(File.join(@specs, "specs"))
    assert_includes @io.string, "missing required field(s): decision required"
  end

  # And the other half of F1: a fourth, unlabelled bullet is rejected rather than silently
  # ignored — the closed set of three fields is enforced, not just their presence.
  def test_an_open_questions_file_with_an_extra_field_is_rejected
    documents = valid_documents.merge(
      "analysis/open-questions.md" => "# Open questions\n\n## OQ-001\n\n- Why it blocks: the ticket " \
                                       "does not say.\n- Decision required: confirm the scope.\n" \
                                       "- Consequence: an implementer would guess.\n- Owner: PO\n"
    )
    provider = SpecificationWorkspace.write_provider(File.join(@temp, "provider"), files: documents)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_with(provider), @io.string
    assert_empty Dir.children(File.join(@specs, "specs"))
    assert_includes @io.string, "unexpected field: owner"
  end

  # A provider must not be able to choose its own output paths: that is how a package escapes
  # its folder. The allowlist rejects the file rather than sanitizing the name.
  def test_a_provider_that_returns_an_unexpected_file_is_rejected
    documents = valid_documents.merge("../../escaped.md" => "x" * 500)
    provider = SpecificationWorkspace.write_provider(File.join(@temp, "provider"), files: documents)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_with(provider), @io.string
    assert_empty Dir.children(File.join(@specs, "specs"))
    refute File.exist?(File.join(@temp, "escaped.md"))
    assert_includes @io.string, "unexpected files"
  end

  def test_non_json_provider_output_is_rejected
    provider = SpecificationWorkspace.write_provider(File.join(@temp, "provider"),
                                                     files: {}, stdout: "<html>not json</html>")

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_with(provider), @io.string
    assert_equal "generation_provider_failed", @platform.last_specification_generation["failure_class"]
    assert_includes @io.string, "valid JSON"
  end

  # A provider CAN return a secret — it may have quoted its own configuration, or echoed an
  # input. The file that lands on disk must not contain it, and the run must say so.
  def test_a_secret_in_provider_output_is_redacted_before_the_file_is_written
    documents = valid_documents
    documents["spec.md"] = documents["spec.md"].sub("## Problem\n",
                                                    "## Problem\n\nUse token=ghp_abcdefghijklmnop1234 to call it.\n")
    provider = SpecificationWorkspace.write_provider(File.join(@temp, "provider"), files: documents)

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_with(provider), @io.string
    written = File.read(File.join(@specs, "specs", PACKAGE_DIR, "spec.md"))
    refute_includes written, "ghp_abcdefghijklmnop1234"
    assert_includes written, "[REDACTED]"
    warnings = @platform.last_specification_generation["warnings"]
    assert warnings.any? { |warning| warning.include?("redacted") }, warnings.inspect
  end

  # A host path in generated output has no legitimate source, so it is a hard failure rather
  # than something to redact — and, like every other failure after staging, it leaves the
  # destination untouched.
  def test_a_host_path_in_provider_output_fails_without_writing
    documents = valid_documents
    documents["analysis/technical.md"] += "\nInspected at #{@source}/app/services/export_report.rb\n"
    provider = SpecificationWorkspace.write_provider(File.join(@temp, "provider"), files: documents)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_with(provider), @io.string
    assert_empty Dir.children(File.join(@specs, "specs"))
    generation = @platform.last_specification_generation
    assert_equal "package_write_failed", generation["failure_class"]
    # CR-001 must-fix 3 AC 2: a failure BEFORE the rename still reports zero output files, and
    # this is now the computed answer rather than a hardcoded one. Keeping the assertion is the
    # point — the fix must not turn every write failure into "something might be on disk".
    assert generation["zero_output_files_written"], generation.inspect
    assert_includes @io.string, "private host filesystem path"
  end

  # ------------------------------------------------------------------------ helpers

  # A minimal but STRUCTURALLY VALID package: every required section present with enough body
  # to clear the emptiness floor. Deliberately not composer output — these tests are about
  # what the boundary accepts from something SpecRelay did not write.
  def valid_documents
    {
      "spec.md" => document(SpecrelayRunner::Specification::DocumentSet::REQUIRED_SECTIONS
                              .fetch("spec.md"), "Specification for #{ISSUE}"),
      "analysis/input-evidence.md" => "# Input evidence for #{ISSUE}\n\n" \
                                       "No supporting input beyond the Jira ticket was recorded.\n",
      "analysis/business.md" => document(SpecrelayRunner::Specification::DocumentSet::REQUIRED_SECTIONS
                                           .fetch("analysis/business.md"), "Business analysis for #{ISSUE}"),
      "analysis/technical.md" => document(SpecrelayRunner::Specification::DocumentSet::REQUIRED_SECTIONS
                                            .fetch("analysis/technical.md"), "Technical analysis for #{ISSUE}")
    }
  end

  def document(sections, title)
    body = sections.map do |section|
      "## #{section}\n\nSubstantive content for the #{section} section of #{ISSUE}, long enough to " \
        "clear the minimum body length the validator enforces.\n"
    end
    "# #{title}\n\n#{body.join("\n")}"
  end

  def restart_platform(payload)
    @platform.stop
    @platform = FakePlatform.new(claim_payload: payload).start
  end

  def run_with(provider_command)
    config = build_config(provider_command)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{config.source_path}], out: @io, err: @io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] })
  end

  def build_config(provider_command)
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
            kind: command
            command: #{provider_command}
            timeout_seconds: 60
          repository_roots:
            "SpecRelay/SpecRelay-Specs": #{@specs}
          context_plus:
            available: true
      workspace_roots:
        tiny-demo-workspace: #{@source}
    YAML
    SpecrelayRunner::Config.load(path)
  end
end
