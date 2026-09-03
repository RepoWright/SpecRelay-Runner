# frozen_string_literal: true

require_relative "test_helper"

# The portable uncommitted-work checkpoint: capturing every selected repository's bounded
# Git-visible work on one machine, and reproducing it exactly on a machine that never saw it.
#
# Everything here runs against REAL git repositories and the real filesystem. A checkpoint that
# round-trips through a double is a checkpoint nobody has proven, because every interesting term
# — the exec bit, a symlink, an empty untracked file, a deletion, an ignored file — is a fact
# about git and the disk rather than about this code.
class PortableCheckpointTest < Minitest::Test
  TASK = "DEMO-0037"

  def setup
    @built = MultiRepositoryWorkspace.build
    @clone = nil
  end

  def teardown
    [ @built&.root, @clone&.root ].compact.each do |root|
      FileUtils.remove_entry(root) if File.directory?(root)
    end
  end

  # ------------------------------------------------------------------ fixtures

  def measuring(root)
    SpecrelayRunner::Workspace.new(root: root, canonical_branch: TASK, create_command: "")
  end

  def creating(root)
    SpecrelayRunner::Workspace.new(root: root, canonical_branch: TASK, task_id: TASK,
                                   create_command: "false")
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  # The task workspace this machine's own project command builds.
  def prepare_workspace(root)
    creating(root).create
  end

  # Every Git-visible kind of change the specification names, spread across two independent
  # repositories: a text edit, a binary addition, an executable bit, a symlink, a rename, a
  # deletion, a non-ignored untracked file, an EMPTY untracked file, and one ignored file that
  # must not travel.
  def dirty_everything(task_root)
    a = File.join(task_root, "component-a")
    File.write(File.join(a, "app.txt"), "edited by the executor\n")
    File.binwrite(File.join(a, "logo.bin"), "\x00\x01\x02\xFF".b)
    File.write(File.join(a, "run.sh"), "#!/bin/sh\necho hi\n")
    FileUtils.chmod(0o755, File.join(a, "run.sh"))
    File.write(File.join(a, "empty.txt"), "")
    FileUtils.ln_s("app.txt", File.join(a, "link.txt"))
    FileUtils.mkdir_p(File.join(a, MultiRepositoryWorkspace::IGNORED_OUTPUT))
    File.write(File.join(a, MultiRepositoryWorkspace::IGNORED_OUTPUT, "scratch.txt"), "ignored\n")

    b = File.join(task_root, "component-b")
    git(b, "mv", "app.txt", "renamed.txt")
    File.write(File.join(b, "renamed.txt"), "renamed and edited\n")
    FileUtils.rm_f(File.join(b, "bin", "mutate"))
  end

  def selection(task_root, paths = %w[component-a component-b])
    measuring(@built.root).select(task_root, paths)
  end

  def capture(task_root, paths = %w[component-a component-b])
    verified = selection(task_root, paths)
    raise verified.error if verified.error

    SpecrelayRunner::Checkpoint.capture(repositories: verified.repositories,
                                        workspace: measuring(@built.root))
  end

  # What Platform stores and hands back: the closed metadata, with the payload transported
  # separately exactly as the download boundary does.
  def stored(captured)
    document = captured.checkpoint.dup
    [ document.reject { |key, _| key == "payload" }, document["payload"] ]
  end

  # The digest of every selected repository as this machine measures it right now.
  def measured_digests(task_root, paths = %w[component-a component-b])
    paths.to_h do |path|
      changes = measuring(@built.root).capture_changes(File.join(task_root, path))
      [ path, Digest::SHA256.hexdigest(changes.diff.to_s) ]
    end
  end

  # A component checked out as a linked worktree keeps its index outside `.git`, so git is asked
  # where it is rather than the layout being assumed.
  def index_bytes(task_root, paths = %w[component-a component-b])
    paths.to_h do |path|
      dir = git(File.join(task_root, path), "rev-parse", "--absolute-git-dir").strip
      [ path, File.binread(File.join(dir, "index")) ]
    end
  end

  # Every working-tree fact a checkpoint has to reproduce: the path, whether it is a directory,
  # what a symlink points at, the executable bit, and the exact bytes.
  def worktree_bytes(task_root, paths = %w[component-a component-b])
    paths.flat_map do |path|
      root = File.join(task_root, path)
      Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |e| e.start_with?(".git") }
         .map do |entry|
        full = File.join(root, entry)
        next [ entry, :dir ] if File.directory?(full) && !File.symlink?(full)
        next [ entry, :symlink, File.readlink(full) ] if File.symlink?(full)

        [ entry, File.stat(full).mode & 0o111, File.binread(full) ]
      end
    end.sort_by(&:first)
  end

  # --------------------------------------------------------------- capture

  # A02, scenario 2 — capture reads. It builds its tree through a temporary index, so the real
  # index bytes, the worktree bytes and `git status` are the same afterwards as before.
  def test_capture_changes_neither_the_source_index_nor_the_worktree
    task_root = prepare_workspace(@built.root).path
    dirty_everything(task_root)
    # Measurement itself marks new files intent-to-add; the boundary under test is what the
    # CHECKPOINT build does after that, so the baseline is taken once measurement has run.
    measured_digests(task_root)
    before_index = index_bytes(task_root)
    before_tree = worktree_bytes(task_root)
    before_status = %w[component-a component-b].to_h { |p| [ p, git(File.join(task_root, p), "status", "--porcelain") ] }

    captured = capture(task_root)

    assert captured.ok?, captured.error
    assert_equal before_index, index_bytes(task_root), "the real index bytes changed"
    assert_equal before_tree, worktree_bytes(task_root), "the worktree bytes changed"
    assert_equal before_status, %w[component-a component-b].to_h { |p| [ p, git(File.join(task_root, p), "status", "--porcelain") ] }
  end

  # A03 — the closed metadata, and the bound. No local path travels in it.
  def test_the_captured_metadata_is_closed_bounded_and_carries_no_local_path
    task_root = prepare_workspace(@built.root).path
    dirty_everything(task_root)

    captured = capture(task_root)

    checkpoint = captured.checkpoint
    assert_equal %w[byte_size digest format payload repositories], checkpoint.keys.sort
    assert_equal SpecrelayRunner::Checkpoint::FORMAT, checkpoint["format"]
    assert_operator checkpoint["byte_size"], :<=, SpecrelayRunner::Checkpoint::MAX_BYTES
    assert_match(/\A[0-9a-f]{64}\z/, checkpoint["digest"])
    decoded = Base64.strict_decode64(checkpoint["payload"])
    assert_equal checkpoint["byte_size"], decoded.bytesize
    assert_equal checkpoint["digest"], Digest::SHA256.hexdigest(decoded)

    entries = checkpoint["repositories"]
    assert_equal %w[component-a component-b], entries.map { |e| e["path"] }
    entries.each do |entry|
      assert_equal %w[base branch change_digest checkpoint_commit origin path], entry.keys.sort
      assert_equal TASK, entry["branch"]
      assert_match(/\A[0-9a-f]{40}\z/, entry["base"])
      assert_match(/\A[0-9a-f]{40}\z/, entry["checkpoint_commit"])
      assert_match(/\A[0-9a-f]{64}\z/, entry["change_digest"])
    end
    assert_equal %w[SpecRelay/component-a SpecRelay/component-b], entries.map { |e| e["origin"] }
    refute_includes checkpoint.reject { |key, _| key == "payload" }.to_json, @built.root
  end

  # Scenario 3 — a selection that names nothing is refused before anything is packaged.
  def test_an_empty_selection_is_refused
    task_root = prepare_workspace(@built.root).path
    dirty_everything(task_root)

    captured = SpecrelayRunner::Checkpoint.capture(repositories: [], workspace: measuring(@built.root))

    refute captured.ok?
    assert_includes captured.error, "no repository"
  end

  # Scenario 3 — the bound is on the DECODED package and refuses rather than truncating.
  def test_a_checkpoint_over_the_bound_is_refused_whole
    task_root = prepare_workspace(@built.root).path
    dirty_everything(task_root)
    File.binwrite(File.join(task_root, "component-a", "big.bin"), SecureRandom.bytes(6 * 1024 * 1024))

    captured = capture(task_root)

    refute captured.ok?
    assert_includes captured.error, "too large"
  end

  # ---------------------------------------------------------------- round trip

  # A01/A04, scenario 1 — the whole point: a machine that never saw the work reproduces every
  # repository byte for byte, mode for mode, link for link, and remeasures to the same digests.
  def test_every_git_visible_change_round_trips_to_a_machine_that_never_saw_it
    source_root = prepare_workspace(@built.root).path
    dirty_everything(source_root)
    recorded = measured_digests(source_root)
    captured = capture(source_root)
    assert captured.ok?, captured.error
    metadata, payload = stored(captured)
    source_bytes = worktree_bytes(source_root)

    @clone = MultiRepositoryWorkspace.clone_of(@built)
    target = creating(@clone.root).create
    restored = SpecrelayRunner::Checkpoint.restore(metadata, payload: payload,
                                                             task_root: target.path,
                                                             workspace: measuring(@clone.root))

    assert restored.ok?, restored.reason
    target_bytes = worktree_bytes(target.path)
    # The ignored scratch file is the one difference that MUST exist: it never travels.
    ignored = File.join(MultiRepositoryWorkspace::IGNORED_OUTPUT, "scratch.txt")
    refute_includes target_bytes.map(&:first), ignored
    assert_equal source_bytes.reject { |entry| entry.first.start_with?(MultiRepositoryWorkspace::IGNORED_OUTPUT) },
                 target_bytes

    %w[component-a component-b].each do |path|
      changes = measuring(@clone.root).capture_changes(File.join(target.path, path))
      assert_equal recorded[path], Digest::SHA256.hexdigest(changes.diff.to_s),
                   "#{path} did not remeasure to the recorded digest"
    end
  end

  # Scenario 9 — every way the target is not what was recorded, each refusing before any
  # repository is written and naming the term that failed.
  def test_a_target_that_is_not_the_recorded_base_refuses_without_writing
    source_root = prepare_workspace(@built.root).path
    dirty_everything(source_root)
    metadata, payload = stored(capture(source_root))

    @clone = MultiRepositoryWorkspace.clone_of(@built)
    target = creating(@clone.root).create
    component = File.join(target.path, "component-a")

    File.write(File.join(component, "app.txt"), "someone else was here\n")
    dirty = SpecrelayRunner::Checkpoint.restore(metadata, payload: payload, task_root: target.path,
                                                          workspace: measuring(@clone.root))
    refute dirty.ok?
    assert_includes dirty.reason, "uncommitted"
    assert_equal "someone else was here\n", File.read(File.join(component, "app.txt")),
                 "a refusing restore must never reset or clean the target"

    git(component, "checkout", "--", "app.txt")
    git(component, "checkout", "-q", "-b", "some-other-branch")
    wrong_branch = SpecrelayRunner::Checkpoint.restore(metadata, payload: payload, task_root: target.path,
                                                                 workspace: measuring(@clone.root))
    refute wrong_branch.ok?
    assert_includes wrong_branch.reason, "branch"

    git(component, "checkout", "-q", TASK)
    File.write(File.join(component, "moved.txt"), "moved\n")
    git(component, "add", "-A")
    git(component, "-c", "user.email=t@e.test", "-c", "user.name=T", "commit", "-q", "-m", "moved")
    moved = SpecrelayRunner::Checkpoint.restore(metadata, payload: payload, task_root: target.path,
                                                          workspace: measuring(@clone.root))
    refute moved.ok?
    assert_includes moved.reason, "base"
  end

  def test_a_recorded_path_outside_the_task_workspace_is_refused
    source_root = prepare_workspace(@built.root).path
    dirty_everything(source_root)
    metadata, payload = stored(capture(source_root))
    metadata["repositories"][0] = metadata["repositories"][0].merge("path" => "../escape")

    @clone = MultiRepositoryWorkspace.clone_of(@built)
    target = creating(@clone.root).create

    refused = SpecrelayRunner::Checkpoint.restore(metadata, payload: payload, task_root: target.path,
                                                            workspace: measuring(@clone.root))

    refute refused.ok?
    assert_includes refused.reason, "task workspace"
  end

  def test_a_target_whose_remote_is_a_different_repository_is_refused
    source_root = prepare_workspace(@built.root).path
    dirty_everything(source_root)
    metadata, payload = stored(capture(source_root))

    @clone = MultiRepositoryWorkspace.clone_of(@built)
    target = creating(@clone.root).create
    git(File.join(target.path, "component-a"), "remote", "set-url", "origin",
        "git@github.com:SpecRelay/somewhere-else.git")

    refused = SpecrelayRunner::Checkpoint.restore(metadata, payload: payload, task_root: target.path,
                                                            workspace: measuring(@clone.root))

    refute refused.ok?
    assert_includes refused.reason, "origin"
  end

  # A05, scenario 9 — bytes that are not the recorded package never reach a repository.
  def test_a_payload_that_does_not_match_its_checksum_is_refused_before_any_repository_is_touched
    source_root = prepare_workspace(@built.root).path
    dirty_everything(source_root)
    metadata, payload = stored(capture(source_root))

    @clone = MultiRepositoryWorkspace.clone_of(@built)
    target = creating(@clone.root).create
    before = worktree_bytes(target.path)

    bytes = Base64.strict_decode64(payload)
    # The same LENGTH, different bytes: the checksum is what must catch this, not the size.
    tampered = Base64.strict_encode64("#{bytes[0..-2]}#{bytes[-1] == 'x' ? 'y' : 'x'}")
    refused = SpecrelayRunner::Checkpoint.restore(metadata, payload: tampered, task_root: target.path,
                                                            workspace: measuring(@clone.root))

    refute refused.ok?
    assert_includes refused.reason, "checksum"
    assert_equal before, worktree_bytes(target.path)
  end

  # A04, scenario 9 — the last gate. A package whose recorded digest does not describe what it
  # actually restores must not start a provider.
  def test_a_post_restore_digest_mismatch_refuses
    source_root = prepare_workspace(@built.root).path
    dirty_everything(source_root)
    captured = capture(source_root)
    metadata, payload = stored(captured)
    metadata["repositories"][0] = metadata["repositories"][0].merge("change_digest" => "f" * 64)

    @clone = MultiRepositoryWorkspace.clone_of(@built)
    target = creating(@clone.root).create

    refused = SpecrelayRunner::Checkpoint.restore(metadata, payload: payload, task_root: target.path,
                                                            workspace: measuring(@clone.root))

    refute refused.ok?
    assert_includes refused.reason, "change_digest"
  end

  # Scenario 7 — the machine that still holds the work verifies and reuses it; nothing is
  # downloaded, created or reapplied.
  def test_an_exactly_matching_local_worktree_verifies_without_restoring
    source_root = prepare_workspace(@built.root).path
    dirty_everything(source_root)
    metadata, = stored(capture(source_root))

    proof = SpecrelayRunner::Checkpoint.verify(metadata, task_root: source_root,
                                                         workspace: measuring(@built.root))

    assert proof.ok?, proof.reason

    File.write(File.join(source_root, "component-a", "app.txt"), "changed since the question\n")
    drifted = SpecrelayRunner::Checkpoint.verify(metadata, task_root: source_root,
                                                           workspace: measuring(@built.root))
    refute drifted.ok?
    assert_includes drifted.reason, "change_digest"
  end
end
