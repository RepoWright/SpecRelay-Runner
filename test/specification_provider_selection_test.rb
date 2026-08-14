# frozen_string_literal: true

require_relative "test_helper"

# MVP-0028 remediation slice 1, defect 1 — WHICH provider generates a specification, and how an
# operator finds out.
#
# The live clean E2E selected "Claude Code (real provider)" and the run printed
# "Generating with built-in deterministic composer (no model, no network)". The cause was not a
# bug in the composer: `runner.specification` was absent from the operator's config, and an absent
# section resolved silently to `composed`. The implementation lane's real Claude profile was
# configured and simply never consulted by the specification lane.
#
# So the property under test is not "the composer works". It is that the composer can only be
# reached by ASKING for it, and that anything else is either the operator's real provider or a
# loud refusal — never a quiet substitution nobody sees until they read the generated prose.
class SpecificationProviderSelectionTest < Minitest::Test
  Settings = SpecrelayRunner::Specification::Settings
  Provider = SpecrelayRunner::Specification::Provider

  def settings_for(specification, env: {})
    Settings.new(specification, env: env)
  end

  def claude_profile(command: "claude", args: [ "--print", "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions" ])
    SpecrelayRunner::ClaudeProfile.new("provider" => "claude", "command" => command, "args" => args)
  end

  # ------------------------------------------------------------------ the silent substitution

  # The exact shape of the operator's live config: a real executor profile, and no
  # `runner.specification` section at all.
  def test_an_unconfigured_specification_provider_is_not_silently_the_composer
    settings = settings_for({})

    refute settings.composed_provider?,
           "an absent runner.specification must not silently select the deterministic composer"
    assert_nil settings.provider_kind,
               "an unconfigured provider must read as UNSET so the caller can decide, not as `composed`"
  end

  def test_an_unconfigured_provider_resolves_to_the_operators_real_claude_profile
    provider = Provider.resolve(settings: settings_for({}), claude_profile: claude_profile, env: {})

    assert_equal "claude", provider.kind
    assert_includes provider.describe, "claude"
    refute_includes provider.describe, "deterministic composer"
  end

  # No specification provider and no real profile is not a state to guess in. The operator gets a
  # refusal naming both ways out, which is what "never a silent substitute" means when there is
  # nothing to substitute WITH.
  def test_an_unconfigured_provider_with_no_real_profile_refuses_with_both_remedies
    error = assert_raises(Provider::Unavailable) do
      Provider.resolve(settings: settings_for({}), claude_profile: nil, env: {})
    end

    assert_includes error.message, "runner.specification.provider.kind"
    assert_includes error.message, "composed"
    assert_includes error.message, "claude"
  end

  # ------------------------------------------------------------------ explicit selection

  def test_the_composer_is_still_available_when_it_is_explicitly_asked_for
    settings = settings_for({ "provider" => { "kind" => "composed" } })

    assert settings.composed_provider?
    provider = Provider.resolve(settings: settings, claude_profile: claude_profile, env: {})

    assert_equal "composed", provider.kind
  end

  # The historical alias must keep working: an operator who wrote `fake` chose the fixture, and
  # this change must not turn their explicit choice into a refusal.
  def test_the_fake_alias_still_selects_the_composer_explicitly
    provider = Provider.resolve(settings: settings_for({ "provider" => { "kind" => "fake" } }),
                                claude_profile: nil, env: {})

    assert_equal "composed", provider.kind
  end

  def test_an_explicit_claude_kind_selects_the_real_profile
    provider = Provider.resolve(settings: settings_for({ "provider" => { "kind" => "claude" } }),
                                claude_profile: claude_profile, env: {})

    assert_equal "claude", provider.kind
  end

  # Asking for the real provider without having configured one is a refusal, not a fallback.
  def test_an_explicit_claude_kind_without_a_profile_refuses
    error = assert_raises(Provider::Unavailable) do
      Provider.resolve(settings: settings_for({ "provider" => { "kind" => "claude" } }),
                       claude_profile: nil, env: {})
    end

    assert_includes error.message, "runner.executor"
  end

  def test_the_environment_override_still_selects_a_kind
    settings = settings_for({}, env: { Settings::PROVIDER_KIND_ENV => "composed" })

    assert_equal "composed", settings.provider_kind
  end

  def test_an_unknown_kind_is_refused_by_name
    error = assert_raises(Settings::Error) { settings_for({ "provider" => { "kind" => "wishful" } }) }

    assert_includes error.message, "composed"
    assert_includes error.message, "claude"
  end

  # ------------------------------------------------------------------ the evidence

  # An operator must be able to answer "what wrote this?" from the recorded package rather than by
  # recognising the prose style. The manifest already carried the pair; what it must never do is
  # carry a value that disagrees with the provider that actually ran.
  def test_the_provider_reports_a_kind_and_description_that_agree
    [ Provider.resolve(settings: settings_for({ "provider" => { "kind" => "composed" } }),
                       claude_profile: nil, env: {}),
      Provider.resolve(settings: settings_for({}), claude_profile: claude_profile, env: {}) ].each do |provider|
      assert_includes Settings::PROVIDER_KINDS, provider.kind
      refute_empty provider.describe
    end
  end

  # The real profile's description is redacted and names the executable, so the run log and the
  # manifest identify the provider without disclosing argv the profile may carry.
  def test_the_claude_provider_description_is_non_secret_and_identifies_the_profile
    provider = Provider.resolve(settings: settings_for({}), claude_profile: claude_profile, env: {})

    assert_includes provider.describe, "claude"
    refute_includes provider.describe, "ANTHROPIC"
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
