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

  # The full selector a connection made by `connection` answers to.
  def selector(workspace_key, base_url: "http://127.0.0.1:3100", project_slug: "tiny-demo")
    "#{base_url}#{SpecrelayRunner::ConnectionStore::PROJECT_SEPARATOR}#{project_slug}" \
      "#{SpecrelayRunner::ConnectionStore::WORKSPACE_SEPARATOR}#{workspace_key}"
  end

  def connection(workspace_key:, runner_public_id: "rnr_one", connected_at: "2026-07-20T10:00:00Z",
                 reviewer_provider: nil, project_slug: "tiny-demo", base_url: "http://127.0.0.1:3100")
    SpecrelayRunner::ConnectionStore::Connection.new(
      base_url: base_url, runner_id: "host-runner", runner_public_id: runner_public_id,
      runner_display_name: "host runner", project_slug: project_slug, workspace_key: workspace_key,
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
    assert_nil store.default_selector
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
    assert_nil store.default_selector, "a version-1 file records no default"
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

    # A bare key that names exactly one connection is accepted, and STORED as the full selector
    # so a project added later cannot make it ambiguous.
    assert_equal selector("tiny-demo-workspace"), store.default_selector
    assert store.default?(store.connections.first)
    assert_equal "tiny-demo-workspace", store.default_connection.workspace_key
    refute store.default_set_but_missing?

    store.clear_default

    assert_nil store.default_selector
    assert_nil store.default_connection
  end

  def test_the_default_is_persisted_as_a_non_secret_top_level_key
    store.save(connection(workspace_key: "tiny-demo-workspace"))
    store.set_default("tiny-demo-workspace")

    assert_equal selector("tiny-demo-workspace"), document["default_workspace_key"]
  end

  # Storing an unresolvable default would only move the failure later, to a `loop` that then
  # has to fail closed. It is refused where the operator can still fix it.
  def test_setting_a_default_for_an_unconnected_workspace_is_refused
    store.save(connection(workspace_key: "tiny-demo-workspace"))

    error = assert_raises(SpecrelayRunner::ConnectionStore::Error) { store.set_default("not-connected") }

    assert_match(/no longer names a connection/, error.message)
    assert_nil store.default_selector, "a refused default must not be written"
  end

  def test_a_default_that_was_hand_edited_to_a_missing_workspace_is_reported_not_resolved
    write_raw("version" => 2, "default_workspace_key" => "gone",
              "connections" => [ connection(workspace_key: "tiny-demo-workspace").to_h_document ])

    assert_equal "gone", store.default_selector
    assert_nil store.default_connection, "it must never resolve to another workspace"
    assert store.default_set_but_missing?
  end

  def test_saving_another_connection_preserves_the_default
    store.save(connection(workspace_key: "first"))
    store.set_default("first")
    store.save(connection(workspace_key: "second", connected_at: "2026-07-28T00:00:00Z"))

    assert_equal selector("first"), store.default_selector
  end

  # --- composite identity ---------------------------------------------------

  # The same workspace key in two projects is a state Platform allows, so the store has to keep
  # both. Treating the key as the identity silently replaced the first record with the second.
  def test_the_same_workspace_key_in_two_projects_is_two_connections
    store.save(connection(workspace_key: "shared", project_slug: "alpha"))
    store.save(connection(workspace_key: "shared", project_slug: "beta",
                          connected_at: "2026-07-28T00:00:00Z"))

    assert_equal 2, store.connections.length
    assert_equal %w[alpha beta], store.connections.map(&:project_slug).sort
  end

  def test_re_saving_the_same_identity_replaces_that_one_entry
    store.save(connection(workspace_key: "shared", project_slug: "alpha"))
    store.save(connection(workspace_key: "shared", project_slug: "alpha",
                          connected_at: "2026-07-28T00:00:00Z"))

    assert_equal 1, store.connections.length
    assert_equal "2026-07-28T00:00:00Z", store.connections.first.connected_at
  end

  def test_a_bare_key_resolves_only_while_it_names_one_connection
    store.save(connection(workspace_key: "shared", project_slug: "alpha"))

    assert store.resolve("shared").resolved?

    store.save(connection(workspace_key: "shared", project_slug: "beta",
                          connected_at: "2026-07-28T00:00:00Z"))
    ambiguous = store.resolve("shared")

    refute ambiguous.resolved?, "a key naming two projects must resolve to neither"
    assert ambiguous.ambiguous?
    assert_equal 2, ambiguous.matches.length
  end

  def test_a_project_qualified_selector_tells_two_duplicate_keys_apart
    store.save(connection(workspace_key: "shared", project_slug: "alpha"))
    store.save(connection(workspace_key: "shared", project_slug: "beta",
                          connected_at: "2026-07-28T00:00:00Z"))

    assert_equal "alpha", store.resolve("alpha/shared").connection.project_slug
    assert_equal "beta", store.resolve("beta/shared").connection.project_slug
  end

  # Two origins may host the same project slug and workspace key, which is why the origin is
  # part of the identity rather than a display field.
  def test_the_platform_origin_is_part_of_the_identity
    store.save(connection(workspace_key: "shared", project_slug: "alpha"))
    store.save(connection(workspace_key: "shared", project_slug: "alpha",
                          base_url: "http://127.0.0.1:3999", connected_at: "2026-07-28T00:00:00Z"))

    assert_equal 2, store.connections.length
    assert_equal "http://127.0.0.1:3999",
                 store.resolve(selector("shared", base_url: "http://127.0.0.1:3999",
                                        project_slug: "alpha")).connection.base_url
  end

  def test_a_record_without_a_project_still_has_one_identity
    write_raw("version" => 2,
              "connections" => [ connection(workspace_key: "legacy")
                                   .to_h_document.merge("project_slug" => nil) ])

    identity = SpecrelayRunner::ConnectionStore.selector_for(store.connections.first)

    assert_equal selector("legacy", project_slug: SpecrelayRunner::ConnectionStore::UNKNOWN_PROJECT),
                 identity
    assert store.resolve(identity).resolved?
  end

  # --- the default across a duplicate key -----------------------------------

  # The case a bare default cannot survive: it was set when the key was unique, and a second
  # project then reused it. Pinning it to the full selector BEFORE the new record lands is what
  # keeps it attached to the connection the operator actually chose.
  def test_an_existing_bare_default_is_pinned_before_a_colliding_record_is_added
    store.save(connection(workspace_key: "shared", project_slug: "alpha"))
    write_raw(JSON.parse(File.read(@path)).merge("default_workspace_key" => "shared"))
    store.save(connection(workspace_key: "shared", project_slug: "beta",
                          connected_at: "2026-07-28T00:00:00Z"))

    assert_equal selector("shared", project_slug: "alpha"), store.default_selector
    assert_equal "alpha", store.default_connection.project_slug
  end

  # Adding a record while the stored default resolves to nothing would let it attach to the new
  # one. It is refused where the operator can still fix it, and nothing is written.
  def test_saving_is_refused_while_the_stored_default_cannot_resolve
    store.save(connection(workspace_key: "first"))
    write_raw(JSON.parse(File.read(@path)).merge("default_workspace_key" => "gone"))

    assert_raises(SpecrelayRunner::ConnectionStore::Error) do
      store.save(connection(workspace_key: "second", connected_at: "2026-07-28T00:00:00Z"))
    end

    assert_equal [ "first" ], store.connections.map(&:workspace_key)
  end

  # --- delete ---------------------------------------------------------------

  def test_delete_removes_exactly_one_connection_and_returns_it
    store.save(connection(workspace_key: "keep"))
    store.save(connection(workspace_key: "drop", connected_at: "2026-07-28T00:00:00Z"))

    removed = store.delete(selector("drop"))

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

    assert_nil store.default_selector
    refute store.default_set_but_missing?
    assert_equal [ "other" ], store.connections.map(&:workspace_key)
  end

  def test_deleting_a_non_default_workspace_leaves_the_default_alone
    store.save(connection(workspace_key: "keep"))
    store.save(connection(workspace_key: "drop", connected_at: "2026-07-28T00:00:00Z"))
    store.set_default("keep")

    store.delete("drop")

    assert_equal selector("keep"), store.default_selector
  end

  # An ambiguous default is safe only while it stays ambiguous: it refuses every bare claim.
  # Removing one of the two connections it names would leave the SAME stored string resolving to
  # the survivor, so a project the operator never chose would silently become their explicit
  # default. The deletion is refused, and nothing is written.
  def test_removing_a_connection_an_ambiguous_default_names_is_refused
    store.save(connection(workspace_key: "shared", project_slug: "alpha"))
    store.save(connection(workspace_key: "shared", project_slug: "beta",
                          connected_at: "2026-07-28T00:00:00Z"))
    write_raw(JSON.parse(File.read(@path)).merge("default_workspace_key" => "shared"))

    error = assert_raises(SpecrelayRunner::ConnectionStore::AmbiguousDefault) do
      store.delete(selector("shared", project_slug: "beta"))
    end

    assert_match(/names 2 connections/, error.message)
    assert_equal 2, store.connections.length, "the refusal must not have written anything"
    assert_equal "shared", store.default_selector
  end

  # The operator settles it with the action that exists for it, and the removal is then ordinary.
  def test_settling_the_default_first_allows_the_same_removal
    store.save(connection(workspace_key: "shared", project_slug: "alpha"))
    store.save(connection(workspace_key: "shared", project_slug: "beta",
                          connected_at: "2026-07-28T00:00:00Z"))
    store.set_default(selector("shared", project_slug: "alpha"))

    store.delete(selector("shared", project_slug: "beta"))

    assert_equal [ "alpha" ], store.connections.map(&:project_slug)
    assert_equal "alpha", store.default_connection.project_slug
  end

  # The rule is about the connections the ambiguous default NAMES. Removing an unrelated one is
  # ordinary cleanup: the default stays ambiguous, so it stays fail-closed.
  def test_removing_a_connection_an_ambiguous_default_does_not_name_is_allowed
    store.save(connection(workspace_key: "shared", project_slug: "alpha"))
    store.save(connection(workspace_key: "shared", project_slug: "beta",
                          connected_at: "2026-07-28T00:00:00Z"))
    store.save(connection(workspace_key: "other", project_slug: "gamma",
                          connected_at: "2026-07-29T00:00:00Z"))
    write_raw(JSON.parse(File.read(@path)).merge("default_workspace_key" => "shared"))

    store.delete(selector("other", project_slug: "gamma"))

    assert_equal 2, store.connections.length
    assert_nil store.default_connection, "the default must still resolve to nothing"
    assert store.resolve(store.default_selector).ambiguous?
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

    found = store.resolve("partial").connection

    refute found.complete?
    assert_equal %i[runner_public_id local_path], found.missing_fields
  end

  def test_a_complete_entry_reports_itself_complete
    store.save(connection(workspace_key: "whole"))

    assert store.resolve("whole").connection.complete?
    assert_empty store.resolve("whole").connection.missing_fields
  end

  # --- the stored reviewer selection (MAPIAI-91) -----------------------------

  # The reviewer provider a guided connection selected is a durable NON-SECRET fact, stored so a
  # later claim can reconstruct it. Only the identifier is stored: how the provider is launched
  # stays on this machine and out of this file.
  def test_a_selected_reviewer_provider_round_trips_and_carries_no_launch_configuration
    store.save(connection(workspace_key: "reviewing", reviewer_provider: "claude"))

    assert_equal "claude", store.resolve("reviewing").connection.reviewer_provider
    entry = document["connections"].first

    assert_equal "claude", entry["reviewer_provider"]
    refute_match(/command|args|timeout|env|credential|account|prompt/i, JSON.generate(entry))
  end

  # A connection made before the selection was stored — and one made on a machine that reviews
  # nothing — must report the absence rather than a substituted value. Nothing downstream may
  # guess from it.
  def test_a_connection_with_no_selected_reviewer_provider_reports_none_and_stays_complete
    store.save(connection(workspace_key: "executing"))

    found = store.resolve("executing").connection

    assert_nil found.reviewer_provider
    assert found.complete?
  end

  def test_a_document_written_before_the_reviewer_selection_existed_still_loads
    write_raw("version" => 2,
              "connections" => [ connection(workspace_key: "older").to_h_document.tap { |e| e.delete("reviewer_provider") } ])

    found = store.resolve("older").connection

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
