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
end
