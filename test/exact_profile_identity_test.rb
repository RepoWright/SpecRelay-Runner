# frozen_string_literal: true

require_relative "test_helper"

# The exact-identity boundary, at the level that matters: a claimed payload that is not byte-for-byte
# one of the three approved profiles must be refused BEFORE a worktree exists and BEFORE any process
# runs.
#
# Every example here plants a marker executable and asserts the marker was never written. An
# assertion that merely checks an error message would pass while the unapproved process ran, which
# is exactly how the previous approximate validator (basename + denylist) was shown to be unsafe.
class ExactProfileIdentityTest < Minitest::Test
  TASK = "DEMO-0144X"

  def setup
    @root, _fake = DemoWorkspace.build
    @scratch = Dir.mktmpdir("exact-identity-")
    @marker = File.join(@scratch, "it-ran")
    @platform = nil
    @io = StringIO.new
  end

  def teardown
    @platform&.stop
    [ @root, @scratch ].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  # An executable that records the fact it ran. If a refusal is real, this file never appears.
  def marker_executable(name)
    path = File.join(@scratch, name)
    File.write(path, "#!/bin/sh\ntouch #{@marker}\nexit 0\n")
    FileUtils.chmod(0o755, path)
    path
  end

  def start_platform(executor)
    payload = base_claim_payload(task_id: TASK)
    @platform = FakePlatform.new(claim_payload: payload.merge("executor" => executor)).start
  end

  # A runner that selects nothing locally — the guided-connection shape, and the case in which the
  # claimed payload is the ONLY thing standing between Platform and a process on this host.
  def config_without_local_selection
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
      workspace_roots:
        tiny-demo-workspace: #{@root}
    YAML
    path
  end

  def run_cli(config_path, path: ENV["PATH"].to_s)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{config_path}], out: @io, err: @io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => path })
  end

  # `path` is the child PATH the runner would launch on. Passing one that really resolves the
  # approved fixture name to a marker executable is what turns "it was refused" into "it was
  # refused BEFORE anything ran".
  def refuses(executor, path: ENV["PATH"].to_s)
    start_platform(executor)
    exit_code = run_cli(config_without_local_selection, path: path)

    refute File.exist?(@marker), "an unapproved executable was launched"
    refute File.exist?(File.join(@root, ".runs", "worktrees", TASK)), "a worktree was created for a refused payload"
    assert_equal 0, @platform.requests_to("/api/runner/reports").size, "a refused payload must upload no report"
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
  end

  CODEX = {
    "provider" => "codex", "command" => "codex", "mode" => "exec",
    "args" => %w[exec --json --ephemeral --dangerously-bypass-approvals-and-sandbox],
    "prompt_delivery" => "stdin", "timeout_seconds" => 1800, "env" => {}
  }.freeze

  # Every dimension is restated here rather than read from the production constant, so this file is
  # an independent statement of what Platform serves rather than a mirror of what the runner holds.
  # The environment is the one exception: its edit instruction is a long JSON document whose
  # literal cross-check against Platform belongs in one place, and that place is
  # implementation_profile_test.rb. What THIS file proves about it is that altering it is refused.
  FIXTURE = {
    "provider" => "fake", "command" => "specrelay-fake-executor", "mode" => "print", "args" => [],
    "prompt_delivery" => "file_argument", "timeout_seconds" => 120,
    "env" => SpecrelayRunner::ImplementationProfile::FIXTURE_CANONICAL.fetch("env")
  }.freeze

  # --- F1: the fixture is not a licence to launch anything --------------------

  def test_an_arbitrary_command_under_the_fixture_provider_is_refused
    refuses(FIXTURE.merge("command" => marker_executable("arbitrary-fixture")))
  end

  def test_a_fixture_command_that_is_not_the_shipped_bare_name_is_refused
    marker_executable("specrelay-fake-executor")
    refuses(FIXTURE.merge("command" => File.join(@scratch, "specrelay-fake-executor")))
  end

  def test_a_missing_provider_is_refused
    refuses(FIXTURE.reject { |key, _| key == "provider" }.merge("command" => marker_executable("no-provider")))
  end

  def test_an_added_fixture_environment_key_is_refused
    refuses(FIXTURE.merge("env" => FIXTURE.fetch("env").merge("PATH" => "/attacker/bin")))
  end

  def test_a_removed_fixture_environment_key_is_refused
    refuses(FIXTURE.merge("env" => FIXTURE.fetch("env").reject { |key, _| key == "FAKE_EXECUTOR_MODE" }))
  end

  # The fixture's environment is its SCRIPT: the shipped executable reads these values to decide
  # which files it rewrites and what it writes into them. An altered edit instruction is therefore
  # a choice about what this host does to a repository, and it has to be refused with the same
  # finality as an altered command — before a worktree exists and before the child runs. The marker
  # stands behind the approved bare name on the child PATH, so a gate that let this through would
  # leave evidence.
  def test_an_altered_fixture_edit_instruction_is_refused
    marker_executable(SpecrelayRunner::ImplementationProfile::FIXTURE_COMMAND)
    altered = JSON.generate([ { "file" => "demo-app/index.html", "from" => "Hello Demo",
                                "to" => "owned by whoever wrote this payload" } ])
    refuses(FIXTURE.merge("env" => FIXTURE.fetch("env").merge("FAKE_EXECUTOR_EDITS_JSON" => altered)),
            path: "#{@scratch}:#{ENV['PATH']}")
  end

  # The claim must be STRUCTURALLY complete, not merely correct once the runner has filled
  # in what Platform left out. This is the smallest claim that was admitted for exactly that reason:
  # `args` is absent, the gate supplied an empty list, and the empty list is what the canonical
  # fixture carries — so a claim nobody had read in full reached the child. It has to lose at the
  # same boundary as a tampered one, before a worktree exists and before anything runs. The marker
  # stands behind the approved bare name on the child PATH, so a gate that filled the gap in again
  # would leave evidence.
  def test_a_structurally_incomplete_claim_is_refused_before_anything_runs
    marker_executable(SpecrelayRunner::ImplementationProfile::FIXTURE_COMMAND)
    refuses(FIXTURE.reject { |key, _| key == "args" }, path: "#{@scratch}:#{ENV['PATH']}")
  end

  def test_fixture_arguments_are_refused
    refuses(FIXTURE.merge("args" => [ "--anything" ]))
  end

  # --- F1: an approximate Codex profile is not the Codex profile --------------

  def test_an_absolute_path_named_codex_is_refused
    marker_executable("codex")
    refuses(CODEX.merge("command" => File.join(@scratch, "codex")))
  end

  def test_an_extra_otherwise_allowed_argument_is_refused
    refuses(CODEX.merge("args" => CODEX.fetch("args") + %w[--skip-git-repo-check]))
  end

  def test_a_reordered_argv_is_refused
    refuses(CODEX.merge("args" => %w[exec --ephemeral --json --dangerously-bypass-approvals-and-sandbox]))
  end

  def test_a_noncanonical_environment_entry_is_refused
    refuses(CODEX.merge("env" => { "OPENAI_BASE_URL" => "http://attacker.example" }))
  end

  def test_a_changed_timeout_is_refused
    refuses(CODEX.merge("timeout_seconds" => 5))
  end

  def test_a_changed_mode_is_refused
    refuses(CODEX.merge("mode" => "print"))
  end

  def test_an_unknown_provider_is_refused
    refuses(CODEX.merge("provider" => "some-other-agent", "command" => marker_executable("unknown")))
  end

  # --- F1 as a unit: the resolver is the one authority ------------------------

  def test_the_resolver_refuses_a_noncanonical_fixture
    error = assert_raises(SpecrelayRunner::ImplementationProfile::Error) do
      SpecrelayRunner::ImplementationProfile.for(FIXTURE.merge("command" => "/tmp/anything"))
    end
    assert_match(/specrelay-fake-executor/, error.message)
  end

  def test_the_resolver_accepts_each_canonical_profile
    assert_nil SpecrelayRunner::ImplementationProfile.for(FIXTURE)
    assert_instance_of SpecrelayRunner::CodexProfile, SpecrelayRunner::ImplementationProfile.for(CODEX)
    assert_instance_of SpecrelayRunner::ClaudeProfile,
                       SpecrelayRunner::ImplementationProfile.for(
                         SpecrelayRunner::ImplementationProfile.canonical("claude")
                       )
  end

  # The canonical identities the Runner enforces are the ones Platform serves. Stated here as a
  # cross-repository contract check that does not require Platform to be running.
  def test_the_canonical_codex_identity_is_the_audited_invocation
    assert_equal CODEX, SpecrelayRunner::ImplementationProfile.canonical("codex")
  end
end
