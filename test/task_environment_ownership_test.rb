# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# Run ownership of an automatically allocated task environment.
#
# The rule being proved is one sentence: an automatic run works in an environment it can PROVE
# the project recorded for it, and in no other. Everything here is a consequence — a manual
# worktree is never adopted however clean it is, another run's is never reused or taken down,
# an unanswerable project command refuses the attempt instead of guessing, and the release at
# the end is asked for as the owning run or not at all.
#
# It runs against a REAL git workspace whose `bin/worktree` implements the accepted project's
# ownership contract, because every claim here is about what that command was asked and what it
# recorded. A stub that returned the expected shape would prove the runner's own narration.
class TaskEnvironmentOwnershipTest < Minitest::Test
  TASK = "EXAMPLE-1-owned-environment"
  BRANCH = TASK
  RUN = "run_alpha"
  OTHER_RUN = "run_beta"

  def setup
    @built = MultiRepositoryWorkspace.build(components: %w[component-a])
    @root = @built.root
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  rescue SystemCallError
    nil
  end

  # ---------------------------------------------------------------- allocation (S1, AC1)

  def test_an_automatic_allocation_asks_the_project_to_record_this_run_as_the_owner
    info = automatic.create

    assert_predicate info, :created?
    assert_equal [ "create #{TASK} --run-id #{RUN}", "status #{TASK} --json" ], invocations
  end

  # The owner is read back from the project's own durable record by THIS process, which is not
  # the one that wrote it — the runner shelled out. A run id the runner merely remembered in
  # memory would satisfy every other assertion in this file and none of the product's purpose.
  def test_a_second_process_reads_the_recorded_owner_from_the_project
    automatic.create

    assert_equal RUN, MultiRepositoryWorkspace.recorded_owner(@root, TASK)
    assert_equal RUN, project_status.fetch("owner_run_id")
  end

  # The allocation is verified after it is built. A project command that accepted `--run-id` and
  # recorded nothing hands back an environment this run could never release, and the run would
  # discover that only at the end — with the work already done.
  def test_an_allocation_the_project_did_not_record_is_refused_rather_than_returned
    ignore_the_run_id!

    error = assert_raises(SpecrelayRunner::Workspace::Error) { automatic.create }

    assert_includes error.message, "records no run owner"
  end

  # ---------------------------------------------------------------- existing environments (S2, AC2)

  # Clean is not owned. This is the environment a person made by hand for the same ticket, and
  # adopting it would delete their branch's unpublished work at the end of this run.
  def test_a_clean_manual_environment_is_refused_and_left_exactly_as_it_is
    allocate_manually

    error = assert_raises(SpecrelayRunner::Workspace::Error) { automatic.create }

    assert_includes error.message, "manual environment"
    assert_environment_untouched
  end

  def test_another_runs_environment_is_refused_and_left_exactly_as_it_is
    allocate_for(OTHER_RUN)

    error = assert_raises(SpecrelayRunner::Workspace::Error) { automatic.create }

    assert_includes error.message, "owned by a different run"
    assert_environment_untouched
  end

  # The refusal must name OWNERSHIP, not tidiness. A dirty foreign environment refused for its
  # uncommitted changes sends an operator to clean a worktree that was never going to be reused,
  # and hides the fact that the run cannot have it at all.
  def test_a_dirty_foreign_environment_is_refused_for_its_owner_and_not_for_its_changes
    allocate_for(OTHER_RUN)
    File.write(File.join(task_workspace, "workspace.txt"), "half-finished work\n")

    error = assert_raises(SpecrelayRunner::Workspace::Error) { automatic.create }

    assert_includes error.message, "owned by a different run"
    refute_includes error.message, "uncommitted"
    assert_equal "half-finished work\n", File.read(File.join(task_workspace, "workspace.txt"))
  end

  # The CONTINUATION lookup, which is how an answered resume finds the worktree its question was
  # asked from. It reads rather than creates, so it needs its own gate: without one, a different
  # run would continue in this run's files.
  def test_the_continuation_lookup_refuses_an_environment_this_run_does_not_own
    allocate_for(OTHER_RUN)

    assert_raises(SpecrelayRunner::Workspace::Error) { automatic.existing }
  end

  def test_the_continuation_lookup_returns_the_environment_this_run_owns
    automatic.create

    assert_equal File.realpath(task_workspace), File.realpath(automatic.existing.path)
  end

  # ---------------------------------------------------------------- unprovable ownership (S3, AC2)

  # A git worktree on the canonical branch that the project holds no record for. It is the shape
  # a half-removed environment leaves behind, and the one an "it exists, so use it" reader adopts.
  def test_a_git_worktree_with_no_ownership_record_is_not_adopted
    allocate_manually
    FileUtils.rm_f(File.join(@root, ".runs", "owners", TASK))

    error = assert_raises(SpecrelayRunner::Workspace::Error) { automatic.create }

    assert_includes error.message, "could not be inspected"
    assert_path_exists task_workspace
  end

  def test_an_assignment_with_no_run_identity_refuses_before_it_allocates_anything
    error = assert_raises(SpecrelayRunner::Workspace::Error) { workspace(run_id: "").create }

    assert_includes error.message, "no run identity"
    assert_empty invocations
  end

  # No ownerless automatic fallback. The assignment's native git creation command builds a
  # worktree with no owner, which this lane could neither prove nor release.
  def test_a_project_without_the_run_aware_command_refuses_instead_of_creating_natively
    FileUtils.rm_f(File.join(@root, "bin", "worktree"))

    error = assert_raises(SpecrelayRunner::Workspace::Error) { automatic.create }

    assert_includes error.message, "no run-aware"
    refute_path_exists File.join(@root, ".runs", "worktrees", TASK)
  end

  def test_a_status_command_that_fails_refuses_rather_than_assuming_ownership
    allocate_for(RUN)
    break_the_command!("status", "exit 1")

    error = assert_raises(SpecrelayRunner::Workspace::Error) { automatic.create }

    assert_includes error.message, "exited 1"
  end

  def test_a_status_document_that_cannot_be_read_refuses_rather_than_assuming_ownership
    allocate_for(RUN)
    break_the_command!("status", "echo 'not a document'; exit 0")

    error = assert_raises(SpecrelayRunner::Workspace::Error) { automatic.create }

    assert_includes error.message, "could not read"
  end

  # An answer about a different environment. The command is addressed by task id, so a project
  # answering from the wrong one would hand this run somebody else's ownership record.
  def test_a_status_document_about_another_task_is_refused
    allocate_for(RUN)
    answer_status!({ "task_id" => "EXAMPLE-2-other", "branch" => BRANCH, "owner_run_id" => RUN })

    error = assert_raises(SpecrelayRunner::Workspace::Error) { automatic.create }

    assert_includes error.message, "different task id"
  end

  def test_a_status_document_naming_another_branch_is_refused
    allocate_for(RUN)
    answer_status!({ "task_id" => TASK, "branch" => "some-other-branch", "owner_run_id" => RUN })

    error = assert_raises(SpecrelayRunner::Workspace::Error) { automatic.create }

    assert_includes error.message, "different branch"
  end

  # ---------------------------------------------------------------- same-run continuation (S4, AC3)

  def test_the_owning_run_reuses_its_clean_environment_without_allocating_a_second_one
    automatic.create
    clear_invocations

    info = automatic.create

    refute_predicate info, :created?
    assert_equal [ "status #{TASK} --json" ], invocations
    assert_equal RUN, MultiRepositoryWorkspace.recorded_owner(@root, TASK)
  end

  # ---------------------------------------------------------------- release (S6-S8, AC4/AC6)

  def test_the_owning_run_releases_its_environment_and_the_project_proves_it
    automatic.create

    assert_predicate release(RUN), :released?
    assert_nil MultiRepositoryWorkspace.recorded_owner(@root, TASK)
    assert_includes invocations, "release #{TASK} --run-id #{RUN} --json"
  end

  # Unpublished edits are this run's own, and need no second confirmation once the report they
  # belong to has been accepted.
  def test_unpublished_edits_in_the_owned_environment_do_not_prevent_its_release
    automatic.create
    File.write(File.join(task_workspace, "workspace.txt"), "written during the run\n")
    File.write(File.join(task_workspace, "notes-by-hand.md"), "and one by hand\n")

    assert_predicate release(RUN), :released?
    refute_path_exists task_workspace
  end

  def test_another_runs_environment_is_never_released
    allocate_for(OTHER_RUN)

    result = release(RUN)

    refute_predicate result, :released?
    assert_includes result.reason, "still allocated"
    assert_path_exists task_workspace
    assert_equal OTHER_RUN, MultiRepositoryWorkspace.recorded_owner(@root, TASK)
  end

  # The project's own ownerless proof, which it makes by inventorying the workspace and every
  # registered component repository. It is authoritative and this runner must not recreate it —
  # in particular it must not decide for itself that a missing directory means nothing to do.
  def test_the_projects_absent_proof_is_completion
    result = release(RUN)

    assert_predicate result, :released?
    assert_includes invocations, "release #{TASK} --run-id #{RUN} --json"
  end

  def test_a_release_this_runner_cannot_prove_is_reported_as_still_allocated
    automatic.create
    break_the_command!("release", "exit 1")

    result = release(RUN)

    refute_predicate result, :released?
    assert_includes result.reason, "exited 1"
  end

  def test_a_release_that_returns_an_unreadable_document_is_not_completion
    automatic.create
    break_the_command!("release", "echo 'released, honestly'; exit 0")

    result = release(RUN)

    refute_predicate result, :released?
    assert_includes result.reason, "could not read"
  end

  # An incomplete teardown: the project succeeded at the command level but reported neither
  # completion outcome, which is the shape a partial release has.
  def test_a_release_that_names_no_completed_outcome_is_not_completion
    automatic.create
    break_the_command!("release",
                       %(printf '{"task_id":"#{TASK}","failures":["a container is still running"]}\\n'; exit 0))

    result = release(RUN)

    refute_predicate result, :released?
    assert_includes result.reason, "no completed release"
  end

  # No file-survival claim, in either direction. Only the project knows what is left, and it has
  # recorded it; a runner guessing would describe an incomplete teardown as a partial success.
  def test_an_incomplete_release_claims_nothing_about_which_files_survived
    automatic.create
    break_the_command!("release", "exit 1")

    reason = release(RUN).reason

    refute_match(/\b(removed|deleted|cleared|retained|survived)\b/i, reason)
  end

  def test_a_release_the_project_performed_for_another_run_is_not_this_runs_completion
    automatic.create
    break_the_command!("release",
                       %(printf '{"task_id":"#{TASK}","outcome":"released","owner_run_id":"#{OTHER_RUN}"}\\n'; exit 0))

    result = release(RUN)

    refute_predicate result, :released?
    assert_includes result.reason, "different run"
  end

  def test_a_release_without_a_run_identity_is_refused_before_the_command_runs
    automatic.create
    clear_invocations

    result = SpecrelayRunner::TaskEnvironment.release(root: @root, task_id: TASK, run_id: "")

    refute_predicate result, :released?
    assert_includes result.reason, "no run identity"
    assert_empty invocations
  end

  # A machine that could not release must not claim again.
  def test_an_unprovable_release_stops_this_machine_from_claiming_again
    allocate_for(OTHER_RUN)

    error = assert_raises(SpecrelayRunner::CleanupRequired) do
      SpecrelayRunner::TaskEnvironment.release!(root: @root, task_id: TASK, run_id: RUN,
                                                io: StringIO.new)
    end

    assert_includes error.message, TASK
  end

  # ---------------------------------------------------------------- preview and manual (S10, AC7)

  # The preview and measurement callers pass no run identity at all, and nothing above applies to
  # them: they neither send `--run-id` nor ask the project who owns anything.
  def test_a_caller_with_no_run_identity_keeps_the_existing_unowned_behavior
    manual = SpecrelayRunner::Workspace.new(root: @root, canonical_branch: BRANCH, task_id: TASK,
                                            create_command: "git worktree add unused")

    assert_predicate manual.create, :created?
    assert_equal [ "create #{TASK}" ], invocations
    assert_equal "", MultiRepositoryWorkspace.recorded_owner(@root, TASK)
  end

  private

  def workspace(run_id:)
    SpecrelayRunner::Workspace.new(root: @root, canonical_branch: BRANCH, task_id: TASK,
                                   run_id: run_id, create_command: "git worktree add unused")
  end

  def automatic = workspace(run_id: RUN)

  def release(run_id) =
    SpecrelayRunner::TaskEnvironment.release(root: @root, task_id: TASK, run_id: run_id)

  def task_workspace = File.join(@root, ".runs", "worktrees", TASK)

  def invocations = MultiRepositoryWorkspace.worktree_invocations(@built.worktree_log)

  def clear_invocations = File.write(@built.worktree_log, "")

  def project_status
    out, status = Open3.capture2(File.join(@root, "bin", "worktree"), "status", TASK, "--json",
                                 chdir: @root)
    raise "status failed: #{out}" unless status.success?

    JSON.parse(out)
  end

  # An environment the project holds, allocated through its own command so the git worktrees are
  # real, then re-recorded under the owner this example needs.
  def allocate_for(run_id)
    system(File.join(@root, "bin", "worktree"), "create", TASK, "--run-id", run_id,
           chdir: @root, out: File::NULL, err: File::NULL) or raise "create failed"
    clear_invocations
  end

  def allocate_manually
    system(File.join(@root, "bin", "worktree"), "create", TASK,
           chdir: @root, out: File::NULL, err: File::NULL) or raise "create failed"
    clear_invocations
  end

  def assert_environment_untouched
    assert_path_exists task_workspace
    assert_equal [], invocations.grep(/\Arelease /)
  end

  # Replace one verb's answer, so a project command that fails, hangs up mid-answer or reports
  # something this runner must not believe is an observable state. Every other verb still
  # reaches the real command, so the environment these examples refuse is a real one.
  def break_the_command!(verb, body)
    path = File.join(@root, "bin", "worktree")
    real = "#{path}-real"
    FileUtils.mv(path, real) unless File.exist?(real)
    File.write(path, <<~SH)
      #!/usr/bin/env sh
      set -u
      if [ "${1:-}" = "#{verb}" ]; then
        TASK="${2:-}"
        #{body}
      fi
      exec "$(dirname "$0")/worktree-real" "$@"
    SH
    FileUtils.chmod(0o755, path)
  end

  def answer_status!(document)
    break_the_command!("status", "cat <<'JSON'\n#{JSON.generate(document)}\nJSON\nexit 0")
  end

  # A project whose create accepts the run identity and records nothing — the ownerless
  # allocation post-create verification exists to catch.
  def ignore_the_run_id!
    path = File.join(@root, "bin", "worktree")
    File.write(path, File.read(path).sub(%(printf '%s' "$RUN_ID" > "$OWNER_FILE"),
                                         %(printf '' > "$OWNER_FILE")))
    FileUtils.chmod(0o755, path)
  end
end
