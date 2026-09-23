# frozen_string_literal: true

require_relative "test_helper"
require "json"

# Workspace-grounded specification generation: the analysis runs in the ticket's own canonical
# task environment instead of an empty temporary directory.
#
# Driven through the real `claim-once` CLI against the real fake Platform, because almost every
# claim here is about the ENVIRONMENT a provider process was handed and about what the runner
# refuses to report — neither of which is observable from a method's return value. The provider
# is a configured command that records its own working directory, so "the provider could read
# every registered repository" is read back from what that process itself saw.
class SpecificationTaskWorkspaceTest < Minitest::Test
  ISSUE = "SR-700"
  TASK = ISSUE
  PACKAGE = "specs/SR-700-add-an-export-button"
  SPECS_SLUG = "SpecRelay/SpecRelay-Specs"
  COMPONENT_SLUG = "SpecRelay/component-a"

  def setup
    @built = SpecificationWorkspace.build_task_environment
    @root = @built.root
    @probe = File.join(@built.temp, "provider-probe.json")
    @io = StringIO.new
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@built.temp) if @built && File.directory?(@built.temp)
  end

  # ------------------------------------------------------------------ S01, S10

  # The load-bearing scenario. One task environment is created by the project's OWN command, and
  # the provider process really ran inside it with the registered repositories present — read
  # back from the directory listing that process recorded for itself, not from the runner's log.
  def test_a_first_generation_creates_one_task_environment_the_provider_can_read
    start
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    assert_equal [ "create #{TASK} --run-id #{SPEC_RUN}", "status #{TASK} --json" ],
                 worktree_invocations
    assert_equal task_workspace, probe["cwd"], "the provider must run in the task environment"
    assert_includes probe["entries"], "component-a"
    assert_includes probe["entries"], "component-b"
    assert_equal "class ExportReport\n  def call = :exported\nend\n", probe["component_source"]
  end

  # S10's other half: the working directory is not the empty temporary directory the lane used
  # before, and it is not the runner's own publication workspace either.
  def test_the_provider_working_directory_is_neither_empty_nor_the_publication_snapshot
    start
    run_cli

    refute_empty probe["entries"]
    refute_equal snapshot_worktree, probe["cwd"]
    assert_path_exists File.join(probe["cwd"], "bin", "worktree")
  end

  # ------------------------------------------------------------------ S02

  # A clean task environment that already exists is REUSED. `create` is never invoked, so no
  # second environment and no alternate layout can appear.
  def test_a_clean_existing_task_environment_is_reused
    prepare_task_environment
    before = Dir.children(File.join(@root, ".runs", "worktrees")).sort
    start
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    # Only the ownership proof. No second allocation, and no rewrite of the recorded owner.
    assert_equal [ "status #{TASK} --json" ], worktree_invocations
    assert_equal before, Dir.children(File.join(@root, ".runs", "worktrees")).sort
    assert_equal task_workspace, probe["cwd"]
  end

  # ------------------------------------------------------------------ S06

  # Graphify answers about the TASK ENVIRONMENT, not about the main checkout. The wrapper reports
  # its own root, so the recorded evidence naming the task environment is the tool's own answer.
  def test_graphify_and_context_plus_resolve_against_the_task_environment
    start
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    tools = @platform.last_specification_generation["tool_evidence"]
    assert tools.all? { |tool| tool["usable"] }, tools.inspect

    # The graph the packet carries is the one the wrapper answered for, and the wrapper reports
    # its OWN root — so a query naming a component of the task environment is the tool's own
    # statement about which tree it resolved against.
    graphify = probe.fetch("packet").fetch("tool_evidence").find { |tool| tool["name"] == "graphify" }
    assert graphify["contributed"], graphify.inspect
    assert_includes graphify["detail"].to_s, "component-a"
    # Relativized against the task environment, so no absolute local path reaches the provider.
    refute_includes graphify["detail"].to_s, @root
    assert_includes probe.fetch("packet").fetch("source").fetch("entry_points").join(" "),
                    "component-a"
  end

  # ------------------------------------------------------------------ S07

  # The whole validated package may change, and the run succeeds. Both destinations hold it: the
  # task environment the analysis happened in, and the retained publication snapshot.
  def test_the_complete_package_may_change_and_lands_in_both_destinations
    start(files: full_package)
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    %w[spec.md analysis/input-evidence.md analysis/business.md analysis/technical.md
       analysis/open-questions.md generation-manifest.json].each do |name|
      assert_path_exists File.join(task_workspace, PACKAGE, name)
    end
  end

  # ------------------------------------------------------------------ S09

  # The snapshot publication reads is BYTE-IDENTICAL to the package the run validated in the task
  # environment. Compared over content, so a snapshot that merely has the right file names fails.
  def test_the_publication_snapshot_matches_the_validated_task_environment_package
    start(files: full_package)
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    assert_equal package_digests(File.join(task_workspace, PACKAGE)),
                 package_digests(File.join(snapshot_worktree, PACKAGE))
    reported = @platform.last_specification_generation.dig("package", "files")
                        .to_h { |file| [ file["path"], file["sha256"] ] }
    assert_equal reported, package_digests(File.join(snapshot_worktree, PACKAGE))
  end

  # ------------------------------------------------------------------ S08

  # A provider that changed a COMPONENT repository fails before success and before publication.
  # The change is left in place: reverting an out-of-scope edit to manufacture a clean run would
  # destroy the only evidence of what the provider did.
  def test_a_provider_change_in_a_component_repository_fails_before_success
    start(escape: "component-a/app/services/export_report.rb")
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    generation = @platform.last_specification_generation
    assert_equal "failed", generation["outcome"]
    assert_equal "generation_provider_failed", generation["failure_class"]
    assert_includes generation["message"], "component-a"
    refute_path_exists File.join(snapshot_worktree, PACKAGE)
    assert_includes File.read(File.join(task_workspace, "component-a", "app", "services",
                                        "export_report.rb")), "escaped"
  end

  # The same rule for a sibling path in the WORKSPACE repository itself, which is the repository
  # the package legitimately lives in — so "inside the package directory" has to be the boundary
  # rather than "inside this repository".
  def test_a_provider_change_beside_the_package_fails_before_success
    start(escape: "README.md")
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_equal "generation_provider_failed",
                 @platform.last_specification_generation["failure_class"]
    refute_path_exists File.join(snapshot_worktree, PACKAGE)
  end

  # An UNTRACKED file counts. A provider that dropped scratch output beside the package would
  # otherwise reach a pull request with it.
  def test_an_untracked_provider_file_outside_the_package_fails_before_success
    start(escape: "notes/provider-scratch.md")
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_equal "generation_provider_failed",
                 @platform.last_specification_generation["failure_class"]
  end

  # A provider that COMMITS its component change leaves a clean `git status` behind. Measuring
  # the tree afterwards therefore proves nothing on its own: what the run must compare is the
  # repository state it captured before launching the provider with the state after it.
  def test_a_provider_that_commits_a_component_change_fails_before_success
    start(sabotage: component_commit)
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    generation = @platform.last_specification_generation
    assert_equal "generation_provider_failed", generation["failure_class"]
    assert_includes generation["message"], "component-a"
    refute_path_exists File.join(snapshot_worktree, PACKAGE)
  end

  # Changing a repository's `origin` to something this product does not recognise used to remove
  # the whole repository from measurement, because the inspected set was derived from the
  # identity map. The dirty file it hides is the proof that the set has to be the repositories
  # the environment CONTAINS, whatever they currently claim to be.
  def test_a_provider_that_repoints_a_component_origin_fails_before_success
    start(sabotage: "git -C component-a remote set-url origin file:///tmp/elsewhere && " \
                    "echo hidden >> component-a/app/services/export_report.rb")
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_equal "generation_provider_failed",
                 @platform.last_specification_generation["failure_class"]
    refute_path_exists File.join(snapshot_worktree, PACKAGE)
  end

  # A repository the environment held and no longer holds is a change to the source state the
  # specification claims to be grounded in, even though no tracked file reports it: the workspace
  # repository ignores its component checkouts.
  def test_a_provider_that_removes_a_contained_repository_fails_before_success
    start(sabotage: "rm -rf component-b")
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_equal "generation_provider_failed",
                 @platform.last_specification_generation["failure_class"]
    refute_path_exists File.join(snapshot_worktree, PACKAGE)
  end

  # And one that appeared. A new git root inside an ignored directory is invisible to every
  # `git status` in the environment, which is exactly why the repository inventory is compared.
  def test_a_provider_that_adds_a_git_repository_fails_before_success
    start(sabotage: "mkdir -p graphify-out/planted && git -C graphify-out/planted init -q")
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_equal "generation_provider_failed",
                 @platform.last_specification_generation["failure_class"]
    refute_path_exists File.join(snapshot_worktree, PACKAGE)
  end

  # ------------------------------------------------------------------ evidence

  # A successful run records WHICH task environment the analysis ran in, and no absolute local
  # path: the identity is Platform's own task id and canonical branch plus the repositories the
  # environment was proved to hold.
  def test_a_successful_run_records_the_task_environment_identity_without_a_local_path
    start
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    identity = @platform.last_specification_generation["task_workspace"]
    assert_equal TASK, identity["task_id"]
    assert_equal TASK, identity["canonical_branch"]
    assert_equal true, identity["created"]
    # Normalized identities, which is how the runner compares one repository to another.
    assert_equal [ COMPONENT_SLUG, "SpecRelay/component-b", SPECS_SLUG ].map(&:downcase).sort,
                 identity["repositories"].sort
    refute_includes @platform.last_specification_generation.to_json, @root
    refute_includes @platform.last_specification_generation.to_json, task_workspace
  end

  # What the OPERATOR is told on success, which is the one piece of evidence they act on before
  # anything is published. It drifted once: the message still described the pre-workspace-grounded
  # design, sending an operator to the runner's opaque isolated workspace to find a package that
  # is materialized into their task worktree. Asserted on meaning rather than on wording — the
  # package path they must open, the snapshot's publication-only role, and the not-yet-published
  # claim — so the sentence can be rewritten without this test becoming a spelling check, but
  # cannot come to name the wrong owner again.
  def test_the_success_output_names_the_task_worktree_as_the_package_location
    start
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string
    output = @io.string

    assert_includes output, PACKAGE, "the operator must be given the package path to open"
    assert_match(/task worktree/i, output, "the location must be named as the task worktree")
    assert_match(/snapshot/i, output, "the isolated workspace must be named as the snapshot")
    assert_match(/nothing was published|no pull request/i, output)

    # The claim that drifted, in both of its halves. The package is NOT held only in the isolated
    # worktree, and the specification checkout is NOT unchanged — the task worktree is a worktree
    # of that very repository, and it holds the package.
    refute_match(/held in this runner's own isolated worktree/i, output)
    refute_match(/not in your specification\s+checkout/i, output)
    refute_includes output, task_workspace, "no absolute local path may reach the operator's log"
  end

  # ------------------------------------------------------------------ S07 (replacement)

  # The validated package REPLACES the directory: a document the previous round carried and the
  # new one does not is gone, so the ticket package states one generation rather than two merged.
  def test_a_stale_document_in_the_ticket_package_is_removed_by_the_new_generation
    prepare_task_environment
    stale = File.join(@built.task_workspace(TASK), PACKAGE, "analysis", "open-questions.md")
    FileUtils.mkdir_p(File.dirname(stale))
    File.write(stale, "# #{ISSUE} open questions\n\nfrom the previous round\n")
    start
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    refute_path_exists File.join(task_workspace, PACKAGE, "analysis", "open-questions.md")
    assert_path_exists File.join(task_workspace, PACKAGE, "spec.md")
  end

  # ------------------------------------------------------------------ the assignment

  # The task identity is REQUIRED, and refused BEFORE anything is created. Reading a missing one
  # as "no task" would point the worktree owner at an empty branch, which is a repository-wide
  # mistake rather than a missing optional field.
  def test_an_assignment_without_the_task_identity_is_refused_before_anything_is_created
    start
    restart_without("run", "task_id", "canonical_branch")

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string
    generation = @platform.last_specification_generation
    assert_equal "assignment_malformed", generation["failure_class"]
    assert_includes generation["message"], "run.task_id"
    refute_path_exists File.join(@root, ".runs", "worktrees")
    refute_path_exists @probe
  end

  def test_an_assignment_without_a_worktree_create_command_is_refused
    start
    restart_without("workspace", "worktree_create_command")

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string
    assert_includes @platform.last_specification_generation["message"],
                    "workspace.worktree_create_command"
    refute_path_exists File.join(@root, ".runs", "worktrees")
  end

  # ------------------------------------------------------------------ owned process group

  # The provider's own process group cannot be shown to have ended. The claim ends at the
  # command-line boundary: no generation result, no release of the task environment, no next claim.
  # Inspection of that one group is refused at the OS boundary, and the grace is shortened so the
  # bounded shutdown runs out quickly; everything else is the real lane.
  def test_a_provider_group_that_cannot_be_shown_to_have_ended_stops_the_claim
    leader = File.join(@built.temp, "provider.pgid")
    start(sabotage: "echo $PPID > #{leader}")

    code = with_unprovable_provider_group(leader) { run_cli }

    assert_path_exists leader, "the provider must really have run"
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, @io.string
    assert_includes @io.string, "process group #{File.read(leader).strip}"
    assert_nil @platform.last_specification_generation, "no generation result may be reported"
    assert_equal 1, @platform.requests_to("/api/runner/claim").size
    refute(worktree_invocations.any? { |call| call.start_with?("release") }, worktree_invocations.inspect)
  end

  # --- harness -------------------------------------------------------------

  def with_unprovable_provider_group(leader)
    runner = SpecrelayRunner::CommandRunner
    grace = runner::TERM_GRACE_SECONDS
    runner.send(:remove_const, :TERM_GRACE_SECONDS)
    runner.const_set(:TERM_GRACE_SECONDS, 0.3)
    kill = Process.method(:kill)
    Process.define_singleton_method(:kill) do |signal, *targets|
      pid = File.exist?(leader) ? Integer(File.read(leader).strip, exception: false) : nil
      group = pid && -pid
      raise Errno::EPERM if signal.to_s == "0" && group && targets == [ group ]

      kill.call(signal, *targets)
    end
    yield
  ensure
    Process.define_singleton_method(:kill, kill)
    runner.send(:remove_const, :TERM_GRACE_SECONDS)
    runner.const_set(:TERM_GRACE_SECONDS, grace)
  end

  # Re-offer this run's claim with fields removed from one block, so the refusal is measured
  # against the document Platform would have to be broken to send.
  def restart_without(block, *fields)
    payload = @payload
    payload[block] = payload[block].except(*fields)
    @platform.stop
    @platform = FakePlatform.new(claim_payload: payload).start
    @config = build_config
    @io = StringIO.new
  end


  def start(files: nil, escape: nil, sabotage: nil, previous_accepted_package: nil, gh_seed: [])
    payload = spec_creation_payload_for(issue_key: ISSUE)
              .merge("previous_accepted_package" => previous_accepted_package)
    payload["run"] = payload["run"].merge("task_id" => TASK, "canonical_branch" => TASK)
    payload["workspace"] = payload["workspace"].merge(
      "worktree_create_command" => "bin/worktree create <TASK-ID>"
    )
    @platform = FakePlatform.new(claim_payload: payload).start
    @gh_dir, = FakeGithub.gh_bin(urls: pull_request_urls, bares: @built.bares, seed: gh_seed)
    @provider = write_probe_provider(files: files || minimal_package, escape: escape,
                                     sabotage: sabotage)
    @config = build_config
    @payload = payload
  end

  def pull_request_urls
    { SPECS_SLUG => "https://github.com/SpecRelay/SpecRelay-Specs/pull/11",
      COMPONENT_SLUG => "https://github.com/SpecRelay/component-a/pull/12",
      "SpecRelay/component-b" => "https://github.com/SpecRelay/component-b/pull/13" }
  end

  # The provider under test: a real process that RECORDS its own working directory and what it
  # can see there, then answers with a document map.
  #
  # It stands where the approved Claude CLI stands — its own bare name, first on the child PATH,
  # answering the profile's structured-output contract — because that closed set of real profiles
  # is now the only way a specification provider can be selected.
  #
  # `escape` makes it write one file outside its package directory, which is the only honest way
  # to exercise the change boundary — a test that planted the file itself would prove the check
  # runs, not that it catches a provider.
  def write_probe_provider(files:, escape:, sabotage: nil)
    dir = Dir.mktmpdir("claude-stub", @built.temp)
    SpecificationWorkspace.write_executable(File.join(dir, "claude"), <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      require "fileutils"
      if ARGV.first == "--version"
        puts "1.0.0"
        exit 0
      end
      exit 0 if %w[auth login].include?(ARGV.first)

      # The packet travels inside the one reviewable prompt document, so it is read back out of
      # the prompt exactly as a provider would read it.
      $LOAD_PATH.unshift(#{SpecificationWorkspace::LIB_ROOT.inspect})
      require "specrelay_runner"
      packet = begin
        SpecrelayRunner::Specification::BalancedJson
          .extract_object(ARGV.last.to_s.split("EVIDENCE (JSON):").last.to_s)
          .then { |object| JSON.parse(object) }
      rescue StandardError
        nil
      end
      component = File.join(Dir.pwd, "component-a", "app", "services", "export_report.rb")
      File.write(#{@probe.inspect}, JSON.generate({
        "cwd" => Dir.pwd,
        "entries" => Dir.children(Dir.pwd).sort,
        "component_source" => (File.read(component) if File.file?(component)),
        "packet" => packet
      }))
      escape = #{escape.inspect}
      if escape
        FileUtils.mkdir_p(File.dirname(escape))
        File.write(escape, "escaped by the provider\\n")
      end
      sabotage = #{sabotage.inspect}
      system("/bin/sh", "-c", sabotage) if sabotage
      puts JSON.generate("type" => "system", "subtype" => "init")
      puts JSON.generate("type" => "result", "subtype" => "success", "is_error" => false,
                         "result" => JSON.generate(#{files.to_json}))
    RUBY
    dir
  end

  def minimal_package
    { "spec.md" => document("#{ISSUE}: add an export button",
                            SpecrelayRunner::Specification::DocumentSet::REQUIRED_SECTIONS
                              .fetch("spec.md")),
      "analysis/input-evidence.md" => document("#{ISSUE} input evidence", [ "Recorded inputs" ]),
      "analysis/business.md" => document("#{ISSUE} business analysis",
                                         SpecrelayRunner::Specification::DocumentSet::REQUIRED_SECTIONS
                                           .fetch("analysis/business.md")),
      "analysis/technical.md" => document("#{ISSUE} technical analysis",
                                          SpecrelayRunner::Specification::DocumentSet::REQUIRED_SECTIONS
                                            .fetch("analysis/technical.md")) }
  end

  def full_package
    minimal_package.merge(
      "analysis/open-questions.md" => <<~MD
        # #{ISSUE} open questions

        ## OQ-001 Which report columns are exported?

        - Why it blocks: the export cannot be built without the column set.
        - Decision required: name the exact columns the export must contain.
        - Consequence: a guessed column set ships the wrong file to every operator.
      MD
    )
  end

  # A document whose every required section carries enough body to clear the structural floor.
  def document(title, sections)
    body = sections.map do |name|
      "## #{name}\n\nThis section records the substantive detail a reviewer needs here, at " \
        "length enough to be real content rather than a heading.\n"
    end
    "# #{title}\n\n#{body.join("\n")}"
  end

  def build_config
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
            "#{SPECS_SLUG}": #{@root}
          context_plus:
            available: true
      workspace_roots:
        tiny-demo-workspace: #{@root}
    YAML
    SpecrelayRunner::Config.load(path)
  end

  def run_cli(env_extra: {})
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
            "PATH" => "#{@provider}:#{@gh_dir}:#{ENV['PATH']}" }
          .merge(SpecificationWorkspace.lane_env(@built.temp)).merge(env_extra)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{@config.source_path}], out: @io, err: @io, env: env)
  end

  # --- observation ---------------------------------------------------------

  # A component change the provider commits, so the environment it leaves behind is clean.
  def component_commit
    "echo committed >> component-a/app/services/export_report.rb && " \
      "git -C component-a -c user.email=p@specrelay.local -c user.name=Provider " \
      "commit -qam 'provider change'"
  end

  def probe = JSON.parse(File.read(@probe))
  def task_workspace = File.realpath(@built.task_workspace(TASK))
  def snapshot_worktree = SpecificationWorkspace.isolated_worktree(@built.temp)

  def worktree_invocations = MultiRepositoryWorkspace.worktree_invocations(@built.worktree_log)

  # Run the project-owned command exactly as the runner would, so a REUSE test starts from an
  # environment the runner did not build.
  # An environment this generation's own Run already owns — the state a same-run retry finds.
  # Allocated through the project's own command with that Run id, because ownership is what
  # makes it reusable and a fixture that recorded none would be preparing a manual environment.
  def prepare_task_environment(run_id: SPEC_RUN)
    SpecificationWorkspace.git!(@root, "status", "--porcelain")
    argv = [ File.join(@root, "bin", "worktree"), "create", TASK ]
    argv += [ "--run-id", run_id ] unless run_id.nil?
    output, status = Open3.capture2e(*argv, chdir: @root)
    raise "fixture worktree create failed: #{output}" unless status.success?

    File.delete(@built.worktree_log) if File.exist?(@built.worktree_log)
  end

  def package_digests(directory)
    Dir.glob(File.join(directory, "**", "*")).select { |path| File.file?(path) }.sort.to_h do |path|
      [ path.delete_prefix("#{directory}/"), Digest::SHA256.hexdigest(File.binread(path)) ]
    end
  end
end
