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
      assert File.file?(File.join(worktree, PACKAGE, name)), "expected #{PACKAGE}/#{name}\n#{@io.string}"
    end
  end

  def test_the_folder_name_is_derived_from_the_issue_key_and_a_sanitized_summary
    run_cli

    assert_equal [ "SR-700-add-an-export-button" ], Dir.children(File.join(worktree, "specs"))
  end

  # ------------------------------------------------------- MAPIAI-62 criterion 1 (S01)

  # The load-bearing assertion of this ticket. The package exists, and it exists ONLY in the
  # Runner-owned worktree; the operator's specification checkout is byte-identical to what it
  # was before the run.
  def test_the_package_is_written_only_into_the_runner_owned_isolated_worktree
    before = SpecificationWorkspace.checkout_snapshot(@specs)
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    assert File.file?(File.join(worktree, PACKAGE, "spec.md")), @io.string
    refute File.exist?(File.join(@specs, PACKAGE)), "nothing may be written into the operator checkout"
    assert_equal before, SpecificationWorkspace.checkout_snapshot(@specs)
    refute_includes worktree, @specs
  end

  # S03 — the operator's dirty working tree is invisible to generation and survives it.
  def test_staged_modified_and_untracked_operator_files_are_untouched
    File.write(File.join(@specs, "README.md"), "# edited by the operator\n")
    File.write(File.join(@specs, "untracked.md"), "operator scratch\n")
    File.write(File.join(@specs, "staged.md"), "staged work\n")
    SpecificationWorkspace.git!(@specs, "add", "staged.md")
    before = SpecificationWorkspace.checkout_snapshot(@specs)
    status_before = SpecificationWorkspace.git!(@specs, "status", "--porcelain")

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    assert_equal before, SpecificationWorkspace.checkout_snapshot(@specs)
    assert_equal status_before, SpecificationWorkspace.git!(@specs, "status", "--porcelain")
  end

  # The one thing this design does write near the seed, asserted directly rather than hidden
  # behind the snapshot's exclusion: git's own linked-worktree bookkeeping, and nothing else.
  def test_the_seed_git_directory_gains_only_worktree_bookkeeping
    before = Dir.children(File.join(@specs, ".git")).sort
    head_before = SpecificationWorkspace.git!(@specs, "rev-parse", "HEAD")
    run_cli

    assert_equal (before + [ "worktrees" ]).uniq.sort, Dir.children(File.join(@specs, ".git")).sort
    assert_equal head_before, SpecificationWorkspace.git!(@specs, "rev-parse", "HEAD")
  end

  # The worktree really is one, detached, and starts from the seed's own commit — so publication
  # can prove identity against a recorded base rather than trusting a directory.
  def test_the_isolated_workspace_is_a_detached_worktree_at_the_recorded_base
    run_cli
    metadata = SpecificationWorkspace.isolated_metadata(SpecificationWorkspace.latest_isolated_workspace(@temp))

    assert_equal SpecificationWorkspace.git!(@specs, "rev-parse", "HEAD").strip, metadata["base_commit"]
    assert_equal SpecificationWorkspace.git!(worktree, "rev-parse", "HEAD").strip, metadata["base_commit"]
    assert_equal "true", SpecificationWorkspace.git!(worktree, "rev-parse", "--is-inside-work-tree").strip
    assert_equal "ready", metadata["state"]
    assert_equal "run_spec123", metadata["run_id"]
  end

  # The opaque id, and only the opaque id, crosses to Platform (design 2 / S32).
  def test_the_reported_workspace_identity_is_opaque_and_carries_no_local_path
    run_cli
    reported = @platform.last_specification_generation.fetch("package_workspace")

    assert_match(/\Aswp_[0-9a-f]{32}\z/, reported["id"])
    assert_equal 7, reported["retention_days"]
    refute_empty reported["expires_at"]
    refute_includes @platform.last_specification_generation.to_json, @temp
    refute_includes @platform.last_specification_generation.to_json, Dir.home
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
      "## Dependencies and assumptions", "## Analysis" ].each do |heading|
      assert_includes spec, heading
    end
    # And references to the evidence file and both analysis files.
    assert_includes spec, "analysis/input-evidence.md"
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
    # CR-001 must-fix 2 renamed this verdict from "used"/"NOT used" to the two-verdict
    # vocabulary the Tool struct has always carried. The property is unchanged: a tool the run
    # only continued past must not be described as having produced evidence.
    assert_includes technical, "Result: did NOT contribute evidence"
    assert_includes technical, "direct source inspection of the changed area"
    # The weaker basis is stated, not papered over.
    assert_includes technical, "No structural graph contributed to this assessment"
  end

  # CR-001 must-fix 2. Round 001 derived `contributed` for Context+ from the operator's
  # `available:` flag, so a configuration value became an evidence claim: the analysis said the
  # tool had been used, and nothing had queried anything. The runner has no MCP client and
  # cannot verify a semantic pass, so it may never claim one.
  def test_context_plus_is_never_reported_as_having_contributed_evidence
    run_cli
    technical = read_package("analysis/technical.md")
    tool = @platform.last_specification_generation["tool_evidence"]
             .find { |entry| entry["name"] == "context_plus" }

    refute tool["contributed"], "the runner cannot verify a semantic query and must not claim one"
    assert tool["usable"], "usable is unchanged — it is what preflight gates on"
    section = technical[/^## Context\+ evidence$(.*?)^## /m, 1].to_s
    assert_includes section, "No semantic evidence was gathered by this process"
    refute_includes section, "Result: contributed evidence"
  end

  # The other half of must-fix 2: an operator CAN put real semantic evidence in front of the
  # runner, and then it is reproduced verbatim under the heading criterion 4 asks for. It is
  # still not the runner's contribution — a person gathered it — so `contributed` stays false
  # and the document attributes it.
  def test_operator_recorded_context_plus_evidence_is_reproduced_verbatim_and_attributed
    @config = build_config(context_plus_queries: [ "where is the weekly report rendered" ],
                           context_plus_evidence: "ReportsController#weekly and ExportReport are the hits")
    run_cli
    technical = read_package("analysis/technical.md")
    tool = @platform.last_specification_generation["tool_evidence"]
             .find { |entry| entry["name"] == "context_plus" }

    section = technical[/^## Context\+ evidence$(.*?)^## /m, 1].to_s
    assert_includes section, "where is the weekly report rendered"
    assert_includes section, "ReportsController#weekly and ExportReport are the hits"
    assert_includes section, "the operator's attestation, not this process's output"
    refute tool["contributed"], "an operator's attestation is not the runner's own evidence"
  end

  # The derived sentences elsewhere in the document must agree with that section. They did not:
  # the analysis asserted "both tool layers reported a usable result" and "no tool reported a
  # false negative" on the strength of the same conflated flag.
  def test_the_derived_claims_distinguish_contribution_from_usability
    run_cli
    technical = read_package("analysis/technical.md")

    refute_includes technical, "both tool layers reported a usable result"
    refute_includes technical, "No tool reported a false negative"
    assert_includes technical, "No Context+ semantic query was performed by this process"
  end

  # CR-003 should-fix 4. This test used to be named for the warn path and assert only that the
  # run refused on Graphify — its own comment conceded it never reached the code it was named
  # for. It now does what its name says: a checkout with no readable source AND a recorded
  # Graphify substitute reaches the warn-and-generate path, and the warning is asserted where it
  # has to arrive.
  #
  # After CR-002 must-fix 2 this warning is the only thing standing between a source-less
  # generation and a document that otherwise reads as fully grounded, so it is worth pinning at
  # both ends rather than only at the producer.
  def test_a_zero_file_inspection_warns_platform_and_the_manifest
    empty_the_source_checkout
    @config = build_config(graphify_substitute: "no source in this checkout to build a graph from")

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    warnings = @platform.last_specification_generation["warnings"]
    assert warnings.any? { |warning| warning.include?("No source file could be read") },
           "the source warning must reach Platform: #{warnings.inspect}"

    manifest = JSON.parse(read_package("generation-manifest.json"))
    assert manifest["warnings"].any? { |warning| warning.include?("No source file could be read") },
           "the source warning must reach the on-disk manifest: #{manifest['warnings'].inspect}"
    assert_equal 0, manifest.dig("source_evidence", "entry_points_inspected")
  end

  # The other half of the same claim: with nothing read, the generated documents must not read
  # as grounded in code.
  def test_a_zero_file_generation_does_not_claim_source_grounding
    empty_the_source_checkout
    @config = build_config(graphify_substitute: "no source in this checkout to build a graph from")
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    spec = read_package("spec.md")
    assert_includes spec, "No source was inspected"
    refute_includes spec, "read-only inspection of the source checkout"
    assert_includes read_package("analysis/technical.md"), "NO SOURCE WAS INSPECTED"
  end

  # A repository that does not install Graphify remains usable. The package must disclose both
  # the missing structural evidence and the absence of readable source instead of silently
  # presenting ticket-only generation as code-grounded.
  def test_an_empty_checkout_without_graphify_uses_the_direct_inspection_fallback
    empty_the_source_checkout

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string
    manifest = JSON.parse(read_package("generation-manifest.json"))
    assert_includes manifest["warnings"],
                    "Graphify is not installed for this checkout; direct source inspection was used instead."
    assert manifest["warnings"].any? { |warning| warning.include?("No source file could be read") }
  end

  def test_the_generated_documents_and_manifest_name_the_real_source_files
    run_cli
    manifest = JSON.parse(read_package("generation-manifest.json"))

    assert_operator manifest.dig("source_evidence", "entry_points_inspected"), :>, 0
    assert_includes read_package("analysis/technical.md"), "`app/services/export_report.rb`"
    assert_empty manifest["warnings"], "a checkout with source must carry no inspection warning"
  end

  # ------------------------------------------------------------------ criterion 7

  def test_success_is_reported_to_platform_with_repository_relative_paths_and_digests
    run_cli
    generation = @platform.last_specification_generation

    assert_equal "generated", generation["outcome"]
    assert_equal "rex_spec123", generation["runner_execution_id"]
    assert_equal PACKAGE, generation.dig("package", "path")
    reported = generation.dig("package", "files")
    assert_equal %w[spec.md analysis/input-evidence.md analysis/open-questions.md analysis/business.md
                    analysis/technical.md generation-manifest.json].sort,
                 reported.map { |file| file["path"] }.sort
    # The digests describe the bytes that are actually on disk.
    reported.each do |file|
      next if file["path"] == "generation-manifest.json"

      on_disk = Digest::SHA256.hexdigest(File.binread(File.join(worktree, PACKAGE, file["path"])))
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

    # The wire: only claim, heartbeat, the provider's live-log events and the generation result.
    # No execution report — this lane uploads none — and the events carry nothing but the
    # normalized progress the run page's existing panel shows.
    paths = @platform.requests.map { |request| request[:path] }.uniq
    assert_equal [ "/api/runner/claim", "/api/runner/events", "/api/runner/specification_generations" ],
                 paths - [ "/api/runner/heartbeat" ]
    assert_empty @platform.requests_to("/api/runner/reports")
    assert_equal [ "log.chunk" ], @platform.protocol_events.map { |event| event["event_type"] }.uniq

    # The disk: the isolated worktree gained a package and nothing else. No branch was created
    # and no commit was made anywhere.
    assert_equal %w[specs], Dir.children(worktree).reject { |name| name == ".git" }
    # The worktree is DETACHED and the repository's branch list is exactly the seed's own. A new
    # branch here would be a branch in the operator's repository, which generation never creates.
    assert_equal [ "main" ],
                 SpecificationWorkspace.git!(worktree, "for-each-ref", "--format=%(refname:short)",
                                             "refs/heads").split
    refute SpecificationWorkspace.git(worktree, "symbolic-ref", "-q", "HEAD").last.success?,
           "the isolated worktree must be detached, so HEAD names no branch"
    # MVP-0028 remediation, defect 4 — the manifest carries no publication claim at all. It is a
    # durable package file, committed into the specification repository by a later publication
    # run, so a snapshot claim written here ("no branch, commit, pull request...") would read as
    # false the moment that happens. Publication state lives in Platform's run record instead.
    manifest = JSON.parse(read_package("generation-manifest.json"))
    refute manifest.key?("publication"), manifest.inspect
  end

  def test_the_source_checkout_is_not_modified
    before = SpecificationWorkspace.checkout_snapshot(@source)
    run_cli

    assert_equal before, SpecificationWorkspace.checkout_snapshot(@source)
  end

  # ------------------------------------------------- MAPIAI-62 criterion 12 / S21

  # Generating again does not replace anything: it creates a SECOND isolated workspace with its
  # own opaque id, and the first one is left exactly as it was. That is what makes Platform's
  # single stored id — rather than a directory the runner overwrites — the thing that decides
  # which package is current.
  def test_a_second_generation_creates_a_new_workspace_and_leaves_the_first_intact
    run_cli
    first = SpecificationWorkspace.sole_isolated_workspace(@temp)
    first_spec = File.read(File.join(first, "worktree", PACKAGE, "spec.md"))
    restart_platform

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    workspaces = SpecificationWorkspace.isolated_workspaces(@temp)
    assert_equal 2, workspaces.length, workspaces.inspect
    assert_equal 1, (workspaces - [ first ]).length
    assert_equal first_spec, File.read(File.join(first, "worktree", PACKAGE, "spec.md")),
                 "the previous workspace must be left intact, merely stale"
  end

  # A failure after the package landed, which Platform ACCEPTED. The report still says the package
  # is on disk — that is true when it is sent — and only once Platform has recorded the failure are
  # the unpublished snapshot and the ticket's task environment discarded.
  def test_an_accepted_failure_after_the_rename_discards_the_snapshot_and_the_environment
    before = SpecificationWorkspace.checkout_snapshot(@specs)
    seen = record_environment_at_submission
    exit_code = with_unreadable_final_manifest { run_cli }

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    generation = @platform.last_specification_generation
    assert_equal "failed", generation["outcome"]
    refute generation["zero_output_files_written"], "the package IS on disk; the report must say so"
    assert_includes generation["message"], PACKAGE
    assert_match(/\Aswp_/, generation.dig("package_workspace", "id").to_s)
    assert_equal [ true ], seen, "the environment was discarded before Platform recorded the failure"
    assert_empty SpecificationWorkspace.isolated_workspaces(@temp), "the unpublished snapshot outlived the failure"
    assert_nil task_worktree, "the task environment outlived the accepted failure"
    assert_equal before, SpecificationWorkspace.checkout_snapshot(@specs)
  end

  # The same failure, refused or unanswered by Platform: nothing recorded it, so both stay.
  def test_a_refused_failure_result_keeps_the_snapshot_and_the_environment
    @platform.generation_response = [ 422, { error: "not acceptable right now" } ]

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, with_unreadable_final_manifest { run_cli }, @io.string

    assert_snapshot_and_environment_kept
  end

  # A 201 that records nothing — the claim is no longer current — is not an acknowledgement.
  def test_a_superseded_failure_result_keeps_the_snapshot_and_the_environment
    @platform.generation_response = SUPERSEDED

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, with_unreadable_final_manifest { run_cli }, @io.string

    assert_snapshot_and_environment_kept
    refute_includes @io.string, "Platform recorded the result"
  end

  def test_a_superseded_refusal_keeps_the_environment_this_run_built
    @platform.generation_response = SUPERSEDED

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, with_broken_redaction { run_cli }, @io.string

    refute_nil task_worktree, "the environment was released for a refusal Platform did not record"
    refute_includes @io.string, "Platform recorded the result"
  end

  def test_an_unreachable_failure_result_keeps_the_snapshot_and_the_environment
    @platform.generation_response = [ 500, { error: "internal server error" } ]

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, with_unreadable_final_manifest { run_cli }, @io.string

    assert_snapshot_and_environment_kept
  end

  # A refusal before any environment existed, accepted by Platform. There is nothing of this Run's
  # to hand back, and no package workspace is invented to clean.
  def test_an_accepted_refusal_before_the_environment_existed_releases_nothing
    @platform.claim_payload = spec_creation_payload_for(issue_key: ISSUE, complete: false)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_equal "refused", @platform.last_specification_generation["outcome"]
    refute_includes @io.string, "still allocated"
    refute_includes @io.string, "Released the task environment"
    assert_empty SpecificationWorkspace.task_worktrees(@source)
  end

  # A refusal after this Run built its task environment but before the package workspace. The
  # environment is this Run's and goes back once Platform has recorded the refusal.
  def test_an_accepted_refusal_after_the_environment_was_built_releases_it
    exit_code = with_broken_redaction { run_cli }

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    assert_equal "refused", @platform.last_specification_generation["outcome"]
    assert_nil task_worktree, "the environment this run built outlived its accepted refusal"
    assert_empty SpecificationWorkspace.isolated_workspaces(@temp)
  end

  # A readable record of a person's environment or another Run's needs no cleanup: it is kept, the
  # release is never asked for, and the refusal is not turned into a cleanup failure.
  def test_an_accepted_refusal_keeps_a_manual_or_foreign_environment_without_a_cleanup_error
    [ "", "run_somebody_else" ].each do |owner|
      restart_platform
      allocate_task_environment(owner)
      log = log_project_command

      assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

      assert_equal "refused", @platform.last_specification_generation["outcome"]
      assert_equal owner, ProjectCommand.recorded_owner(@source, ISSUE)
      refute_nil task_worktree
      refute_includes project_verbs(log), "release", "a protected environment was asked to be released"
      refute_includes @io.string, "Release it by hand"
    end
  end

  # A status that answers "no environment" proves nothing by itself. The run-qualified release is
  # asked and proves the absence, which completes the cleanup. The missing specification checkout
  # refuses before any environment is built.
  def test_an_accepted_refusal_with_no_environment_asks_the_release_to_prove_absence
    FileUtils.mv(@specs, "#{@specs}.moved")
    log = log_project_command

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_includes project_lines(log), "release #{ISSUE} --run-id #{SPEC_RUN} --json", @io.string
    refute_includes @io.string, "Release it by hand"
  end

  # A status the Runner cannot read does not stand for absence: the release is asked, and the
  # environment this Run owns is handed back.
  def test_an_accepted_refusal_with_an_unreadable_status_releases_the_environment_this_run_owns
    { "nonzero" => "exit 1", "malformed" => "echo 'not a status document'; exit 0" }.each do |name, answer|
      restart_platform
      allocate_task_environment(SPEC_RUN)
      log_project_command(status: answer)

      assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, "#{name}: #{@io.string}"

      assert_equal "refused", @platform.last_specification_generation["outcome"], name
      assert_nil ProjectCommand.recorded_owner(@source, ISSUE), "#{name}: the owned environment was kept"
      assert_nil task_worktree, name
      refute_includes @io.string, "Release it by hand", name
    end
  end

  # With no readable status, the release command is still the authority that protects a person's
  # environment and another Run's. It refuses, nothing is removed, and the incomplete cleanup is
  # visible and nonzero.
  def test_the_release_protects_a_manual_or_foreign_environment_when_status_is_unreadable
    [ "", "run_somebody_else" ].each do |owner|
      restart_platform
      allocate_task_environment(owner)
      log_project_command(status: "exit 1")

      assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

      assert_equal owner, ProjectCommand.recorded_owner(@source, ISSUE)
      refute_nil task_worktree
      assert_includes @io.string, "Release it by hand"
    end
  end

  # A project without its run-aware command cannot prove anything was left behind or that nothing
  # was, so the accepted refusal ends in an incomplete cleanup.
  def test_an_accepted_refusal_without_the_project_command_is_an_incomplete_cleanup
    FileUtils.rm_f(File.join(@source, "bin", "worktree"))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_equal "refused", @platform.last_specification_generation["outcome"]
    assert_includes @io.string, "Release it by hand"
  end

  # An unmapped workspace root is not proof of absence: an earlier attempt may have allocated the
  # environment while the mapping existed.
  def test_an_accepted_refusal_with_an_unmapped_workspace_root_is_an_incomplete_cleanup
    @config = build_config(workspace_roots: {})

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_equal "refused", @platform.last_specification_generation["outcome"]
    assert_includes @io.string, "Release it by hand"
    refute_includes @io.string, @temp, "the cleanup reason exposed a local path"
  end

  # Every incomplete cleanup stops a loop that would otherwise go on claiming.
  def test_an_incomplete_cleanup_after_an_accepted_refusal_stops_the_loop_before_another_claim
    { "unreadable" => -> { allocate_task_environment("run_somebody_else")
                           log_project_command(status: "exit 1") },
      "unmapped" => -> { @config = build_config(workspace_roots: {}) },
      "no command" => -> { FileUtils.rm_f(File.join(@source, "bin", "worktree")) } }.each do |name, cause|
      restart_platform(claim_limit: 2)
      cause.call

      code = Timeout.timeout(45) { run_cli(command: %w[loop --poll-interval 5 --on-failure continue]) }

      assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, "#{name}: #{@io.string}"
      assert_equal 1, @platform.requests_to("/api/runner/claim").size, "#{name}: the loop claimed again"
      assert_equal "refused", @platform.last_specification_generation["outcome"], name
    end
  end

  # Generation success is not the end of the Run: publication still needs both.
  def test_a_generated_package_keeps_its_snapshot_and_environment_for_publication
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    assert File.file?(File.join(worktree, PACKAGE, "spec.md"))
    assert File.file?(File.join(task_worktree, PACKAGE, "spec.md"))
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

  # Explicit cancellation is Platform's own terminal record: no late result, and this Run's
  # snapshot and environment are discarded.
  def test_an_explicit_cancellation_discards_the_snapshot_and_the_environment
    @platform.signal_cancelled!

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_empty @platform.specification_generations
    assert_empty SpecificationWorkspace.isolated_workspaces(@temp)
    assert_nil task_worktree
  end

  # An expired lease is not a definitive ending known to this process. Everything stays.
  def test_an_expired_lease_keeps_the_snapshot_and_the_environment
    @platform.signal_expired!

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_empty @platform.specification_generations
    refute_empty SpecificationWorkspace.isolated_workspaces(@temp)
    refute_nil task_worktree
  end

  # ------------------------------------------------------------------ helpers

  # The package lives in the Runner-owned worktree, found through the store rather than at a
  # path a test could predict — the workspace id is opaque and random by design.
  def worktree = SpecificationWorkspace.isolated_worktree(@temp)

  # The ticket's task environment, where the package is materialized.
  def task_worktree = SpecificationWorkspace.task_worktree(@source, ISSUE)
  def read_package(name) = File.read(File.join(worktree, PACKAGE, name))

  # A checkout that RESOLVES, can still build the ticket's task environment, and contains nothing
  # readable to write a specification from. That is a different condition from a missing workspace
  # root, and — since generation is grounded in the task environment — a different condition from
  # a wiped directory: removing `.git` would refuse for a missing environment rather than
  # exercise the zero-source path this asserts about.
  #
  # `bin/worktree` is RESTORED into the checkout afterwards, untracked. An automatic run may only
  # allocate through the project's own run-aware command, so a checkout without one refuses
  # before generation and never reaches the condition under test — but a tracked one would be
  # carried into the task environment and counted as a readable source file, which is the very
  # thing this is emptying. The connected checkout keeps the command; the environment built from
  # its history does not.
  #
  # The removal is COMMITTED, because the task environment is built from this checkout's history.
  def empty_the_source_checkout
    command = File.join(@source, "bin", "worktree")
    allocator = File.read(command)
    Dir.glob(File.join(@source, "*"), File::FNM_DOTMATCH).each do |path|
      next if path.end_with?("/.", "/..", "/.git")

      FileUtils.remove_entry(path)
    end
    SpecificationWorkspace.git!(@source, "add", "-A")
    SpecificationWorkspace.git!(@source, "-c", "user.email=fixture@specrelay.local",
                                "-c", "user.name=SpecRelay Fixture", "commit", "-q",
                                "-m", "empty the readable source")
    FileUtils.mkdir_p(File.dirname(command))
    SpecificationWorkspace.write_executable(command, allocator)
    restart_platform
    @io = StringIO.new
  end

  def rebuild_with(graph:, graphify_substitute: nil)
    FileUtils.remove_entry(@temp)
    @source, @specs, @temp = SpecificationWorkspace.build(graph: graph)
    @config = build_config(graphify_substitute: graphify_substitute)
  end

  # A fresh claim for a second `claim-once` against the same checkouts.
  def restart_platform(claim_limit: nil)
    @platform.stop
    @platform = FakePlatform.new(claim_payload: spec_creation_payload_for(issue_key: ISSUE),
                                 claim_limit: claim_limit).start
    @config = build_config
    @io = StringIO.new
  end

  # Every verb the connected checkout's project command is asked, in order. `status`, when given,
  # is the shell the status verb runs instead of the project's own answer. The command sits in
  # front of the real one, which it calls for everything else, so the recorded owner stays the
  # project's own file.
  def log_project_command(status: nil)
    command = File.join(@source, "bin", "worktree")
    FileUtils.mv(command, "#{command}.project") unless File.exist?("#{command}.project")
    log = File.join(@source, ".runs", "project-command.log")
    FileUtils.mkdir_p(File.dirname(log))
    FileUtils.rm_f(log)
    SpecificationWorkspace.write_executable(command, <<~SH)
      #!/usr/bin/env sh
      echo "$*" >> "#{log}"
      #{status ? %(if [ "$1" = status ]; then #{status}; fi) : ''}
      exec "#{command}.project" "$@"
    SH
    log
  end

  def project_lines(log) = File.exist?(log) ? File.readlines(log, chomp: true) : []
  def project_verbs(log) = project_lines(log).map { |line| line.split.first }

  # An environment an earlier allocation left for this ticket, recorded as `owner`'s: a Run id, or
  # an empty string for one a person made. Built by the project's own command, as a real one is.
  def allocate_task_environment(owner)
    unless task_worktree
      command = [ File.join(@source, "bin", "worktree"), "create", ISSUE, "--run-id", "run_earlier", "--json" ]
      _out, status = Open3.capture2e(*command, chdir: @source)
      raise "the fixture could not allocate #{ISSUE}" unless status.success?
    end
    ProjectCommand.own!(@source, ISSUE, owner)
  end

  # Fail the manifest digest, which is taken from the FINAL location after the rename. The only
  # production failure that genuinely lands after the atomic move, and the reason `call`
  # converts a stray Errno into a write error that reports the package as present.
  #
  # Matched on the package-relative suffix rather than an absolute path: the workspace id is
  # random, so the final location does not exist until the run under test creates it.
  #
  # `define_singleton_method` + restore rather than a mocking library: this suite has no gems,
  # which is the same reason with_broken_redaction in the preflight test is written this way.
  SUPERSEDED = [ 201, { outcome: "superseded", execution_state: "CANCELLED", run_state: "CANCELLED" } ].freeze

  def assert_snapshot_and_environment_kept
    refute_empty SpecificationWorkspace.isolated_workspaces(@temp), "the snapshot was removed without an acknowledgement"
    refute_nil task_worktree, "the environment was released without an acknowledgement"
    refute_includes @io.string, "Released the task environment"
  end

  # Whether the ticket's task environment still existed at the moment Platform received each
  # generation result.
  def record_environment_at_submission
    seen = []
    original = @platform.method(:specification_generation)
    source = @source
    @platform.define_singleton_method(:specification_generation) do |request|
      seen << !SpecificationWorkspace.task_worktree(source, ISSUE).nil?
      original.call(request)
    end
    seen
  end

  # The runner's redaction guard failing its own probe — a refusal preflight makes after the task
  # environment exists and before the package workspace does.
  def with_broken_redaction
    original = SpecrelayRunner::Redaction.method(:redact)
    SpecrelayRunner::Redaction.define_singleton_method(:redact) { |text| text }
    yield
  ensure
    SpecrelayRunner::Redaction.define_singleton_method(:redact, original)
  end

  def with_unreadable_final_manifest
    suffix = "#{PACKAGE}/generation-manifest.json"
    original = File.method(:binread)
    File.define_singleton_method(:binread) do |path, *rest|
      raise Errno::EIO, path.to_s if path.to_s.end_with?(suffix)

      original.call(path, *rest)
    end
    yield
  ensure
    File.define_singleton_method(:binread, original)
  end

  def build_config(graphify_substitute: nil, context_plus_queries: [], context_plus_evidence: nil,
                   workspace_roots: { "tiny-demo-workspace" => @source })
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
            queries: #{context_plus_queries.to_json}
            evidence: #{context_plus_evidence.nil? ? '~' : context_plus_evidence.to_json}
          graphify:
            substitute: #{graphify_substitute.nil? ? '~' : graphify_substitute.to_json}
      workspace_roots: #{workspace_roots.to_json}
    YAML
    SpecrelayRunner::Config.load(path)
  end

  # The approved Claude profile's bare name first on the child PATH, answering with the
  # deterministic composer's own documents so the CONTENT assertions above stay inspectable
  # without a model. Everything between the claim and the write is the real code path.
  def provider_stub = @provider_stub ||= SpecificationWorkspace.claude_stub(@temp, compose: true)

  def run_cli(env_extra: {}, command: %w[claim-once])
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
            "PATH" => SpecificationWorkspace.provider_path(provider_stub) }
          .merge(SpecificationWorkspace.lane_env(@temp)).merge(env_extra)
    SpecrelayRunner::CLI.run([ *command, "--config", @config.source_path ], out: @io, err: @io, env: env)
  end
end
