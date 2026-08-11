# frozen_string_literal: true

require_relative "test_helper"

# MAPIAI-62 scenarios S01, S02 and S04 — the specification repository checkout is a validated
# GIT SEED and a credential source, and never a destination.
#
# This file REPLACES `specification_source_checkout_reuse_test.rb`, which asserted the opposite:
# that a package landed inside the reused workspace checkout. The resolution mechanism it tested
# is unchanged and still worth testing — an explicit mapping wins, and the source workspace
# checkout is reused only when its own `origin` verifiably matches — but what happens after
# resolution is now the point, so the assertions moved rather than the setup.
#
# Every test runs the real CLI against a real fake Platform with real git repositories, because
# "the package landed in the isolated worktree" and "both checkouts are byte-identical" are facts
# about the disk, not statements about which private method returned what.
class SpecificationSeedResolutionTest < Minitest::Test
  ISSUE = "SR-700"
  PACKAGE = "specs/SR-700-add-an-export-button"
  # The default `spec_creation_payload_for` specification_target: owner SpecRelay, repository
  # SpecRelay-Specs — so this is the slug a workspace checkout's remote must resolve to for
  # reuse to be offered.
  TARGET_SLUG = "SpecRelay/SpecRelay-Specs"

  def setup
    @source, @specs, @temp = SpecificationWorkspace.build
    @io = StringIO.new
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@temp) if @temp && File.directory?(@temp)
  end

  # ------------------------------------------------------ S01: the seed is only a seed

  def test_the_reused_workspace_checkout_is_a_seed_and_receives_no_package
    SpecificationWorkspace.git_init(@source, remote: "https://github.com/#{TARGET_SLUG}.git")
    before_source = SpecificationWorkspace.checkout_snapshot(@source)
    before_specs = SpecificationWorkspace.checkout_snapshot(@specs)
    start_platform

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli(repository_roots: false), @io.string

    assert File.file?(File.join(worktree, PACKAGE, "spec.md")), @io.string
    assert_equal before_source, SpecificationWorkspace.checkout_snapshot(@source)
    assert_equal before_specs, SpecificationWorkspace.checkout_snapshot(@specs)
    # The worktree really was seeded from the REUSED checkout, not from the unrelated fixture.
    assert_equal SpecificationWorkspace.git!(@source, "rev-parse", "HEAD").strip,
                 SpecificationWorkspace.git!(worktree, "rev-parse", "HEAD").strip
  end

  # ------------------------------------------------- S02: a separate specification repository

  def test_an_explicit_mapping_seeds_from_that_repository_and_leaves_both_checkouts_unchanged
    # The workspace checkout is ALSO a real git repo, but for a different repository entirely —
    # proving the explicit mapping wins regardless of what the workspace checkout's remote is.
    SpecificationWorkspace.git_init(@source, remote: "https://github.com/SpecRelay/tiny-demo-workspace.git")
    before_source = SpecificationWorkspace.checkout_snapshot(@source)
    before_specs = SpecificationWorkspace.checkout_snapshot(@specs)
    start_platform

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli(repository_roots: true), @io.string

    assert File.file?(File.join(worktree, PACKAGE, "spec.md")), @io.string
    assert_equal before_source, SpecificationWorkspace.checkout_snapshot(@source)
    assert_equal before_specs, SpecificationWorkspace.checkout_snapshot(@specs)
    assert_equal SpecificationWorkspace.git!(@specs, "rev-parse", "HEAD").strip,
                 SpecificationWorkspace.git!(worktree, "rev-parse", "HEAD").strip
  end

  # ----------------------------------------------------------- S04: unverifiable seed refuses

  def test_a_workspace_checkout_with_the_wrong_remote_is_not_reused
    SpecificationWorkspace.git_init(@source, remote: "https://github.com/SpecRelay/some-unrelated-repo.git")
    before = SpecificationWorkspace.checkout_snapshot(@source)
    start_platform

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(repository_roots: false), @io.string
    assert_equal "specification_repository_unresolved",
                 @platform.last_specification_generation["failure_class"]
    assert_equal before, SpecificationWorkspace.checkout_snapshot(@source)
    assert_empty SpecificationWorkspace.isolated_workspaces(@temp),
                 "an unresolvable seed must refuse before any workspace exists"
  end

  def test_an_unverifiable_workspace_checkout_is_not_reused
    # No git repository at all under the workspace root — the ordinary state for a checkout this
    # operator never intended as a specification destination.
    start_platform

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli(repository_roots: false), @io.string
    generation = @platform.last_specification_generation
    assert_equal "specification_repository_unresolved", generation["failure_class"]
    assert_includes generation["message"], "runner.specification.repository_roots"
    assert_empty SpecificationWorkspace.isolated_workspaces(@temp)
  end

  # ------------------------------------------------------------------------- helpers

  def worktree = SpecificationWorkspace.isolated_worktree(@temp)

  def start_platform
    @platform = FakePlatform.new(claim_payload: spec_creation_payload_for(issue_key: ISSUE)).start
  end

  def run_cli(repository_roots:)
    config = build_config(repository_roots: repository_roots)
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] }
          .merge(SpecificationWorkspace.lane_env(@temp))
    SpecrelayRunner::CLI.run(%W[claim-once --config #{config.source_path}], out: @io, err: @io, env: env)
  end

  def build_config(repository_roots:)
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
            #{repository_roots ? "\"#{TARGET_SLUG}\": #{@specs}" : '{}'}
          context_plus:
            available: true
      workspace_roots:
        tiny-demo-workspace: #{@source}
    YAML
    SpecrelayRunner::Config.load(path)
  end
end
