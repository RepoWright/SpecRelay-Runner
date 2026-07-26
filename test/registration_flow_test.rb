# frozen_string_literal: true

require_relative "test_helper"

# Proof that the standalone runner registers itself and then drives a full
# claim-once flow authenticated by its REGISTERED per-runner credential
# (MVP-0011), over the real HTTP boundary against a fake Platform server. The
# runner never stores a secret in its config: the registration token and the
# issued credential both travel only through the environment and the
# Authorization header.
class RegistrationFlowTest < Minitest::Test
  TASK = "DEMO-0001"

  def setup
    @root, @executor = DemoWorkspace.build
    @platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK, executor_command: @executor)).start
    @config = build_config
    @io = StringIO.new
  end

  def teardown
    @platform.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def build_config
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{@platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: local-dev-runner-1
        display_name: Local Developer Runner
        credential_env: TEST_CREDENTIAL
        registration_token_env: TEST_REG_TOKEN
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{@root}
    YAML
    SpecrelayRunner::Config.load(path)
  end

  def register(env)
    io = StringIO.new
    code = SpecrelayRunner::CLI.run(%W[register --config #{@config.source_path}], out: io, err: io, env: env)
    [ code, io.string ]
  end

  def test_register_then_claim_once_in_registered_mode
    # 1. Register with the one-time registration token (env-supplied, not in the file).
    code, output = register("TEST_REG_TOKEN" => FakePlatform::EXPECTED_REGISTRATION_TOKEN, "PATH" => ENV["PATH"])
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    assert_includes output, "Registered."
    assert_includes output, FakePlatform::ISSUED_CREDENTIAL # shown exactly once to the operator

    # The registration request carried the registration token as the bearer and
    # the runner identity in the body — never a credential.
    registration = @platform.last_registration
    assert_equal "Bearer #{FakePlatform::EXPECTED_REGISTRATION_TOKEN}", registration[:headers]["authorization"]
    assert_equal "local-dev-runner-1", registration.dig(:body, "runner", "id")

    # 2. claim-once authenticated by the ISSUED credential (registered mode).
    io = StringIO.new
    code = SpecrelayRunner::CLI.run(
      %W[claim-once --config #{@config.source_path}], out: io, err: io,
      env: { "TEST_CREDENTIAL" => FakePlatform::ISSUED_CREDENTIAL, "PATH" => ENV["PATH"] }
    )
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, io.string
    assert_includes io.string, "registered runner credential"

    # The full lifecycle ran over HTTP using the registered credential as bearer.
    assert_equal 1, @platform.requests_to("/api/runner/claim").size
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
    api_calls = @platform.requests.reject { |r| r[:path] == "/api/runner/registration" }
    api_calls.each do |request|
      assert_equal "Bearer #{FakePlatform::ISSUED_CREDENTIAL}", request[:headers]["authorization"]
    end
  end

  def test_register_rejects_when_no_registration_token_is_set
    code, output = register("PATH" => ENV["PATH"])
    assert_equal SpecrelayRunner::CLI::USAGE_ERROR, code
    assert_match(/TEST_REG_TOKEN/, output)
  end

  def test_register_reports_a_rejected_token_without_leaking_it
    code, output = register("TEST_REG_TOKEN" => "srt_wrong-token", "PATH" => ENV["PATH"])
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code
    assert_match(/Registration failed/, output)
    refute_includes output, "srt_wrong-token"
  end
end
