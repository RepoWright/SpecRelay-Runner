# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  def write_config(body)
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, body)
    path
  end

  def valid_config
    <<~YAML
      platform:
        base_url: http://127.0.0.1:3000
        token_env: MY_TOKEN
      runner:
        id: r1
        display_name: Runner One
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{Dir.mktmpdir('ws')}
    YAML
  end

  def test_loads_a_valid_config
    config = SpecrelayRunner::Config.load(write_config(valid_config))
    assert_equal "http://127.0.0.1:3000", config.base_url
    assert_equal "r1", config.runner["id"]
  end

  def test_reads_token_from_env_never_the_file
    config = SpecrelayRunner::Config.load(write_config(valid_config))
    assert_equal "secret-value", config.api_token(env: { "MY_TOKEN" => "secret-value" })
  end

  def test_raises_when_token_env_is_unset
    config = SpecrelayRunner::Config.load(write_config(valid_config))
    error = assert_raises(SpecrelayRunner::Config::Error) { config.api_token(env: {}) }
    assert_match(/MY_TOKEN/, error.message)
  end

  def test_requires_base_url
    body = valid_config.sub("base_url: http://127.0.0.1:3000\n", "")
    assert_raises(SpecrelayRunner::Config::Error) { SpecrelayRunner::Config.load(write_config(body)) }
  end

  def test_requires_runner_identity
    body = valid_config.sub("id: r1\n", "")
    assert_raises(SpecrelayRunner::Config::Error) { SpecrelayRunner::Config.load(write_config(body)) }
  end

  def test_resolves_workspace_root_from_env_first
    config = SpecrelayRunner::Config.load(write_config(valid_config))
    root = Dir.mktmpdir("explicit")
    resolved = config.workspace_root("tiny-demo-workspace",
                                     env: { "SPECRELAY_RUNNER_WORKSPACE_ROOT_TINY_DEMO_WORKSPACE" => root })
    assert_equal root, resolved
  end

  def test_missing_config_file_is_a_clear_error
    error = assert_raises(SpecrelayRunner::Config::Error) { SpecrelayRunner::Config.load("/no/such/file.yml") }
    assert_match(/not found/, error.message)
  end

  # --- Registered-mode auth resolution (MVP-0011) ----------------------------

  def registered_config
    <<~YAML
      platform:
        base_url: http://127.0.0.1:3000
        token_env: MY_TOKEN
      runner:
        id: r1
        display_name: Runner One
        credential_env: MY_CREDENTIAL
        registration_token_env: MY_REG_TOKEN
        claim_policy:
          mode: all_eligible
    YAML
  end

  def test_resolve_auth_prefers_the_registered_credential
    config = SpecrelayRunner::Config.load(write_config(registered_config))
    auth = config.resolve_auth(env: { "MY_CREDENTIAL" => "src_cred", "MY_TOKEN" => "dev" })
    assert_equal :registered, auth.mode
    assert_equal "src_cred", auth.token
  end

  def test_resolve_auth_falls_back_to_development_token
    config = SpecrelayRunner::Config.load(write_config(registered_config))
    auth = config.resolve_auth(env: { "MY_TOKEN" => "dev" })
    assert_equal :development, auth.mode
    assert_equal "dev", auth.token
  end

  def test_resolve_auth_requires_one_of_the_two
    config = SpecrelayRunner::Config.load(write_config(registered_config))
    assert_raises(SpecrelayRunner::Config::Error) { config.resolve_auth(env: {}) }
  end

  def test_registration_token_reads_from_env_never_the_file
    config = SpecrelayRunner::Config.load(write_config(registered_config))
    assert_equal "srt_one-time", config.registration_token(env: { "MY_REG_TOKEN" => "srt_one-time" })
    assert_raises(SpecrelayRunner::Config::Error) { config.registration_token(env: {}) }
  end

  # --- selecting the real executor profile (MVP-0016) ------------------------

  def config_with_executor(block)
    SpecrelayRunner::Config.load(write_config(<<~YAML))
      platform:
        base_url: http://127.0.0.1:3300
      runner:
        id: r1
        display_name: Runner One
        claim_policy:
          mode: all_eligible
        executor:
      #{block.lines.map { |line| "      #{line}" }.join.rstrip}
    YAML
  end

  # No override at all: the deterministic fake-executor regression path, which must
  # never require Claude Code to be installed or authenticated.
  def test_no_executor_override_selects_no_real_profile
    config = SpecrelayRunner::Config.load(write_config(valid_config))

    assert_empty config.executor_override
    assert_nil config.selected_claude_profile
  end

  def test_a_non_claude_override_selects_no_real_profile
    config = config_with_executor(<<~YAML)
      provider: fake
      command: specrelay-fake-executor
    YAML

    assert_equal "fake", config.executor_override["provider"]
    assert_nil config.selected_claude_profile
  end

  def test_a_claude_override_selects_the_real_profile
    config = config_with_executor(<<~YAML)
      provider: claude
      command: claude
      args: [--print, --output-format, stream-json, --verbose, --dangerously-skip-permissions]
      prompt_delivery: argument
      timeout_seconds: 900
      env: {}
    YAML

    profile = config.selected_claude_profile
    refute_nil profile
    assert_equal %w[--print --output-format stream-json --verbose --dangerously-skip-permissions], profile.args
    # The override is non-secret logical config and is what Platform merges.
    assert_equal 900, config.executor_override["timeout_seconds"]
  end

  # --- reconstructing a guided connection (MAPIAI-91) ------------------------

  def stored_connection(reviewer_provider: nil)
    SpecrelayRunner::ConnectionStore::Connection.new(
      base_url: "http://127.0.0.1:3100", runner_id: "host-runner", runner_public_id: "rnr_one",
      runner_display_name: "host runner", project_slug: "tiny-demo",
      workspace_key: "tiny-demo-workspace", project_key: "tiny-demo",
      workspace_display_name: "Tiny Demo Workspace",
      repository_url: "https://github.com/SpecRelay/tiny-demo-workspace", default_branch: "main",
      local_path: Dir.mktmpdir("ws"), reviewer_provider: reviewer_provider,
      connected_at: "2026-08-17T00:00:00Z"
    )
  end

  # The stored selection is reconstructed into the EXISTING `runner.reviewer:` shape, so
  # {Review::Settings} stays the single owner of provider precedence and launch defaults.
  def test_a_guided_connection_reconstructs_the_stored_reviewer_provider
    config = SpecrelayRunner::Config.from_connection(stored_connection(reviewer_provider: "claude"),
                                                    credential: "src_from-keychain")

    assert_equal({ "provider" => "claude" }, config.reviewer_settings)
    assert_equal "claude", SpecrelayRunner::Review::Settings.from(config, env: {}).provider
  end

  # No stored selection means NO reviewer — never one inferred from the executor, PATH, or a
  # default. The connection stays completely usable for non-review work.
  def test_a_connection_without_a_stored_reviewer_provider_configures_no_reviewer
    config = SpecrelayRunner::Config.from_connection(stored_connection, credential: "src_from-keychain")

    assert_empty config.reviewer_settings
    refute SpecrelayRunner::Review::Settings.from(config, env: {}).configured?
    assert_equal :registered, config.resolve_auth(env: {}).mode
    assert_equal config.connection.local_path, config.workspace_root("tiny-demo-workspace", env: {})
  end

  # A selected profile the runner refuses to launch is an operator config error,
  # surfaced by the CLI before any Platform request.
  def test_an_unsafe_claude_override_raises
    config = config_with_executor(<<~YAML)
      provider: claude
      command: claude
      args: [--print, --output-format, stream-json, --verbose, --resume]
    YAML

    error = assert_raises(SpecrelayRunner::ClaudeProfile::Error) { config.selected_claude_profile }
    assert_match(/--resume/, error.message)
  end
end
