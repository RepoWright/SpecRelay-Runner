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
    assert_equal "package_write_failed", @platform.last_specification_generation["failure_class"]
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
