# frozen_string_literal: true

require_relative "test_helper"

# MVP-0015 — the repository extraction itself, asserted as behavior.
#
# Two things changed when the runner became its own repository: it must resolve
# the deterministic demo executor it now OWNS without an operator supplying an
# absolute path, and the spike-era config env var must keep working for an
# operator who already exported it. Both are proved here against the real files
# this repository ships, not against a stub.
class RepositoryBoundaryTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  # --- the runner owns its deterministic executor fixture -------------------

  def test_ships_the_fake_executor_in_its_own_bin
    path = File.join(ROOT, "bin", "specrelay-fake-executor")

    assert File.executable?(path), "the runner must ship an executable specrelay-fake-executor"
  end

  def test_resolves_a_bundled_bare_command_to_this_repositorys_bin
    executor = SpecrelayRunner::Executor.new(
      config: { "command" => "specrelay-fake-executor" },
      worktree_path: Dir.mktmpdir("wt"), staging_dir: Dir.mktmpdir("staging")
    )

    # Platform seeds the BARE name because it cannot know where this repository is
    # checked out on the runner's host; the runner turns it into a real path.
    assert_equal File.join(ROOT, "bin", "specrelay-fake-executor"), executor.command
    assert File.executable?(executor.command)
  end

  def test_leaves_a_real_provider_command_untouched_for_path_lookup
    executor = SpecrelayRunner::Executor.new(
      config: { "command" => "claude" },
      worktree_path: Dir.mktmpdir("wt"), staging_dir: Dir.mktmpdir("staging")
    )

    # `claude` is not ours to resolve — it must reach the normal PATH lookup.
    assert_equal "claude", executor.command
  end

  def test_leaves_an_absolute_path_untouched
    executor = SpecrelayRunner::Executor.new(
      config: { "command" => "/opt/custom/executor" },
      worktree_path: Dir.mktmpdir("wt"), staging_dir: Dir.mktmpdir("staging")
    )

    assert_equal "/opt/custom/executor", executor.command
  end

  def test_does_not_resolve_a_bare_name_this_repository_does_not_ship
    executor = SpecrelayRunner::Executor.new(
      config: { "command" => "not-a-bundled-executable" },
      worktree_path: Dir.mktmpdir("wt"), staging_dir: Dir.mktmpdir("staging")
    )

    assert_equal "not-a-bundled-executable", executor.command
  end

  # --- config path resolution across the rename ------------------------------

  def config_file
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: http://127.0.0.1:3300
      runner:
        id: r1
        display_name: Runner One
        claim_policy:
          mode: all_eligible
    YAML
    path
  end

  def test_resolves_the_config_path_from_the_canonical_env_var
    path = config_file

    assert_equal path, SpecrelayRunner::Config.resolve_path(nil, { "SPECRELAY_RUNNER_CONFIG" => path })
  end

  def test_still_honours_the_spike_era_env_var_as_a_deprecated_alias
    path = config_file

    assert_equal path, SpecrelayRunner::Config.resolve_path(nil, { "SPECRELAY_RUNNER_SPIKE_CONFIG" => path })
  end

  def test_prefers_the_canonical_env_var_over_the_deprecated_alias
    canonical = config_file
    legacy = config_file

    resolved = SpecrelayRunner::Config.resolve_path(
      nil, { "SPECRELAY_RUNNER_CONFIG" => canonical, "SPECRELAY_RUNNER_SPIKE_CONFIG" => legacy }
    )

    assert_equal canonical, resolved
  end

  def test_an_explicit_flag_beats_every_env_var
    explicit = config_file

    resolved = SpecrelayRunner::Config.resolve_path(
      explicit, { "SPECRELAY_RUNNER_CONFIG" => config_file, "SPECRELAY_RUNNER_SPIKE_CONFIG" => config_file }
    )

    assert_equal explicit, resolved
  end

  # --- the boundary itself ---------------------------------------------------

  # Comments are stripped first: several files legitimately EXPLAIN that the
  # runner carries no Rails or ActiveRecord, and matching that prose would make
  # the check pass or fail for the wrong reason. Only executable code is scanned.
  def code_lines(path)
    File.readlines(path).reject { |line| line.strip.start_with?("#") || line.strip.empty? }.join
  end

  def runner_sources
    Dir.glob(File.join(ROOT, "{lib,bin}", "**", "*")).select { |p| File.file?(p) }
  end

  def test_carries_no_rails_or_activerecord_dependency
    refute_empty runner_sources

    offenders = runner_sources.select do |path|
      code_lines(path).match?(/require\s+["']rails|\bActiveRecord\b|\bApplicationRecord\b|\bRails\./)
    end

    assert_empty offenders, "runner code must stay Rails-free and ActiveRecord-free"
  end

  def test_does_not_reach_into_the_platform_repository_at_runtime
    offenders = runner_sources.select { |path| code_lines(path).include?("specrelay-platform") }

    assert_empty offenders, "the runner must reach Platform only over HTTP, never through its files"
  end

  # MVP-0017 — the runner must not acquire Jira integration.
  #
  # The scan targets what actually constitutes integration: a Jira client constant or
  # namespace, a Jira REST path, or an Atlassian host the runner would call. It deliberately
  # does NOT flag the word "Jira" in operator prose or in the report contract's
  # `final_jira_update_ready` field name — the runner legitimately tells the operator that
  # Jira was not advanced, and legitimately names a field Platform reads on ingest. Flagging
  # those would make this test pass or fail for the wrong reason.
  JIRA_INTEGRATION = %r{
    SpecRelay::Integrations::Jira | \bJira:: | \bJiraClient\b |
    /rest/api/ | atlassian\.net/rest | \.atlassian\.net["'] |
    search_ready_issues | transition_issue | fetch_issue
  }xi

  def test_acquires_no_jira_integration
    refute_empty runner_sources

    offenders = runner_sources.select { |path| code_lines(path).match?(JIRA_INTEGRATION) }

    assert_empty offenders, "the runner must never talk to Jira; Platform owns provider integration"
  end

  # The same rule for the other two boundaries MVP-0017 names: the runner must not gain
  # project-routing or direct Platform-persistence behaviour.
  def test_acquires_no_platform_persistence_or_routing_logic
    offenders = runner_sources.select do |path|
      code_lines(path).match?(/\bWorkspaceDefinition\b|\bJiraConnection\b|\bRunnerWorkspaceConnection\b|\bRegisteredRunner\b/)
    end

    assert_empty offenders,
                 "the runner must not reference Platform's persisted models; it exchanges JSON over HTTP"
  end

  # MVP-0017 — the runner and Platform each normalize a repository URL to compare a local
  # checkout against a workspace definition. If the two normalizations disagreed, a
  # checkout the runner accepted locally would be rejected server-side (or worse, the
  # reverse), so the agreement is asserted directly on the cases that differ in the wild.
  def test_repository_identity_normalization_matches_the_documented_platform_rule
    expectations = {
      "https://github.com/SpecRelay/tiny-demo-workspace" => "github.com/specrelay/tiny-demo-workspace",
      "https://github.com/SpecRelay/tiny-demo-workspace.git" => "github.com/specrelay/tiny-demo-workspace",
      "https://github.com/SpecRelay/tiny-demo-workspace/" => "github.com/specrelay/tiny-demo-workspace",
      "git@github.com:SpecRelay/tiny-demo-workspace.git" => "github.com/specrelay/tiny-demo-workspace",
      "ssh://git@github.com/SpecRelay/tiny-demo-workspace" => "github.com/specrelay/tiny-demo-workspace",
      # Credentials embedded in a remote must not change identity (and must not survive it).
      "https://user:secret@github.com/SpecRelay/tiny-demo-workspace" => "github.com/specrelay/tiny-demo-workspace",
      "https://github.com:443/SpecRelay/tiny-demo-workspace" => "github.com/specrelay/tiny-demo-workspace"
    }

    expectations.each do |url, expected|
      assert_equal expected, SpecrelayRunner::RepositoryCheck.repository_identity(url), url
    end
  end

  def test_repository_identity_still_distinguishes_different_repositories
    tiny = SpecrelayRunner::RepositoryCheck.repository_identity("https://github.com/SpecRelay/tiny-demo-workspace")
    other = SpecrelayRunner::RepositoryCheck.repository_identity("https://github.com/SpecRelay/some-other-repo")
    forked = SpecrelayRunner::RepositoryCheck.repository_identity("https://github.com/Other/tiny-demo-workspace")

    refute_equal tiny, other
    refute_equal tiny, forked
  end
end
