# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"

# What the task environment CONTAINS before analysis starts.
#
# Workspace-grounded generation is only worth having if the state it grounds itself in is the
# ticket's real current state: the specification pull request the ticket already has, and the
# implementation pull requests an earlier round already shipped. Both are reconstructed inside
# the task environment, and both fail CLOSED — a specification written from a head GitHub no
# longer shows would claim continuity it does not have.
#
# Every git fact here is real. Each accepted head exists only in that component's own bare remote
# when the run starts, so "the runner materialized it" cannot pass by accident: the checkout has
# to fetch it.
class SpecificationTaskStateTest < Minitest::Test
  ISSUE = "SR-700"
  FOLDER = "SR-700-add-an-export-button"
  # One ticket, one branch: the task environment, the component repository and the specification
  # pull request are all on it. `TASK` and `SPEC_BRANCH` are the same string on purpose — a
  # fixture that gave the specification lane its own name would describe the split this product
  # no longer has.
  TASK = FOLDER
  SPEC_BRANCH = TASK
  PACKAGE = "specs/#{FOLDER}"
  SPECS_SLUG = "SpecRelay/SpecRelay-Specs"
  COMPONENT_SLUG = "SpecRelay/component-a"
  SPEC_PR = "https://github.com/SpecRelay/SpecRelay-Specs/pull/7"
  ACCEPTED_PR = "https://github.com/SpecRelay/component-a/pull/12"

  PREVIOUS_FILES = {
    "spec.md" => "# SR-700: add an export button\n\nRound one, as published.\n",
    "analysis/business.md" => "# SR-700 business analysis\n\nThe reporter retypes rows.\n"
  }.freeze

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

  # ------------------------------------------------------------------ S03

  # A revision starts from the package the ticket's own specification pull request carries, and
  # that package is present IN THE TASK ENVIRONMENT before the provider runs — so a provider that
  # reads its own package directory reads the previous round rather than an empty folder.
  def test_a_revision_makes_the_existing_pull_request_package_visible_before_generation
    build_previous_package_on_spec_branch
    start(revision: SPEC_PR)
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    PREVIOUS_FILES.each_key do |name|
      assert_includes probe["package_before"].to_h.keys, name,
                      "the provider must see #{name} from the existing pull request"
    end
    assert_equal PREVIOUS_FILES["spec.md"].strip, probe["package_before"]["spec.md"].to_s.strip
  end

  # It does not MERGE that pull request. The task environment stays on the canonical branch at
  # the default branch's commit; only the package directory carries the previous round.
  def test_the_revision_is_not_merged_into_the_task_environment
    build_previous_package_on_spec_branch
    start(revision: SPEC_PR)
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    assert_equal TASK, git(task_workspace, "symbolic-ref", "--quiet", "--short", "HEAD").strip
    assert_equal git(@root, "rev-parse", "main").strip,
                 git(task_workspace, "rev-parse", "HEAD").strip
  end

  # ------------------------------------------------------------------ S04

  # The accepted head is really placed, in the component repository that owns it, on the canonical
  # branch — fetched from that repository's own remote, because the run's checkout never had it.
  def test_a_populated_accepted_package_is_materialized_before_the_provider_starts
    head = publish_accepted_round
    start(previous_accepted_package: accepted_package(head), gh_seed: [ accepted_pull_request(head) ])
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    component = File.join(task_workspace, "component-a")
    assert_equal head, git(component, "rev-parse", "HEAD").strip
    assert_equal TASK, git(component, "symbolic-ref", "--quiet", "--short", "HEAD").strip
    assert_includes probe["accepted_source"].to_s, "shipped in round one"
  end

  # ------------------------------------------------------------------ S05

  # A pull request GitHub no longer shows as open refuses BEFORE the provider is launched. The
  # probe file is the proof: it exists only if the provider ran.
  def test_a_closed_accepted_pull_request_refuses_before_the_provider_launches
    head = publish_accepted_round
    start(previous_accepted_package: accepted_package(head),
          gh_seed: [ accepted_pull_request(head).merge("state" => "CLOSED") ])

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string
    assert_refused "is closed, not open"
  end

  def test_a_moved_accepted_head_refuses_before_the_provider_launches
    head = publish_accepted_round
    start(previous_accepted_package: accepted_package("f" * 40),
          gh_seed: [ accepted_pull_request(head) ])

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string
    assert_refused "moved from"
  end

  def test_an_accepted_pull_request_on_another_branch_refuses_before_the_provider_launches
    head = publish_accepted_round
    start(previous_accepted_package: accepted_package(head),
          gh_seed: [ accepted_pull_request(head).merge("headRefName" => "someone-elses-branch") ])

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string
    assert_refused "is on branch"
  end

  # An accepted repository the task environment does not hold refuses too: analysis of a
  # continuation whose code is absent would be grounded in nothing.
  def test_an_accepted_repository_missing_from_the_task_environment_refuses
    head = publish_accepted_round
    package = accepted_package(head)
    package["implementation_pull_requests"][0] = package["implementation_pull_requests"][0].merge(
      "repository" => "SpecRelay/component-z",
      "clone_url" => "https://github.com/SpecRelay/component-z",
      "pull_request_url" => "https://github.com/SpecRelay/component-z/pull/12"
    )
    start(previous_accepted_package: package, gh_seed: [ accepted_pull_request(head) ])

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string
    assert_refused "component-z"
  end

  # An unreadable pull request — no `gh` on the path at all — is refused rather than treated as
  # "nothing to continue from".
  def test_an_unreadable_accepted_pull_request_refuses_before_the_provider_launches
    head = publish_accepted_round
    start(previous_accepted_package: accepted_package(head), gh_seed: [ accepted_pull_request(head) ])
    @gh_dir = File.join(@built.temp, "no-gh-here")
    FileUtils.mkdir_p(@gh_dir)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string
    assert_refused "could not read the accepted pull request"
  end

  # ------------------------------------------------ containment of the package destination

  # A specification root that is a SYMBOLIC LINK out of the task environment. It is committed in
  # the repository, so the environment `bin/worktree` builds carries it and nothing about the
  # workspace looks dirty — which is exactly the shape a lexical containment check waves through.
  #
  # The revision path reaches it first: the previous package is placed BEFORE the provider runs,
  # so a link here deletes and writes outside the task workspace while every later boundary check
  # still reports a clean tree.
  def test_a_revision_may_not_place_the_previous_package_through_a_symlinked_root
    build_previous_package_on_spec_branch(package: "lane/#{FOLDER}")
    outside = link_specification_root_outside("lane")
    start(revision: SPEC_PR, specification_root: "lane")

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string
    assert_outside_untouched(outside)
  end

  # The same link, on a FIRST specification: the write of the generated package itself must not
  # resolve outside the task environment either, and the run must not report a package it wrote
  # somewhere nobody can inspect.
  def test_a_first_specification_may_not_write_the_package_through_a_symlinked_root
    outside = link_specification_root_outside("lane")
    start(specification_root: "lane")

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string
    assert_outside_untouched(outside)
  end

  # ------------------------------------------------ S04/S05 in a REUSED task environment

  # The cross-runner case the outcome exists to support. The environment was left behind by an
  # earlier round on another machine, so it is REUSED — and it must still be proved to contain the
  # implementation this ticket accepted, or a new specification would be written from code the
  # ticket never shipped.
  def test_a_reused_environment_behind_the_accepted_head_is_advanced_to_it
    head = publish_accepted_round
    prepare_task_environment
    start(previous_accepted_package: accepted_package(head), gh_seed: [ accepted_pull_request(head) ])
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    component = File.join(task_workspace, "component-a")
    assert_equal head, git(component, "rev-parse", "HEAD").strip
    assert_equal TASK, git(component, "symbolic-ref", "--quiet", "--short", "HEAD").strip
    assert_includes probe["accepted_source"].to_s, "shipped in round one"
  end

  # Newer work is PRESERVED. A reused environment legitimately carries a descendant of what was
  # accepted, and rewinding it to the accepted commit would delete the round that produced it.
  def test_a_reused_environment_ahead_of_the_accepted_head_is_not_rewound
    head = publish_accepted_round
    prepare_task_environment
    newer = commit_on_top_of(head)
    start(previous_accepted_package: accepted_package(head), gh_seed: [ accepted_pull_request(head) ])
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    assert_equal newer, git(File.join(task_workspace, "component-a"), "rev-parse", "HEAD").strip
  end

  # Divergence is refused rather than merged: this reconstructs a base, it does not resolve one.
  def test_a_reused_environment_that_diverged_from_the_accepted_head_refuses
    head = publish_accepted_round
    prepare_task_environment
    commit_beside(head)
    start(previous_accepted_package: accepted_package(head), gh_seed: [ accepted_pull_request(head) ])

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string
    assert_refused "diverged"
  end

  # The live pull-request proof runs on a reused environment too. Without it, a workspace left on
  # one runner would generate happily from a head GitHub no longer shows as accepted.
  def test_a_closed_accepted_pull_request_refuses_in_a_reused_environment
    head = publish_accepted_round
    prepare_task_environment
    start(previous_accepted_package: accepted_package(head),
          gh_seed: [ accepted_pull_request(head).merge("state" => "CLOSED") ])

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string
    assert_refused "is closed, not open"
  end

  # --- assertions ----------------------------------------------------------

  # Every refusal in this file must satisfy the same three things: the reason reaches Platform,
  # no provider ran, and no package was published from a state the runner could not confirm.
  def assert_refused(reason)
    generation = @platform.last_specification_generation
    assert_includes generation["message"].to_s, reason
    refute_path_exists @probe, "no provider may run once the task state could not be reconstructed"
    assert_equal true, generation["zero_output_files_written"]
  end

  # --- harness -------------------------------------------------------------

  # Build the task environment with the project's own command, so a test starts from one this
  # run did NOT create.
  def prepare_task_environment
    output, status = Open3.capture2e(File.join(@root, "bin", "worktree"), "create", TASK, chdir: @root)
    raise "fixture worktree create failed: #{output}" unless status.success?

    File.delete(@built.worktree_log) if File.exist?(@built.worktree_log)
  end

  # One commit on component-a's canonical branch, on top of the accepted head — the ordinary
  # shape of a reused environment that has moved on.
  def commit_on_top_of(head)
    component = File.join(@built.task_workspace(TASK), "component-a")
    git(component, "fetch", "-q", "origin", TASK)
    git(component, "checkout", "-q", "-B", TASK, head)
    write_and_commit(component, "# a later round\n")
  end

  # A commit that is NOT a descendant of the accepted head: the environment and the accepted
  # implementation have both moved, from a common ancestor.
  def commit_beside(_head)
    component = File.join(@built.task_workspace(TASK), "component-a")
    write_and_commit(component, "# an unrelated local round\n")
  end

  def write_and_commit(component, note)
    path = File.join(component, "app", "services", "export_report.rb")
    File.write(path, "#{File.read(path)}#{note}")
    git(component, "-c", "user.email=fixture@specrelay.local", "-c", "user.name=SpecRelay Fixture",
        "commit", "-qam", "local round")
    git(component, "rev-parse", "HEAD").strip
  end

  # A specification root committed as a SYMBOLIC LINK to a directory outside the repository,
  # holding a sentinel whose bytes prove nothing outside was written or deleted.
  def link_specification_root_outside(name)
    outside = File.join(@built.temp, "outside-#{name}")
    FileUtils.mkdir_p(outside)
    File.write(File.join(outside, "sentinel.txt"), "sentinel\n")
    # A branch that carried a real folder here leaves an empty directory behind on checkout.
    FileUtils.rm_rf(File.join(@root, name))
    File.symlink(outside, File.join(@root, name))
    git(@root, "add", name)
    git(@root, "-c", "user.email=fixture@specrelay.local", "-c", "user.name=SpecRelay Fixture",
        "commit", "-qm", "add the specification root")
    git(@root, "push", "-q", "origin", "HEAD:refs/heads/main")
    outside
  end

  def assert_outside_untouched(outside)
    assert_equal "sentinel\n", File.read(File.join(outside, "sentinel.txt"))
    assert_equal [ "sentinel.txt" ], Dir.children(outside).sort
  end

  def start(revision: nil, previous_accepted_package: nil, gh_seed: nil, specification_root: "specs")
    payload = spec_creation_payload_for(issue_key: ISSUE, existing_pull_request_url: revision,
                                        specification_root: specification_root)
              .merge("previous_accepted_package" => previous_accepted_package)
    payload["run"] = payload["run"].merge("task_id" => TASK, "canonical_branch" => TASK)
    payload["workspace"] = payload["workspace"].merge(
      "worktree_create_command" => "bin/worktree create <TASK-ID>"
    )
    @platform = FakePlatform.new(claim_payload: payload).start
    seed = gh_seed || (revision ? [ spec_pull_request ] : [])
    @gh_dir, = FakeGithub.gh_bin(pull_request_url: SPEC_PR, urls: pull_request_urls,
                                 bares: @built.bares, seed: seed)
    @provider = write_probe_provider
    @config = build_config
    payload
  end

  def pull_request_urls
    { SPECS_SLUG => SPEC_PR, COMPONENT_SLUG => ACCEPTED_PR,
      "SpecRelay/component-b" => "https://github.com/SpecRelay/component-b/pull/13" }
  end

  def spec_pull_request
    { "url" => SPEC_PR, "state" => "OPEN", "headRefName" => SPEC_BRANCH,
      "baseRefName" => "main",
      "headRefOid" => git(@root, "rev-parse", "refs/remotes/origin/#{SPEC_BRANCH}").strip }
  end

  def accepted_pull_request(head)
    { "url" => ACCEPTED_PR, "state" => "OPEN", "headRefName" => TASK, "baseRefName" => "main",
      "headRefOid" => head }
  end

  def accepted_package(head)
    { "package_id" => "art_previous123", "checksum" => "c" * 64, "source_run_id" => "run_previous",
      "approved_specification" => { "reference" => SPEC_PR, "digest" => "d" * 64 },
      "implementation_pull_requests" => [
        { "repository" => COMPONENT_SLUG,
          "clone_url" => "https://github.com/SpecRelay/component-a",
          "branch" => TASK, "head_commit" => head, "pull_request_url" => ACCEPTED_PR }
      ] }
  end

  # The round the previous specification actually shipped, pushed to component-a's own remote from
  # a separate clone so the run's checkout genuinely has to fetch it.
  def publish_accepted_round
    clone = File.join(@built.temp, "accepted-clone")
    system("git", "clone", "-q", @built.bares.fetch("component-a"), clone, exception: true)
    git(clone, "config", "user.email", "runner@example.test")
    git(clone, "config", "user.name", "Runner Test")
    git(clone, "config", "commit.gpgsign", "false")
    File.write(File.join(clone, "app", "services", "export_report.rb"),
               "class ExportReport\n  # shipped in round one\n  def call = :exported\nend\n")
    git(clone, "commit", "-qam", "#{ISSUE}: shipped round one")
    git(clone, "push", "-q", "origin", "HEAD:refs/heads/#{TASK}")
    git(clone, "rev-parse", "HEAD").strip
  end

  # The previous specification package, on the ticket's branch in the remote.
  #
  # Pushed from a SEPARATE clone, exactly as {#publish_accepted_round} does, because the previous
  # round was published by a runner rather than by this checkout. It also keeps the operator's
  # checkout free of a local branch named after the ticket — `git worktree add -b` refuses to
  # create one that already exists locally, so a fixture that left one behind would block the
  # very task environment this test is about.
  def build_previous_package_on_spec_branch(package: PACKAGE)
    clone = File.join(@built.temp, "spec-round-one-clone")
    system("git", "clone", "-q", @built.bares.fetch("."), clone, exception: true)
    git(clone, "config", "user.email", "runner@example.test")
    git(clone, "config", "user.name", "Runner Test")
    git(clone, "config", "commit.gpgsign", "false")
    git(clone, "checkout", "-q", "-b", SPEC_BRANCH)
    PREVIOUS_FILES.each do |name, body|
      path = File.join(clone, package, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
      git(clone, "add", File.join(package, name))
    end
    git(clone, "commit", "-q", "-m", "#{ISSUE}: generated specification package")
    git(clone, "push", "-q", "origin", "#{SPEC_BRANCH}:refs/heads/#{SPEC_BRANCH}")
    git(@root, "fetch", "-q", "origin", "#{SPEC_BRANCH}:refs/remotes/origin/#{SPEC_BRANCH}")
  end

  # The provider records the package directory it found BEFORE it wrote anything, which is how a
  # revision's starting document is observed rather than inferred.
  #
  # It stands where the approved Claude CLI stands — its own bare name, first on the child PATH,
  # answering the profile's structured-output contract — because that closed set of real profiles
  # is now the only way a specification provider can be selected.
  def write_probe_provider
    dir = Dir.mktmpdir("claude-stub", @built.temp)
    SpecificationWorkspace.write_executable(File.join(dir, "claude"), <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      if ARGV.first == "--version"
        puts "1.0.0"
        exit 0
      end
      exit 0 if %w[auth login].include?(ARGV.first)

      accepted = File.join(Dir.pwd, "component-a", "app", "services", "export_report.rb")
      package = Dir.glob(File.join(Dir.pwd, #{PACKAGE.inspect}, "**", "*")).select { |p| File.file?(p) }
      File.write(#{@probe.inspect}, JSON.generate({
        "cwd" => Dir.pwd,
        "accepted_source" => (File.read(accepted) if File.file?(accepted)),
        "package_before" => package.to_h { |p| [ p.delete_prefix(File.join(Dir.pwd, #{PACKAGE.inspect}) + "/"), File.read(p) ] }
      }))
      puts JSON.generate("type" => "system", "subtype" => "init")
      puts JSON.generate("type" => "result", "subtype" => "success", "is_error" => false,
                         "result" => JSON.generate(#{generated_package.to_json}))
    RUBY
    dir
  end

  def generated_package
    sections = SpecrelayRunner::Specification::DocumentSet::REQUIRED_SECTIONS
    { "spec.md" => document("#{ISSUE}: add an export button", sections.fetch("spec.md")),
      "analysis/input-evidence.md" => document("#{ISSUE} input evidence", [ "Recorded inputs" ]),
      "analysis/business.md" => document("#{ISSUE} business analysis",
                                         sections.fetch("analysis/business.md")),
      "analysis/technical.md" => document("#{ISSUE} technical analysis",
                                          sections.fetch("analysis/technical.md")) }
  end

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

  def probe = JSON.parse(File.read(@probe))
  def task_workspace = File.realpath(@built.task_workspace(TASK))

  def git(root, *args)
    stdout, status = Open3.capture2e("git", "-C", root, *args)
    raise "git #{args.join(' ')} failed in #{root}: #{stdout}" unless status.success?

    stdout
  end
end
