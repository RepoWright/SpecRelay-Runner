# frozen_string_literal: true

require_relative "test_helper"

# MVP-0026 criteria 5 and 6 — the runner refuses BEFORE writing anything.
#
# Every test here asserts the same three things about a different missing capability:
#
#   1. the run exits non-zero with the stable failure class for that capability;
#   2. the refusal reached Platform with an operator-actionable message and the zero-write
#      claim;
#   3. the specification checkout is byte-for-byte what it was before the claim.
#
# The third is the one that matters and is why these run through the real CLI against the
# real fake Platform rather than calling Preflight directly. "Preflight returned a refusal"
# is a statement about a method; "the destination directory is unchanged" is a statement
# about the operator's disk, and it is the one criterion 5 actually makes.
class SpecificationPreflightTest < Minitest::Test
  ISSUE = "SR-700"

  def setup
    @source, @specs, @temp = SpecificationWorkspace.build
    @io = StringIO.new
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@temp) if @temp && File.directory?(@temp)
  end

  # ------------------------------------------------------------- each required capability

  def test_a_malformed_assignment_refuses_before_writing
    payload = spec_creation_payload_for(issue_key: ISSUE)
    payload["specification_target"].delete("repository_url")

    assert_refusal "assignment_malformed", payload: payload
    assert_includes @io.string, "specification_target.repository_url"
  end

  # An incomplete bundle is refused rather than generated from with warnings. Platform will
  # not offer one, so a runner seeing it has been handed something its own Platform says is
  # not assignable.
  def test_an_incomplete_input_bundle_refuses_before_writing
    assert_refusal "assignment_malformed",
                   payload: spec_creation_payload_for(issue_key: ISSUE, complete: false)
    assert_includes @io.string, "not complete"
  end

  def test_an_unconfigured_specification_repository_refuses_and_names_the_variable
    assert_refusal "specification_repository_unresolved", repository_roots: false

    assert_includes @io.string, "SPECRELAY_RUNNER_SPEC_REPOSITORY_ROOT_SPECRELAY_SPECRELAY_SPECS"
  end

  def test_a_specification_repository_checkout_that_does_not_exist_refuses
    assert_refusal "specification_repository_unresolved",
                   repository_root_override: File.join(@temp, "no-such-checkout")
  end

  # A traversing specification folder must be REJECTED, not sanitized: a silently rewritten
  # destination is one the operator cannot predict.
  def test_an_unsafe_specification_folder_refuses
    assert_refusal "specification_folder_unsafe",
                   payload: spec_creation_payload_for(issue_key: ISSUE, specification_root: "../../etc")
    assert_includes @io.string, "may not traverse"
  end

  def test_an_absolute_specification_folder_refuses
    assert_refusal "specification_folder_unsafe",
                   payload: spec_creation_payload_for(issue_key: ISSUE, specification_root: "/etc/specs")
  end

  def test_an_unwritable_specification_folder_refuses
    FileUtils.chmod(0o500, File.join(@specs, "specs"))
    assert_refusal "specification_folder_unwritable"
  ensure
    FileUtils.chmod(0o755, File.join(@specs, "specs"))
  end

  def test_an_unresolvable_source_workspace_refuses
    assert_refusal "source_workspace_unresolved", workspace_root: File.join(@temp, "no-such-source")
    assert_includes @io.string, "grounded in the real source checkout"
  end

  # An input Platform classified as unusable must not be written around. The bundle is
  # complete overall, so this models a bundle that disagrees with itself.
  def test_input_content_that_cannot_be_read_refuses
    inputs = [ { "kind" => "description", "name" => "Jira description", "read_status" => "available",
                 "reason" => "read from the Jira issue" },
               { "kind" => "attachment", "name" => "requirements.docx", "read_status" => "unsupported",
                 "reason" => "SpecRelay cannot read that media type" } ]

    assert_refusal "input_content_unreadable", payload: spec_creation_payload_for(issue_key: ISSUE, inputs: inputs)
    assert_includes @io.string, "requirements.docx"
  end

  def test_a_deferred_external_reference_with_no_capability_refuses
    inputs = [ { "kind" => "confluence_page", "name" => "Reporting requirements",
                 "read_status" => "deferred_to_runner_mcp",
                 "reason" => "an external reference a later capability must read" } ]

    assert_refusal "external_reference_analysis_unavailable",
                   payload: spec_creation_payload_for(issue_key: ISSUE, inputs: inputs)
    assert_includes @io.string, "external_references.substitute"
  end

  def test_a_deferred_image_with_no_capability_refuses
    inputs = [ { "kind" => "screenshot", "name" => "export-mockup.png", "media_type" => "image/png",
                 "read_status" => "deferred_to_runner_mcp", "reason" => "an image a later capability must analyse" } ]

    assert_refusal "external_reference_analysis_unavailable",
                   payload: spec_creation_payload_for(issue_key: ISSUE, inputs: inputs)
    assert_includes @io.string, "image analysis"
  end

  def test_a_stale_graph_with_no_substitute_refuses
    rebuild_source(graph: :stale)

    assert_refusal "graphify_unavailable"
    assert_includes @io.string, "STALE"
    assert_includes @io.string, "graphify.substitute"
  end

  def test_missing_graphify_wrappers_with_no_substitute_refuse
    rebuild_source(graph: :missing)

    assert_refusal "graphify_unavailable"
    assert_includes @io.string, "bin/graph-check"
  end

  def test_context_plus_neither_available_nor_substituted_refuses
    assert_refusal "context_plus_unavailable", context_plus: false
    assert_includes @io.string, "context_plus.substitute"
  end

  def test_a_configured_provider_command_that_is_missing_refuses
    assert_refusal "generation_provider_unavailable",
                   provider: { kind: "command", command: File.join(@temp, "no-such-provider") }
    assert_includes @io.string, "not an executable file"
  end

  def test_a_command_provider_with_no_command_configured_refuses
    assert_refusal "generation_provider_unavailable", provider: { kind: "command" }
    assert_includes @io.string, "SPECRELAY_RUNNER_SPEC_PROVIDER_COMMAND"
  end

  # The redaction guard is a precondition of writing, so it is verified rather than assumed.
  # Stubbing it into a no-op is the only way to reach this branch, and reaching it is the
  # point: an unverified precondition is a comment, not a check.
  def test_a_redaction_guard_that_does_not_redact_refuses
    with_broken_redaction { assert_refusal "redaction_validation_unavailable" }
  end

  # Replaces the redactor with a pass-through for the duration of one test, and always puts
  # the real one back. This repository has no mocking library on purpose, so the swap is
  # explicit rather than hidden behind a stub DSL.
  def with_broken_redaction
    original = SpecrelayRunner::Redaction.method(:redact)
    SpecrelayRunner::Redaction.define_singleton_method(:redact) { |text| text }
    yield
  ensure
    SpecrelayRunner::Redaction.define_singleton_method(:redact, original)
  end

  # ------------------------------------------------------------------ substituted paths

  # The mirror image of the refusals above: a recorded substitute lets generation proceed,
  # and the gap is written into the evidence rather than hidden. Without this, every
  # "substitute" branch above would be untested in its successful direction.
  def test_a_recorded_substitute_lets_generation_proceed_and_is_recorded
    rebuild_source(graph: :stale)
    start_platform(spec_creation_payload_for(issue_key: ISSUE))
    exit_code = run_cli(config: build_config(graphify_substitute: "read the changed area directly"))

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    technical = File.read(File.join(@specs, "specs", "SR-700-add-an-export-button", "analysis", "technical.md"))
    assert_includes technical, "read the changed area directly"
    # See the note in specification_generation_test.rb: the verdict vocabulary changed under
    # CR-001 must-fix 2; the property this line protects — a substituted tool is recorded as
    # having contributed nothing — did not.
    assert_includes technical, "Result: did NOT contribute evidence"
  end

  def test_a_substituted_external_reference_is_a_warning_rather_than_a_refusal
    inputs = [ { "kind" => "confluence_page", "name" => "Reporting requirements",
                 "read_status" => "deferred_to_runner_mcp", "reason" => "deferred" } ]
    start_platform(spec_creation_payload_for(issue_key: ISSUE, inputs: inputs))
    exit_code = run_cli(config: build_config(external_references_substitute: "the reporter pasted the page inline"))

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    business = File.read(File.join(@specs, "specs", "SR-700-add-an-export-button", "analysis", "business.md"))
    assert_includes business, "Needs product clarification"
    assert_includes business, "Reporting requirements"
    warnings = @platform.last_specification_generation["warnings"]
    assert warnings.any? { |warning| warning.include?("Reporting requirements") }, warnings.inspect
  end

  # ------------------------------------------------------------------------- helpers

  # Asserts the whole refusal contract for one capability, including the thing that actually
  # matters: the destination is untouched.
  def assert_refusal(failure_class, payload: nil, **config_options)
    start_platform(payload || spec_creation_payload_for(issue_key: ISSUE))
    before = snapshot(@specs)

    exit_code = run_cli(config: build_config(**config_options))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    assert_equal before, snapshot(@specs), "preflight must not create or modify any output file"
    generation = @platform.last_specification_generation
    refute_nil generation, "the refusal must be reported to Platform\n#{@io.string}"
    assert_equal "refused", generation["outcome"]
    assert_equal failure_class, generation["failure_class"], @io.string
    assert generation["zero_output_files_written"]
    assert_equal "rex_spec123", generation["runner_execution_id"]
    refute_empty generation["message"].to_s
    assert_empty @platform.requests_to("/api/runner/reports")
  end

  def snapshot(root)
    Dir.glob("#{root}/**/*", File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort.to_h do |path|
      [ path.delete_prefix("#{root}/"), Digest::SHA256.hexdigest(File.binread(path)) ]
    end
  end

  def rebuild_source(graph:)
    FileUtils.remove_entry(@source)
    SpecificationWorkspace.build_source(@source, graph: graph)
  end

  def start_platform(payload)
    @platform = FakePlatform.new(claim_payload: payload).start
  end

  def build_config(repository_roots: true, repository_root_override: nil, workspace_root: nil,
                   context_plus: true, graphify_substitute: nil, external_references_substitute: nil,
                   provider: { kind: "fake" })
    root = repository_root_override || @specs
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
            kind: #{provider.fetch(:kind)}
            command: #{provider[:command] || '~'}
          repository_roots:
            #{repository_roots ? "\"SpecRelay/SpecRelay-Specs\": #{root}" : '{}'}
          context_plus:
            available: #{context_plus}
          graphify:
            substitute: #{graphify_substitute.nil? ? '~' : graphify_substitute.to_json}
          external_references:
            substitute: #{external_references_substitute.nil? ? '~' : external_references_substitute.to_json}
      workspace_roots:
        tiny-demo-workspace: #{workspace_root || @source}
    YAML
    SpecrelayRunner::Config.load(path)
  end

  def run_cli(config:)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{config.source_path}], out: @io, err: @io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] })
  end
end
