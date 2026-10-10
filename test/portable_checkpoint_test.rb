# frozen_string_literal: true

require_relative "test_helper"

# The remote checkpoint: every changed repository of a task workspace captured as one snapshot
# commit on its recorded base, pushed to an immutable `runner-checkpoints/<id>` ref on that
# repository's own origin, and reconstructed as dirty work by whichever machine continues.
#
# Everything here runs against REAL git repositories, each answered by its own local bare remote.
# Nothing reaches a network: every origin is the GitHub url the runner normalizes, served locally.
#
# The fixture is the four-repository shape the change request names: A is unchanged, B is changed
# with no pull request, and C and D are changed on top of their reviewed pull-request heads.
class PortableCheckpointTest < Minitest::Test
  TASK = "DEMO-0037"
  COMPONENTS = %w[component-a component-b component-c component-d].freeze
  REVIEWED = %w[component-c component-d].freeze
  ID = "0f1e2d3c-4b5a-4968-8776-655443322110"
  REF = "refs/heads/runner-checkpoints/#{ID}".freeze

  def setup
    @built = MultiRepositoryWorkspace.build(components: COMPONENTS)
    @task = creating(@built.root).create.path
    @reviewed_heads = REVIEWED.to_h { |name| [ name, publish_reviewed_round(name) ] }
    @second = nil
  end

  def teardown
    [ @built&.root, @second ].compact.each { |root| FileUtils.remove_entry(root) if File.directory?(root) }
    @built&.bares&.each_value { |bare| FileUtils.remove_entry(File.dirname(bare)) if File.directory?(bare) }
  end

  # ------------------------------------------------------------------ fixtures

  def creating(root)
    SpecrelayRunner::Workspace.new(root: root, canonical_branch: TASK, task_id: TASK, create_command: "false")
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  def path(name, root = @task) = name == "." ? root : File.join(root, name)
  def bare(name) = @built.bares.fetch(name)
  def head(dir) = git(dir, "rev-parse", "HEAD").strip

  # A reviewed round on the canonical branch, published to the repository's own remote. Its head
  # is the base the change request requires for a repository with a reviewed pull request.
  def publish_reviewed_round(name)
    File.write(File.join(path(name), "app.txt"), "#{name}\nreviewed round\n")
    git(path(name), "commit", "-qam", "reviewed round")
    git(path(name), "push", "-q", "origin", "HEAD:refs/heads/#{TASK}")
    head(path(name))
  end

  def reviewed
    REVIEWED.map do |name|
      { "repository_key" => name, "clone_url" => "git@github.com:SpecRelay/#{name}.git", "branch" => TASK,
        "head_commit" => @reviewed_heads.fetch(name),
        "pull_request_url" => "https://github.com/SpecRelay/#{name}/pull/1" }
    end
  end

  # Every Git-visible kind of change, spread across B, C and D, plus one ignored file that must
  # not travel. B also holds a local commit its remote never saw.
  def provider_changes
    b = path("component-b")
    File.write(File.join(b, "app.txt"), "component-b\nlocal commit\n")
    git(b, "commit", "-qam", "unpushed local work")
    File.write(File.join(b, "app.txt"), "component-b\nlocal commit\nthen edited\n")
    File.binwrite(File.join(b, "logo.bin"), "\x00\x01\x02\xFF".b)
    FileUtils.chmod(0o755, File.join(b, "app.txt"))
    FileUtils.ln_s("app.txt", File.join(b, "link.txt"))
    FileUtils.mkdir_p(File.join(b, "notes"))
    File.write(File.join(b, "notes", "new.md"), "untracked\n")
    FileUtils.mkdir_p(File.join(b, MultiRepositoryWorkspace::IGNORED_OUTPUT))
    File.write(File.join(b, MultiRepositoryWorkspace::IGNORED_OUTPUT, "log.txt"), "ignored\n")

    c = path("component-c")
    File.write(File.join(c, "app.txt"), "component-c\nreviewed round\nunstaged correction\n")
    FileUtils.rm(File.join(c, "bin", "mutate"))

    d = path("component-d")
    File.write(File.join(d, "app.txt"), "component-d\nreviewed round\nstaged correction\n")
    git(d, "add", "app.txt")
    File.write(File.join(d, "d-new.txt"), "untracked in d\n")
  end

  def capture(root: @task, id: ID)
    SpecrelayRunner::Checkpoint.capture(task_root: root, reviewed: reviewed, id: id)
  end

  def captured
    provider_changes
    result = capture
    raise result.error unless result.ok?

    result.checkpoint
  end

  # What Platform stores and hands back: the closed metadata in the assignment, and the manifest
  # bytes on the claim-bound download.
  def assigned(checkpoint) = checkpoint.except("payload")

  # Everything a capture or a refused restore must leave alone, for every repository: the branch,
  # HEAD, the index, the status and every working-tree byte, ignored files included.
  def state(root)
    [ ".", *COMPONENTS ].map do |name|
      dir = path(name, root)
      [ name, git(dir, "branch", "--show-current"), head(dir), git(dir, "ls-files", "--stage"),
        git(dir, "status", "--porcelain", "--untracked-files=all", "--ignored"), bytes(dir) ]
    end
  end

  def bytes(dir)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).reject { |e| e == ".git" || e.start_with?(".git/") }.sort.map do |e|
      full = File.join(dir, e)
      next [ e, :link, File.readlink(full) ] if File.symlink?(full)
      next [ e, :dir ] if File.directory?(full)

      [ e, File.stat(full).mode & 0o111, File.binread(full) ]
    end
  end

  def checkpoint_refs(name)
    git(bare(name), "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads/runner-checkpoints/").lines.map(&:strip)
  end

  def tree_of(dir, commit) = git(dir, "rev-parse", "#{commit}^{tree}").strip

  # The Git-visible tree of a working copy, read through a temporary index exactly as git sees it.
  def working_tree(dir)
    Dir.mktmpdir do |scratch|
      env = { "GIT_INDEX_FILE" => File.join(scratch, "index") }
      [ %w[read-tree HEAD], %w[add --all] ].each { |args| Open3.capture2e(env, "git", "-C", dir, *args) }
      Open3.capture2e(env, "git", "-C", dir, "write-tree").first.strip
    end
  end

  # A second machine holding the same project, answered by the SAME remotes: a checkpoint pushed
  # from the first machine is only proven by one that has to fetch it.
  def second_machine(detached: false)
    @second = File.join(Dir.mktmpdir("specrelay-checkpoint-second-"), "workspace")
    clone(bare("."), @second, "multi-demo-workspace")
    MultiRepositoryWorkspace.write_project_command(@second, COMPONENTS)
    COMPONENTS.each { |name| clone(bare(name), File.join(@second, name), name) }
    if detached
      FileUtils.mkdir_p(File.join(@second, ".runs"))
      FileUtils.touch(File.join(@second, ".runs", "detach-components"))
    end
    creating(@second).create.path
  end

  def clone(source, target, name)
    system("git", "clone", "-q", source, target, exception: true)
    { "user.email" => "runner@example.test", "user.name" => "Runner Test", "commit.gpgsign" => "false" }
      .each { |key, value| git(target, "config", key, value) }
    git(target, "remote", "set-url", "origin", "git@github.com:SpecRelay/#{name}.git")
    FakeGithub.serve_locally(target, source)
  end

  def restore(checkpoint, root, created:, payload: nil)
    SpecrelayRunner::Checkpoint.restore(assigned(checkpoint), payload: payload || checkpoint["payload"],
                                                              task_root: root, branch: TASK, created: created)
  end

  # A manifest re-sealed around edited entries, so only the edited term is wrong.
  def resealed(checkpoint)
    entries = checkpoint["repositories"].map(&:dup)
    yield entries
    bytes = JSON.generate("format" => checkpoint["format"], "repositories" => entries)
    checkpoint.merge("repositories" => entries, "byte_size" => bytes.bytesize,
                     "digest" => Digest::SHA256.hexdigest(bytes), "payload" => Base64.strict_encode64(bytes))
  end

  # ------------------------------------------------------------------ capture

  # AC1 / scenario 1 — all and only the changed repositories get a ref, each on its own remote,
  # and the asking worktree is exactly what it was.
  def test_every_changed_repository_and_only_those_get_a_checkpoint_ref
    provider_changes
    before = state(@task)

    result = capture

    assert result.ok?, result.error
    checkpoint = result.checkpoint
    assert_equal %w[component-b component-c component-d], checkpoint["repositories"].map { |e| e["path"] }
    checkpoint["repositories"].each do |entry|
      assert_equal REF, entry["checkpoint_ref"]
      assert_equal [ "#{REF} #{entry['snapshot_sha']}" ], checkpoint_refs(entry["path"])
      assert_equal "SpecRelay/#{entry['path']}", entry["origin"]
    end
    assert_empty checkpoint_refs("component-a"), "an unchanged repository gets no ref"
    assert_empty checkpoint_refs("."), "an unchanged workspace repository gets no ref"
    assert_equal before, state(@task), "capture changed the asking worktree"
  end

  # Scenario 1 / 3.2 — the reviewed head is the base of a reviewed repository; a repository with
  # no pull request and no upstream is based on its origin's default branch, never on local HEAD.
  def test_each_snapshot_has_its_recorded_base_as_its_sole_parent
    checkpoint = captured
    entries = checkpoint["repositories"].to_h { |entry| [ entry["path"], entry ] }

    REVIEWED.each do |name|
      assert_equal @reviewed_heads.fetch(name), entries.fetch(name)["base_sha"]
      assert_equal "refs/heads/#{TASK}", entries.fetch(name)["base_ref"]
    end
    default_tip = git(bare("component-b"), "rev-parse", "refs/heads/main").strip
    assert_equal default_tip, entries.fetch("component-b")["base_sha"], "the local commit is not the base"
    assert_equal "refs/heads/main", entries.fetch("component-b")["base_ref"]
    entries.each_value do |entry|
      parents = git(bare(entry["path"]), "rev-list", "--parents", "-n", "1", entry["snapshot_sha"]).split
      assert_equal [ entry["snapshot_sha"], entry["base_sha"] ], parents
    end
  end

  # Scenario 3 — the snapshot tree IS the Git-visible working tree: the local commit, the edits,
  # the mode, the symlink, the binary and the untracked file, and not the ignored file.
  def test_the_snapshot_tree_is_the_complete_git_visible_working_tree
    checkpoint = captured

    checkpoint["repositories"].each do |entry|
      assert_equal working_tree(path(entry["path"])), tree_of(bare(entry["path"]), entry["snapshot_sha"])
    end
    b = checkpoint["repositories"].find { |entry| entry["path"] == "component-b" }
    listing = git(bare("component-b"), "ls-tree", "-r", b["snapshot_sha"])
    assert_match(/^100755 blob \h+\tapp\.txt$/, listing)
    assert_match(/^120000 blob \h+\tlink\.txt$/, listing)
    assert_includes listing, "logo.bin"
    assert_includes listing, "notes/new.md"
    refute_includes listing, MultiRepositoryWorkspace::IGNORED_OUTPUT, "an ignored file was force-added"
  end

  def test_the_manifest_is_closed_bounded_and_carries_no_local_path
    checkpoint = captured

    assert_equal %w[byte_size digest format payload repositories], checkpoint.keys.sort
    assert_equal SpecrelayRunner::Checkpoint::FORMAT, checkpoint["format"]
    checkpoint["repositories"].each do |entry|
      assert_equal SpecrelayRunner::Checkpoint::ENTRY_FIELDS, entry.keys.sort
      assert_match(/\A\h{64}\z/, entry["change_digest"])
    end
    refute_includes checkpoint.to_json, @built.root
    refute_includes Base64.strict_decode64(checkpoint["payload"]), @built.root
  end

  # Scenario 4 — nothing changed is still a checkpoint: an empty manifest, and no ref anywhere.
  def test_a_workspace_with_no_change_captures_an_empty_manifest
    result = capture

    assert result.ok?, result.error
    assert_empty result.checkpoint["repositories"]
    [ ".", *COMPONENTS ].each { |name| assert_empty checkpoint_refs(name) }
  end

  # Scenario 5 — a configured upstream is the base, pinned to the SHA its origin advertises.
  def test_a_configured_upstream_is_the_base_of_a_repository_without_a_pull_request
    b = path("component-b")
    File.write(File.join(b, "app.txt"), "component-b\nupstream work\n")
    git(b, "commit", "-qam", "upstream work")
    git(b, "push", "-q", "origin", "HEAD:refs/heads/feature-upstream")
    upstream = head(b)
    git(b, "config", "branch.#{TASK}.remote", "origin")
    git(b, "config", "branch.#{TASK}.merge", "refs/heads/feature-upstream")
    File.write(File.join(b, "app.txt"), "component-b\nupstream work\nand more\n")

    result = capture

    assert result.ok?, result.error
    entry = result.checkpoint["repositories"].find { |e| e["path"] == "component-b" }
    assert_equal upstream, entry["base_sha"]
    assert_equal "refs/heads/feature-upstream", entry["base_ref"]
  end

  # Scenario 5 — no upstream and no readable default branch: the question is refused before any
  # ref is pushed anywhere.
  def test_an_unresolvable_base_refuses_before_any_ref_is_pushed
    provider_changes
    git(bare("component-b"), "symbolic-ref", "HEAD", "refs/heads/no-such-branch")

    result = capture

    refute result.ok?
    assert_includes result.error, "component-b"
    COMPONENTS.each { |name| assert_empty checkpoint_refs(name) }
  end

  # Scenario 8 — a retry of the same capture is the same capture.
  def test_a_retry_with_the_same_id_and_snapshot_is_idempotent
    first = captured
    second = capture

    assert second.ok?, second.error
    assert_equal first["repositories"], second.checkpoint["repositories"]
    assert_equal 1, checkpoint_refs("component-b").size
  end

  # Scenario 8 — the ref is immutable: the same id with another snapshot refuses and the ref is
  # never moved, forced or replaced.
  def test_the_same_id_with_another_snapshot_refuses_without_moving_the_ref
    first = captured
    File.write(File.join(path("component-b"), "app.txt"), "a different snapshot\n")

    second = capture

    refute second.ok?
    assert_includes second.error, "runner-checkpoints/#{ID}"
    first["repositories"].each do |entry|
      assert_equal [ "#{REF} #{entry['snapshot_sha']}" ], checkpoint_refs(entry["path"])
    end
  end

  # Scenario 7 / AC3 — one remote refuses the push: nothing is stored, and the refs this capture
  # created on the other remotes are removed.
  def test_a_failing_push_stores_nothing_and_removes_the_refs_it_created
    provider_changes
    hook = File.join(bare("component-d"), "hooks", "pre-receive")
    File.write(hook, "#!/bin/sh\necho refused >&2\nexit 1\n")
    FileUtils.chmod(0o755, hook)

    result = capture

    refute result.ok?
    assert_nil result.checkpoint
    assert_includes result.error, "component-d"
    COMPONENTS.each { |name| assert_empty checkpoint_refs(name), "#{name} kept a ref of a failed capture" }
  end

  def test_a_repository_without_a_supported_origin_refuses_the_capture
    provider_changes
    git(path("component-b"), "remote", "set-url", "origin", "file:///not/github")

    result = capture

    refute result.ok?
    assert_includes result.error, "component-b"
    COMPONENTS.each { |name| assert_empty checkpoint_refs(name) }
  end

  # A commit on a repository's default branch, made on another machine after this workspace was
  # built, so this checkout does not hold it.
  def advance_remote(name)
    publisher = File.join(Dir.mktmpdir("specrelay-checkpoint-publisher-"), name)
    system("git", "clone", "-q", bare(name), publisher, exception: true)
    File.write(File.join(publisher, "elsewhere.txt"), "pushed from another machine\n")
    git(publisher, "add", "elsewhere.txt")
    git(publisher, "-c", "user.email=other@example.test", "-c", "user.name=Other", "-c", "commit.gpgsign=false",
        "commit", "-qm", "pushed elsewhere")
    git(publisher, "push", "-q", "origin", "HEAD:refs/heads/main")
    FileUtils.remove_entry(File.dirname(publisher))
  end

  # A changed repository whose origin moved on holds a base this checkout does not descend from:
  # a snapshot on it would silently revert the remote's commits, so nothing is pushed anywhere.
  def test_a_changed_repository_behind_its_remote_base_refuses_before_any_ref_is_pushed
    provider_changes
    advance_remote("component-b")

    result = capture

    refute result.ok?
    assert_includes result.error, "component-b"
    COMPONENTS.each { |name| assert_empty checkpoint_refs(name), "#{name} received a ref" }
  end

  # An untouched repository whose origin merely moved on holds no work: no entry, and no ref.
  def test_a_clean_repository_behind_its_remote_base_is_unchanged
    provider_changes
    advance_remote("component-a")

    result = capture

    assert result.ok?, result.error
    assert_equal %w[component-b component-c component-d], result.checkpoint["repositories"].map { |e| e["path"] }
    assert_empty checkpoint_refs("component-a")
  end

  # The manifest is checked against the contract's bounds before anything is pushed, so a field
  # Platform would refuse never leaves a ref behind on any remote.
  def test_a_manifest_field_beyond_the_contract_bound_refuses_before_any_ref_is_pushed
    provider_changes
    # Under component-a's ignored output, so only this repository's own path is out of bounds.
    long = File.join(path("component-a"), MultiRepositoryWorkspace::IGNORED_OUTPUT, "a-long-repository-name-" * 8)
    remote = File.join(Dir.mktmpdir("specrelay-checkpoint-long-"), "long.git")
    system("git", "init", "-q", "--bare", "-b", "main", remote, exception: true)
    system("git", "init", "-q", "-b", "main", long, exception: true)
    File.write(File.join(long, "file.txt"), "long\n")
    git(long, "add", "file.txt")
    git(long, "-c", "user.email=runner@example.test", "-c", "user.name=Runner Test", "-c", "commit.gpgsign=false",
        "commit", "-qm", "long")
    git(long, "remote", "add", "origin", "git@github.com:SpecRelay/long.git")
    FakeGithub.serve_locally(long, remote)
    git(long, "push", "-q", "origin", "main")
    File.write(File.join(long, "file.txt"), "long, edited\n")

    result = capture

    refute result.ok?
    assert_includes result.error, "component-a/#{MultiRepositoryWorkspace::IGNORED_OUTPUT}"
    COMPONENTS.each { |name| assert_empty checkpoint_refs(name), "#{name} received a ref" }
    assert_empty git(remote, "for-each-ref", "refs/heads/runner-checkpoints/")
  ensure
    FileUtils.remove_entry(File.dirname(remote)) if remote && File.directory?(remote)
  end

  # Platform refused the question: the refs THIS capture created are removed, and nothing else.
  def test_withdrawing_a_refused_capture_removes_only_the_refs_it_created
    provider_changes
    result = capture
    assert result.ok?, result.error
    task_branches = COMPONENTS.to_h { |name| [ name, git(bare(name), "for-each-ref", "refs/heads/#{TASK}") ] }

    orphans = SpecrelayRunner::Checkpoint.withdraw(result)

    assert_empty orphans
    COMPONENTS.each { |name| assert_empty checkpoint_refs(name), "#{name} kept a ref of a refused question" }
    assert_equal task_branches, COMPONENTS.to_h { |name| [ name, git(bare(name), "for-each-ref", "refs/heads/#{TASK}") ] }
  end

  # A retry that found the ref already in place did not create it, so it does not remove it.
  def test_withdrawing_a_retried_capture_keeps_a_ref_it_did_not_create
    first = captured
    retried = capture
    assert retried.ok?, retried.error

    SpecrelayRunner::Checkpoint.withdraw(retried)

    first["repositories"].each do |entry|
      assert_equal [ "#{REF} #{entry['snapshot_sha']}" ], checkpoint_refs(entry["path"])
    end
  end

  # ------------------------------------------------------------------ restore

  # AC4 / AC5 / scenario 9 — a machine that never saw the work fetches the refs and lands on
  # exactly the recorded files, dirty, on the recorded bases. B needs no pull request.
  def test_a_fresh_machine_restores_every_snapshot_as_dirty_work_on_its_base
    checkpoint = captured
    target = second_machine

    result = restore(checkpoint, target, created: true)

    assert result.ok?, result.reason
    assert_restored(checkpoint, target)
    assert_equal head(path("component-a", @built.root)), head(path("component-a", target))
    assert_empty git(path("component-a", target), "status", "--porcelain")
  end

  # A multi-repository project prepares its components detached; the recorded branch is
  # established at the recorded base, and an unrecorded component stays detached and clean.
  def test_detached_components_are_placed_on_the_task_branch_at_their_base
    checkpoint = captured
    target = second_machine(detached: true)

    result = restore(checkpoint, target, created: true)

    assert result.ok?, result.reason
    assert_restored(checkpoint, target)
    assert_empty git(path("component-a", target), "branch", "--show-current")
  end

  # AC4 / scenario 10 — the machine that asked uses the same procedure on its own worktree: the
  # local commit is folded away and the work is the snapshot, dirty, on the recorded base.
  def test_the_asking_machine_restores_through_the_same_procedure
    checkpoint = captured

    result = restore(checkpoint, @task, created: false)

    assert result.ok?, result.reason
    assert_restored(checkpoint, @task)
  end

  def assert_restored(checkpoint, root)
    checkpoint["repositories"].each do |entry|
      dir = path(entry["path"], root)
      assert_equal TASK, git(dir, "branch", "--show-current").strip, entry["path"]
      assert_equal entry["base_sha"], head(dir), "#{entry['path']} is not on its recorded base"
      assert_equal tree_of(dir, entry["snapshot_sha"]), working_tree(dir), "#{entry['path']} is not the snapshot"
      assert_empty git(dir, "diff", "--cached", "--name-only"), "#{entry['path']} kept staged changes"
      refute_empty git(dir, "status", "--porcelain"), "#{entry['path']} is not dirty"
      refute_includes git(dir, "for-each-ref", "--format=%(refname)", "refs/heads/"), "runner-checkpoints",
                      "a restore creates no local branch for the checkpoint"
    end
  end

  # Scenario 10 — an edit nobody recorded, in a repository the checkpoint does not name, refuses
  # and stays exactly where it is.
  def test_an_unrelated_edit_on_the_asking_machine_refuses_and_is_kept
    checkpoint = captured
    File.write(File.join(path("component-a"), "app.txt"), "an edit nobody recorded\n")
    before = state(@task)

    result = restore(checkpoint, @task, created: false)

    refute result.ok?
    assert_includes result.reason, "component-a"
    assert_equal before, state(@task)
  end

  def test_an_edit_on_top_of_the_recorded_work_refuses_and_is_kept
    checkpoint = captured
    File.write(File.join(path("component-c"), "app.txt"), "edited after the question\n")
    before = state(@task)

    result = restore(checkpoint, @task, created: false)

    refute result.ok?
    assert_includes result.reason, "component-c"
    assert_equal before, state(@task)
  end

  # Scenario 11 — every failed proof refuses before any checked-out ref, index or file changes.
  # Objects the proof fetched may remain; nothing else may.
  def assert_refused_untouched(checkpoint, target, reason, payload: nil)
    before = state(target)
    remote = COMPONENTS.to_h { |name| [ name, checkpoint_refs(name) ] }

    result = restore(checkpoint, target, created: true, payload: payload)

    refute result.ok?, "the restore was not refused"
    assert_includes result.reason, reason
    assert_equal before, state(target), "a refused restore changed checked-out state"
    assert_equal remote, COMPONENTS.to_h { |name| [ name, checkpoint_refs(name) ] }, "a refused restore changed a remote ref"
  end

  def test_a_missing_checkpoint_ref_refuses_before_anything_changes
    checkpoint = captured
    git(bare("component-c"), "update-ref", "-d", REF)

    assert_refused_untouched(checkpoint, second_machine, "no longer exists")
  end

  def test_a_moved_checkpoint_ref_refuses_before_anything_changes
    checkpoint = captured
    git(bare("component-c"), "update-ref", REF, @reviewed_heads.fetch("component-c"))

    assert_refused_untouched(checkpoint, second_machine, "moved")
  end

  def test_a_snapshot_whose_parent_is_not_the_recorded_base_refuses_before_anything_changes
    checkpoint = resealed(captured) do |entries|
      entries.find { |e| e["path"] == "component-b" }["base_sha"] = git(bare("component-b"), "rev-parse", "main").strip.tr("0-9a-f", "1-9a-f0")
    end

    assert_refused_untouched(checkpoint, second_machine, "parent")
  end

  def test_a_change_digest_that_does_not_match_the_snapshot_refuses_before_anything_changes
    checkpoint = resealed(captured) { |entries| entries.first["change_digest"] = "0" * 64 }

    assert_refused_untouched(checkpoint, second_machine, "change_digest")
  end

  def test_a_checkout_whose_origin_is_another_repository_refuses_before_anything_changes
    checkpoint = captured
    target = second_machine
    git(path("component-b", target), "remote", "set-url", "origin", "git@github.com:SpecRelay/someone-else.git")

    assert_refused_untouched(checkpoint, target, "origin")
  end

  def test_a_recorded_path_outside_the_task_workspace_refuses_before_anything_changes
    checkpoint = resealed(captured) { |entries| entries.first["path"] = "../escape" }

    assert_refused_untouched(checkpoint, second_machine, "not inside the task workspace")
  end

  def test_a_manifest_that_does_not_match_its_digest_refuses_before_anything_changes
    checkpoint = captured
    tampered = Base64.strict_encode64(Base64.strict_decode64(checkpoint["payload"]).sub("component-b", "component-x"))

    assert_refused_untouched(checkpoint, second_machine, "checksum", payload: tampered)
  end

  # A local branch of the recorded name at another commit is somebody else's round: it is never
  # moved, and the whole restore refuses before any repository is placed.
  def test_a_local_task_branch_at_another_commit_in_a_detached_checkout_is_never_moved
    checkpoint = captured
    target = second_machine(detached: true)
    clone_b = File.join(@second, "component-b")
    other = git(clone_b, "commit-tree", "-m", "another round", "-p", "HEAD", "HEAD^{tree}").strip
    git(clone_b, "branch", TASK, other)

    assert_refused_untouched(checkpoint, target, "never moved")
  end

  # The best-effort lifecycle step: consumed refs are removed from every remote.
  def test_discarding_a_consumed_checkpoint_removes_its_refs
    checkpoint = captured

    orphans = SpecrelayRunner::Checkpoint.discard(assigned(checkpoint), task_root: @task)

    assert_empty orphans
    COMPONENTS.each { |name| assert_empty checkpoint_refs(name) }
  end
end
