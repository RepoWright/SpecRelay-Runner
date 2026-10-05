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

  def release! = SpecrelayRunner::TaskEnvironment.release!(root: @workspace.root, task_id: TASK, run_id: RUN)

  # The project's failure document on stdout and a nonzero exit, as `release --json` reports one.
  def fail_release_with(document)
    @workspace.leak!("release", "#{JSON.generate({ 'task_id' => TASK }.merge(document))}\n")
    @workspace.fail!("release")
  end

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

  # ---- the project's own reason for a failed release ---------------------------------------

  # The project prints its failure document on stdout and exits nonzero. Its own words are what
  # the operator needs, so they are carried into the reason that stops the session.
  def test_a_failed_release_carries_the_projects_own_reason
    { "blocked" => [ { "outcome" => "blocked", "owner_run_id" => RUN, "failures" => [ "docker is not reachable" ],
                       "recoverable" => true }, "docker is not reachable" ],
      "refused containment" => [ { "outcome" => "refused", "owner_run_id" => RUN,
                                   "refusals" => [ "component-a is a symlink" ] }, "component-a is a symlink" ],
      "refused absence" => [ { "outcome" => "refused", "remaining_resources" => [ "registry record for #{TASK}" ] },
                             "registry record for #{TASK}" ],
      "degraded" => [ { "state" => "DEGRADED", "owner_run_id" => RUN,
                        "failures" => [ "compose down failed: exit 1", "volume still present" ] },
                      "compose down failed: exit 1; volume still present" ],
      "project error" => [ { "error" => "another release holds the lock" }, "another release holds the lock" ],
      "manual" => [ { "outcome" => "refused", "owner_run_id" => nil }, "manual environment" ],
      "foreign" => [ { "outcome" => "refused" }, "owned by a different run" ] }.each do |name, (document, reason)|
      fail_release_with(document)

      error = assert_raises(SpecrelayRunner::CleanupRequired, name) { release! }

      assert_includes error.message, TASK, name
      assert_includes error.message, reason, name
      refute_includes error.message, "exited 1", name
    end
  end

  # The reason is the project's text, so it is bounded and passes the same path and secret
  # redaction as every other line this runner prints.
  def test_the_projects_reason_is_bounded_and_redacted
    fail_release_with("outcome" => "blocked",
                      "failures" => [ "cannot read /Users/someone/secret-checkout/compose.yaml " \
                                      "with token ghp_#{'a1B2' * 9}; #{'docker said no. ' * 80}" ])

    message = assert_raises(SpecrelayRunner::CleanupRequired) { release! }.message

    refute_includes message, "/Users/someone"
    refute_includes message, "ghp_"
    assert_includes message, "[PRIVATE_PATH_REDACTED]"
    assert_operator message.length, :<=, SpecrelayRunner::TaskEnvironment::REASON_LIMIT + 200
  end

  # Without a readable document there is no reason to report, and the exit status is what is left.
  def test_unreadable_failure_output_keeps_the_exit_status
    @workspace.leak!("release", "Traceback: something broke\n")
    @workspace.fail!("release")

    assert_includes assert_raises(SpecrelayRunner::CleanupRequired) { release! }.message, "exited 1"
  end

  # A failed command is never completion, whatever outcome its document names.
  def test_a_failed_command_that_names_a_release_is_not_completion
    fail_release_with("outcome" => "released", "owner_run_id" => RUN)

    result = release

    refute_predicate result, :released?
    assert_includes result.reason, "exited 1"
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
