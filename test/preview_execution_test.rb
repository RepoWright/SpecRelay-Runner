# frozen_string_literal: true

require_relative "test_helper"

# MAPIAI-97 — the ordered preview lifecycle, proved against a REAL project-owned command.
#
# The fixture's `bin/worktree` records the working directory and arguments of every invocation, so
# the order, the argv and the root below are observed at the actual command boundary rather than
# read back out of the runner's own narration. The two facts this file exists to prove are that
# nothing runs before the source set is accepted, and that no failure after `create` is ever
# reported as clean.
class PreviewExecutionTest < Minitest::Test
  TASK = "MAPIAI-97-preview"
  REPO_A = "SpecRelay/component-a"
  REPO_B = "SpecRelay/component-b"
  URL_A = "https://github.com/SpecRelay/component-a/pull/21"
  URL_B = "https://github.com/SpecRelay/component-b/pull/22"

  # Answers from a table, so a pull request that is closed, missing or foreign is expressible
  # without a network.
  class FakeGitHubReader
    def initialize(answers) = (@answers = answers)
    def pull_request(root:, slug:, url:, env:) = @answers[url]
  end

  def setup
    @workspace = PreviewWorkspace.build
    @heads = { URL_A => PreviewWorkspace.pull_request_head(root, "component-a", "alpha"),
               URL_B => PreviewWorkspace.pull_request_head(root, "component-b", "beta") }
    @workspace.status!(PreviewWorkspace.status_document(TASK))
  end

  def teardown
    FileUtils.remove_entry(@workspace.root)
  rescue SystemCallError
    nil
  end

  def root = @workspace.root

  def task_root = File.join(@workspace.runs, "worktrees", TASK)

  def payload(sources: [ [ REPO_A, URL_A ], [ REPO_B, URL_B ] ], **overrides)
    { "contract_version" => "mapiai-97", "assignment_kind" => "task_preview",
      "claim" => { "execution_id" => "rex_abc", "claimed_at" => nil, "lease_expires_at" => nil },
      "preview" => { "id" => "prv_abc", "ticket_key" => "MAPIAI-97", "project_slug" => "tiny-demo",
                     "task_id" => TASK, "canonical_branch" => TASK },
      "workspace" => { "key" => "multi-demo-workspace", "repository_url" => nil, "default_branch" => "main" },
      "sources" => sources.map { |repository, url| { "repository" => repository, "pull_request_url" => url } } }
      .merge(overrides)
  end

  def answers(state: "OPEN")
    @heads.to_h do |url, head|
      [ url, { "state" => state, "headRefName" => "pr", "headRefOid" => head, "isCrossRepository" => false } ]
    end
  end

  def execution(document = payload, answers: answers(), stop_check: nil, on_output: nil, on_sources: nil)
    SpecrelayRunner::PreviewExecution.new(payload: document, root: root, env: {}, stop_check: stop_check,
                                          on_output: on_output, on_sources: on_sources,
                                          github: FakeGitHubReader.new(answers))
  end


  # Shrink the real bounded timeouts for one example. The constant is restored in `ensure`, so no
  # other example — in this file or another — ever sees the change.
  def with_timeouts(seconds)
    klass = SpecrelayRunner::PreviewExecution
    original = klass::TIMEOUTS
    klass.send(:remove_const, :TIMEOUTS)
    klass.const_set(:TIMEOUTS, original.transform_values { seconds }.freeze)
    yield
  ensure
    klass.send(:remove_const, :TIMEOUTS)
    klass.const_set(:TIMEOUTS, original)
  end

  # CR-005 F5 — a command that stops making progress still leaves evidence. What it printed before
  # it stalled is already on the stream (the consumer is fed per line, not at exit), and the
  # outcome names the verb that timed out rather than a blank reason.
  def test_a_timed_out_release_streams_what_it_printed_and_names_the_verb
    lines = []
    run = execution(on_output: ->(_source, text) { lines << text })
    assert_predicate run.start, :available?

    @workspace.hang!("release")
    outcome = with_timeouts(1) { run.release }

    assert_equal SpecrelayRunner::PreviewExecution::RELEASE_FAILED, outcome.state
    assert_includes outcome.reason, "timed out"
    assert_includes outcome.reason, "release"
    assert outcome.cleanup_required?, "a release that never finished still owns the environment"
    assert_includes lines, "still release-ing #{TASK}",
                    "the output the command produced before it stalled never reached the stream"
  end

  # The complete order, the exact arguments, and the one root every command runs in.
  def test_the_project_owned_lifecycle_runs_in_exactly_this_order_from_the_connected_root
    snapshots = []
    preview = execution(on_sources: ->(snapshot) { snapshots << snapshot })
    outcome = preview.start

    assert outcome.available?, outcome.reason
    released = preview.release

    assert_equal SpecrelayRunner::PreviewExecution::RELEASED, released.state
    assert_equal [ "create #{TASK}", "up #{TASK}", "status #{TASK} --json", "release #{TASK}" ],
                 @workspace.invocations.map(&:last)
    assert_equal [ File.realpath(root) ] * 4, @workspace.invocations.map(&:first)
    # The bounded snapshot is reported once, BEFORE anything is created.
    assert_equal 1, snapshots.length
    assert_equal [ REPO_A, REPO_B ], snapshots.first.map { |entry| entry["repository"] }
  end

  # Steps 8-9 really happened: each repository sits at the resolved pull-request head on the
  # canonical branch, holding that head's content.
  def test_every_resolved_head_is_materialized_on_the_canonical_branch
    assert execution.start.available?

    { "component-a" => [ URL_A, "alpha" ], "component-b" => [ URL_B, "beta" ] }.each do |name, (url, marker)|
      path = File.join(task_root, name)

      assert_equal @heads[url], DemoWorkspace.git(path, "rev-parse", "HEAD").to_s.strip
      assert_equal TASK, DemoWorkspace.git(path, "rev-parse", "--abbrev-ref", "HEAD").to_s.strip
      assert_equal "#{marker}\n", File.read(File.join(path, "app.txt"))
    end
  end

  def test_the_available_document_is_the_closed_wire_shape_and_carries_no_operational_detail
    outcome = execution.start

    assert_equal %w[contract_version task_id state primary_url services], outcome.document.keys
    assert_equal [ "dashboard" ], outcome.document["services"].map { |service| service["service"] }
    dumped = JSON.generate(outcome.document)
    %w[worktree_path compose_project port_block host_port repositories slot postgres].each do |leaked|
      refute_includes dumped, leaked
    end
  end

  def test_an_assignment_refusal_is_clean_and_runs_no_command
    outcome = execution(payload.merge("assignment_kind" => "run")).start

    assert_equal SpecrelayRunner::PreviewExecution::FAILED_CLEAN, outcome.state
    assert_equal "invalid_assignment", outcome.failure_kind
    refute_predicate outcome, :cleanup_required?
    assert_equal [], @workspace.invocations
  end

  def test_a_source_refusal_is_clean_and_creates_nothing
    outcome = execution(answers: answers(state: "CLOSED")).start

    assert_equal SpecrelayRunner::PreviewExecution::FAILED_CLEAN, outcome.state
    assert_equal "source_unavailable", outcome.failure_kind
    assert_includes outcome.reason, "not open"
    assert_equal [], @workspace.invocations
  end

  # The only evidence that downgrades a create failure to clean is the project-owned lifecycle
  # saying the environment does not exist.
  def test_a_failed_create_is_clean_only_when_the_project_says_the_environment_is_absent
    @workspace.fail!("create")
    @workspace.absent!
    outcome = execution.start

    assert_equal SpecrelayRunner::PreviewExecution::FAILED_CLEAN, outcome.state
    assert_equal "worktree_failed", outcome.failure_kind
    assert_equal %w[create status], @workspace.verbs
  end

  def test_a_failed_create_owns_cleanup_when_the_project_cannot_prove_the_environment_is_absent
    @workspace.fail!("create")
    outcome = execution.start

    assert_equal SpecrelayRunner::PreviewExecution::FAILED_CLEANUP, outcome.state
    assert_predicate outcome, :cleanup_required?
    assert_equal %w[create status], @workspace.verbs
  end

  def test_status_never_runs_after_a_failed_up
    @workspace.fail!("up")
    outcome = execution.start

    assert_equal SpecrelayRunner::PreviewExecution::FAILED_CLEANUP, outcome.state
    assert_equal "startup_failed", outcome.failure_kind
    assert_equal %w[create up], @workspace.verbs
  end

  def test_a_failed_status_owns_cleanup
    @workspace.fail!("status")
    outcome = execution.start

    assert_equal "status_failed", outcome.failure_kind
    assert_predicate outcome, :cleanup_required?
    assert_equal %w[create up status], @workspace.verbs
  end

  def test_an_unsafe_status_document_owns_cleanup_and_yields_no_url
    document = PreviewWorkspace.status_document(TASK)
    document["services"].first["url"] = "http://10.0.0.5:5173"
    document["primary_url"] = "http://10.0.0.5:5173"
    @workspace.status!(document)
    outcome = execution.start

    assert_equal "invalid_status", outcome.failure_kind
    assert_predicate outcome, :cleanup_required?
    assert_nil outcome.document
  end

  # A Stop seen while STARTING must prevent availability, and it must not be answered by skipping
  # the cleanup the create it already ran may have earned.
  def test_a_stop_during_starting_prevents_availability
    stopped = false
    preview = execution(stop_check: -> { stopped },
                        on_output: ->(_stream, line) { stopped = true if line.include?("create") })
    outcome = preview.start

    assert_equal SpecrelayRunner::PreviewExecution::STOPPED, outcome.state
    assert_predicate outcome, :cleanup_required?
    assert_equal %w[create], @workspace.verbs
    assert_equal SpecrelayRunner::PreviewExecution::RELEASED, preview.release.state
  end

  def test_a_duplicate_stop_control_never_runs_release_twice
    preview = execution
    preview.start
    first = preview.release
    second = preview.release

    assert_equal SpecrelayRunner::PreviewExecution::RELEASED, second.state
    assert_same first, second
    assert_equal 1, @workspace.verbs.count("release")
  end

  # A failed release keeps this Runner occupied; Retry is the SAME execution running the SAME
  # command again rather than a new claim.
  def test_a_failed_release_can_be_retried_by_the_same_execution
    preview = execution
    preview.start
    @workspace.fail!("release")
    failed = preview.release

    assert_equal SpecrelayRunner::PreviewExecution::RELEASE_FAILED, failed.state
    assert_predicate failed, :cleanup_required?

    @workspace.succeed!

    assert_equal SpecrelayRunner::PreviewExecution::RELEASED, preview.release.state
    assert_equal 2, @workspace.verbs.count("release")
    assert_equal %w[create up status release release], @workspace.verbs
  end

  # Releasing an environment the project says does not exist is a real cleanup, not a fabricated
  # one: nothing is allocated, so nothing is held.
  def test_releasing_an_absent_environment_is_a_successful_cleanup
    preview = execution
    preview.start
    @workspace.absent!

    assert_equal SpecrelayRunner::PreviewExecution::RELEASED, preview.release.state
  end
end
