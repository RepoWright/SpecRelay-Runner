# frozen_string_literal: true

require_relative "test_helper"

# MVP-0021 — the runner's local connection state, including the explicit default workspace.
#
# The claims this file is here to prove:
#   - list/show/default/delete all operate on the same non-secret document;
#   - a version-1 file written by an earlier runner still loads, and gains no default;
#   - the default is refused unless it names a real connection, and cleared automatically when
#     that connection is removed — a dangling default is the fail-closed failure mode scope 4
#     exists to prevent, so it must not be reachable through normal use;
#   - deleting removes exactly one entry and nothing else;
#   - corrupt state is REPORTED as unreadable rather than silently read as empty;
#   - every write is atomic and lands at mode 0600.
class ConnectionStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("connection-store")
    @path = File.join(@dir, "connections.json")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def store = SpecrelayRunner::ConnectionStore.new(@path)

  def connection(workspace_key:, runner_public_id: "rnr_one", connected_at: "2026-07-20T10:00:00Z",
                 reviewer_provider: nil)
    SpecrelayRunner::ConnectionStore::Connection.new(
      base_url: "http://127.0.0.1:3100", runner_id: "host-runner", runner_public_id: runner_public_id,
      runner_display_name: "host runner", project_slug: "tiny-demo", workspace_key: workspace_key,
      project_key: "tiny-demo", workspace_display_name: "Tiny Demo Workspace",
      repository_url: "https://github.com/SpecRelay/tiny-demo-workspace", default_branch: "main",
      local_path: "/Users/someone/dev/tiny-demo-workspace", reviewer_provider: reviewer_provider,
      connected_at: connected_at
    )
  end

  # --- listing --------------------------------------------------------------

  def test_a_missing_file_is_an_empty_but_readable_store
    assert_empty store.connections
    assert store.readable?, "a machine that has never connected is not a damaged machine"
    assert_nil store.default_workspace_key
    assert_nil store.document_version
  end

  def test_connections_are_listed_newest_first_by_connected_at
    store.save(connection(workspace_key: "older", connected_at: "2026-07-01T00:00:00Z"))
    store.save(connection(workspace_key: "newest", connected_at: "2026-07-28T00:00:00Z"))
    store.save(connection(workspace_key: "middle", connected_at: "2026-07-14T00:00:00Z"))

    assert_equal %w[newest middle older], store.connections.map(&:workspace_key)
  end

  # An entry with no usable timestamp must still be listed, not dropped: it is a real
  # connection the machine can execute for.
  def test_an_entry_with_an_unparseable_timestamp_sorts_last_and_is_still_listed
    store.save(connection(workspace_key: "dated", connected_at: "2026-07-01T00:00:00Z"))
    write_raw("connections" => [ connection(workspace_key: "undated", connected_at: "not a time").to_h_document,
                                *store.connections.map(&:to_h_document) ])

    assert_equal %w[dated undated], store.connections.map(&:workspace_key)
  end

  # --- version compatibility ------------------------------------------------

  # The risk the specification calls out by name: an existing connections.json must keep
  # working. A machine that had to reconnect every workspace to get a dashboard would have
  # made the feature cost more than it saved.
  def test_a_version_1_document_written_by_an_earlier_runner_still_loads
    write_raw("version" => 1,
              "connections" => [ connection(workspace_key: "tiny-demo-workspace").to_h_document ])

    assert_equal [ "tiny-demo-workspace" ], store.connections.map(&:workspace_key)
    assert_equal 1, store.document_version
    assert_nil store.default_workspace_key, "a version-1 file records no default"
    assert store.readable?
  end

  # A future runner may add keys this one does not know. Refusing to read such a file would
  # strand a machine after a downgrade for no safety benefit.
  def test_a_newer_document_version_is_still_readable
    write_raw("version" => 99, "something_new" => true,
              "connections" => [ connection(workspace_key: "tiny-demo-workspace").to_h_document ])

    assert_equal [ "tiny-demo-workspace" ], store.connections.map(&:workspace_key)
  end

  def test_saving_upgrades_the_document_to_version_2_without_losing_connections
    write_raw("version" => 1, "connections" => [ connection(workspace_key: "first").to_h_document ])
    store.save(connection(workspace_key: "second", connected_at: "2026-07-28T00:00:00Z"))

    assert_equal SpecrelayRunner::ConnectionStore::VERSION, document["version"]
    assert_equal %w[second first], store.connections.map(&:workspace_key)
  end

  # --- the explicit default -------------------------------------------------

  def test_a_default_can_be_set_read_and_cleared
    store.save(connection(workspace_key: "tiny-demo-workspace"))
    store.set_default("tiny-demo-workspace")

    assert_equal "tiny-demo-workspace", store.default_workspace_key
    assert store.default?("tiny-demo-workspace")
    assert_equal "tiny-demo-workspace", store.default_connection.workspace_key
    refute store.default_set_but_missing?

    store.clear_default

    assert_nil store.default_workspace_key
    assert_nil store.default_connection
  end

  def test_the_default_is_persisted_as_a_non_secret_top_level_key
    store.save(connection(workspace_key: "tiny-demo-workspace"))
    store.set_default("tiny-demo-workspace")

    assert_equal "tiny-demo-workspace", document["default_workspace_key"]
  end

  # Storing an unresolvable default would only move the failure later, to a `loop` that then
  # has to fail closed. It is refused where the operator can still fix it.
  def test_setting_a_default_for_an_unconnected_workspace_is_refused
    store.save(connection(workspace_key: "tiny-demo-workspace"))

    error = assert_raises(SpecrelayRunner::ConnectionStore::Error) { store.set_default("not-connected") }

    assert_match(/no connection for workspace 'not-connected'/, error.message)
    assert_nil store.default_workspace_key, "a refused default must not be written"
  end

  def test_a_default_that_was_hand_edited_to_a_missing_workspace_is_reported_not_resolved
    write_raw("version" => 2, "default_workspace_key" => "gone",
              "connections" => [ connection(workspace_key: "tiny-demo-workspace").to_h_document ])

    assert_equal "gone", store.default_workspace_key
    assert_nil store.default_connection, "it must never resolve to another workspace"
    assert store.default_set_but_missing?
  end

  def test_saving_another_connection_preserves_the_default
    store.save(connection(workspace_key: "first"))
    store.set_default("first")
    store.save(connection(workspace_key: "second", connected_at: "2026-07-28T00:00:00Z"))

    assert_equal "first", store.default_workspace_key
  end

  # --- delete ---------------------------------------------------------------

  def test_delete_removes_exactly_one_connection_and_returns_it
    store.save(connection(workspace_key: "keep"))
    store.save(connection(workspace_key: "drop", connected_at: "2026-07-28T00:00:00Z"))

    removed = store.delete("drop")

    assert_equal "drop", removed.workspace_key
    assert_equal [ "keep" ], store.connections.map(&:workspace_key)
  end

  def test_deleting_a_missing_connection_is_a_no_op_rather_than_an_error
    store.save(connection(workspace_key: "keep"))

    assert_nil store.delete("never-connected")
    assert_equal [ "keep" ], store.connections.map(&:workspace_key)
  end

  # The whole point of clearing it here: a default left pointing at a removed workspace would
  # make every later `loop` fail closed for a reason the operator did not cause.
  def test_deleting_the_default_workspace_clears_the_default_in_the_same_write
    store.save(connection(workspace_key: "other"))
    store.save(connection(workspace_key: "going", connected_at: "2026-07-28T00:00:00Z"))
    store.set_default("going")

    store.delete("going")

    assert_nil store.default_workspace_key
    refute store.default_set_but_missing?
    assert_equal [ "other" ], store.connections.map(&:workspace_key)
  end

  def test_deleting_a_non_default_workspace_leaves_the_default_alone
    store.save(connection(workspace_key: "keep"))
    store.save(connection(workspace_key: "drop", connected_at: "2026-07-28T00:00:00Z"))
    store.set_default("keep")

    store.delete("drop")

    assert_equal "keep", store.default_workspace_key
  end

  # --- damaged state --------------------------------------------------------

  # `connections` deliberately keeps its pre-existing "report as empty rather than crash"
  # behaviour, because a corrupt file must not stop a runner from starting up and saying what
  # to do. `readable?` is what lets the new surfaces tell the two states apart.
  def test_corrupt_json_is_reported_as_unreadable_while_still_not_raising
    File.write(@path, "{ this is not json")

    assert_empty store.connections
    refute store.readable?
  end

  def test_a_json_document_that_is_not_a_connection_store_is_unreadable
    File.write(@path, JSON.generate([ "an", "array" ]))

    refute store.readable?
  end

  def test_a_document_whose_connections_key_is_not_a_list_is_unreadable
    File.write(@path, JSON.generate("version" => 2, "connections" => "nope"))

    refute store.readable?
  end

  def test_entries_missing_an_identity_are_skipped_rather_than_returned_half_built
    write_raw("connections" => [ { "workspace_key" => "", "base_url" => "http://x" },
                                { "base_url" => "", "workspace_key" => "k" },
                                connection(workspace_key: "good").to_h_document ])

    assert_equal [ "good" ], store.connections.map(&:workspace_key)
  end

  # `missing_fields` is what the readiness test reports as `local_state_invalid`, so the fields
  # it names have to be the ones a claim would actually need.
  def test_a_structurally_incomplete_entry_names_its_missing_fields
    write_raw("connections" => [ connection(workspace_key: "partial").to_h_document
                                  .merge("local_path" => "", "runner_public_id" => nil) ])

    found = store.connection_for("partial")

    refute found.complete?
    assert_equal %i[runner_public_id local_path], found.missing_fields
  end

  def test_a_complete_entry_reports_itself_complete
    store.save(connection(workspace_key: "whole"))

    assert store.connection_for("whole").complete?
    assert_empty store.connection_for("whole").missing_fields
  end

  # --- the stored reviewer selection (MAPIAI-91) -----------------------------

  # The reviewer provider a guided connection selected is a durable NON-SECRET fact, stored so a
  # later claim can reconstruct it. Only the identifier is stored: how the provider is launched
  # stays on this machine and out of this file.
  def test_a_selected_reviewer_provider_round_trips_and_carries_no_launch_configuration
    store.save(connection(workspace_key: "reviewing", reviewer_provider: "claude"))

    assert_equal "claude", store.connection_for("reviewing").reviewer_provider
    entry = document["connections"].first

    assert_equal "claude", entry["reviewer_provider"]
    refute_match(/command|args|timeout|env|credential|account|prompt/i, JSON.generate(entry))
  end

  # A connection made before the selection was stored — and one made on a machine that reviews
  # nothing — must report the absence rather than a substituted value. Nothing downstream may
  # guess from it.
  def test_a_connection_with_no_selected_reviewer_provider_reports_none_and_stays_complete
    store.save(connection(workspace_key: "executing"))

    found = store.connection_for("executing")

    assert_nil found.reviewer_provider
    assert found.complete?
  end

  def test_a_document_written_before_the_reviewer_selection_existed_still_loads
    write_raw("version" => 2,
              "connections" => [ connection(workspace_key: "older").to_h_document.tap { |e| e.delete("reviewer_provider") } ])

    found = store.connection_for("older")

    assert_equal "older", found.workspace_key
    assert_nil found.reviewer_provider
  end

  # --- write posture --------------------------------------------------------

  def test_every_write_lands_at_mode_0600_and_leaves_no_temporary_file
    store.save(connection(workspace_key: "first"))
    store.set_default("first")
    store.save(connection(workspace_key: "second", connected_at: "2026-07-28T00:00:00Z"))
    store.delete("second")

    assert_equal "100600", format("%o", File.stat(@path).mode)
    assert_equal [ "connections.json" ], Dir.children(@dir), "an atomic rename leaves nothing behind"
  end

  def test_the_state_file_contains_nothing_credential_shaped
    store.save(connection(workspace_key: "tiny-demo-workspace"))
    store.set_default("tiny-demo-workspace")

    body = File.read(@path)

    refute_match(/src_|srt_|sre_|credential|token|password/i, body)
  end

  def test_a_write_to_an_unwritable_location_raises_a_named_error
    unwritable = SpecrelayRunner::ConnectionStore.new(File.join(@dir, "denied", "connections.json"))
    FileUtils.mkdir_p(File.join(@dir, "denied"))
    File.chmod(0o500, File.join(@dir, "denied"))

    error = assert_raises(SpecrelayRunner::ConnectionStore::Error) do
      unwritable.save(connection(workspace_key: "nope"))
    end

    assert_match(/could not write the runner connection file/, error.message)
  ensure
    File.chmod(0o700, File.join(@dir, "denied")) if File.directory?(File.join(@dir, "denied"))
  end

  # --- path resolution ------------------------------------------------------

  def test_the_state_file_location_is_overridable_for_tests_and_alternate_homes
    assert_equal "/tmp/elsewhere.json",
                 SpecrelayRunner::ConnectionStore.default_path(env: { "SPECRELAY_RUNNER_STATE_FILE" => "/tmp/elsewhere.json" })
    assert_equal File.join("/home/x", SpecrelayRunner::ConnectionStore::DEFAULT_RELATIVE_PATH),
                 SpecrelayRunner::ConnectionStore.default_path(env: {}, home: "/home/x")
  end

  private

  def write_raw(document)
    File.write(@path, "#{JSON.pretty_generate(document)}\n")
    File.chmod(0o600, @path)
  end

  def document = JSON.parse(File.read(@path))
end
