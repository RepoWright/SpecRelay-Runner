# frozen_string_literal: true

require_relative "test_helper"

# WHICH provider generates a specification, and what happens to everything else that once could.
#
# The lane used to answer this question twice: `runner.specification.provider.kind` selected a
# deterministic composer or an arbitrary configured executable, while a separate Claude-only
# narrowing of the operator's real profile answered it for the real provider. Two answers to one
# question is how the live run that exposed this generated plausible prose from the composer while the
# operator believed they had selected a real model.
#
# There is now ONE authority — {SpecrelayRunner::ImplementationProfile}, the same exact whole-hash
# comparison the implementation lane launches against — and exactly two real providers behind it.
# The property under test is that nothing else can reach generation: not the fixture, not an
# unknown provider, not a profile that differs from the approved one by a single field, and not the
# configuration keys that used to name an arbitrary command.
class SpecificationProviderSelectionTest < Minitest::Test
  Provider = SpecrelayRunner::Specification::Provider
  Settings = SpecrelayRunner::Specification::Settings
  ImplementationProfile = SpecrelayRunner::ImplementationProfile
  Assignment = SpecrelayRunner::Specification::Assignment

  CLAUDE = SpecrelayRunner::ClaudeProfile::CANONICAL
  CODEX = SpecrelayRunner::CodexProfile::CANONICAL
  FIXTURE = ImplementationProfile::FIXTURE_CANONICAL

  def assignment_for(executor, profile: nil)
    Assignment.parse(spec_creation_payload_for(
                       issue_key: "SR-700",
                       specification_provider: { "profile" => profile, "executor" => executor }
                     ))
  end

  # ------------------------------------------------------------------ S01: the two real providers

  def test_each_approved_real_profile_resolves_to_its_own_adapter
    assert_equal "claude", Provider.resolve(profile: ImplementationProfile.for(CLAUDE), env: {}).kind
    assert_equal "codex", Provider.resolve(profile: ImplementationProfile.for(CODEX), env: {}).kind
  end

  def test_the_assignments_exact_profile_selects_the_matching_provider
    assert_equal "claude",
                 Provider.resolve(profile: assignment_for(CLAUDE).selected_implementation_profile, env: {}).kind
    assert_equal "codex",
                 Provider.resolve(profile: assignment_for(CODEX).selected_implementation_profile, env: {}).kind
  end

  # The claim is compared AS IT ARRIVED. A padded, differently cased provider names nothing in the
  # closed set; folding it into a match would be comparing what the gate wishes the claim had said.
  def test_a_decorated_provider_is_refused_rather_than_normalized
    error = assert_raises(ImplementationProfile::Error) do
      assignment_for(CODEX.merge("provider" => " Codex ")).selected_implementation_profile
    end

    assert_includes error.message, "not supported by this runner"
  end

  # ------------------------------------------------------------------ S02: one field is enough

  def test_every_missing_extra_or_altered_codex_field_is_refused
    {
      "a missing timeout" => CODEX.reject { |key, _| key == "timeout_seconds" },
      "a missing environment" => CODEX.reject { |key, _| key == "env" },
      "an extra top-level key" => CODEX.merge("model" => "o4"),
      "an altered argument list" => CODEX.merge("args" => CODEX.fetch("args") + [ "--output-schema" ]),
      "an altered command" => CODEX.merge("command" => "/tmp/codex"),
      "an altered prompt delivery" => CODEX.merge("prompt_delivery" => "argument"),
      "an altered timeout" => CODEX.merge("timeout_seconds" => 60),
      "an added environment entry" => CODEX.merge("env" => { "OPENAI_API_KEY" => "sk-live-000" })
    }.each do |described, executor|
      assert_raises(ImplementationProfile::Error, described) do
        assignment_for(executor).selected_implementation_profile
      end
    end
  end

  # A refusal names the dimension, never the claimed value: the claim is remote input and may
  # itself be the thing that must not be repeated into a log Platform stores.
  def test_a_refusal_never_echoes_the_claimed_environment_value
    error = assert_raises(ImplementationProfile::Error) do
      assignment_for(CODEX.merge("env" => { "OPENAI_API_KEY" => "sk-live-must-not-appear" }))
        .selected_implementation_profile
    end

    refute_includes error.message, "sk-live-must-not-appear"
  end

  def test_an_unknown_provider_is_refused_rather_than_treated_as_the_fixture
    error = assert_raises(ImplementationProfile::Error) do
      assignment_for(CLAUDE.merge("provider" => "wishful")).selected_implementation_profile
    end

    assert_includes error.message, "claude"
    assert_includes error.message, "codex"
  end

  # ------------------------------------------------------------------ S03: fixture is not absence

  # The fixture and an absent selection both resolve to NO real profile, and the lane has to tell
  # them apart: an operator who explicitly selected the deterministic fixture has decided this
  # machine does not generate specifications, and that decision must not fall through to whatever
  # Platform selected. The distinguishing fact is the selection block itself.
  def test_an_explicit_local_fixture_is_distinguishable_from_no_local_selection
    explicit = config_with("provider" => ImplementationProfile::FIXTURE)
    absent = config_with(nil)

    assert_nil explicit.selected_implementation_profile
    assert_nil absent.selected_implementation_profile
    refute_empty explicit.executor_override, "an explicit fixture selection must remain visible as a selection"
    assert_empty absent.executor_override
  end

  def test_the_assignments_fixture_selection_yields_no_real_provider
    assignment = assignment_for(FIXTURE, profile: ImplementationProfile::FIXTURE)

    assert_nil assignment.selected_implementation_profile
    assert_equal ImplementationProfile::FIXTURE, assignment.selected_provider_profile
  end

  # ------------------------------------------------------------------ S04: nothing else can run

  def test_no_profile_refuses_and_names_only_the_two_real_providers
    error = assert_raises(Provider::Unavailable) { Provider.resolve(profile: nil, env: {}) }

    assert_includes error.message, "no specification generation provider is configured"
    assert_includes error.message, "claude"
    assert_includes error.message, "codex"
    [ "composed", "command", "runner.specification.provider" ].each do |removed|
      refute_includes error.message, removed,
                      "the refusal must not send an operator to a configuration key that no longer selects anything"
    end
  end

  # The removed surface is removed, not merely unreachable: a configuration file or environment
  # variable that still names a kind or an arbitrary command selects nothing at all.
  def test_the_generation_provider_configuration_surface_no_longer_exists
    settings = Settings.new({ "provider" => { "kind" => "command", "command" => "/tmp/anything" } },
                            env: { "SPECRELAY_RUNNER_SPEC_PROVIDER" => "composed",
                                   "SPECRELAY_RUNNER_SPEC_PROVIDER_COMMAND" => "/tmp/anything" })

    %i[provider_kind provider_command provider_args provider_timeout_seconds
       composed_provider? claude_provider? provider_kind_configured?].each do |removed|
      refute_respond_to settings, removed
    end
    refute Settings.const_defined?(:PROVIDER_KIND_ENV), "the provider-kind environment override is gone"
    refute Settings.const_defined?(:PROVIDER_KINDS), "the lane has no provider-kind vocabulary of its own"
  end

  def test_the_composer_and_the_configured_command_are_no_longer_providers
    %i[Composed Command].each do |removed|
      refute Provider.const_defined?(removed, false),
             "#{removed} must not remain reachable as a production generation provider"
    end
  end

  # --------------------------------------------------- S02: a refused profile prepares nothing

  # Records what it was asked to do and does none of it, so "the exact profile was judged first"
  # becomes a statement about the operator's disk rather than about a return value. The real
  # store's `prepare!` runs `FileUtils.mkdir_p`, and `create` builds a git worktree — an ordering
  # regression therefore CREATES state on this machine for a claim the runner is about to refuse.
  class RecordingWorkspaceStore
    def initialize = @touched = []

    attr_reader :touched

    def root = File.join(Dir.tmpdir, "specrelay-recording-store-never-created")
    def overlaps?(_checkout) = false
    def prepare! = @touched << :prepare!
    def sweep(**) = @touched << :sweep
    def create(**) = @touched << :create
  end

  # Required behavior 1: an unknown, missing, extra or ALTERED profile refuses before source or
  # workspace preparation. The seed and the destination path are validated first because both are
  # pure reads that can each end the run on their own; everything after them that touches this
  # machine must come after the profile is known to be launchable.
  #
  # The profile here differs from the approved Codex hash by one field, which is the cheapest
  # thing a compromised or mis-built payload can be, and the hardest to notice.
  def test_an_altered_assignment_profile_refuses_before_the_workspace_root_is_prepared
    source, specs, temp = SpecificationWorkspace.build
    store = RecordingWorkspaceStore.new

    result = preflight_for(CODEX.merge("timeout_seconds" => 60), source: source, specs: specs,
                                                                 workspaces: store)

    assert result.refused?
    assert_equal "generation_provider_unavailable", result.failure_class
    assert_empty store.touched,
                 "an altered profile must be refused before the package workspace root is touched"
  ensure
    FileUtils.remove_entry(temp) if temp && File.directory?(temp)
  end

  # The same call with the APPROVED profile must still reach the workspace root, or the test above
  # would pass just as well against a preflight that refused everything.
  def test_the_approved_profile_still_reaches_the_workspace_root
    source, specs, temp = SpecificationWorkspace.build
    store = RecordingWorkspaceStore.new

    preflight_for(CODEX, source: source, specs: specs, workspaces: store)

    assert_includes store.touched, :prepare!
  ensure
    FileUtils.remove_entry(temp) if temp && File.directory?(temp)
  end

  def preflight_for(executor, source:, specs:, workspaces:)
    SpecrelayRunner::Specification::Preflight.call(
      assignment: assignment_for(executor),
      settings: Settings.new({ "repository_roots" => { "SpecRelay/SpecRelay-Specs" => specs } }, env: {}),
      config: config_with(nil),
      env: { "SPECRELAY_RUNNER_WORKSPACE_ROOT" => source, "HOME" => source },
      workspaces: workspaces
    )
  end

  def config_with(executor)
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    block = executor.nil? ? "" : "\n  executor: #{JSON.generate(executor)}"
    File.write(path, <<~YAML)
      platform:
        base_url: http://127.0.0.1:3200
        token_env: TEST_TOKEN
      runner:
        id: test-runner
        display_name: Test Runner#{block}
      workspace_roots:
        tiny-demo-workspace: /tmp/tiny-demo
    YAML
    SpecrelayRunner::Config.load(path)
  end
