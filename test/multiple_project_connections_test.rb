# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/fake_project_platform"

# Connecting ONE machine to SEVERAL projects, against a Platform fake that enforces the real
# server-side ownership rule.
#
# The behaviour under test is the operator's: add a project, add another, keep both, run either.
# Every claim here is about what survives that — the first project's registration, its credential,
# its checkout and its explicit default — and about what must never happen: a credential from one
# project presented to another, a saved connection silently overwritten by a workspace key that
# happens to repeat, or a one-time enrollment code spent on an attempt that could not succeed.
class MultipleProjectConnectionsTest < Minitest::Test
  ALPHA_REPOSITORY = "https://github.com/SpecRelay/alpha-workspace"
  BETA_REPOSITORY = "https://github.com/SpecRelay/beta-workspace"
  GAMMA_REPOSITORY = "https://github.com/SpecRelay/gamma-workspace"

  def setup
    @platform = FakeProjectPlatform.new.start
    @state_file = File.join(Dir.mktmpdir("state"), "connections.json")
    @secret_store = FakeSecretStore.new
  end

  def teardown
    @platform&.stop
  end

  # --- fixtures -------------------------------------------------------------

  def store = @store ||= SpecrelayRunner::ConnectionStore.new(@state_file)

  def connect(code:, checkout:, secret_store: @secret_store, out: StringIO.new, err: StringIO.new)
    result = SpecrelayRunner::Connect.call(
      code: code, out: out, err: err, env: { "PATH" => ENV["PATH"].to_s },
      checkout_path: checkout, store: store, secret_store: secret_store, platform: "arm64-darwin23"
    )
    [ result, out.string, err.string ]
  end

  # A real Git repository with a real remote and branch, so the checkout validation the guided
  # connection performs runs its real git commands rather than a stub.
  def git_checkout(remote:, branch: "main")
    path = Dir.mktmpdir("checkout")
    run_git(path, %w[init --quiet])
    run_git(path, [ "symbolic-ref", "HEAD", "refs/heads/#{branch}" ])
    run_git(path, [ "remote", "add", "origin", remote ])
    File.write(File.join(path, "README.md"), "demo\n")
    run_git(path, %w[add .])
    run_git(path, [ "-c", "user.email=t@example.test", "-c", "user.name=Test",
                    "commit", "--quiet", "-m", "initial" ])
    path
  end

  def run_git(path, args)
    result = SpecrelayRunner::CommandRunner.run([ "git", "-C", path, *args ], chdir: path,
                                                env: { "PATH" => ENV["PATH"].to_s }, timeout_seconds: 30)
    raise "git #{args.join(' ')} failed: #{result.stderr}" unless result.success?
  end

  # The two projects nearly every case here needs: one already connected, one being added.
  def connect_alpha
    code = @platform.add_project(slug: "alpha", workspace_key: "alpha-workspace",
                                 repository_url: ALPHA_REPOSITORY)
    connect(code: code, checkout: git_checkout(remote: ALPHA_REPOSITORY))
  end

  def connect_beta(workspace_key: "beta-workspace")
    code = @platform.add_project(slug: "beta", workspace_key: workspace_key,
                                 repository_url: BETA_REPOSITORY)
    connect(code: code, checkout: git_checkout(remote: BETA_REPOSITORY))
  end

  def selector_for(connection) = SpecrelayRunner::ConnectionStore.selector_for(connection)
  def selectors = store.connections.map { |connection| selector_for(connection) }

  # --- several projects on one machine --------------------------------------

  def test_a_second_project_connects_without_disconnecting_the_first
    connect_alpha
    alpha = store.connections.first.dup

    result, = connect_beta

    assert result.ready?, "the second project did not become ready: #{result.detail}"
    assert_equal %w[alpha beta], store.connections.map(&:project_slug).sort
    # The first project's whole record is untouched: same machine identity, same repository, same
    # local checkout. A repointed machine would have rewritten it.
    retained = store.connections.find { |connection| connection.project_slug == "alpha" }

    assert_equal alpha.to_h, retained.to_h
  end

  def test_each_project_gets_its_own_platform_registration
    connect_alpha
    connect_beta

    assert_equal 2, @platform.registrations.length
    refute_equal @platform.registration_for("alpha").runner_id,
                 @platform.registration_for("beta").runner_id
    # Distinct registrations mean distinct public ids, which is what scopes the stored credential.
    refute_equal @platform.registration_for("alpha").public_id,
                 @platform.registration_for("beta").public_id
  end

  def test_a_third_project_also_connects_and_all_three_stay_selectable
    connect_alpha
    connect_beta
    code = @platform.add_project(slug: "gamma", workspace_key: "gamma-workspace",
                                 repository_url: GAMMA_REPOSITORY)
    result, = connect(code: code, checkout: git_checkout(remote: GAMMA_REPOSITORY))

    assert result.ready?, "the third project did not become ready: #{result.detail}"
    assert_equal 3, store.connections.length
    assert_equal 3, selectors.uniq.length
  end

  # The machine identity a project is registered under has to be stable, or a retry would create
  # a second registration instead of updating the first.
  def test_a_projects_machine_identity_is_stable_across_a_retry
    connect_alpha
    first = @platform.registration_for("alpha").runner_id

    # A fresh code for the SAME workspace is exactly what an operator is given after a failed
    # attempt, and what a reconnect uses.
    code = @platform.issue_code("alpha", "alpha-workspace")
    connect(code: code, checkout: git_checkout(remote: ALPHA_REPOSITORY))

    assert_equal 1, @platform.registrations.length
    assert_equal first, @platform.registration_for("alpha").runner_id
  end

  # --- credentials stay inside their own project ----------------------------

  def test_connecting_a_second_project_never_presents_the_first_projects_credential
    connect_alpha
    alpha_credential = @platform.registration_for("alpha").credential

    connect_beta

    # Beta was issued its own credential rather than adopting alpha's.
    refute_equal alpha_credential, @platform.registration_for("beta").credential
    # …and alpha's stored copy is still the credential Platform still holds for alpha.
    alpha_public_id = @platform.registration_for("alpha").public_id

    assert_equal alpha_credential,
                 @secret_store.read(account: SpecrelayRunner::SecretStore.account_for_runner(alpha_public_id))
  end

  def test_each_project_stores_its_credential_under_its_own_registration
    connect_alpha
    connect_beta

    accounts = %w[alpha beta].map do |slug|
      SpecrelayRunner::SecretStore.account_for_runner(@platform.registration_for(slug).public_id)
    end

    assert_equal accounts.length, accounts.uniq.length
    accounts.each { |account| assert @secret_store.stored?(account), "#{account} was not stored" }
  end

  def test_reconnecting_a_project_keeps_the_credential_it_already_holds
    connect_alpha
    held = @platform.registration_for("alpha").credential
    writes_before = @secret_store.writes.length

    code = @platform.issue_code("alpha", "alpha-workspace")
    _result, out, = connect(code: code, checkout: git_checkout(remote: ALPHA_REPOSITORY))

    assert_equal held, @platform.registration_for("alpha").credential
    assert_includes out, "unchanged"
    # Only the connector token is rewritten on a reconnect; the credential is not touched.
    assert_equal writes_before + 1, @secret_store.writes.length
  end

  def test_a_second_workspace_in_a_known_project_reuses_that_projects_registration
    connect_alpha
    registration = @platform.registration_for("alpha")
    code = @platform.add_project(slug: "alpha", workspace_key: "alpha-second",
                                 repository_url: ALPHA_REPOSITORY)
    connect(code: code, checkout: git_checkout(remote: ALPHA_REPOSITORY))

    assert_equal 1, @platform.registrations.length
    assert_equal registration.public_id, @platform.registration_for("alpha").public_id
    assert_equal 2, store.connections.count { |connection| connection.project_slug == "alpha" }
  end

  # --- duplicate workspace keys ---------------------------------------------

  def test_two_projects_using_the_same_workspace_key_are_both_kept
    connect_alpha
    code = @platform.add_project(slug: "beta", workspace_key: "alpha-workspace",
                                 repository_url: BETA_REPOSITORY)
    connect(code: code, checkout: git_checkout(remote: BETA_REPOSITORY))

    assert_equal 2, store.connections.length
    assert_equal %w[alpha beta], store.connections.map(&:project_slug).sort
    # The two records are told apart by their full selectors, not by the repeated key.
    assert_equal 2, selectors.uniq.length
  end

  def test_a_shared_workspace_key_resolves_by_its_project_qualified_selector
    connect_alpha
    code = @platform.add_project(slug: "beta", workspace_key: "alpha-workspace",
                                 repository_url: BETA_REPOSITORY)
    connect(code: code, checkout: git_checkout(remote: BETA_REPOSITORY))

    resolved = store.resolve("beta/alpha-workspace")

    assert resolved.resolved?, "the project-qualified selector did not resolve"
    assert_equal "beta", resolved.connection.project_slug
    # The bare key now names two records, so it resolves to neither.
    assert store.resolve("alpha-workspace").ambiguous?
  end

  # --- an existing default survives a new project ---------------------------

  def test_an_existing_default_stays_attached_to_its_original_connection
    connect_alpha
    store.set_default("alpha-workspace")

    code = @platform.add_project(slug: "beta", workspace_key: "alpha-workspace",
                                 repository_url: BETA_REPOSITORY)
    connect(code: code, checkout: git_checkout(remote: BETA_REPOSITORY))

    reloaded = SpecrelayRunner::ConnectionStore.new(@state_file)
    resolved = reloaded.resolve(reloaded.default_selector)

    assert resolved.resolved?, "the default no longer names exactly one connection"
    assert_equal "alpha", resolved.connection.project_slug
  end

  def test_a_stale_default_refuses_enrollment_before_the_code_is_spent
    connect_alpha
    store.set_default("alpha-workspace")
    # The operator edited the file, or removed the connection the default named from another
    # terminal. Adding a record now would let the stale default attach to the NEW one.
    rewrite_default("no-such-workspace")

    code = @platform.add_project(slug: "beta", workspace_key: "beta-workspace",
                                 repository_url: BETA_REPOSITORY)
    error = assert_raises(SpecrelayRunner::ConnectionStore::Error) do
      connect(code: code, checkout: git_checkout(remote: BETA_REPOSITORY))
    end

    assert_match(/default/i, error.message)
    refute @platform.spent?(code), "the enrollment code was consumed by an attempt that refused"
    assert_equal 1, store.connections.length
  end

  def test_an_unreadable_connection_store_refuses_before_the_code_is_spent
    connect_alpha
    File.write(@state_file, "{ this is not connection state")

    code = @platform.add_project(slug: "beta", workspace_key: "beta-workspace",
                                 repository_url: BETA_REPOSITORY)
    assert_raises(SpecrelayRunner::ConnectionStore::Error) do
      connect(code: code, checkout: git_checkout(remote: BETA_REPOSITORY))
    end

    refute @platform.spent?(code), "the enrollment code was consumed by an attempt that refused"
    # The damaged file was not replaced by a store that silently treated it as empty.
    assert_equal "{ this is not connection state", File.read(@state_file)
  end

  # --- failures leave the other project usable ------------------------------

  def test_a_checkout_that_is_not_the_assigned_repository_leaves_the_first_project_intact
    connect_alpha
    alpha = store.connections.first.dup

    code = @platform.add_project(slug: "beta", workspace_key: "beta-workspace",
                                 repository_url: BETA_REPOSITORY)
    assert_raises(SpecrelayRunner::Connect::Error) do
      connect(code: code, checkout: git_checkout(remote: GAMMA_REPOSITORY))
    end

    refute @platform.spent?(code), "the enrollment code was consumed by a local failure"
    assert_equal 1, store.connections.length
    assert_equal alpha.to_h, store.connections.first.to_h
    assert_equal 1, @platform.registrations.length
  end

  def test_an_unusable_secret_store_refuses_before_the_code_is_spent
    connect_alpha
    code = @platform.add_project(slug: "beta", workspace_key: "beta-workspace",
                                 repository_url: BETA_REPOSITORY)

    assert_raises(SpecrelayRunner::SecretStore::Error) do
      connect(code: code, checkout: git_checkout(remote: BETA_REPOSITORY),
              secret_store: FakeSecretStore.new(fail_write: true))
    end

    refute @platform.spent?(code), "the enrollment code was consumed by a local failure"
    assert_equal 1, store.connections.length
  end

  # --- the announced identity is the one that will be enrolled --------------

  def test_the_identity_is_announced_after_the_assignment_is_known
    connect_alpha
    _result, out, = connect_beta

    registered = @platform.registration_for("beta").runner_id

    assert_includes out, registered
    # The announcement follows the assignment, so what the operator reads is the identity this
    # project will really be registered under rather than a hostname-only guess.
    assert out.index("Assigned project") < out.index(registered),
           "the runner identity was announced before the project was known:\n#{out}"
  end

  private

  # Put an arbitrary value in the stored default field, which is what a hand-edited file or a
  # connection removed elsewhere leaves behind.
  def rewrite_default(value)
    document = JSON.parse(File.read(@state_file))
    document[SpecrelayRunner::ConnectionStore::DEFAULT_KEY_FIELD] = value
    File.write(@state_file, "#{JSON.pretty_generate(document)}\n")
  end
end
