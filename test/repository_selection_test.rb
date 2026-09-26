# frozen_string_literal: true

require_relative "test_helper"

# MAPIAI-84/MAPIAI-93 — the executor's repository selection document, at its own boundary.
#
# It is the ONE input that turns a semantic decision into something the runner will act on, so
# it is a CLOSED, BOUNDED document: a relative path plus an ordered list of argv commands, and
# nothing else. Everything the executor must not put there — an absolute path, a pull-request
# URL, a credential, a shell string, a claimed exit code, its own reasoning — is refused here
# rather than filtered later, because a document the parser accepted is a document the verifier
# is asked to trust.
#
# Path containment, git roots, remotes, branches, change sets and duplicate identity are NOT
# this class's: they are facts about repositories on disk and belong to {Workspace}. Whether a
# command PASSES is not this class's either: only {RepositoryVerification}, running it, knows.
# This proves only that the document itself is read safely.
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
    assert_empty result.entries
  end

  def test_relative_paths_and_their_commands_are_read_in_order
    write(JSON.generate({ "repositories" => [
      { "path" => "component-b", "commands" => [ %w[bin/test], %w[bin/lint --strict] ] },
      { "path" => ".", "commands" => [] }
    ] }))
    result = read
    assert result.ok?, result.error
    assert_equal [ "component-b", "." ], result.entries.map(&:path)
    assert_equal [ %w[bin/test], %w[bin/lint --strict] ], result.entries.first.commands,
                 "commands are executed in the order the executor declared them"
  end

  # MAPIAI-93 — the semantic input for NOT_FOUND. A repository with no applicable verification
  # says so explicitly; it is neither a failure nor an invitation to invent a command.
  def test_an_empty_command_list_is_the_no_verification_found_answer
    write(JSON.generate({ "repositories" => [ { "path" => "component-a", "commands" => [] } ] }))
    result = read
    assert result.ok?, result.error
    assert_empty result.entries.first.commands
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
    write(JSON.generate({ "repositories" => [ { "path" => "component-a", "commands" => [],
                                                "pull_request_url" => "https://github.com/o/r/pull/1" } ] }))
    refute read.ok?
    assert_match(/must carry only/, read.error)
  end

  # An entry that states no command list has not answered the question. Silence and "I found no
  # verification" are different facts, exactly as an absent document and an empty list are.
  def test_an_entry_without_a_command_list_is_refused
    write(JSON.generate({ "repositories" => [ { "path" => "component-a" } ] }))
    refute read.ok?
    assert_match(/must carry only/, read.error)
  end

  # A claimed outcome is the one thing this document may never carry: Runner derives every
  # status from its OWN execution, so an executor's exit code could only mislead.
  def test_an_entry_claiming_an_outcome_is_refused
    write(JSON.generate({ "repositories" => [ { "path" => "component-a", "commands" => [ %w[bin/test] ],
                                                "exit_code" => 0, "status" => "passed" } ] }))
    refute read.ok?
    assert_match(/must carry only/, read.error)
  end

  # A shell string is not an argv array. Accepting one would put a shell — and every quoting,
  # globbing and injection question that comes with it — between the executor and the process.
  def test_a_shell_string_instead_of_an_argv_array_is_refused
    [ "bin/test && bin/lint", "bin/test" ].each do |shell|
      write(JSON.generate({ "repositories" => [ { "path" => "component-a", "commands" => [ shell ] } ] }))
      refute read.ok?, "#{shell.inspect} is a shell string, not an argv array"
      assert_match(/argv array/i, read.error)
    end
  end

  def test_a_command_list_that_is_not_a_list_is_refused
    write(JSON.generate({ "repositories" => [ { "path" => "component-a", "commands" => "bin/test" } ] }))
    refute read.ok?
    assert_match(/list of commands/i, read.error)
  end

  def test_an_empty_argv_is_refused
    write(JSON.generate({ "repositories" => [ { "path" => "component-a", "commands" => [ [] ] } ] }))
    refute read.ok?
    assert_match(/names no program/i, read.error)
  end

  def test_a_non_string_or_blank_argv_element_is_refused
    [ [ [ "bin/test", 3 ] ], [ [ "bin/test", "" ] ], [ [ "  " ] ], [ [ "bin/test", nil ] ],
      [ [ "bin/test", [ "nested" ] ] ] ].each do |commands|
      write(JSON.generate({ "repositories" => [ { "path" => "component-a", "commands" => commands } ] }))
      refute read.ok?, "#{commands.inspect} is not an argv of non-empty strings"
    end
  end

  def test_more_commands_than_the_bound_are_refused
    commands = Array.new(SpecrelayRunner::RepositorySelection::MAX_COMMANDS + 1) { %w[bin/test] }
    write(JSON.generate({ "repositories" => [ { "path" => "component-a", "commands" => commands } ] }))
    refute read.ok?
    assert_match(/at most/i, read.error)
  end

  def test_more_argv_elements_than_the_bound_are_refused
    argv = Array.new(SpecrelayRunner::RepositorySelection::MAX_ARGUMENTS + 1) { "--flag" }
    write(JSON.generate({ "repositories" => [ { "path" => "component-a", "commands" => [ argv ] } ] }))
    refute read.ok?
    assert_match(/at most/i, read.error)
  end

  def test_an_oversized_argv_element_is_refused
    long = "x" * (SpecrelayRunner::RepositorySelection::MAX_ARGUMENT_LENGTH + 1)
    write(JSON.generate({ "repositories" => [ { "path" => "component-a", "commands" => [ [ "bin/test", long ] ] } ] }))
    refute read.ok?
    assert_match(/too long/i, read.error)
  end

  def test_a_2000_character_argv_element_is_accepted
    argument = "x" * 2_000
    write(JSON.generate({ "repositories" => [ { "path" => "component-a", "commands" => [ [ "bin/test", argument ] ] } ] }))

    result = read

    assert result.ok?, result.error
    assert_equal argument, result.entries.first.commands.first.last
  end

  def test_an_entry_with_a_blank_or_missing_path_is_refused
    [ [ {} ], [ { "path" => "", "commands" => [] } ], [ { "path" => "   ", "commands" => [] } ],
      [ "component-a" ] ].each do |repositories|
      write(JSON.generate({ "repositories" => repositories }))
      refute read.ok?, "#{repositories.inspect} names no repository"
    end
  end

  def test_an_oversized_document_is_refused_without_being_parsed
    write(JSON.generate({ "repositories" => [ { "path" => "a" * (SpecrelayRunner::RepositorySelection::MAX_BYTES + 1),
                                                "commands" => [] } ] }))
    refute read.ok?
    assert_match(/too large/i, read.error)
  end

  def test_more_entries_than_the_bound_are_refused
    entries = Array.new(SpecrelayRunner::RepositorySelection::MAX_ENTRIES + 1) { |i| { "path" => "r#{i}", "commands" => [] } }
    write(JSON.generate({ "repositories" => entries }))
    refute read.ok?
    assert_match(/at most/i, read.error)
  end

  # The refusal is what an operator reads, so it must not echo the document: a selection an
  # executor got wrong is exactly the place an unexpected secret would appear.
  def test_a_refusal_does_not_echo_the_document
    write(JSON.generate({ "repositories" => [ { "path" => "r", "commands" => [],
                                                "token" => "sk-live-DO-NOT-LEAK-0123456789" } ] }))
    refute_match(/sk-live/, read.error)
  end
end
