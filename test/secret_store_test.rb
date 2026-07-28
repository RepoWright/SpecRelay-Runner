# frozen_string_literal: true

require_relative "test_helper"

# MVP-0017 — the macOS Keychain adapter seam.
#
# The real `security` command is not invoked here: shelling out to it would touch the
# developer's Keychain and could raise an interactive prompt in CI. What is proved instead is
# everything around the tool — the platform gate refuses a non-macOS host with NO plaintext
# fallback; the argv handed to the tool never contains the credential (an argv element is
# visible in the process table, review-001 F8); the value is delivered on stdin; every write is
# read back and a mismatch is undone; a missing item is a normal empty result; and no failure
# message ever echoes the credential.
#
# The one thing a fake runner CANNOT prove is how the real tool reads a prompt. That is what
# shipped broken in round 002, and it is covered by `keychain_tty_test.rb` under a real pty.
class SecretStoreTest < Minitest::Test
  SERVICE = SpecrelayRunner::SecretStore::SERVICE
  ACCOUNT = "runner:rnr_ea88b7a19b174a9788acf36f2fac693d"

  # Records argv AND stdin for every invocation and returns scripted results, so a test can
  # assert both what the adapter put on the command line and what it deliberately kept off it.
  class RecordingRunner
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

    # Every invocation's argv, flattened, for "the credential is nowhere in argv" assertions.
    def all_argv = invocations.flatten
  end

  def ok(stdout: "") = SpecrelayRunner::CommandRunner::Result.new(exit_code: 0, stdout: stdout, stderr: "", timed_out: false)
  def failed(stderr: "") = SpecrelayRunner::CommandRunner::Result.new(exit_code: 44, stdout: "", stderr: stderr, timed_out: false)

  # A runner scripted for a SUCCESSFUL write: the interactive upsert, then the verifying
  # read-back returning what was stored.
  def write_runner(stored:)
    RecordingRunner.new([ ok, ok(stdout: "#{stored}\n") ])
  end

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

  # --- how the credential is delivered --------------------------------------

  def test_the_write_is_an_interactive_invocation_with_nothing_secret_in_argv
    runner = write_runner(stored: "src_abc")
    store = SpecrelayRunner::SecretStore.new(runner: runner)

    assert store.write(account: ACCOUNT, credential: "src_abc")

    # THE point of this example: the credential is in no process's argv, so it is not visible
    # in the process table (review-001 F8).
    assert_equal %w[security -i], runner.invocations.first
    refute runner.all_argv.any? { |element| element.include?("src_abc") },
           "credential leaked into argv: #{runner.all_argv.inspect}"
  end

  def test_the_credential_is_delivered_on_stdin_as_an_upsert
    runner = write_runner(stored: "src_abc")
    SpecrelayRunner::SecretStore.new(runner: runner).write(account: ACCOUNT, credential: "src_abc")

    command = runner.stdins.first

    assert_equal "add-generic-password -a #{ACCOUNT} -s #{SERVICE} -U -w src_abc\n", command
    # `-U` is what makes a reconnect an upsert instead of a duplicate-item error.
    assert_includes command, " -U "
  end

  # The regression guard for the shipped defect, at the unit level: a valueless `-w` means
  # "prompt", and the real tool reads that prompt from /dev/tty, not from the pipe we control.
  # Nothing in the write path may ever depend on being prompted again.
  def test_the_write_never_asks_the_tool_to_prompt
    runner = write_runner(stored: "src_abc")
    SpecrelayRunner::SecretStore.new(runner: runner).write(account: ACCOUNT, credential: "src_abc")

    refute_equal "-w", runner.invocations.first.last,
                 "a trailing valueless -w makes `security` prompt on the terminal, not read stdin"
    refute_includes runner.invocations.first, "add-generic-password"
  end

  # Reading needs no stdin at all; only the write path carries one.
  def test_reading_sends_no_stdin
    runner = RecordingRunner.new([ ok(stdout: "src_abc\n") ])
    store = SpecrelayRunner::SecretStore.new(runner: runner)

    store.read(account: ACCOUNT)

    assert_nil runner.stdins.first
  end

  def test_reads_the_stored_credential
    runner = RecordingRunner.new([ ok(stdout: "src_abc\n") ])
    store = SpecrelayRunner::SecretStore.new(runner: runner)

    assert_equal "src_abc", store.read(account: ACCOUNT)
    assert_equal %w[security find-generic-password], runner.invocations.first.first(2)
  end

  # A runner that has not connected yet is a normal state, not a failure.
  def test_reads_nil_when_no_item_is_stored
    store = SpecrelayRunner::SecretStore.new(runner: RecordingRunner.new([ failed(stderr: "item not found") ]))

    assert_nil store.read(account: ACCOUNT)
  end

  def test_reads_nil_when_the_security_tool_cannot_be_launched
    store = SpecrelayRunner::SecretStore.new(runner: RecordingRunner.new([ nil ]))

    assert_nil store.read(account: ACCOUNT)
  end

  # --- the write is verified, not assumed -----------------------------------

  def test_a_write_is_read_back_before_it_is_reported_as_saved
    runner = write_runner(stored: "src_abc")
    SpecrelayRunner::SecretStore.new(runner: runner).write(account: ACCOUNT, credential: "src_abc")

    assert_equal 2, runner.invocations.size, "the write must be verified by a read-back"
    assert_equal %w[security find-generic-password], runner.invocations.last.first(2)
  end

  # `security -i` splits its command line on whitespace and still exits 0 after storing a
  # truncated value — measured against the real tool. A stored value that is not the credential
  # would surface much later as an unexplained authentication failure, so it is undone here.
  def test_a_write_that_stored_something_else_is_removed_and_raises
    runner = RecordingRunner.new([ ok, ok(stdout: "src_ab\n"), ok ])
    store = SpecrelayRunner::SecretStore.new(runner: runner)

    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      store.write(account: ACCOUNT, credential: "src_abc")
    end

    assert_match(/did not store the runner credential exactly as issued/, error.message)
    assert_equal %w[security delete-generic-password], runner.invocations.last.first(2)
    refute_includes error.message, "src_abc"
  end

  # Refused up front rather than silently truncated.
  def test_a_credential_the_tool_cannot_receive_intact_is_refused_without_writing
    runner = RecordingRunner.new([ ok, ok ])
    store = SpecrelayRunner::SecretStore.new(runner: runner)

    [ "src_a b", "src_a\\b", "src_a\"b", "src_a'b", "src_a\tb" ].each do |credential|
      error = assert_raises(SpecrelayRunner::SecretStore::Error) do
        store.write(account: ACCOUNT, credential: credential)
      end

      assert_match(/whitespace, a quote, or a backslash/, error.message)
      refute_includes error.message, credential
    end

    assert_empty runner.invocations, "nothing may be handed to the tool when the value is refused"
  end

  def test_an_empty_credential_is_refused
    runner = RecordingRunner.new([ ok ])

    assert_raises(SpecrelayRunner::SecretStore::Error) do
      SpecrelayRunner::SecretStore.new(runner: runner).write(account: ACCOUNT, credential: "  ")
    end
    assert_empty runner.invocations
  end

  # --- the writability pre-flight -------------------------------------------

  # `connect` calls this BEFORE spending the one-time enrollment code, so a machine whose
  # Keychain cannot be written to fails at no cost.
  def test_verifying_writability_uses_a_throwaway_item_and_removes_it
    runner = RecordingRunner.new([ ok, ok(stdout: "#{SpecrelayRunner::SecretStore::PROBE_VALUE}\n"), ok ])
    store = SpecrelayRunner::SecretStore.new(runner: runner)

    assert store.verify_writable!

    assert_equal %w[security -i], runner.invocations.first
    assert_includes runner.stdins.first, SpecrelayRunner::SecretStore::PROBE_ACCOUNT
    # The probe value is fixed and meaningless — a real credential is never used to test.
    assert_includes runner.stdins.first, SpecrelayRunner::SecretStore::PROBE_VALUE
    # And the probe item does not outlive the check.
    assert_equal %w[security delete-generic-password], runner.invocations.last.first(2)
    assert_includes runner.invocations.last, SpecrelayRunner::SecretStore::PROBE_ACCOUNT
  end

  def test_a_failed_writability_check_raises_and_still_removes_the_probe
    runner = RecordingRunner.new([ failed(stderr: "User interaction is not allowed."), ok ])
    store = SpecrelayRunner::SecretStore.new(runner: runner)

    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      store.verify_writable!
    end

    assert_match(/Keychain writability check/, error.message)
    assert_match(/Unlock your login keychain/, error.message)
    assert_equal %w[security delete-generic-password], runner.invocations.last.first(2)
  end

  # --- failure reporting ----------------------------------------------------

  def test_a_denied_write_raises_with_a_remedy_and_never_echoes_the_credential
    store = SpecrelayRunner::SecretStore.new(
      runner: RecordingRunner.new([ failed(stderr: "User interaction is not allowed.") ])
    )

    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      store.write(account: ACCOUNT, credential: "src_super-secret")
    end

    assert_match(/macOS Keychain/, error.message)
    assert_match(/Unlock your login keychain/, error.message)
    assert_match(/User interaction is not allowed/, error.message)
    refute_includes error.message, "src_super-secret"
  end

  def test_a_credential_shaped_stderr_line_is_redacted_before_it_is_surfaced
    store = SpecrelayRunner::SecretStore.new(
      runner: RecordingRunner.new([ failed(stderr: "failed with token=src_leaked-value-1234567890") ])
    )

    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      store.write(account: ACCOUNT, credential: "src_abc")
    end

    refute_includes error.message, "src_leaked-value-1234567890"
    assert_includes error.message, SpecrelayRunner::Redaction::REDACTION
  end

  def test_a_tool_that_cannot_be_launched_is_reported_as_such
    store = SpecrelayRunner::SecretStore.new(runner: RecordingRunner.new([ nil ]))

    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      store.write(account: ACCOUNT, credential: "src_abc")
    end

    assert_match(/could not be run/, error.message)
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
    runner = write_runner(stored: "src_abc")
    store = SpecrelayRunner::SecretStore.new(runner: runner)

    store.write(account: SpecrelayRunner::SecretStore.account_for_runner("rnr_x"), credential: "src_abc")

    assert_includes runner.stdins.first, "runner:rnr_x"
    refute_includes runner.stdins.first, "workspace:"
  end

  # An account name is not attacker-controlled today, but it is interpolated into the same
  # stdin command line, so it gets the same guard rather than a comment promising it is safe.
  def test_an_account_name_that_could_alter_the_command_line_is_refused
    runner = RecordingRunner.new([ ok, ok ])

    assert_raises(SpecrelayRunner::SecretStore::Error) do
      SpecrelayRunner::SecretStore.new(runner: runner)
                                  .write(account: "runner:x -w injected", credential: "src_abc")
    end
    assert_empty runner.invocations
  end

  # --- deletion (MVP-0021 scope 5) ------------------------------------------

  def test_deleting_a_credential_addresses_exactly_that_account_and_service
    runner = RecordingRunner.new([ ok ])

    assert SpecrelayRunner::SecretStore.new(runner: runner).delete_credential(account: ACCOUNT)
    assert_equal [ [ "security", "delete-generic-password", "-a", ACCOUNT, "-s", SERVICE ] ],
                 runner.invocations
  end

  # `security` exits non-zero when there is nothing to delete. That is the state the caller asked
  # for, so it is success — an operator cleaning up a connection whose credential was already
  # gone must not be shown a failure.
  def test_deleting_a_credential_that_is_not_there_is_success
    runner = RecordingRunner.new([ failed(stderr: "SecKeychainSearchCopyNext: The specified item could not be found") ])

    assert SpecrelayRunner::SecretStore.new(runner: runner).delete_credential(account: ACCOUNT)
  end

  # Only a tool that could not be RUN is a failure: unlike "no such item", it means the operator's
  # request was not carried out and they need to know.
  def test_a_keychain_that_cannot_be_reached_raises_and_names_the_account
    runner = RecordingRunner.new([ nil ])

    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      SpecrelayRunner::SecretStore.new(runner: runner).delete_credential(account: ACCOUNT)
    end

    assert_match(/could not remove the Keychain item #{Regexp.escape(ACCOUNT)}/, error.message)
    assert_match(/could not be run/, error.message)
  end

  def test_a_deletion_that_times_out_is_reported_as_a_timeout
    timed_out = SpecrelayRunner::CommandRunner::Result.new(exit_code: nil, stdout: "", stderr: "", timed_out: true)
    runner = RecordingRunner.new([ timed_out ])

    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      SpecrelayRunner::SecretStore.new(runner: runner).delete_credential(account: ACCOUNT)
    end

    assert_match(/did not finish within/, error.message)
    refute_match(/exit \)/, error.message)
  end
end
