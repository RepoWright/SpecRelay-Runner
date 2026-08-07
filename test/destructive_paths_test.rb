# frozen_string_literal: true

require_relative "test_helper"

# CR-001 — the two destructive runner paths must fail closed instead of success-shaped.
#
# Round 001 shipped both operations reporting success without having established it, and the
# suite was green throughout. The reason is recorded here because it is the actual lesson:
# **every double answered either correctly or unhappily, and neither answered WRONGLY.**
# `FakeSecretStore` could not refuse a deletion, and every disconnect double returned a
# well-formed `disconnected` block. A caller that believes whatever it is told cannot be caught
# by a double that only ever tells the truth.
#
# So these examples are written from the other side. Each one supplies an answer that is
# *plausible and wrong* — a Keychain that refuses, a 200 carrying an HTML error page — and
# asserts that the runner refuses to convert it into a success.
#
#   F1  a non-zero `security` exit that is NOT item-not-found means the item is STILL STORED
#   F2  a 200 is not a confirmation; Platform has to say what it did
#
# Numbering below follows CR-001's own acceptance criteria.
class DestructivePathsTest < Minitest::Test
  RUNNER_ACCOUNT = "runner:rnr_fake"
  CREDENTIAL = FakePlatform::ISSUED_CREDENTIAL
  REPOSITORY = "https://github.com/SpecRelay/tiny-demo-workspace"

  R = SpecrelayRunner::CommandRunner::Result

  def setup
    @dir = Dir.mktmpdir("destructive")
    @state_file = File.join(@dir, "connections.json")
    @checkout = git_checkout(REPOSITORY)
    @platform = FakePlatform.new(
      claim_payload: claim_payload_for(task_id: "DEMO-0021", executor_command: "specrelay-fake-executor")
    ).start
    @secret_store = FakeSecretStore.new(entries: { RUNNER_ACCOUNT => CREDENTIAL })
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # === CR-001 criterion 1: the delete_credential classification matrix ===================
  #
  # Against a recording runner rather than the real tool, but the statuses are the real tool's,
  # measured on macOS: an absent item exits 44, and a locked/denied keychain exits 36 with the
  # item still stored.

  def test_a_deleted_item_is_success
    assert store_with(R.new(exit_code: 0, stdout: "", stderr: "", timed_out: false))
      .delete_credential(account: RUNNER_ACCOUNT)
  end

  # The one non-zero status that means the caller already has what it asked for.
  def test_an_item_that_is_not_there_is_success
    assert store_with(item_not_found).delete_credential(account: RUNNER_ACCOUNT)
  end

  # THE regression. Round 001 returned true here.
  def test_a_refused_deletion_raises_and_says_the_item_is_still_stored
    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      store_with(refused).delete_credential(account: RUNNER_ACCOUNT)
    end

    assert_match(/refused to remove the item #{Regexp.escape(RUNNER_ACCOUNT)}/, error.message)
    assert_match(/still stored/, error.message)
    assert_match(/exit 36/, error.message)
  end

  def test_a_tool_that_could_not_be_launched_raises
    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      store_with(nil).delete_credential(account: RUNNER_ACCOUNT)
    end

    assert_match(/could not be run/, error.message)
  end

  def test_a_timeout_raises_and_is_named_as_a_timeout
    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      store_with(R.new(exit_code: nil, stdout: "", stderr: "", timed_out: true)).delete_credential(account: RUNNER_ACCOUNT)
    end

    assert_match(/did not finish within/, error.message)
    refute_match(/exit \)/, error.message)
  end

  def test_a_nil_exit_status_without_timeout_is_a_refusal
    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      store_with(R.new(exit_code: nil, stdout: "", stderr: "terminated by signal", timed_out: false))
        .delete_credential(account: RUNNER_ACCOUNT)
    end

    assert_match(/refused to remove the item #{Regexp.escape(RUNNER_ACCOUNT)}/, error.message)
    assert_match(/still stored/, error.message)
    refute_match(/exit 0/, error.message)
  end

  # Recognised by the tool's own message as well as by its status, so a `security` that
  # renumbered its statuses is still understood rather than reclassified as a refusal.
  def test_item_not_found_is_recognised_by_the_tools_own_message_too
    renumbered = R.new(exit_code: 99, stdout: "",
                       stderr: "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.",
                       timed_out: false)

    assert store_with(renumbered).delete_credential(account: RUNNER_ACCOUNT)
  end

  def test_no_failure_message_contains_a_credential_value
    [ refused, nil, R.new(exit_code: nil, stdout: "", stderr: CREDENTIAL, timed_out: true) ].each do |result|
      error = assert_raises(SpecrelayRunner::SecretStore::Error) do
        store_with(result).delete_credential(account: RUNNER_ACCOUNT)
      end
      refute_includes error.message, CREDENTIAL
      refute_match(/src_/, error.message)
    end
  end

  # The private `delete` that `verify_writable!` and `store!` rely on must keep ignoring
  # failures — only the public classification changed.
  def test_the_writability_probe_still_tolerates_a_failing_cleanup_delete
    runner = Object.new
    runner.define_singleton_method(:run) { |*, **| R.new(exit_code: 36, stdout: "", stderr: "denied", timed_out: false) }
    store = SpecrelayRunner::SecretStore.new(runner: runner)

    # The probe's own write fails here, which is the point: it must raise about the WRITE, not
    # about the ensure-block delete that follows it.
    error = assert_raises(SpecrelayRunner::SecretStore::Error) { store.verify_writable! }

    assert_match(/could not save the Keychain writability check/, error.message)
  end

  # === CR-001 criterion 2: a refused removal reaches the operator as a refusal ===========

  def test_disconnect_local_with_a_refusing_keychain_removes_the_entry_but_reports_failure
    store_connection("tiny-demo-workspace")
    @secret_store.fail_delete = true

    status, out, err = run_cli(%w[connections disconnect-local tiny-demo-workspace --remove-credential])

    assert_equal 1, status, "a refused credential removal is an operation failure, not a success"
    assert_empty stored_keys, "the local entry really was removed, and the message must say so"
    assert_match(/Removed the local connection for tiny-demo-workspace/, "#{out}#{err}")
    assert_match(/could NOT be removed and is still stored/, "#{out}#{err}")
    refute_match(/credential \(runner:rnr_fake\) was removed/, "#{out}#{err}")
    assert_equal [ RUNNER_ACCOUNT ], @secret_store.refused_deletes
    assert @secret_store.stored?(RUNNER_ACCOUNT), "the credential really is still there"
  end

  def test_the_refusal_is_carried_as_the_remedy_and_stays_redacted
    store_connection("tiny-demo-workspace")
    @secret_store.fail_delete = true

    _status, _out, err = run_cli(%w[connections disconnect-local tiny-demo-workspace --remove-credential])

    assert_match(/Remedy: .*refused to remove the item runner:rnr_fake/, err)
    refute_includes err, CREDENTIAL
  end

  # A successful removal must still report success — the fix must not make the honest path noisy.
  def test_a_permitted_removal_still_succeeds
    store_connection("tiny-demo-workspace")

    status, out, = run_cli(%w[connections disconnect-local tiny-demo-workspace --remove-credential])

    assert_equal 0, status
    assert_match(/credential \(runner:rnr_fake\) was removed/, out)
    assert_equal [ RUNNER_ACCOUNT ], @secret_store.deletes
  end

  # === CR-001 criterion 3: the legacy-item cleanup ======================================

  def test_forget_legacy_credential_against_a_refusing_keychain_reports_failure
    store_connection("tiny-demo-workspace")
    @secret_store.write(account: "workspace:tiny-demo-workspace", credential: "src_legacy")
    @secret_store.fail_delete = true

    status, out, err = run_cli(%w[connections forget-legacy-credential tiny-demo-workspace])

    assert_equal 1, status
    refute_match(/Removed the legacy per-workspace Keychain item/, out)
    assert_match(/refused to remove the item workspace:tiny-demo-workspace/, err)
    assert @secret_store.stored?("workspace:tiny-demo-workspace")
  end

  # === CR-001 criterion 4: a 200 is only a confirmation when Platform states an outcome ==
  #
  # Driven through the REAL HTTP client against the real fake server, so the body really is
  # parsed by `PlatformClient#parse` rather than handed to the operation pre-shaped.

  def test_a_200_carrying_a_non_json_body_is_not_a_confirmation
    store_connection("tiny-demo-workspace")
    @platform.unconfirmed_disconnect_raw = "<html><body>502 Bad Gateway</body></html>"

    assert_unconfirmed
  end

  def test_a_200_with_no_disconnected_block_is_not_a_confirmation
    store_connection("tiny-demo-workspace")
    @platform.unconfirmed_disconnect = { contract_version: "mvp-0021" }

    assert_unconfirmed
  end

  def test_a_200_with_no_outcome_is_not_a_confirmation
    store_connection("tiny-demo-workspace")
    @platform.unconfirmed_disconnect = { disconnected: { workspace_key: "tiny-demo-workspace" } }

    assert_unconfirmed
  end

  def test_a_200_with_an_unrecognised_outcome_is_not_a_confirmation
    store_connection("tiny-demo-workspace")
    @platform.unconfirmed_disconnect = { disconnected: { outcome: "not_a_real_outcome" } }

    _status, _out, err = assert_unconfirmed

    assert_match(/it reported 'not_a_real_outcome'/, err, "the operator is told what it did say")
  end

  # Exit 1, not 2: the request was well-formed and local state is fine — it is the ANSWER that
  # could not be trusted, which is an operation failure.
  def assert_unconfirmed
    before = File.read(@state_file)
    status, out, err = run_cli(%w[connections disconnect-platform tiny-demo-workspace])

    assert_equal 1, status
    assert_match(/did not confirm the disconnect/, err)
    assert_match(/nothing local was changed/, err)
    refute_match(/Platform confirmed/, "#{out}#{err}")
    assert_equal before, File.read(@state_file), "the state file must be byte-identical"
    [ status, out, err ]
  end

  # === CR-001 criterion 5: the dashboard performs no local write on an unconfirmed 200 ===

  def test_the_dashboard_does_not_offer_local_removal_after_an_unconfirmed_200
    store_connection("tiny-demo-workspace")
    @platform.unconfirmed_disconnect_raw = "<html><body>captive portal</body></html>"
    before = File.read(@state_file)
    menu = ScriptedMenu.new([ "tiny-demo-workspace", :disconnect_platform, :back, :quit ],
                            confirmations: [ true ])

    printed = drive_dashboard(menu)

    refute_match(/Platform confirmed/, printed)
    assert_match(/did not confirm the disconnect/, printed)
    assert_match(/Nothing local was changed/, printed)
    assert_equal 1, menu.confirmations.length, "it must not go on to ask about local removal"
    assert_equal before, File.read(@state_file), "the state file must be byte-identical"
    assert_equal [ "tiny-demo-workspace" ], stored_keys
  end

  # === CR-001 criterion 6: no success message is ever empty =============================

  def test_a_confirmed_outcome_with_a_blank_detail_still_renders_a_sentence
    store_connection("tiny-demo-workspace")
    @platform.unconfirmed_disconnect = { disconnected: { outcome: "revoked", detail: "" } }

    status, out, = run_cli(%w[connections disconnect-platform tiny-demo-workspace])

    assert_equal 0, status
    assert_match(/Platform removed this runner's grant for tiny-demo-workspace/, out)
    refute_match(/\A\s*\n/, out, "the first line must not be blank")
  end

  def test_an_already_absent_outcome_with_no_detail_still_renders_a_sentence
    store_connection("tiny-demo-workspace")
    @platform.unconfirmed_disconnect = { disconnected: { outcome: "already_absent" } }

    status, out, = run_cli(%w[connections disconnect-platform tiny-demo-workspace])

    assert_equal 0, status
    assert_match(/holds no grant for this runner on 'tiny-demo-workspace'/, out)
  end

  # === CR-001 criterion 7: the two confirmed outcomes behave exactly as reviewed =========

  def test_a_revoked_outcome_still_succeeds_and_still_offers_local_removal
    store_connection("tiny-demo-workspace")

    status, out, = run_cli(%w[connections disconnect-platform tiny-demo-workspace])

    assert_equal 0, status
    assert_match(/removed this runner's grant/, out)
    assert_match(/Next: .*disconnect-local/, out)
    assert_empty @platform.grants
    assert_equal [ "tiny-demo-workspace" ], stored_keys
  end

  def test_the_idempotent_retry_still_exits_zero
    store_connection("tiny-demo-workspace")
    run_cli(%w[connections disconnect-platform tiny-demo-workspace])

    status, out, = run_cli(%w[connections disconnect-platform tiny-demo-workspace])

    assert_equal 0, status
    assert_match(/holds no grant for this runner/, out)
  end

  def test_the_dashboard_still_offers_local_removal_after_a_confirmed_disconnect
    store_connection("tiny-demo-workspace")
    menu = ScriptedMenu.new([ "tiny-demo-workspace", :disconnect_platform, :quit ],
                            confirmations: [ true, true, true ])

    drive_dashboard(menu)

    assert_empty @platform.grants
    assert_empty stored_keys
    assert_match(/Platform confirmed/, menu.confirmations[1])
  end

  private

  # A minimal scripted menu, mirroring `dashboard_test.rb`'s. Duplicated deliberately: this file
  # must be able to fail on its own, and coupling it to another test file's private double would
  # make a CR regression suite depend on an unrelated file's refactors.
  class ScriptedMenu
    attr_reader :confirmations

    def initialize(selections, confirmations: [])
      @selections = selections
      @confirmations = []
      @answers = confirmations
    end

    def select(title:, entries:, footer:, header: [])
      raise "the dashboard asked for more input than the script provides" if @selections.empty?

      @selections.shift
    end

    def confirm(prompt)
      @confirmations << prompt
      @answers.empty? ? false : @answers.shift
    end

    def pause(_message = nil) = nil
    def clear = nil
    def restore = nil
    def width = 100
  end

  def drive_dashboard(menu)
    out = StringIO.new
    SpecrelayRunner::Dashboard.new(operations: operations, out: out, err: StringIO.new, menu: menu,
                                   dispatch: ->(_argv) { 0 }).call
    out.string
  end

  def operations
    SpecrelayRunner::ConnectionOperations.new(env: env, secret_store: @secret_store,
                                             platform: "arm64-darwin25")
  end

  def store_with(result)
    runner = Object.new
    runner.define_singleton_method(:run) { |*, **| result }
    SpecrelayRunner::SecretStore.new(runner: runner)
  end

  def item_not_found
    R.new(exit_code: 44, stdout: "",
          stderr: "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.",
          timed_out: false)
  end

  def refused
    R.new(exit_code: 36, stdout: "",
          stderr: "security: SecKeychainItemDelete: User interaction is not allowed.", timed_out: false)
  end

  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    status = SpecrelayRunner::CLI.new(out: out, err: err, env: env, input: StringIO.new,
                                     secret_store: @secret_store).run(argv)
    [ status, out.string, err.string ]
  end

  def env = { "SPECRELAY_RUNNER_STATE_FILE" => @state_file, "PATH" => ENV.fetch("PATH", "") }

  def store_connection(workspace_key)
    SpecrelayRunner::ConnectionStore.new(@state_file).save(
      SpecrelayRunner::ConnectionStore::Connection.new(
        base_url: @platform.base_url, runner_id: "host-runner", runner_public_id: "rnr_fake",
        runner_display_name: "host runner", project_slug: "tiny-demo", workspace_key: workspace_key,
        project_key: "tiny-demo", workspace_display_name: "Tiny Demo Workspace",
        repository_url: REPOSITORY, default_branch: "main", local_path: @checkout,
        connected_at: "2026-07-20T10:00:00Z"
      )
    )
  end

  def stored_keys = SpecrelayRunner::ConnectionStore.new(@state_file).connections.map(&:workspace_key)

  def git_checkout(remote)
    path = File.join(@dir, "checkout")
    FileUtils.mkdir_p(path)
    run_git(path, %w[init --initial-branch main])
    run_git(path, [ "remote", "add", "origin", remote ])
    File.write(File.join(path, "README.md"), "demo\n")
    run_git(path, %w[add .])
    run_git(path, [ "-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-m", "init" ])
    path
  end

  def run_git(path, args)
    system("git", "-C", path, *args, out: File::NULL, err: File::NULL) ||
      raise("git #{args.join(' ')} failed in #{path}")
  end
end
