# frozen_string_literal: true

require_relative "test_helper"

# MVP-0017 — the macOS Keychain adapter seam.
#
# The `security` command itself is not invoked here: shelling out to the real tool would
# touch the developer's Keychain and could raise an interactive prompt in CI. What must be
# proved instead is everything around it — that the platform gate refuses a non-macOS host
# with NO plaintext fallback, that the argv handed to the tool is an upsert carrying the
# credential as a distinct element (never a shell string), that a missing item is a normal
# empty result rather than an error, and that a failure message never echoes the credential.
class SecretStoreTest < Minitest::Test
  # Records the argv it was handed and returns a scripted result, so the exact command
  # line the adapter builds is assertable.
  class RecordingRunner
    attr_reader :invocations

    def initialize(results)
      @results = results
      @invocations = []
    end

    def run(argv, **_kwargs)
      @invocations << argv
      @results.shift
    end
  end

  # Every example drives exactly one invocation; asserting that keeps a silent extra call
  # from passing as a match on the first one.
  def single_invocation(runner)
    assert_equal 1, runner.invocations.size
    runner.invocations.first
  end

  def ok(stdout: "") = SpecrelayRunner::CommandRunner::Result.new(exit_code: 0, stdout: stdout, stderr: "", timed_out: false)
  def failed(stderr: "") = SpecrelayRunner::CommandRunner::Result.new(exit_code: 44, stdout: "", stderr: stderr, timed_out: false)

  # --- the platform gate ----------------------------------------------------

  def test_supports_macos
    assert SpecrelayRunner::SecretStore.macos?("arm64-darwin23")
    assert SpecrelayRunner::SecretStore.macos?("x86_64-darwin21")
  end

  def test_refuses_every_other_platform_with_no_plaintext_fallback
    %w[x86_64-linux aarch64-linux x64-mingw-ucrt].each do |platform|
      error = assert_raises(SpecrelayRunner::SecretStore::UnsupportedPlatform) do
        SpecrelayRunner::SecretStore.for(platform: platform)
      end

      assert_match(/only supported on macOS/, error.message)
      assert_match(/will not save a plaintext credential/, error.message)
    end
  end

  # --- the argv handed to `security` ----------------------------------------

  def test_writes_an_upsert_with_the_credential_as_a_distinct_argv_element
    runner = RecordingRunner.new([ ok ])
    store = SpecrelayRunner::SecretStore.new(runner: runner)

    assert store.write(account: "workspace:tiny-demo-workspace", credential: "src_abc")

    argv = single_invocation(runner)

    assert_equal %w[security add-generic-password], argv.first(2)
    # `-U` is what makes a reconnect an upsert instead of a duplicate-item error.
    assert_includes argv, "-U"
    assert_equal [ "-s", SpecrelayRunner::SecretStore::SERVICE ], argv.values_at(argv.index("-s"), argv.index("-s") + 1)
    # The credential is its own element, so no shell can word-split or expand it.
    assert_equal "src_abc", argv.last
    assert_equal "-w", argv[-2]
  end

  def test_reads_the_stored_credential
    runner = RecordingRunner.new([ ok(stdout: "src_abc\n") ])
    store = SpecrelayRunner::SecretStore.new(runner: runner)

    assert_equal "src_abc", store.read(account: "workspace:tiny-demo-workspace")
    assert_equal %w[security find-generic-password], single_invocation(runner).first(2)
  end

  # A runner that has not connected yet is a normal state, not a failure.
  def test_reads_nil_when_no_item_is_stored
    store = SpecrelayRunner::SecretStore.new(runner: RecordingRunner.new([ failed(stderr: "item not found") ]))

    assert_nil store.read(account: "workspace:tiny-demo-workspace")
  end

  def test_reads_nil_when_the_security_tool_cannot_be_launched
    store = SpecrelayRunner::SecretStore.new(runner: RecordingRunner.new([ nil ]))

    assert_nil store.read(account: "workspace:tiny-demo-workspace")
  end

  # --- failure reporting ----------------------------------------------------

  def test_a_denied_write_raises_with_a_remedy_and_never_echoes_the_credential
    store = SpecrelayRunner::SecretStore.new(
      runner: RecordingRunner.new([ failed(stderr: "User interaction is not allowed.") ])
    )

    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      store.write(account: "workspace:tiny-demo-workspace", credential: "src_super-secret")
    end

    assert_match(/macOS Keychain/, error.message)
    assert_match(/choose Allow/, error.message)
    assert_match(/User interaction is not allowed/, error.message)
    refute_includes error.message, "src_super-secret"
  end

  def test_a_credential_shaped_stderr_line_is_redacted_before_it_is_surfaced
    store = SpecrelayRunner::SecretStore.new(
      runner: RecordingRunner.new([ failed(stderr: "failed with token=src_leaked-value-1234567890") ])
    )

    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      store.write(account: "workspace:a", credential: "src_abc")
    end

    refute_includes error.message, "src_leaked-value-1234567890"
    assert_includes error.message, SpecrelayRunner::Redaction::REDACTION
  end

  # --- the account name is non-secret and workspace-scoped ------------------

  def test_the_keychain_account_names_only_the_workspace
    account = SpecrelayRunner::SecretStore.account_for("tiny-demo-workspace")

    assert_equal "workspace:tiny-demo-workspace", account
    # No local path, operator email, or provider account may appear in the key.
    refute_match(%r{/}, account)
    refute_includes account, "@"
  end
end
