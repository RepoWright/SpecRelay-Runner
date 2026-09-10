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

  # MAPIAI-87 CR-001 F1 — `previous_accepted_package` is required and nullable, so an absent or
  # open-shaped one is a malformed ASSIGNMENT rather than "no previous implementation". It refuses
  # on this same path: before evidence, before the writer, before an isolated workspace, and
  # before any output file exists.
  def test_an_absent_previous_accepted_package_refuses_before_writing
    payload = spec_creation_payload_for(issue_key: ISSUE)
    payload.delete("previous_accepted_package")

    assert_refusal "assignment_malformed", payload: payload
    assert_includes @io.string, "previous_accepted_package"
  end

  def test_an_incomplete_previous_accepted_package_refuses_before_writing
    payload = spec_creation_payload_for(issue_key: ISSUE)
    payload["previous_accepted_package"] = { "package_id" => "art_previous123" }

    assert_refusal "assignment_malformed", payload: payload
    assert_includes @io.string, "is missing"
  end

  # MAPIAI-87 CR-002 F1 — an unknown key is attacker-controlled text, and THIS lane sends the raw
  # refusal message to Platform as durable evidence. A secret placed in a JSON key must therefore
  # not survive validation: nothing here may echo it into the operator log, the refusal payload,
  # or any other request this attempt makes.
  #
  # The key is deliberately not token-shaped, so this proves the validator never named it rather
  # than that {Redaction} masked it afterwards.
  SECRET_KEY = "x-SECRETVALUE-a3f9c1"

  def test_an_unknown_continuation_field_never_reaches_platform_or_the_operator
    payload = spec_creation_payload_for(issue_key: ISSUE)
    payload["previous_accepted_package"] = {
      "package_id" => "art_previous123", "checksum" => "c" * 64, "source_run_id" => "run_previous",
      "approved_specification" => { "reference" => "https://github.com/SpecRelay/SpecRelay-Specs/pull/6",
                                    "digest" => "d" * 64 },
      "implementation_pull_requests" => [], SECRET_KEY => "ghp_livetoken"
    }

    assert_refusal "assignment_malformed", payload: payload

    refute_includes @io.string, "SECRETVALUE"
    refute_includes @platform.requests.to_json, "SECRETVALUE"
    assert_includes @platform.last_specification_generation["message"], "previous_accepted_package"
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

  # MAPIAI-62 — the operator's specification folder is no longer a destination, so its
  # permissions no longer decide anything. What CAN stop a generation is this runner's own
  # state root, and that is a different refusal with a different remedy.
  def test_an_unwritable_runner_package_workspace_root_refuses
    root = SpecificationWorkspace.package_workspace_root(@temp)
    FileUtils.mkdir_p(root)
    FileUtils.chmod(0o500, root)
    assert_refusal "package_workspace_unavailable"
    assert_includes @io.string, SpecrelayRunner::Specification::PackageWorkspaceStore::DEFAULT_RELATIVE_PATH
  ensure
    FileUtils.chmod(0o755, root)
  end

  # review-001 F1 — the Runner's state root must be DISJOINT from the operator's checkouts.
  #
  # A root inside one of them put `swp_<id>/` into a repository the operator owns, which is the
  # exact defect this MVP exists to remove. Both checkouts are asserted on both probes: the
  # refusal has to leave the OTHER one alone too, and only comparing both would catch a fix that
  # merely moved the write.
  def test_a_package_workspace_root_inside_the_specification_seed_refuses_before_writing
    assert_disjoint_state_root_refusal(@specs)
  end

  def test_a_package_workspace_root_inside_the_source_checkout_refuses_before_writing
    assert_disjoint_state_root_refusal(@source)
  end

  # S04 — a seed with no resolvable commit refuses before any workspace or provider write.
  def test_a_seed_checkout_with_no_commit_refuses_before_creating_a_workspace
    FileUtils.remove_entry(@specs)
    FileUtils.mkdir_p(@specs)
    SpecificationWorkspace.git!(@specs, "init", "-q", "-b", "main")

    assert_refusal "package_workspace_unavailable"
    assert_empty SpecificationWorkspace.isolated_workspaces(@temp)
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

  def test_missing_graphify_wrappers_use_direct_source_inspection_without_a_substitute
    rebuild_source(graph: :missing)
    start_platform(spec_creation_payload_for(issue_key: ISSUE))
    exit_code = run_cli(config: build_config)

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    assert_includes provider_evidence, "Graphify is not installed for this checkout"
    warnings = @platform.last_specification_generation["warnings"]
    assert_includes warnings, "Graphify is not installed for this checkout; direct source inspection was used instead."
  end

  def test_a_partial_graphify_installation_still_refuses
    rebuild_source(graph: :fresh)
    FileUtils.rm(File.join(@source, "bin", "graph-query"))

    assert_refusal "graphify_unavailable"
    assert_includes @io.string, "incomplete or not executable"
  end

  def test_context_plus_neither_available_nor_substituted_continues_with_an_explicit_warning
    start_platform(spec_creation_payload_for(issue_key: ISSUE))
    config = build_config(context_plus: false)

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli(config: config), @io.string
    warning = "Context+ is not available on this runner; direct source inspection was used without " \
              "semantic Context+ evidence."
    assert_includes @platform.last_specification_generation["warnings"], warning
    tool = @platform.last_specification_generation["tool_evidence"]
             .find { |entry| entry["name"] == "context_plus" }
    refute tool["usable"]
    refute tool["contributed"]
  end

  # No selection at all — neither a local one nor one on the assignment — refuses. There is no
  # writer left to fall back to, which is the point.
  def test_an_assignment_with_no_selected_provider_refuses
    start_platform(spec_creation_payload_for(issue_key: ISSUE,
                                             specification_provider: { "profile" => nil, "executor" => nil }))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(config: build_config), @io.string
    assert_equal "generation_provider_unavailable",
                 @platform.last_specification_generation["failure_class"], @io.string
    assert_includes @io.string, "no specification generation provider is configured"
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
    # The property this protects — a substituted tool is recorded as having contributed nothing,
    # in the evidence a writer must work from — did not change; where it is asserted did, because
    # the composer that used to copy it verbatim is no longer a provider.
    assert_includes provider_evidence, "read the changed area directly"
    assert_includes provider_evidence, "contributed"
    refute @platform.last_specification_generation["warnings"].any? { |warning| warning.include?("not installed") }
  end

  def test_a_substituted_external_reference_is_a_warning_rather_than_a_refusal
    inputs = [ { "kind" => "confluence_page", "name" => "Reporting requirements",
                 "read_status" => "deferred_to_runner_mcp", "reason" => "deferred" } ]
    start_platform(spec_creation_payload_for(issue_key: ISSUE, inputs: inputs))
    exit_code = run_cli(config: build_config(external_references_substitute: "the reporter pasted the page inline"))

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    assert_includes provider_evidence, "Reporting requirements"
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
    # MAPIAI-62 — and it must not leave a Runner-owned workspace behind either. The workspace is
    # created as preflight's LAST step, so every refusal above happens before one exists.
    assert_empty SpecificationWorkspace.isolated_workspaces(@temp),
                 "a refusal must not create an isolated package workspace"
    generation = @platform.last_specification_generation
    refute_nil generation, "the refusal must be reported to Platform\n#{@io.string}"
    assert_equal "refused", generation["outcome"]
    assert_equal failure_class, generation["failure_class"], @io.string
    assert generation["zero_output_files_written"]
    assert_equal "rex_spec123", generation["runner_execution_id"]
    refute_empty generation["message"].to_s
    assert_empty @platform.requests_to("/api/runner/reports")
  end

  # review-001 F1 — refuse, write nothing into EITHER checkout, and leave both byte-identical
  # at the file level and at the git level.
  def assert_disjoint_state_root_refusal(state_root)
    start_platform(spec_creation_payload_for(issue_key: ISSUE))
    files = { specs: snapshot(@specs), source: snapshot(@source) }
    # Only the seed is a git checkout in this fixture; the source is a plain directory, so it is
    # compared at the file level alone.
    git = SpecificationWorkspace.git_state(@specs)

    exit_code = run_cli(config: build_config, state_root: state_root)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    generation = @platform.last_specification_generation
    assert_equal "package_workspace_unavailable", generation["failure_class"], @io.string
    assert generation["zero_output_files_written"]
    assert_empty Dir.glob("#{state_root}/**/swp_*", File::FNM_DOTMATCH),
                 "a generation must never create an isolated workspace inside an operator checkout"
    assert_equal files[:specs], snapshot(@specs)
    assert_equal files[:source], snapshot(@source)
    assert_equal git, SpecificationWorkspace.git_state(@specs)
  end

  def snapshot(root) = SpecificationWorkspace.checkout_snapshot(root)

  def read_package(name)
    File.read(File.join(SpecificationWorkspace.isolated_worktree(@temp),
                        "specs/SR-700-add-an-export-button", name))
  end

  def rebuild_source(graph:)
    FileUtils.remove_entry(@source)
    SpecificationWorkspace.build_source(@source, graph: graph)
  end

  def start_platform(payload)
    @platform = FakePlatform.new(claim_payload: payload).start
  end

  def build_config(repository_roots: true, repository_root_override: nil, workspace_root: nil,
                   context_plus: true, graphify_substitute: nil, external_references_substitute: nil)
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

  # The approved Claude profile's own bare name, first on the child PATH: the assignment carries
  # the exact profile Platform serves, so every test here crosses the real selection path.
  def provider_stub
    @provider_stub ||= SpecificationWorkspace.claude_stub(@temp,
                                                          files: SpecificationWorkspace.valid_documents(ISSUE),
                                                          capture_prompt_to: prompt_path)
  end

  def prompt_path = @prompt_path ||= File.join(@temp, "prompt.txt")

  # What the provider was actually handed. The recorded tool gaps used to be asserted against the
  # composer's own prose; the evidence they belong to is the packet, and this reads it there.
  def provider_evidence = File.read(prompt_path)

  def run_cli(config:, state_root: @temp)
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
            "PATH" => SpecificationWorkspace.provider_path(provider_stub) }
          .merge(SpecificationWorkspace.lane_env(state_root))
    SpecrelayRunner::CLI.run(%W[claim-once --config #{config.source_path}], out: @io, err: @io, env: env)
  end
end
