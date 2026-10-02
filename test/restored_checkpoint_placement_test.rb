# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

# Continuing an answered question on a machine that never held the work, in a project whose task
# environment is several INDEPENDENT repositories.
#
# Such a project prepares its component checkouts DETACHED at their base, so the continuation
# builds the environment with the project's own command and then meets every recorded component
# without the branch the checkpoint recorded. The subject here is that one state: the branch is
# established on a checkout this attempt's own create left detached, at the base it is already
# sitting on, and every other refusal stays exactly where it was.
#
# Everything runs against REAL git repositories. A placement proven against a double would prove
# nothing: "the branch already exists in the clone this checkout shares", "it is checked out in
# another worktree" and "this clone has moved past the base" are facts about git and the disk.
class RestoredCheckpointPlacementTest < Minitest::Test
  TASK = "DEMO-0207"
  RECORDED = %w[component-a component-b].freeze

  def setup
    @built = MultiRepositoryWorkspace.build
    @scratch = Dir.mktmpdir("specrelay-placement-")
    @clone = nil
    @platform = nil
  end

  def teardown
    @platform&.stop
    [ @built&.root, @clone&.root, @scratch ].compact.each do |dir|
      FileUtils.remove_entry(dir) if File.directory?(dir)
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

  # The machine that asked the question: an ordinary environment, components on the canonical
  # branch, with real uncommitted work in two of the three repositories.
  def asked
    source = creating(@built.root).create.path
    RECORDED.each do |name|
      file = File.join(source, name, "app.txt")
      File.write(file, "#{File.read(file)}interrupted by the provider\n")
    end
    verified = measuring(@built.root).select(source, RECORDED)
    raise verified.error if verified.error

    captured = SpecrelayRunner::Checkpoint.capture(repositories: verified.repositories,
                                                   workspace: measuring(@built.root))
    raise captured.error unless captured.ok?

    [ source, *stored(captured) ]
  end

  # What Platform stores and hands back: the closed metadata, with the payload transported
  # separately exactly as the download boundary does.
  def stored(captured)
    document = captured.checkpoint.dup
    [ document.reject { |key, _| key == "payload" }, document["payload"] ]
  end

  # The second machine, whose project command leaves every component DETACHED at its base — the
  # shape a real multi-repository workspace prepares, and the one this ticket exists for.
  def second_machine
    @clone = MultiRepositoryWorkspace.clone_of(@built)
    FileUtils.mkdir_p(File.join(@clone.root, ".runs"))
    FileUtils.touch(File.join(@clone.root, ".runs", "detach-components"))
    @clone.root
  end

  def restore(metadata, payload, task_root, created: true)
    SpecrelayRunner::Checkpoint.restore(metadata, payload: payload, task_root: task_root,
                                                  workspace: measuring(@clone.root), created: created)
  end

  def component(task_root, name = "component-a") = File.join(task_root, name)
  def branch_of(path) = git(path, "branch", "--show-current").strip
  def head_of(path) = git(path, "rev-parse", "HEAD").strip
  def clone_component(name) = File.join(@clone.root, name)

  # Every working-tree fact a refusal must leave alone: the path, the executable bit and the bytes.
  def worktree_bytes(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |e| e.start_with?(".git") }.map do |entry|
      full = File.join(root, entry)
      next [ entry, :dir ] if File.directory?(full) && !File.symlink?(full)
      next [ entry, :symlink, File.readlink(full) ] if File.symlink?(full)

      [ entry, File.stat(full).mode & 0o111, File.binread(full) ]
    end.sort_by(&:first)
  end

  # A real commit this clone could legitimately be holding, built without moving its checkout.
  def unrelated_commit(path)
    head = head_of(path)
    git(path, "commit-tree", git(path, "rev-parse", "#{head}^{tree}").strip, "-p", head,
        "-m", "another round").strip
  end

  # --------------------------------------------------------------- placement

  # A01 — the regression. A machine that never saw the work builds the environment with the
  # project's own command, which leaves every component detached, and the continuation puts each
  # recorded one on the recorded branch at the recorded base before it imports anything. The final
  # verify then remeasures to the recorded digests, which is what a provider start waits on.
  def test_a_detached_component_is_placed_on_the_recorded_branch_and_restored
    source, metadata, payload = asked
    target = creating(second_machine).create
    RECORDED.each do |name|
      assert_empty branch_of(component(target.path, name)), "the project command must leave it detached"
    end

    restored = restore(metadata, payload, target.path)

    assert restored.ok?, restored.reason
    metadata["repositories"].each do |entry|
      path = component(target.path, entry["path"])
      assert_equal TASK, branch_of(path), "#{entry['path']} is not on the recorded branch"
      assert_equal entry["base"], head_of(path), "#{entry['path']} is not at the recorded base"
      assert_equal worktree_bytes(component(source, entry["path"])), worktree_bytes(path)
    end
  end

  # A02 — the bound on what a restore may write. A component the checkpoint does not record is
  # left exactly as the project built it: detached, clean and unplaced.
  def test_a_component_the_checkpoint_does_not_record_is_left_detached_and_clean
    _source, metadata, payload = asked
    target = creating(second_machine).create
    untouched = component(target.path, "component-c")
    before = worktree_bytes(untouched)

    assert restore(metadata, payload, target.path).ok?

    assert_empty branch_of(untouched), "an unrecorded component must not be placed"
    assert_empty git(untouched, "status", "--porcelain").strip
    assert_equal before, worktree_bytes(untouched)
  end

  # --------------------------------------------------------------- refusals

  # A03, under the OQ-001 decision — nothing fetches, resets or moves this checkout, so a clone
  # that has advanced past the recorded base cannot continue the work. The refusal names BOTH
  # commits, because that is the only thing that tells an operator which machine can.
  def test_a_detached_component_at_another_commit_refuses_and_names_both_commits
    _source, metadata, payload = asked
    root = second_machine
    moved = clone_component("component-a")
    File.write(File.join(moved, "app.txt"), "this clone moved on\n")
    git(moved, "add", "-A")
    git(moved, "-c", "user.email=t@e.test", "-c", "user.name=T", "commit", "-q", "-m", "moved on")
    target = creating(root).create
    recorded = metadata["repositories"].first["base"]
    before = worktree_bytes(component(target.path))

    refused = restore(metadata, payload, target.path)

    refute refused.ok?
    assert_includes refused.reason, "base commit"
    assert_includes refused.reason, recorded, "the refusal must name the recorded base"
    assert_includes refused.reason, head_of(component(target.path)), "the refusal must name the actual commit"
    assert_empty branch_of(component(target.path)), "a refused continuation places nothing"
    assert_equal before, worktree_bytes(component(target.path))
  end

  def test_a_dirty_detached_component_refuses_without_placing_it
    _source, metadata, payload = asked
    target = creating(second_machine).create
    File.write(File.join(component(target.path), "app.txt"), "someone else was here\n")

    refused = restore(metadata, payload, target.path)

    refute refused.ok?
    assert_includes refused.reason, "uncommitted"
    assert_empty branch_of(component(target.path))
    assert_equal "someone else was here\n", File.read(File.join(component(target.path), "app.txt"))
  end

  def test_a_detached_component_whose_origin_is_a_different_repository_refuses
    _source, metadata, payload = asked
    target = creating(second_machine).create
    git(component(target.path), "remote", "set-url", "origin", "git@github.com:SpecRelay/somewhere-else.git")

    refused = restore(metadata, payload, target.path)

    refute refused.ok?
    assert_includes refused.reason, "origin"
    assert_empty branch_of(component(target.path))
  end

  # A detached checkout holds nothing and is this claim's own; one somebody has put on a branch of
  # their own is still somebody else's, and keeps the refusal it has always had.
  def test_a_component_checked_out_on_another_branch_keeps_the_recorded_branch_refusal
    _source, metadata, payload = asked
    target = creating(second_machine).create
    git(component(target.path), "checkout", "-q", "-b", "some-other-branch")

    refused = restore(metadata, payload, target.path)

    refute refused.ok?
    assert_includes refused.reason, "branch"
    assert_equal "some-other-branch", branch_of(component(target.path))
  end

  # The branch may already exist in the clone this checkout shares with other environments, left
  # by an earlier round on this machine. Selecting it blindly would hand the provider that round's
  # commit, so it is never moved and never selected anywhere but the recorded base.
  def test_a_local_branch_of_the_recorded_name_at_another_commit_is_never_moved
    _source, metadata, payload = asked
    root = second_machine
    shared = clone_component("component-a")
    other = unrelated_commit(shared)
    git(shared, "branch", TASK, other)
    target = creating(root).create

    refused = restore(metadata, payload, target.path)

    refute refused.ok?
    assert_includes refused.reason, "never moved"
    assert_equal other, git(shared, "rev-parse", "refs/heads/#{TASK}").strip
    assert_empty branch_of(component(target.path))
  end

  def test_a_local_branch_of_the_recorded_name_checked_out_elsewhere_refuses
    _source, metadata, payload = asked
    root = second_machine
    shared = clone_component("component-a")
    git(shared, "checkout", "-q", "-b", TASK)
    target = creating(root).create

    refused = restore(metadata, payload, target.path)

    refute refused.ok?
    assert_includes refused.reason, "another worktree"
    assert_empty branch_of(component(target.path))
  end

  # A05 — bytes that are not the recorded package never reach a repository, and never place one
  # either: integrity is settled before any target is opened.
  def test_a_payload_that_does_not_match_its_checksum_places_nothing
    _source, metadata, payload = asked
    target = creating(second_machine).create
    bytes = Base64.strict_decode64(payload)
    tampered = Base64.strict_encode64("#{bytes[0..-2]}#{bytes[-1] == 'x' ? 'y' : 'x'}")

    refused = restore(metadata, tampered, target.path)

    refute refused.ok?
    assert_includes refused.reason, "checksum"
    RECORDED.each { |name| assert_empty branch_of(component(target.path, name)) }
  end

  # A04 — a worktree this attempt did not create is never placed, because nothing there proves why
  # a checkout is detached. The reuse path keeps the refusal it has always had.
  def test_a_worktree_this_attempt_did_not_create_is_never_placed
    _source, metadata, payload = asked
    target = creating(second_machine).create

    refused = restore(metadata, payload, target.path, created: false)

    refute refused.ok?
    assert_includes refused.reason, "is not the recorded"
    assert_empty branch_of(component(target.path))
  end

  # ------------------------------------------------- the whole continuation

  # A01/A05 — the run the reporter could not continue, end to end. The question is asked and
  # released on one machine; a SECOND machine with no task worktree claims the answered run,
  # builds the environment with the project's own command, places every recorded component on the
  # canonical branch at its recorded base, restores the work, and only then starts the provider
  # with the answers.
  def test_a_second_machine_with_detached_components_continues_the_answered_run
    checkpoint = released_question
    other = second_machine
    restart_platform(resume_payload(other, checkpoint))
    @platform.checkpoint_payload = checkpoint["payload"]
    io = StringIO.new

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli_in(other, io), io.string

    assert_includes io.string, "[resume-executor] resumed"
    assert_includes io.string, "Match the recorded component."
    assert_includes io.string, "do_not_repeat: the first edit"
    # What the fresh provider was actually handed: the recorded branch, the recorded base, and the
    # interrupted bytes it has to continue from.
    observed = YAML.safe_load(File.read(observed_path))
    assert_equal TASK, observed.fetch("branch")
    assert_equal checkpoint["repositories"].first["base"], observed.fetch("head")
    assert_includes observed.fetch("file"), "interrupted"
    assert_equal 1, @platform.requests_to("/api/runner/executor_questions/exq_fake/checkpoint").size
    assert_equal 1, @platform.delivery_acknowledgements.size
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
  end

  # ------------------------------------------------- end-to-end fixtures

  BATCH = {
    "questions" => [
      { "prompt" => "Which component owns the total?",
        "options" => [ { "key" => "a", "label" => "component-a", "recommended" => true } ] }
    ],
    "continuation_context" => {
      "progress" => "the first edit landed", "changed_areas" => "component-a/app.txt",
      "why_it_matters" => "ownership decides where the rule lives", "next_step" => "apply the rule",
      "remaining_work" => "the rule and its tests", "do_not_repeat" => "the first edit"
    }
  }.freeze

  ANSWERS = [ { "option" => "a", "text" => "Match the recorded component." } ].freeze

  # What the executor reports as its selection. `component-a` is the one repository it changes, and
  # it has no applicable verification of its own here — a valid, non-blocking answer.
  SELECTED = %([ { "path" => "component-a", "commands" => [] } ]).freeze

  def fixture_dir = @fixture_dir ||= fixture_bin
  def observed_path = @observed_path ||= File.join(@scratch, "observed.yml")

  # Phase one, on the machine that holds the work: a provider that CHANGES a component and then
  # asks. The session is released, so the run ends with real uncommitted work and a checkpoint.
  def released_question
    use_fixture(fixture_dir, question_executor,
                env: { "FAKE_EXECUTOR_QUESTION_JSON" => BATCH.to_json })
    @platform = FakePlatform.new(claim_payload: implementation_payload(@built.root)).start
    @platform.release_question!
    io = StringIO.new
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli_in(@built.root, io), io.string
    assert_includes io.string, "[question-executor] edited before asking"
    @platform.executor_questions.first[:body]["checkpoint"]
  end

  # Committed ONCE, into the first machine, before anything clones it: the second machine is a
  # clone, so re-committing the package there would move its history past the recorded base.
  def approved_package
    @approved_package ||= specification_package_block(TASK, root: @built.root, repository: "component-c")
  end

  def implementation_payload(root)
    claim_payload_for(task_id: TASK, root: root).merge("specification_package" => approved_package)
  end

  # Phase two: the same run, claimed again, carrying the answers and the recorded checkpoint —
  # metadata and the one claim-bound download path, never the bytes.
  def resume_payload(root, checkpoint)
    use_fixture(fixture_dir, resume_executor)
    implementation_payload(root).merge(
      "resume" => { "question_id" => "exq_fake", "checkpoint" => assigned(checkpoint),
                    "continuation_context" => BATCH["continuation_context"],
                    "questions" => BATCH["questions"], "answers" => ANSWERS }
    )
  end

  def assigned(checkpoint)
    checkpoint.reject { |key, _| key == "payload" }
              .merge("download_path" => "/api/runner/executor_questions/exq_fake/checkpoint")
  end

  def restart_platform(payload)
    @platform.stop
    @platform = FakePlatform.new(claim_payload: payload).start
    @platform.delivery_response =
      [ 200, { question: { id: "exq_fake", state: "RESUMED", deadline_at: "2026-08-13T12:00:00Z",
                           remaining_seconds: 0, answers: ANSWERS } } ]
  end

  def run_cli_in(root, io)
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{@platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: test-runner
        display_name: Test Runner
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{root}
    YAML
    SpecrelayRunner::CLI.run(%W[claim-once --config #{path}], out: io, err: io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
                                    "PATH" => "#{fixture_dir}:#{ENV['PATH']}" })
  end

  def write_executor(name, source)
    path = File.join(@scratch, name)
    File.write(path, source)
    FileUtils.chmod(0o755, path)
    path
  end

  def question_executor
    write_executor("question-executor", DemoWorkspace.with_selection_reporter(<<~'RUBY', paths: SELECTED))
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      prompt = File.read(ARGV.last.to_s)
      request = prompt[%r{`([^`]*/question-request\.json)`}, 1]
      abort "[question-executor] the prompt named no bridge" if request.nil?
      settled = %w[question-answer.json question-error.json].map { |n| File.join(File.dirname(request), n) }

      file = "component-a/app.txt"
      File.write(file, "#{File.read(file)}interrupted by the provider\n")
      puts "[question-executor] edited before asking"

      SELECTION.call
      File.write("#{request}.partial", ENV.fetch("FAKE_EXECUTOR_QUESTION_JSON"))
      File.rename("#{request}.partial", request)
      puts "[question-executor] asked"

      deadline = Time.now + 10
      sleep 0.05 until Time.now > deadline || settled.any? { |path| File.file?(path) }
      exit 0
    RUBY
  end

  # It records the branch, head and bytes it was HANDED before it changes anything, outside the
  # task workspace so the recording never becomes part of the diff under test.
  def resume_executor
    source = <<~'RUBY'.sub("OBSERVED", observed_path.inspect)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      require "yaml"
      prompt = File.read(ARGV.last.to_s)
      section = prompt[/## Answers to your earlier questions.*/m].to_s
      abort "[resume-executor] the prompt carried no answers" if section.empty?
      puts "[resume-executor] resumed #{section.lines.map(&:strip).reject(&:empty?).join(' | ')}"

      File.write(OBSERVED, YAML.dump(
        "branch" => `git -C component-a branch --show-current`.strip,
        "head" => `git -C component-a rev-parse HEAD`.strip,
        "file" => File.read("component-a/app.txt")
      ))

      file = "component-a/app.txt"
      File.write(file, "#{File.read(file)}resumed by the provider\n")
      puts "[resume-executor] applied edit"
      SELECTION.call
      exit 0
    RUBY
    write_executor("resume-executor", DemoWorkspace.with_selection_reporter(source, paths: SELECTED))
  end
end
