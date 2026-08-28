# frozen_string_literal: true

require_relative "test_helper"

# MAPIAI-97 — releasing the task environment a finished implementation run leaves behind.
#
# It matters now for a reason it did not before: the preview lane addresses the SAME task id, so
# an environment nobody released is the difference between a preview that starts and one that
# fails on a worktree it did not create. The rule proved here is that a release the project
# refused stops this machine from claiming again, rather than being logged and forgotten.
class TaskEnvironmentTest < Minitest::Test
  TASK = "MAPIAI-97-cleanup"

  def setup
    @workspace = PreviewWorkspace.build(components: %w[component-a])
    @io = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@workspace.root)
  rescue SystemCallError
    nil
  end

  def release = SpecrelayRunner::TaskEnvironment.release(root: @workspace.root, task_id: TASK)

  def test_it_invokes_the_project_owned_release_once_from_the_connected_root
    assert_predicate release, :released?
    assert_equal [ [ File.realpath(@workspace.root), "release #{TASK}" ] ], @workspace.invocations
  end

  # An environment the project says does not exist needs no cleanup. Reporting otherwise would
  # stop a healthy runner for ever.
  def test_an_unknown_environment_needs_no_cleanup
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

  # A project that owns no lifecycle command built no environment through one, and this runner
  # must not guess how to take down a directory it did not create.
  def test_a_project_without_the_command_releases_nothing_and_reports_nothing_to_clean
    FileUtils.rm_f(File.join(@workspace.root, "bin", "worktree"))

    assert_predicate release, :released?
    assert_equal [], @workspace.invocations
  end

  def test_a_refused_release_stops_this_machine_from_claiming_again
    @workspace.fail!("release")

    error = assert_raises(SpecrelayRunner::CleanupRequired) do
      SpecrelayRunner::TaskEnvironment.release!(root: @workspace.root, task_id: TASK, io: @io)
    end

    assert_includes error.message, "still allocated"
  end

  def test_a_successful_release_says_so_and_lets_the_loop_continue
    assert SpecrelayRunner::TaskEnvironment.release!(root: @workspace.root, task_id: TASK, io: @io)
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
