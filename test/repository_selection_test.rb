# frozen_string_literal: true

require_relative "test_helper"

# MAPIAI-84 — the executor's repository selection document, at its own boundary.
#
# It is the ONE input that turns a semantic decision into something the runner will act on, so
# it is a CLOSED, BOUNDED document: relative paths and nothing else. Everything the executor
# must not put there — an absolute path, a pull-request URL, a credential, its own reasoning —
# is refused here rather than filtered later, because a document the parser accepted is a
# document the verifier is asked to trust.
#
# Path containment, git roots, remotes, branches, change sets and duplicate identity are NOT
# this class's: they are facts about repositories on disk and belong to {Workspace}. This proves
# only that the document itself is read safely.
class RepositorySelectionTest < Minitest::Test
  def setup
    @staging = Dir.mktmpdir("selection-")
  end

  def teardown
    FileUtils.remove_entry(@staging) if @staging && File.directory?(@staging)
  end

  def path = SpecrelayRunner::RepositorySelection.path(@staging)
  def write(content) = File.write(path, content)
  def read = SpecrelayRunner::RepositorySelection.read(@staging)

  def test_the_document_lives_outside_the_task_workspace
    assert_equal @staging, File.dirname(path),
                 "a selection document inside the workspace would appear in the diff it describes"
  end

  def test_an_explicit_empty_selection_is_the_no_change_answer
    write(JSON.generate({ "repositories" => [] }))
    result = read
    assert result.ok?, result.error
    assert_empty result.paths
  end

  def test_relative_paths_are_read_in_order
    write(JSON.generate({ "repositories" => [ { "path" => "component-b" }, { "path" => "." } ] }))
    result = read
    assert result.ok?, result.error
    assert_equal [ "component-b", "." ], result.paths
  end

  # An ABSENT document is not an empty selection: the executor never answered.
  def test_a_missing_document_is_refused
    refute read.ok?
    assert_match(/did not write/i, read.error)
  end

  def test_unparseable_bytes_are_refused
    write("not json at all")
    refute read.ok?
    assert_match(/could not be read/i, read.error)
  end

  def test_a_document_that_is_not_an_object_with_repositories_is_refused
    [ "[]", JSON.generate({ "repos" => [] }), JSON.generate({ "repositories" => "component-a" }) ].each do |body|
      write(body)
      refute read.ok?, "#{body} is not a selection document"
    end
  end

  # Closed shape: an entry carries a path and nothing else, so a pull-request URL, a credential
  # or a paragraph of reasoning cannot ride along in a field the runner would then store.
  def test_an_entry_carrying_any_other_field_is_refused
    write(JSON.generate({ "repositories" => [ { "path" => "component-a",
                                                "pull_request_url" => "https://github.com/o/r/pull/1" } ] }))
    refute read.ok?
    assert_match(/must carry only a "path"/, read.error)
  end

  def test_an_entry_with_a_blank_or_missing_path_is_refused
    [ [ {} ], [ { "path" => "" } ], [ { "path" => "   " } ], [ "component-a" ] ].each do |repositories|
      write(JSON.generate({ "repositories" => repositories }))
      refute read.ok?, "#{repositories.inspect} names no repository"
    end
  end

  def test_an_oversized_document_is_refused_without_being_parsed
    write(JSON.generate({ "repositories" => [ { "path" => "a" * (SpecrelayRunner::RepositorySelection::MAX_BYTES + 1) } ] }))
    refute read.ok?
    assert_match(/too large/i, read.error)
  end

  def test_more_entries_than_the_bound_are_refused
    entries = Array.new(SpecrelayRunner::RepositorySelection::MAX_ENTRIES + 1) { |i| { "path" => "r#{i}" } }
    write(JSON.generate({ "repositories" => entries }))
    refute read.ok?
    assert_match(/at most/i, read.error)
  end

  # The refusal is what an operator reads, so it must not echo the document: a selection an
  # executor got wrong is exactly the place an unexpected secret would appear.
  def test_a_refusal_does_not_echo_the_document
    write(JSON.generate({ "repositories" => [ { "path" => "r", "token" => "sk-live-DO-NOT-LEAK-0123456789" } ] }))
    refute_match(/sk-live/, read.error)
  end
end
