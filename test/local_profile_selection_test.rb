# frozen_string_literal: true

require_relative "test_helper"

# The local `runner.executor:` block is a PROVIDER-ONLY selection, the same shape Platform accepts.
#
# It used to be a full profile on this side and a provider-only key on Platform's, so neither
# representation worked across both halves of the ordinary local-selection path: the shape Platform
# accepts raised here before readiness, and the shape written here was rejected there.
class LocalProfileSelectionTest < Minitest::Test
  def config_with(executor)
    body = { "platform" => { "base_url" => "http://127.0.0.1:3100", "token_env" => "TEST_TOKEN" },
             "runner" => { "id" => "r", "display_name" => "R",
                           "claim_policy" => { "mode" => "all_eligible" } } }
    body["runner"]["executor"] = executor if executor
    SpecrelayRunner::Config.new(body)
  end

  # --- the accepted shape ----------------------------------------------------

  def test_a_provider_only_codex_selection_resolves_the_canonical_profile
    profile = config_with("provider" => "codex").selected_implementation_profile

    assert_instance_of SpecrelayRunner::CodexProfile, profile
    assert_equal "codex", profile.command
    assert_equal %w[exec --json --ephemeral --dangerously-bypass-approvals-and-sandbox], profile.args
    assert_equal "stdin", profile.prompt_delivery
    assert_equal 1800, profile.timeout_seconds
  end

  def test_a_provider_only_claude_selection_resolves_the_canonical_profile
    profile = config_with("provider" => "claude").selected_implementation_profile

    assert_instance_of SpecrelayRunner::ClaudeProfile, profile
    assert_equal "claude", profile.command
    assert_equal "argument", profile.prompt_delivery
  end

  # The fixture selects no real profile, which is what keeps the offline path free of any provider
  # readiness check.
  def test_a_provider_only_fixture_selection_resolves_to_no_real_profile
    assert_nil config_with("provider" => "fake").selected_implementation_profile
  end

  def test_no_local_block_selects_nothing
    assert_nil config_with(nil).selected_implementation_profile
  end

  def test_the_selection_is_case_and_space_insensitive
    assert_instance_of SpecrelayRunner::CodexProfile,
                       config_with("provider" => "  Codex ").selected_implementation_profile
  end

  # --- everything else is refused, before any Platform request ---------------

  def test_a_local_block_carrying_a_command_is_refused
    error = assert_raises(SpecrelayRunner::Config::Error) do
      config_with({ "provider" => "codex", "command" => "/bin/sh" }).selected_implementation_profile
    end
    assert_match(/only a provider/, error.message)
    assert_match(/command/, error.message)
  end

  def test_a_local_block_carrying_its_own_argv_is_refused
    error = assert_raises(SpecrelayRunner::Config::Error) do
      config_with({ "provider" => "codex", "args" => %w[exec --json] }).selected_implementation_profile
    end
    assert_match(/only a provider/, error.message)
  end

  def test_a_local_block_carrying_an_environment_is_refused
    assert_raises(SpecrelayRunner::Config::Error) do
      config_with({ "provider" => "claude", "env" => { "ANTHROPIC_BASE_URL" => "x" } }).selected_implementation_profile
    end
  end

  def test_a_local_block_with_no_provider_is_refused
    assert_raises(SpecrelayRunner::Config::Error) { config_with({ "timeout_seconds" => 5 }).selected_implementation_profile }
  end

  def test_an_unsupported_local_provider_is_refused
    error = assert_raises(SpecrelayRunner::ImplementationProfile::Error) do
      config_with("provider" => "some-other-agent").selected_implementation_profile
    end
    assert_match(/some-other-agent/, error.message)
  end

  # The selection this runner sends to Platform is the same provider-only hash, so Platform can
  # expand it from its own fixed map. Sending anything wider is what Platform now refuses.
  def test_the_claim_request_carries_only_the_provider_key
    assert_equal({ "provider" => "codex" }, config_with("provider" => "codex").executor_override)
  end
end
