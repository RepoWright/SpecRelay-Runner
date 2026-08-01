# frozen_string_literal: true

require_relative "test_helper"

# MVP-0026 — the runner turns a claimed specification assignment into a generated package.
#
# Driven through the real `claim-once` CLI against the real fake Platform HTTP server, for the
# same reason MVP-0025's test was: most of what this MVP promises is about what the runner does
# NOT do after a claim, and only the end-to-end path can prove that. The side-effect assertions
# read the fake Platform's recorded REQUEST LOG, so "uploaded no execution report" is a fact
# about the wire rather than about a method that was not called.
class SpecificationGenerationTest < Minitest::Test
  ISSUE = "SR-700"
  PACKAGE = "specs/SR-700-add-an-export-button"

  def setup
    @source, @specs, @temp = SpecificationWorkspace.build
    @platform = FakePlatform.new(claim_payload: spec_creation_payload_for(issue_key: ISSUE)).start
    @config = build_config
    @io = StringIO.new
  end

  def teardown
    @platform.stop
    FileUtils.remove_entry(@temp) if @temp && File.directory?(@temp)
  end

  # ------------------------------------------------------------------ criterion 1

  def test_generates_the_three_required_documents_at_a_deterministic_safe_path
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    %w[spec.md analysis/business.md analysis/technical.md generation-manifest.json].each do |name|
      assert File.file?(File.join(@specs, PACKAGE, name)), "expected #{PACKAGE}/#{name}\n#{@io.string}"
    end
  end

  def test_the_folder_name_is_derived_from_the_issue_key_and_a_sanitized_summary
    run_cli

    assert_equal [ "SR-700-add-an-export-button" ], Dir.children(File.join(@specs, "specs"))
  end

  # ------------------------------------------------------------------ criterion 2

  def test_the_generated_specification_is_grounded_in_the_ticket_rather_than_template_prose
    run_cli
    spec = read_package("spec.md")

    # Ticket identity and the real reported problem, not a restated summary.
    assert_includes spec, ISSUE
    assert_includes spec, "https://example.atlassian.net/browse/#{ISSUE}"
    # The REPORTER's words are quoted under Problem — not SpecRelay's own bundle bookkeeping,
    # which is the paragraph a naive "first paragraph" read lands on (found in the live pass).
    problem = spec[/^## Problem$(.*?)^## /m, 1].to_s
    assert_includes problem, "retype it by hand"
    refute_includes problem, "Every expected input was readable"
    # Every section criterion 2 names.
    [ "## Problem", "## Outcome", "## Input summary", "## Proposed behavior", "## Non-goals",
      "## Acceptance criteria", "## Validation expectations",
      "## Dependencies, assumptions, and open questions", "## Analysis" ].each do |heading|
      assert_includes spec, heading
    end
    # And references to both analysis files.
    assert_includes spec, "analysis/business.md"
    assert_includes spec, "analysis/technical.md"
  end

  # ------------------------------------------------------------------ criterion 3

  def test_the_business_analysis_records_impact_gaps_and_a_recommendation
    run_cli
    business = read_package("analysis/business.md")

    [ "## User problem and affected workflow", "## Stakeholder impact",
      "## Risks, edge cases, and missing product decisions", "## Acceptance-criteria rationale",
      "## Input conflicts and gaps", "## Recommendation" ].each { |heading| assert_includes business, heading }
    assert_match(/Ready to approve|Approve with warnings|Needs product clarification/, business)
  end

  # ------------------------------------------------------------------ criterion 4

  def test_the_technical_analysis_records_real_source_files_and_both_tool_verdicts
    run_cli
    technical = read_package("analysis/technical.md")

    # Real files from the real checkout, repository-relative.
    assert_includes technical, "`app/services/export_report.rb`"
    # Both tool layers, each with an explicit verdict rather than silence.
    assert_includes technical, "## Graphify evidence"
    assert_includes technical, "graph FRESH for this checkout"
    assert_includes technical, "## Context+ evidence"
    assert_includes technical, "Context+"
    [ "## Dependency and blast-radius assessment", "## Likely implementation approach",
      "## Implementation surface", "## Tests a future implementation ticket needs",
      "## Technical risks, unknowns, and blocked evidence" ].each { |h| assert_includes technical, h }
  end

  def test_an_unusable_graph_is_recorded_as_unusable_rather_than_omitted
    rebuild_with(graph: :stale, graphify_substitute: "direct source inspection of the changed area")
    run_cli
    technical = read_package("analysis/technical.md")

    assert_includes technical, "STALE"
    assert_includes technical, "Result: NOT used"
    assert_includes technical, "direct source inspection of the changed area"
    # The weaker basis is stated, not papered over.
    assert_includes technical, "No structural graph contributed to this assessment"
  end

  # ------------------------------------------------------------------ criterion 7

  def test_success_is_reported_to_platform_with_repository_relative_paths_and_digests
    run_cli
    generation = @platform.last_specification_generation

    assert_equal "generated", generation["outcome"]
    assert_equal "rex_spec123", generation["runner_execution_id"]
    assert_equal PACKAGE, generation.dig("package", "path")
    reported = generation.dig("package", "files")
    assert_equal %w[spec.md analysis/business.md analysis/technical.md generation-manifest.json].sort,
                 reported.map { |file| file["path"] }.sort
    # The digests describe the bytes that are actually on disk.
    reported.each do |file|
      next if file["path"] == "generation-manifest.json"

      on_disk = Digest::SHA256.hexdigest(File.binread(File.join(@specs, PACKAGE, file["path"])))
      assert_equal on_disk, file["sha256"], file["path"]
    end
    assert generation["tool_evidence"].any? { |tool| tool["name"] == "graphify" }
    assert generation.key?("open_questions")
  end

  # The regression the LIVE evidence pass found and this suite originally missed. The real
  # Graphify wrappers print absolute paths; quoting their output verbatim put the operator's
  # home directory into a file destined for a shared specification repository, and the
  # writer's host-path guard then failed the whole generation. The correct outcome is a
  # successful generation whose quoted tool evidence is repository-relative.
  def test_absolute_paths_in_graph_tool_output_are_made_repository_relative
    run_cli
    technical = read_package("analysis/technical.md")

    refute_includes technical, @source
    assert_includes technical, "app/services/export_report.rb"
    assert_includes technical, "graphify-out/graph.json"
  end

  def test_no_absolute_host_path_reaches_the_generated_files_or_the_platform_payload
    run_cli
    payload = JSON.generate(@platform.last_specification_generation)

    [ @specs, @source, Dir.home ].each do |host_path|
      refute_includes payload, host_path
      %w[spec.md analysis/business.md analysis/technical.md generation-manifest.json].each do |name|
        refute_includes read_package(name), host_path
      end
    end
  end

  # ------------------------------------------------------------------ criterion 15

  def test_nothing_is_committed_pushed_published_or_sent_to_jira
    run_cli

    # The wire: only claim, heartbeat, and the generation result. No execution report, and no
    # protocol events (this lane emits none).
    paths = @platform.requests.map { |request| request[:path] }.uniq
    assert_equal [ "/api/runner/claim", "/api/runner/specification_generations" ], paths - [ "/api/runner/heartbeat" ]
    assert_empty @platform.requests_to("/api/runner/reports")
    assert_empty @platform.requests_to("/api/runner/events")

    # The disk: the specification checkout gained a package and nothing else. No git
    # repository was initialized, no branch created, no commit made.
    refute File.exist?(File.join(@specs, ".git")), "the runner must not create a git repository"
    assert_equal %w[README.md specs].sort, Dir.children(@specs).sort
    # And the manifest says so in the package itself.
    manifest = JSON.parse(read_package("generation-manifest.json"))
    assert_nil manifest.dig("publication", "branch")
    assert_nil manifest.dig("publication", "pull_request_url")
    assert_includes manifest.dig("publication", "note"), "no branch, commit, push, pull request"
  end

  def test_the_source_checkout_is_not_modified
    before = checkout_snapshot(@source)
    run_cli

    assert_equal before, checkout_snapshot(@source)
  end

  # ------------------------------------------------------------------ criterion 12

  def test_a_second_generation_atomically_replaces_the_package_and_records_the_replacement
    run_cli
    marker = File.join(@specs, PACKAGE, "stale-leftover.md")
    File.write(marker, "left by a previous generation")

    @platform.stop
    @platform = FakePlatform.new(claim_payload: spec_creation_payload_for(issue_key: ISSUE)).start
    @config = build_config
    @io = StringIO.new
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    refute File.exist?(marker), "replacement must not merge with the previous package"
    manifest = JSON.parse(read_package("generation-manifest.json"))
    assert manifest["replaced_existing_package"], "the manifest must record the replacement"
    assert @platform.last_specification_generation.dig("package", "replaced_existing_package")
    # No staging or set-aside directory survives.
    assert_equal [ "SR-700-add-an-export-button" ], Dir.children(File.join(@specs, "specs"))
  end

  def test_the_refuse_policy_refuses_instead_of_replacing
    run_cli
    original = read_package("spec.md")

    @platform.stop
    @platform = FakePlatform.new(claim_payload: spec_creation_payload_for(issue_key: ISSUE)).start
    @config = build_config
    @io = StringIO.new
    exit_code = run_cli(env_extra: { "SPECRELAY_RUNNER_SPEC_ON_EXISTING_PACKAGE" => "refuse" })

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    assert_equal "existing_package_present", @platform.last_specification_generation["failure_class"]
    assert_equal original, read_package("spec.md"), "the existing package must be untouched"
  end

  # ------------------------------------------------------------------ criterion 10

  def test_a_cancelled_claim_stops_without_reporting_success
    @platform.signal_cancelled!
    exit_code = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    assert_empty @platform.specification_generations,
                 "a superseded attempt must not report a generation result"
    assert_includes @io.string, "No generation result was submitted"
  end

  # ------------------------------------------------------------------ helpers

  def read_package(name) = File.read(File.join(@specs, PACKAGE, name))

  # Every file under a checkout with its digest, so "nothing was modified" is asserted over
  # content rather than over mtimes, which a copy would also preserve.
  def checkout_snapshot(root)
    Dir.glob("#{root}/**/*", File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort.to_h do |path|
      [ path.delete_prefix("#{root}/"), Digest::SHA256.hexdigest(File.binread(path)) ]
    end
  end

  def rebuild_with(graph:, graphify_substitute: nil)
    FileUtils.remove_entry(@temp)
    @source, @specs, @temp = SpecificationWorkspace.build(graph: graph)
    @config = build_config(graphify_substitute: graphify_substitute)
  end

  def build_config(graphify_substitute: nil)
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
          graphify:
            substitute: #{graphify_substitute.nil? ? '~' : graphify_substitute.to_json}
      workspace_roots:
        tiny-demo-workspace: #{@source}
    YAML
    SpecrelayRunner::Config.load(path)
  end

  def run_cli(env_extra: {})
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] }.merge(env_extra)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{@config.source_path}], out: @io, err: @io, env: env)
  end
end
