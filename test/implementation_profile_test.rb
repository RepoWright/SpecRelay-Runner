# frozen_string_literal: true

require_relative "test_helper"

# The ONE closed choice every implementation executor is resolved through: Claude, Codex, or the
# shipped deterministic fixture, each by EXACT identity. Nothing else resolves.
#
# The flow-level proof that a refusal happens before a worktree exists and before any process runs
# lives in exact_profile_identity_test.rb; this file is the unit contract underneath it.
class ImplementationProfileTest < Minitest::Test
  CLAUDE = SpecrelayRunner::ClaudeProfile::CANONICAL
  CODEX = SpecrelayRunner::CodexProfile::CANONICAL
  FIXTURE = SpecrelayRunner::ImplementationProfile::FIXTURE_CANONICAL

  # The edit instruction Platform's deterministic demo profile carries, restated independently of
  # the runner's own constant, so the agreement asserted below is a real comparison.
  PLATFORM_EDITS = [
    { "file" => "demo-app/index.html", "from" => "Hello Demo", "to" => "SpecRelay Runner Repository Extraction" },
    { "file" => "demo-app/test/homepage.test.mjs", "from" => "Hello Demo",
      "to" => "SpecRelay Runner Repository Extraction" }
  ].freeze

  def resolve(config) = SpecrelayRunner::ImplementationProfile.for(config)

  # --- the closed set --------------------------------------------------------

  def test_the_claude_profile_resolves_to_the_claude_owner
    assert_instance_of SpecrelayRunner::ClaudeProfile, resolve(CLAUDE)
  end

  def test_the_codex_profile_resolves_to_the_codex_owner
    assert_instance_of SpecrelayRunner::CodexProfile, resolve(CODEX)
  end

  # The fixture has no real provider to own, so it resolves to no profile — which is what keeps the
  # offline regression path free of any provider readiness check.
  def test_the_deterministic_fixture_resolves_to_no_real_profile
    assert_nil resolve(FIXTURE)
  end

  def test_the_supported_providers_are_exactly_claude_codex_and_the_fixture
    assert_equal %w[claude codex fake], SpecrelayRunner::ImplementationProfile::PROVIDERS.sort
  end

  # --- everything else is refused --------------------------------------------

  # The claim must BE a canonical hash, not merely resemble one after the runner has tidied it up.
  # Every one of these was accepted while the gate normalized the claim first: a missing field was
  # filled in from a default, an absent environment became an empty one, an unknown key was never
  # looked at, and a decorated provider was trimmed and case-folded into a match. Platform emits
  # the complete hash, so none of these shapes has a legitimate source.

  def test_an_omitted_timeout_is_refused_rather_than_defaulted
    error = assert_raises(SpecrelayRunner::ImplementationProfile::Error) do
      resolve(CODEX.reject { |key, _| key == "timeout_seconds" })
    end
    assert_match(/executor is missing timeout_seconds/, error.message)
  end

  def test_an_omitted_environment_is_refused_rather_than_assumed_empty
    error = assert_raises(SpecrelayRunner::ImplementationProfile::Error) do
      resolve(CODEX.reject { |key, _| key == "env" })
    end
    assert_match(/executor is missing env/, error.message)
  end

  # An unknown key is a claim this runner does not understand. Ignoring it would mean launching on
  # the strength of a hash nobody has read in full.
  def test_an_extra_top_level_key_is_refused_rather_than_ignored
    error = assert_raises(SpecrelayRunner::ImplementationProfile::Error) do
      resolve(CODEX.merge("semantic_events" => "auto"))
    end
    assert_match(/executor carries semantic_events/, error.message)
  end

  def test_a_decorated_provider_is_refused_rather_than_trimmed
    error = assert_raises(SpecrelayRunner::ImplementationProfile::Error) do
      resolve(CODEX.merge("provider" => "  Codex "))
    end
    assert_match(/is not supported by this runner/, error.message)
  end

  # A value of the right shape but the wrong type is a different claim, so it is refused for the
  # same reason a different value is.
  def test_a_timeout_written_as_a_string_is_refused
    error = assert_raises(SpecrelayRunner::ImplementationProfile::Error) do
      resolve(CODEX.merge("timeout_seconds" => "1800"))
    end
    assert_match(/executor\.timeout_seconds is not the approved codex profile/, error.message)
  end

  def test_an_unknown_provider_is_refused_rather_than_treated_as_the_fixture
    error = assert_raises(SpecrelayRunner::ImplementationProfile::Error) do
      resolve(CODEX.merge("provider" => "some-other-agent"))
    end
    assert_match(/some-other-agent/, error.message)
    assert_match(/claude, codex, fake/, error.message)
  end

  def test_a_missing_provider_is_refused
    error = assert_raises(SpecrelayRunner::ImplementationProfile::Error) do
      resolve(CODEX.reject { |key, _| key == "provider" })
    end
    assert_match(/provider is required/, error.message)
  end

  def test_an_absent_or_empty_executor_block_is_refused
    assert_raises(SpecrelayRunner::ImplementationProfile::Error) { resolve(nil) }
    assert_raises(SpecrelayRunner::ImplementationProfile::Error) { resolve({}) }
  end

  # Each identity dimension, named in the refusal so an operator can see which one differed.
  { "command" => "/opt/elsewhere/codex", "mode" => "print", "args" => %w[exec --json],
    "prompt_delivery" => "argument", "timeout_seconds" => 30,
    "env" => { "OPENAI_BASE_URL" => "http://attacker.example" } }.each do |field, value|
    define_method("test_a_changed_#{field}_is_refused") do
      error = assert_raises(SpecrelayRunner::ImplementationProfile::Error) { resolve(CODEX.merge(field => value)) }
      assert_match(/executor\.#{field} is not the approved codex profile/, error.message)
    end
  end

  # A refusal names the dimension and what it must be; it never echoes the claimed value, which is
  # remote input and may itself be the thing that should not be repeated into a log.
  def test_a_refusal_never_echoes_the_claimed_value
    error = assert_raises(SpecrelayRunner::ImplementationProfile::Error) do
      resolve(CODEX.merge("command" => "/opt/attacker/secret-tool"))
    end
    refute_match(%r{/opt/attacker/secret-tool}, error.message)
  end

  # --- the fixture environment is pinned, not merely namespaced ---------------

  # The ONE literal cross-check of the fixture environment against the profile Platform serves
  # (Demo::TinyDemoExecutorConfig.build). The two repositories cannot share a constant, so the
  # agreement is asserted rather than assumed: if either side changes this document, the fixture
  # assignment stops resolving and this example says so.
  def test_the_canonical_fixture_environment_is_the_one_platform_serves
    assert_equal({ "FAKE_EXECUTOR_MODE" => "success",
                   "FAKE_EXECUTOR_EDITS_JSON" => JSON.generate(PLATFORM_EDITS) },
                 FIXTURE.fetch("env"))
  end

  # Each of the three ways an environment can differ. The fixture's environment is its SCRIPT — the
  # shipped executable reads it to decide which files it rewrites and what it writes into them — so
  # it is pinned exactly like the command, not bounded by a namespace rule.
  def test_an_added_fixture_environment_key_is_refused
    refuses_fixture_environment(FIXTURE.fetch("env").merge("PATH" => "/attacker/bin"))
  end

  def test_a_removed_fixture_environment_key_is_refused
    refuses_fixture_environment(FIXTURE.fetch("env").reject { |key, _| key == "FAKE_EXECUTOR_MODE" })
  end

  def test_an_altered_fixture_edit_instruction_is_refused
    altered = JSON.generate([ { "file" => "demo-app/index.html", "from" => "Hello Demo",
                                "to" => "owned by whoever wrote this payload" } ])
    refuses_fixture_environment(FIXTURE.fetch("env").merge("FAKE_EXECUTOR_EDITS_JSON" => altered))
  end

  def refuses_fixture_environment(env)
    error = assert_raises(SpecrelayRunner::ImplementationProfile::Error) { resolve(FIXTURE.merge("env" => env)) }
    assert_match(/executor\.env is not the approved fake profile/, error.message)
  end

  def test_the_fixture_command_must_be_the_shipped_bare_name
    error = assert_raises(SpecrelayRunner::ImplementationProfile::Error) do
      resolve(FIXTURE.merge("command" => "/tmp/anything"))
    end
    assert_match(/specrelay-fake-executor/, error.message)
  end

  # --- the canonical map is what a provider-only selection expands to ---------

  def test_canonical_returns_the_approved_identity_for_each_provider
    assert_equal CLAUDE, SpecrelayRunner::ImplementationProfile.canonical("claude")
    assert_equal CODEX, SpecrelayRunner::ImplementationProfile.canonical("codex")
    assert_equal FIXTURE, SpecrelayRunner::ImplementationProfile.canonical("fake")
  end

  def test_canonical_refuses_an_unsupported_provider
    assert_raises(SpecrelayRunner::ImplementationProfile::Error) do
      SpecrelayRunner::ImplementationProfile.canonical("some-other-agent")
    end
  end
end
