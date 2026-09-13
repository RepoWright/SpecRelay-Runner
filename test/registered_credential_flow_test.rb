# frozen_string_literal: true

require_relative "test_helper"

# Proof that a machine holding a per-runner credential drives a full claim-once flow in
# REGISTERED mode over the real HTTP boundary against a fake Platform server.
#
# The credential is the only thing that authenticates the runner API, and it never touches the
# config file: it travels through the environment and the Authorization header. There is no
# command that mints one from a token any more — a machine gets its credential by connecting,
# which is the one path that also names the project it joined and the member who owns it.
class RegisteredCredentialFlowTest < Minitest::Test
  # The one directory on the child PATH that provides the approved fixture name. The PAYLOAD is
  # always the canonical fixture profile; which script that approved name resolves to on this
  # host is the test's choice, exactly as it is the operator's choice on a real machine.
  def fixture_dir = @fixture_dir ||= fixture_bin
  TASK = "DEMO-0001"

  def setup
    @root, @executor = DemoWorkspace.build
    use_fixture(fixture_dir, @executor)
    @platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK)).start
    @config = build_config
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
        id: local-dev-runner-one
        display_name: Local Developer Runner
        credential_env: TEST_CREDENTIAL
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{@root}
    YAML
    SpecrelayRunner::Config.load(path)
  end

  def claim_once(env)
    io = StringIO.new
    code = SpecrelayRunner::CLI.run(%W[claim-once --config #{@config.source_path}], out: io, err: io, env: env)
    [ code, io.string ]
  end

  def test_claim_once_runs_the_full_lifecycle_in_registered_mode
    code, output = claim_once("TEST_CREDENTIAL" => FakePlatform::ISSUED_CREDENTIAL,
                              "PATH" => "#{fixture_dir}:#{ENV['PATH']}")

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    assert_includes output, "registered runner credential"
    assert_equal 1, @platform.requests_to("/api/runner/claim").size
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
    # Every call carried the credential — the runner has no second way to authenticate.
    @platform.requests.each do |request|
      assert_equal "Bearer #{FakePlatform::ISSUED_CREDENTIAL}", request[:headers]["authorization"]
    end
  end

  # The retired token-enrollment command. Its endpoint is gone from Platform, and so is the
  # command: an operator who still types it is told it is unknown rather than sent at a path
  # that no longer answers.
  def test_the_withdrawn_registration_command_is_unknown
    io = StringIO.new
    code = SpecrelayRunner::CLI.run(%W[register --config #{@config.source_path}], out: io, err: io, env: {})

    assert_equal SpecrelayRunner::CLI::USAGE_ERROR, code
    assert_match(/unknown command: register/, io.string)
    assert_empty @platform.requests
  end
end
