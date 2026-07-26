# frozen_string_literal: true

require_relative "test_helper"

# MVP-0017 — the macOS Keychain adapter seam.
#
# The `security` command itself is not invoked here: shelling out to the real tool would
# touch the developer's Keychain and could raise an interactive prompt in CI. What must be
# proved instead is everything around it — that the platform gate refuses a non-macOS host
# with NO plaintext fallback, that the argv handed to the tool is an upsert which does NOT
# contain the credential (round 002, review-001 F8: an argv element is visible in the process
# table, and `security` documents `-w` as insecure for exactly that reason), that the value is
# delivered on stdin instead, that a missing item is a normal empty result rather than an error,
# and that a failure message never echoes the credential.
class SecretStoreTest < Minitest::Test
  # Records the argv it was handed and returns a scripted result, so the exact command
  # line the adapter builds is assertable.
  class RecordingRunner
    # `stdins` is recorded alongside `invocations` so an example can assert both what the
    # adapter put on the command line and what it deliberately kept off it.
    attr_reader :invocations, :stdins

    def initialize(results)
      @results = results
      @invocations = []
      @stdins = []
    end

    def run(argv, **kwargs)
      @invocations << argv
      @stdins << kwargs[:stdin_data]
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

  def test_writes_an_upsert_that_keeps_the_credential_out_of_argv
    runner = RecordingRunner.new([ ok ])
    store = SpecrelayRunner::SecretStore.new(runner: runner)

    assert store.write(account: "workspace:tiny-demo-workspace", credential: "src_abc")

    argv = single_invocation(runner)

    assert_equal %w[security add-generic-password], argv.first(2)
    # `-U` is what makes a reconnect an upsert instead of a duplicate-item error.
    assert_includes argv, "-U"
    assert_equal [ "-s", SpecrelayRunner::SecretStore::SERVICE ], argv.values_at(argv.index("-s"), argv.index("-s") + 1)
    # THE point of this example: the credential is nowhere in the process's argv, so it is not
    # visible in the process table (review-001 F8).
    refute_includes argv, "src_abc"
    refute argv.any? { |element| element.include?("src_abc") }, "credential leaked into argv: #{argv.inspect}"
    # `-w` is last and valueless, which is what makes `security` prompt and read stdin.
    assert_equal "-w", argv.last
  end

  def test_delivers_the_credential_on_stdin_twice_for_the_confirmation_prompt
    runner = RecordingRunner.new([ ok ])
    store = SpecrelayRunner::SecretStore.new(runner: runner)

    store.write(account: "workspace:tiny-demo-workspace", credential: "src_abc")

    # `security` prompts for the password and then for a confirmation.
    assert_equal "src_abc\nsrc_abc\n", runner.stdins.first
  end

  # Reading needs no stdin at all; only the write path prompts.
  def test_reading_sends_no_stdin
    runner = RecordingRunner.new([ ok(stdout: "src_abc\n") ])
    store = SpecrelayRunner::SecretStore.new(runner: runner)

    store.read(account: "workspace:tiny-demo-workspace")

    assert_nil runner.stdins.first
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

  # --- the account name is non-secret and RUNNER-scoped ---------------------

  # Round 003 (review-002, F3 residual): the credential is per RUNNER
  # (`registered_runners.credential_digest`), so its Keychain account must be too. Keying it per
  # workspace meant a first-time connection to a second workspace rotated the shared credential
  # and orphaned the first workspace's stored copy.
  def test_the_keychain_account_names_only_the_runner_identity
    account = SpecrelayRunner::SecretStore.account_for_runner("rnr_ea88b7a19b174a9788acf36f2fac693d")

    assert_equal "runner:rnr_ea88b7a19b174a9788acf36f2fac693d", account
    # No local path, operator email, or provider account may appear in the key.
    refute_match(%r{/}, account)
    refute_includes account, "@"
  end

  # Retained for READS only, so a machine that connected under the old scheme keeps working.
  def test_the_legacy_workspace_account_name_is_unchanged
    assert_equal "workspace:tiny-demo-workspace",
                 SpecrelayRunner::SecretStore.legacy_account_for("tiny-demo-workspace")
  end

  def test_nothing_writes_to_the_legacy_account_any_more
    runner = RecordingRunner.new([ ok ])
    store = SpecrelayRunner::SecretStore.new(runner: runner)

    store.write(account: SpecrelayRunner::SecretStore.account_for_runner("rnr_x"), credential: "src_abc")

    argv = single_invocation(runner)

    assert_includes argv, "runner:rnr_x"
    refute argv.any? { |element| element.start_with?("workspace:") }
  end
end