end

# MVP-0028 remediation slice 1, defect 8 — what the runner tells an operator about Jira.
#
# The successful publication log used to end with "No Jira field was written, no status was
# transitioned, and no comment was added." Every word was true of the runner, and it was printed
# immediately before Platform wrote all three. The last thing an operator read said the ticket was
# untouched at the moment it was being updated.
class SpecificationPublicationWordingTest < Minitest::Test
  SOURCE = File.expand_path("../lib/specrelay_runner/specification/publication.rb", __dir__)

  def source = @source ||= File.read(SOURCE)

  # Asserted against the SOURCE rather than a captured run, because the claim is about a sentence
  # that must not exist anywhere in the success path — and a log-capture test only proves it was
  # absent from the one path the fixture happened to take.
  def test_the_success_path_makes_no_time_sensitive_claim_about_jira_being_untouched
    emitted = source.lines.reject { |line| line.strip.start_with?("#") }.join

    refute_includes emitted, "No Jira field was written",
                    "the runner must not claim Jira is untouched immediately before Platform writes it"
    refute_includes emitted, "no comment was added"
  end

  # The replacement states a BOUNDARY, which stays true whenever it is read, rather than a moment,
  # which stops being true the instant Platform finalizes.
  def test_the_success_path_states_the_boundary_instead
    emitted = source.lines.reject { |line| line.strip.start_with?("#") }.join

    assert_includes emitted, "does not write Jira"
    assert_includes emitted, "Platform finalizes"
  end
end
