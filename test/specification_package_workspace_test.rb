# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "open3"
require "rbconfig"
require "time"

# MAPIAI-62 design 1 and 4 — the Runner-owned isolated workspace store: real git worktrees, a
# real cross-process lock, and the fixed seven-day / twenty-workspace retention contract.
#
# Everything here runs against the real filesystem and real `git`, because every invariant this
# class holds is about files, worktrees, locks or deletions. A test with a stubbed FileUtils
# would prove that a method was called, not that a symlink was refused or that a sweep could not
# remove a workspace another process was publishing from.
class SpecificationPackageWorkspaceTest < Minitest::Test
  Store = SpecrelayRunner::Specification::PackageWorkspaceStore
  Workspace = SpecrelayRunner::Specification::PackageWorkspace
  GitCommands = SpecrelayRunner::Specification::GitCommands

  IDENTITY = {
    "run_id" => "run_spec123", "runner_execution_id" => "rex_spec123", "runner_id" => "test-runner",
    "runner_public_id" => "", "repository_slug" => "SpecRelay/SpecRelay-Specs",
    "repository_url" => "https://github.com/SpecRelay/SpecRelay-Specs",
    "package_path" => "specs/SR-700-add-an-export-button"
  }.freeze

  def setup
    @temp = Dir.mktmpdir("specrelay-workspace-store-")
    @seed = SpecificationWorkspace.git_init(File.join(@temp, "SpecRelay-Specs"))
    @store = Store.new(root: File.join(@temp, "state"), env: { "PATH" => ENV["PATH"] })
    @store.prepare!
  end

  def teardown
    FileUtils.remove_entry(@temp) if @temp && File.directory?(@temp)
  end

  # ------------------------------------------------------------------ what a workspace is

  def test_it_creates_a_detached_no_checkout_worktree_under_the_state_root
    workspace = create

    assert workspace.root.start_with?("#{@store.root}/")
    assert_equal "true", git(workspace.worktree_root, "rev-parse", "--is-inside-work-tree").strip
    assert_equal git(@seed, "rev-parse", "HEAD").strip, git(workspace.worktree_root, "rev-parse", "HEAD").strip
    # `--no-checkout`: the worktree starts genuinely empty, so anything in it later was put there
    # by this generation. That is what makes the exact-file-set check at publication meaningful.
    assert_empty Dir.children(workspace.worktree_root).reject { |name| name == ".git" }
  end

  def test_two_workspaces_never_collide_and_are_independently_addressable
    first = create
    second = create

    refute_equal first.id, second.id
    assert_equal 2, @store.all.length
    assert_equal first.root, @store.find(first.id).root
  end

  def test_the_metadata_carries_the_identity_and_no_secret_or_local_path
    workspace = create
    document = JSON.parse(File.read(File.join(workspace.root, "workspace.json")))

    assert_equal IDENTITY["run_id"], document["run_id"]
    assert_equal git(@seed, "rev-parse", "HEAD").strip, document["base_commit"]
    assert_equal Workspace::GENERATING, document["state"]
    refute_includes document.to_json, @seed
    refute_includes document.to_json, workspace.root
    refute_includes document.to_json, Dir.home
  end

  def test_an_id_that_is_not_the_shape_this_store_issues_resolves_to_nothing
    [ "../../etc", "swp_short", "", "swp_#{'z' * 32}", "/absolute" ].each do |candidate|
      assert_nil @store.find(candidate), candidate.inspect
    end
  end

  # ------------------------------------------------------------------ retention (design 4)

  def test_the_retention_contract_is_fixed_at_seven_days_and_twenty_workspaces
    assert_equal 7, Store::RETENTION_DAYS
    assert_equal 20, Store::MAX_RETAINED
    assert_in_delta (Time.now.utc + (7 * 86_400)).to_f, create.expires_at.to_f, 60
  end

  # S23/S24 — expired workspaces go, and only expired ones.
  def test_the_sweep_removes_expired_workspaces_and_keeps_live_ones
    expired = create
    live = create
    expire!(expired)

    assert_equal 1, @store.sweep(clock: Time)

    refute File.exist?(expired.root)
    assert File.directory?(live.root)
  end

  # S24 — over the quota, oldest first, and never the one the caller is about to use.
  def test_the_sweep_trims_to_the_quota_oldest_first_and_keeps_the_current_workspace
    made = Array.new(Store::MAX_RETAINED + 3) { |index| age(create, minutes: 1_000 - index) }
    current = made.last

    @store.sweep(clock: Time, keep: current.id)

    remaining = @store.all.map(&:id)
    # Twenty retained means twenty on disk — `keep` counts toward the quota rather than sitting
    # outside it, or a busy machine would settle at twenty-one.
    assert_equal Store::MAX_RETAINED, remaining.length
    assert_includes remaining, current.id, "the workspace being used must survive the quota"
    # The three oldest are the ones that went.
    made.first(3).each { |workspace| refute File.exist?(workspace.root), workspace.id }
  end

  def test_the_sweep_removes_the_worktree_registration_from_the_seed
    workspace = create
    assert_includes git(@seed, "worktree", "list"), workspace.id
    expire!(workspace)

    @store.sweep(clock: Time)

    refute_includes git(@seed, "worktree", "list"), workspace.id
  end

  # S25 — the sweep cannot remove a workspace another process is working in. Proven with a REAL
  # second process holding the REAL lock, because an in-process flag would prove nothing about
  # two runner processes on one machine.
  def test_the_sweep_skips_a_workspace_another_process_holds_the_lock_for
    workspace = create
    expire!(workspace)

    removed = with_lock_held(workspace.id) { @store.sweep(clock: Time) }

    assert_equal 0, removed
    assert File.directory?(workspace.root), "an active workspace must survive its own expiry"
  end

  def test_the_lock_serializes_two_holders_in_this_process
    workspace = create
    inner = @store.with_lock(workspace.id) do
      @store.with_lock(workspace.id, blocking: false) { :entered }
    end

    assert_nil inner, "a non-blocking second acquisition must not enter the block"
  end

  # ------------------------------------------------------------------ never outside the root

  def test_a_symlinked_entry_in_the_state_root_is_never_followed_or_removed
    outside = File.join(@temp, "somebody-elses-directory")
    FileUtils.mkdir_p(outside)
    File.write(File.join(outside, "precious.txt"), "do not delete\n")
    File.symlink(outside, File.join(@store.root, Workspace.generate_id))

    assert_empty @store.all, "a symlink is not a workspace"
    assert_equal 0, @store.sweep(clock: Time)
    assert File.file?(File.join(outside, "precious.txt"))
  end

  # review-001 F2 — the reviewer's exact probe. `all` skipped a symlinked entry, but lookup BY ID
  # only checked the path lexically and `File.directory?` follows a symlink, so a workspace moved
  # out of the store and linked back in resolved and had its metadata read. Enumeration, lookup
  # and removal now apply one rule, which is what this asserts on all three.
  def test_an_entry_symlinked_outside_the_state_root_is_never_resolved_by_id
    workspace = create
    outside = File.join(@temp, "moved-out-of-the-store")
    FileUtils.mv(workspace.root, outside)
    File.symlink(outside, workspace.root)

    assert_nil @store.find(workspace.id), "lookup by id must not follow a symlinked entry"
    assert_empty @store.all
    refute @store.remove(Workspace.new(id: workspace.id, root: workspace.root))
    # Not merely "not published" — not even READ, and certainly not deleted.
    assert File.file?(File.join(outside, "workspace.json")), "the external directory must survive"
  end

  # The same rule one level up: the entry itself is an ordinary directory, but the STATE ROOT is
  # reached through a symlink, so a lexical prefix test passes while the canonical path does not.
  def test_a_workspace_reached_through_a_symlinked_state_root_is_still_contained
    linked = File.join(@temp, "state-by-another-name")
    File.symlink(@store.root, linked)
    store = Store.new(root: linked, env: { "PATH" => ENV["PATH"] })
    workspace = create

    # Resolving the root through a link is legitimate — the workspace is genuinely inside it.
    refute_nil store.find(workspace.id), "a symlinked root must still resolve its own workspaces"
    assert_equal 1, store.all.length
  end

  def test_removal_refuses_a_workspace_whose_directory_is_outside_the_state_root
    outside = File.join(@temp, "outside-workspace")
    FileUtils.mkdir_p(outside)

    refute @store.remove(Workspace.new(id: Workspace.generate_id, root: outside))
    assert File.directory?(outside)
  end

  # ------------------------------------------------------------------ helpers

  def create
    @store.create(commands: GitCommands.new(checkout_root: @seed, env: { "PATH" => ENV["PATH"] }),
                  base_commit: git(@seed, "rev-parse", "HEAD").strip, identity: IDENTITY, clock: Time)
  end

  def rewrite(workspace, fields)
    path = File.join(workspace.root, "workspace.json")
    File.write(path, "#{JSON.pretty_generate(JSON.parse(File.read(path)).merge(fields))}\n")
    Workspace.new(id: workspace.id, root: workspace.root)
  end

  def expire!(workspace) = rewrite(workspace, "expires_at" => (Time.now.utc - 60).iso8601)

  # Backdate creation AND expiry together, so an aged workspace is still live — which is what
  # makes the quota test about the quota rather than about expiry.
  def age(workspace, minutes:)
    created = Time.now.utc - (minutes * 60)
    rewrite(workspace, "created_at" => created.iso8601,
                       "expires_at" => (created + (Store::RETENTION_DAYS * 86_400)).iso8601)
  end

  def with_lock_held(workspace_id)
    lock = File.join(@store.root, "#{workspace_id}.lock")
    ready = File.join(@temp, "held")
    holder = spawn(RbConfig.ruby, "-e", <<~RUBY)
      File.open(#{lock.dump}, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        File.write(#{ready.dump}, "held")
        sleep 30
      end
    RUBY
    sleep 0.02 until File.exist?(ready)
    yield
  ensure
    if holder
      Process.kill("TERM", holder)
      Process.wait(holder)
    end
  end

  def git(root, *args)
    out, status = Open3.capture2e("git", "-C", root, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end
end
