# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/fake_platform"

# Where the fixtures read the published runner contract from.
#
# The contract belongs to the WORKSPACE, not to this repository, and this repository is checked out
# in one of two supported places relative to it: standalone beside `contracts/`, or inside a task
# worktree at `repositories/specrelay-runner`. The fixture used to state only the first, so every
# test that validated a result document against the contract failed in a task worktree with a bare
# `Errno::ENOENT` — ten files' worth, and none of it a product defect.
#
# Both layouts are stated explicitly and tried in order. This file proves both, and proves the two
# properties that make the fix safe rather than convenient: the schema is never copied into this
# repository, and a missing contract is a loud failure rather than a skipped check.
class ContractLayoutTest < Minitest::Test
  RELATIVE = FakePlatform::CONTRACT_RELATIVE_PATH

  def setup
    @dir = Dir.mktmpdir("contract-layout")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # --- both supported layouts -----------------------------------------------

  def test_the_standalone_layout_resolves_the_contract_beside_the_repository
    standalone = root_holding_contract("standalone")
    task = File.join(@dir, "task-without")

    assert_equal File.join(standalone, RELATIVE), FakePlatform.contract_in([ standalone, task ])
  end

  def test_the_task_worktree_layout_resolves_the_workspace_contract
    standalone = File.join(@dir, "standalone-without")
    task = root_holding_contract("task")

    assert_equal File.join(task, RELATIVE), FakePlatform.contract_in([ standalone, task ])
  end

  # Stated order, not a search: when a machine happens to have both, the nearer one wins and the
  # choice is predictable rather than dependent on which directory was met first.
  def test_the_nearer_root_wins_when_both_layouts_are_present
    standalone = root_holding_contract("both-standalone")
    task = root_holding_contract("both-task")

    assert_equal File.join(standalone, RELATIVE), FakePlatform.contract_in([ standalone, task ])
  end

  # --- the two properties that keep the fix honest --------------------------

  def test_a_contract_in_neither_layout_fails_loudly_and_says_where_it_looked
    roots = [ File.join(@dir, "a"), File.join(@dir, "b") ]
    error = assert_raises(RuntimeError) { FakePlatform.contract_in(roots) }

    assert_match(/could not find #{Regexp.escape(RELATIVE)}/, error.message)
    roots.each { |root| assert_includes error.message, root }
    assert_match(/do not copy it/, error.message)
  end

  # --- this checkout, as it really is ---------------------------------------

  def test_this_checkout_resolves_a_real_authoritative_contract
    resolved = FakePlatform.generation_result_contract

    assert File.file?(resolved), "the contract did not resolve in this layout"
    assert_equal RELATIVE, resolved.delete_prefix("#{supported_root_of(resolved)}/")
  end

  # The schema must never be vendored here: a copy silently stops tracking the published document,
  # which is the whole reason the fixture reads it instead of restating its keys.
  def test_no_contract_copy_exists_inside_this_repository
    repository = File.expand_path("..", __dir__)

    refute File.file?(File.join(repository, RELATIVE)),
           "a copy of the contract was vendored into the runner repository"
    refute_includes FakePlatform.generation_result_contract, "#{repository}/"
  end

  # Validation is still real: the keys come from the document, and they are the ones Platform's
  # contract declares rather than a restated list.
  def test_the_declared_keys_come_from_the_published_document
    published = JSON.parse(File.read(FakePlatform.generation_result_contract)).fetch("properties").keys

    assert_equal published, FakePlatform.generation_result_keys
    refute_empty FakePlatform.generation_result_keys
  end

  private

  def root_holding_contract(name)
    root = File.join(@dir, name)
    path = File.join(root, RELATIVE)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate("properties" => { "outcome" => {} }))
    root
  end

  def supported_root_of(resolved)
    FakePlatform::SUPPORTED_CONTRACT_ROOTS.find { |root| resolved.start_with?("#{root}/") }
  end
end
