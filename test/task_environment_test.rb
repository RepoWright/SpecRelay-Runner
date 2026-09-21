# frozen_string_literal: true

require_relative "test_helper"

# Releasing the task environment a finished implementation run leaves behind.
#
# It matters for a reason it did not before: the preview lane addresses the SAME task id, so an
# environment nobody released is the difference between a preview that starts and one that fails
# on a worktree it did not create. The rules proved here are that the release is asked for as the
# run that OWNS the environment, and that one the project would not prove released stops this
# machine from claiming again rather than being logged and forgotten.
#
# The ownership contract itself — who may reuse, allocate and take down an environment — is
# proved in {TaskEnvironmentOwnershipTest}. What is proved here is how this adapter is invoked
# and what it reports back to the session.
class TaskEnvironmentTest < Minitest::Test
  TASK = "EXAMPLE-1-cleanup"
  RUN = "run_alpha"

  def setup
    @workspace = PreviewWorkspace.build(components: %w[component-a])
    @workspace.own!(TASK, RUN)
    @io = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@workspace.root)
  rescue SystemCallError
    nil
  end

  def release = SpecrelayRunner::TaskEnvironment.release(root: @workspace.root, task_id: TASK,
                                                         run_id: RUN)

  # Once, from the connected root, naming the owning run. The working directory is asserted
  # because a project command run from anywhere else would address a different checkout.
  def test_it_invokes_the_project_owned_release_once_from_the_connected_root
    assert_predicate release, :released?
    assert_equal [ [ File.realpath(@workspace.root), "release #{TASK} --run-id #{RUN} --json" ] ],
                 @workspace.invocations
  end

  # The project's own proof that there is nothing to take down. It is the project that
  # inventories the workspace and every registered component repository to establish it, and
  # this runner must neither recreate that inventory nor shortcut it.
  def test_the_projects_own_absent_proof_needs_no_cleanup
    @workspace.absent!

    assert_predicate release, :released?
  end

  def test_a_refused_release_names_the_environment_that_is_still_allocated
    @workspace.fail!("release")

    result = release

    refute_predicate result, :released?
    assert_includes result.reason, TASK
    assert_includes result.reason, "still allocated"
  end

  # A project that owns no run-aware lifecycle command could never have recorded this run as an
  # owner, so it cannot prove a release either. Reporting nothing to clean up would be a guess
  # about an environment this runner can no longer see.
  def test_a_project_without_the_run_aware_command_cannot_prove_a_release
    FileUtils.rm_f(File.join(@workspace.root, "bin", "worktree"))

    result = release

    refute_predicate result, :released?
    assert_includes result.reason, "no run-aware"
    assert_equal [], @workspace.invocations
  end

  def test_a_refused_release_stops_this_machine_from_claiming_again
    @workspace.fail!("release")

    error = assert_raises(SpecrelayRunner::CleanupRequired) do
      SpecrelayRunner::TaskEnvironment.release!(root: @workspace.root, task_id: TASK, run_id: RUN,
                                                io: @io)
    end

    assert_includes error.message, "still allocated"
  end

  def test_a_successful_release_says_so_and_lets_the_loop_continue
    assert SpecrelayRunner::TaskEnvironment.release!(root: @workspace.root, task_id: TASK,
                                                     run_id: RUN, io: @io)
    assert_includes @io.string, "Released the task environment #{TASK}"
  end

  # ---- CR-005 F3: which lane owns a task environment --------------------------------------

  # The CLOSED matrix. Every lane is named by its own explicit discriminator and answers for
  # itself, so the decision does not depend on the order the dispatcher happens to try them in.
  #
  # The preflight entry is the one that matters. It is built the way Platform's own
  # `PreflightPayload` builds it — same `run.task_id`, same `run.type` — because a preflight runs
  # on an implementation run and therefore carries both. Deciding cleanup from `run.task_id`, as
  # this runner used to, meant a successful package preflight invoked the project-owned release
  # for an environment it had never created.
  def lanes
    {
      "an executable implementation run" =>
        [ { "run" => { "id" => "run_1", "type" => "implementation", "task_id" => TASK } }, true ],
      "a specification package preflight" =>
        [ { "assignment_kind" => SpecrelayRunner::PackagePreflight::Assignment::KIND,
            "run" => { "id" => "run_1", "type" => "implementation", "task_id" => TASK } }, false ],
      "a review" =>
        [ { "assignment_type" => "review",
            "run" => { "id" => "run_1", "type" => "implementation", "task_id" => TASK } }, false ],
      "a specification generation" =>
        [ { "run" => { "id" => "run_1", "type" => "spec_creation", "task_id" => TASK } }, false ],
      "a live preview" =>
        [ { "assignment_kind" => "task_preview",
            "preview" => { "task_id" => TASK } }, false ],
      "an assignment naming no lane at all" => [ { "run" => { "task_id" => TASK } }, false ]
    }
  end

  def test_only_the_executable_implementation_lane_owns_a_task_environment
    wrong = lanes.reject do |_name, (payload, expected)|
      SpecrelayRunner::Execution.implementation?(payload) == expected
    end

    assert_equal [], wrong.keys, "these lanes answered the wrong owner for post-run cleanup"
  end

  # The review lane's own discriminator still recognises the review entry above, so the matrix is
  # testing real assignments rather than shapes invented for it.
  def test_the_matrix_uses_assignments_each_lane_really_recognises
    payloads = lanes.transform_values { |(payload, _)| payload }

    assert SpecrelayRunner::PackagePreflight::Assignment.preflight?(payloads["a specification package preflight"])
    assert SpecrelayRunner::Review::Assignment.review?(payloads["a review"])
    assert SpecrelayRunner::Specification::Assignment.specification?(payloads["a specification generation"])
    assert SpecrelayRunner::PreviewAssignment.preview?(payloads["a live preview"])
  end
end
