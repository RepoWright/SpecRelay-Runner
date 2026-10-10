# frozen_string_literal: true

require_relative "test_helper"

# Continuing an answered question that was asked during a CHANGE-REQUEST round. Such a claim
# carries both the recorded checkpoint and the reviewed target, and the two proofs only agree in
# one order: a reused worktree is remeasured against the checkpoint before its reviewed heads are
# proved without moving anything, and a created one is put on the reviewed heads before the
# checkpoint is restored onto them.
#
# Every git fact is real. Phase one runs the reviewed round through the CLI until its provider
# changes files and asks, so the checkpoint is the one the runner itself recorded on the reviewed
# head; phase two claims the same run again with the answers.
class AnsweredReworkResumeTest < Minitest::Test
  def fixture_dir = @fixture_dir ||= fixture_bin
  TASK = "DEMO-0410"
  BRANCH = TASK
  PR_URL = "https://github.com/SpecRelay/tiny-demo-workspace/pull/9"
  ORIGIN_URL = "git@github.com:SpecRelay/tiny-demo-workspace.git"

  BATCH = {
    "questions" => [ { "prompt" => "Should the corrected heading keep the round marker?" } ],
    "continuation_context" => {
      "progress" => "the idempotent edit is half done", "changed_areas" => "demo-app/index.html",
      "why_it_matters" => "the reviewer asked for a single heading", "next_step" => "finish the edit",
      "remaining_work" => "the second paragraph", "do_not_repeat" => "the heading rewrite"
    }
  }.freeze

  ANSWERS = [ { "option" => "", "text" => "Keep the marker." } ].freeze

  def setup
    @root, = DemoWorkspace.build
    @bare = FakeGithub.add_remote(@root, url: ORIGIN_URL)
    @package = specification_package_block(TASK, root: @root)
    git(@root, "push", "-q", "origin", "HEAD:refs/heads/main")
    @scratch = Dir.mktmpdir("specrelay-answered-rework-")
    @reviewed_head = publish_commit("<h1>Hello SpecRelay Demo</h1>\n<p>round one</p>\n", "reviewed round")
    @second = nil
  end

  def teardown
    @platform&.stop
    [ @root, @scratch, @second ].compact.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  # --- harness -------------------------------------------------------------

  # A commit on the reviewed branch, written from a separate clone so the runner's own checkout
  # genuinely has to fetch it.
  def publish_commit(content, message)
    clone = File.join(@scratch, "publisher")
    unless File.directory?(clone)
      system("git", "clone", "-q", @bare, clone, exception: true)
      %w[user.email=runner@example.test user.name=Runner\ Test commit.gpgsign=false].each do |pair|
        git(clone, "config", *pair.split("=", 2))
      end
    end
    git(clone, "fetch", "-q", "origin")
    git(clone, "checkout", "-q", "-B", BRANCH, "origin/#{BRANCH}") if remote_branch?
    File.write(File.join(clone, "demo-app", "index.html"), content)
    git(clone, "commit", "-qam", message)
    git(clone, "push", "-q", "origin", "HEAD:refs/heads/#{BRANCH}")
    git(clone, "rev-parse", "HEAD").strip
  end

  def remote_branch? = system("git", "-C", @bare, "rev-parse", "--verify", "--quiet", "refs/heads/#{BRANCH}", out: File::NULL)

  def reviewed_repository(**overrides)
    { "repository_key" => "tiny-demo-workspace", "clone_url" => ORIGIN_URL, "branch" => BRANCH,
      "head_commit" => @reviewed_head, "pull_request_url" => PR_URL }.merge(overrides.transform_keys(&:to_s))
  end

  def rework_payload(repository = reviewed_repository)
    payload = claim_payload_for(task_id: TASK, publication: {}, rework: { "repositories" => [ repository ] })
    payload.merge("specification_package" => @package)
  end

  def resume_block(checkpoint)
    { "question_id" => "exq_fake", "checkpoint" => assigned(checkpoint),
      "continuation_context" => BATCH["continuation_context"],
      "questions" => BATCH["questions"], "answers" => ANSWERS }
  end

  # Metadata and the claim-bound download path, never the bytes.
  def assigned(checkpoint)
    checkpoint.reject { |key, _| key == "payload" }
              .merge("download_path" => "/api/runner/executor_questions/exq_fake/checkpoint")
  end

  def start(payload)
    @platform&.stop
    @platform = FakePlatform.new(claim_payload: payload).start
    @gh_dir, @gh_log, = FakeGithub.gh_bin(pull_request_url: PR_URL, bare: @bare,
                                          seed: [ { "url" => PR_URL, "state" => "OPEN",
                                                    "headRefName" => BRANCH, "headRefOid" => "live" } ])
  end

  def run_cli_in(root)
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
    io = StringIO.new
    code = SpecrelayRunner::CLI.run(%W[claim-once --config #{path}], out: io, err: io,
                                    env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "HOME" => ENV["HOME"].to_s,
                                           "PATH" => "#{fixture_dir}:#{@gh_dir}:#{ENV['PATH']}" })
    [ code, io.string ]
  end

  # Phase one: the reviewed round is continued, its provider changes a tracked file, adds an
  # untracked evidence note and asks. Platform releases the session at once, so this machine keeps
  # a dirty worktree at the reviewed head, the remote holds the checkpoint ref, and Platform holds
  # only the manifest naming it.
  def asked_during_rework(commit_first: false)
    use_fixture(fixture_dir, asking_executor,
                env: { "FAKE_EXECUTOR_QUESTION_JSON" => BATCH.to_json,
                       "ASKING_EXECUTOR_COMMIT_FIRST" => commit_first ? "1" : "" })
    start(rework_payload)
    code, output = run_cli_in(@root)
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    assert_includes output, "[asking-executor] asked"
    checkpoint = @platform.executor_questions.first[:body]["checkpoint"]
    assert_equal @reviewed_head, checkpoint["repositories"].fetch(0)["base_sha"],
                 "the checkpoint of a rework round is recorded on the reviewed head"
    checkpoint
  end

  # Phase two: the same run, claimed again with the change request AND the answered question.
  def resume_answered(checkpoint, repository: reviewed_repository, checkpoint_block: checkpoint)
    use_fixture(fixture_dir, recording_executor)
    start(rework_payload(repository).merge("resume" => resume_block(checkpoint_block)))
    @platform.delivery_response = [ 200, { question: { id: "exq_fake", state: "RESUMED" } } ]
    @platform.checkpoint_payload = checkpoint_block["payload"]
  end

  # A fresh machine: cloned from the remote, holding no worktree for the branch.
  def second_machine
    @second = File.join(Dir.mktmpdir("specrelay-answered-rework-second-"), "workspace")
    system("git", "clone", "-q", @bare, @second, exception: true)
    git(@second, "config", "user.email", "runner@example.test")
    git(@second, "config", "user.name", "Runner Test")
    git(@second, "config", "commit.gpgsign", "false")
    git(@second, "remote", "set-url", "origin", ORIGIN_URL)
    FakeGithub.serve_locally(@second, @bare)
    @second
  end

  def worktree_path(root = @root) = File.join(root, ".runs/worktrees", TASK)

  # Everything a reset, stash or rebuild would change: the commit, the status and every byte of
  # the uncommitted work, untracked files included.
  def snapshot(path)
    [ git(path, "rev-parse", "HEAD"), git(path, "status", "--porcelain", "--untracked-files=all"),
      git(path, "diff", "HEAD"), File.read(File.join(path, "evidence-note.md")) ]
  end

  def checkpoint_ref_of(checkpoint) = checkpoint["repositories"].fetch(0)["checkpoint_ref"]

  # The remote's checkpoint refs: what a refusal must keep and a consumed resume removes.
  def remote_checkpoints
    git(@bare, "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads/runner-checkpoints/")
  end

  # A manifest re-sealed around one edited entry, so only the edited term is wrong.
  def resealed(checkpoint)
    entries = checkpoint["repositories"].map(&:dup)
    yield entries.first
    bytes = JSON.generate("format" => checkpoint["format"], "repositories" => entries)
    checkpoint.merge("repositories" => entries, "byte_size" => bytes.bytesize,
                     "digest" => Digest::SHA256.hexdigest(bytes), "payload" => Base64.strict_encode64(bytes))
  end

  def assert_refused_before_provider(reason, path)
    before = snapshot(path)
    refs = remote_checkpoints
    code, output = run_cli_in(@root)
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, reason
    assert_refused_cleanly(reason)
    assert_equal before, snapshot(path), "the worktree must be byte-identical"
    assert_equal refs, remote_checkpoints, "a refusal keeps the checkpoint ref for the next attempt"
    output
  end

  def assert_refused_cleanly(reason)
    refute_path_exists prompt_path, "no provider may start"
    releases = @platform.requests_to("/api/runner/claim_releases")
    assert_equal 1, releases.length, "the claim must be released so the run stays claimable"
    assert_includes releases.first[:body]["reason"].to_s, reason
    assert_empty @platform.requests_to("/api/runner/reports"), "no report may be uploaded"
    assert_empty @platform.delivery_acknowledgements, "the answered checkpoint must not be consumed"
    assert_empty @platform.executor_questions
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  # --- capture -------------------------------------------------------------

  # The asking run pushes the snapshot to its own immutable ref on the verified
  # origin, never to the task or pull-request branch, and Platform receives only the manifest.
  def test_the_asking_run_pushes_one_checkpoint_ref_and_platform_stores_only_its_manifest
    branch_before = git(@bare, "rev-parse", "refs/heads/#{BRANCH}").strip

    checkpoint = asked_during_rework

    entry = checkpoint["repositories"].fetch(0)
    assert_equal SpecrelayRunner::Checkpoint::FORMAT, checkpoint["format"]
    assert_match(%r{\Arefs/heads/runner-checkpoints/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z}, entry["checkpoint_ref"])
    assert_equal entry["snapshot_sha"], git(@bare, "rev-parse", entry["checkpoint_ref"]).strip
    assert_equal [ entry["snapshot_sha"], @reviewed_head ],
                 git(@bare, "rev-list", "--parents", "-n", "1", entry["snapshot_sha"]).split
    assert_equal branch_before, git(@bare, "rev-parse", "refs/heads/#{BRANCH}").strip, "the PR branch moved"
    manifest = JSON.parse(Base64.strict_decode64(checkpoint["payload"]))
    assert_equal checkpoint["repositories"], manifest["repositories"], "Platform stores the manifest, not a pack"
    assert_includes git(worktree_path, "status", "--porcelain", "--untracked-files=all"), "evidence-note.md"
  end

  # --- same machine --------------------------------------------------------

  # The machine that asked restores from the remote ref through the same procedure,
  # and the consumed ref is removed once the delivery is confirmed.
  def test_the_same_machine_restores_from_the_remote_ref_and_continues_with_the_answers
    checkpoint = asked_during_rework
    before = snapshot(worktree_path)
    resume_answered(checkpoint)

    code, output = run_cli_in(@root)

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    assert_equal @reviewed_head, File.read(observed_head_path).strip
    assert_equal before[2], File.read(observed_diff_path), "the restored work is the recorded work"
    assert_includes File.read(observed_status_path), "?? evidence-note.md"
    assert_includes output, "[recording-executor] started"
    assert_prompt_carries_change_request_and_answers
    assert_equal 1, @platform.delivery_acknowledgements.size
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
    assert_equal 0, FakeGithub.pr_creates(@gh_log), "the reviewed pull request is reused"
    assert_empty remote_checkpoints, "the consumed checkpoint ref is removed after delivery"
  end

  # A local commit on top of the reviewed head is part of the paused work: it is checkpointed on
  # the reviewed head, and the resume continues from the reviewed head with its effect as dirty
  # work. The pull request's branch never moves.
  def test_a_local_commit_on_the_reviewed_branch_is_checkpointed_and_resumed_as_dirty_work
    branch_before = git(@bare, "rev-parse", "refs/heads/#{BRANCH}").strip
    checkpoint = asked_during_rework(commit_first: true)
    refute_equal @reviewed_head, git(worktree_path, "rev-parse", "HEAD").strip, "the provider committed locally"
    expected_diff = git(worktree_path, "diff", @reviewed_head)
    resume_answered(checkpoint)

    code, output = run_cli_in(@root)

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    assert_equal @reviewed_head, File.read(observed_head_path).strip
    assert_equal expected_diff, File.read(observed_diff_path), "the local commit's effect is restored as dirty work"
    assert_includes File.read(observed_status_path), "?? evidence-note.md"
    assert_equal 1, @platform.delivery_acknowledgements.size
    assert system("git", "-C", @bare, "merge-base", "--is-ancestor", branch_before, "refs/heads/#{BRANCH}"),
           "the pull-request branch only ever moves forward, through publication"
  end

  # The same local commit, but the pull request moved: the resume refuses before the local branch
  # is moved back to any base, so the local commit is still checked out.
  def test_a_moved_pull_request_head_refuses_before_a_local_commit_on_the_reviewed_branch_is_moved
    checkpoint = asked_during_rework(commit_first: true)
    resume_answered(checkpoint)
    publish_commit("<h1>Hello SpecRelay Demo</h1>\n<p>pushed later</p>\n", "moved on")

    assert_refused_before_provider("moved", worktree_path)
  end

  # --- fresh machine -------------------------------------------------------

  def test_a_fresh_machine_places_the_reviewed_head_restores_the_remote_checkpoint_and_continues
    checkpoint = asked_during_rework
    expected_diff = git(worktree_path, "diff", "HEAD")
    other = second_machine
    resume_answered(checkpoint)

    code, output = run_cli_in(other)

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    assert_equal @reviewed_head, File.read(observed_head_path).strip
    assert_equal expected_diff, File.read(observed_diff_path), "the restored work is the recorded work"
    assert_includes File.read(observed_status_path), "?? evidence-note.md"
    assert_includes output, "[recording-executor] started"
    assert_prompt_carries_change_request_and_answers
    assert_equal 1, @platform.requests_to("/api/runner/executor_questions/exq_fake/checkpoint").size
    assert_equal 1, @platform.delivery_acknowledgements.size
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
    assert_empty remote_checkpoints
  end

  def assert_prompt_carries_change_request_and_answers
    prompt = File.read(prompt_path)
    assert_includes prompt, "## Change request — 002-review-fixes"
    assert_includes prompt, @reviewed_head
    assert_includes prompt, "The edit is not idempotent."
    assert_includes prompt, "## Answers to your earlier questions"
    assert_includes prompt, "Keep the marker."
    assert_includes prompt, "next_step: finish the edit"
  end

  # --- refusals before any provider ----------------------------------------

  def test_a_moved_pull_request_head_refuses_and_keeps_the_worktree
    checkpoint = asked_during_rework
    resume_answered(checkpoint)
    publish_commit("<h1>Hello SpecRelay Demo</h1>\n<p>pushed later</p>\n", "moved on")

    assert_refused_before_provider("moved", worktree_path)
  end

  # The pull request moved and the claim names the new head, but the work was recorded on the
  # old one: which version to continue cannot be proven.
  def test_a_checkpoint_base_other_than_the_reviewed_head_refuses_and_keeps_the_worktree
    checkpoint = asked_during_rework
    moved = publish_commit("<h1>Hello SpecRelay Demo</h1>\n<p>pushed later</p>\n", "moved on")
    resume_answered(checkpoint, repository: reviewed_repository(head_commit: moved))

    assert_refused_before_provider("is not at the reviewed head", worktree_path)
  end

  def test_an_unrecorded_edit_in_the_worktree_refuses_and_keeps_it
    checkpoint = asked_during_rework
    File.write(File.join(worktree_path, "demo-app", "index.html"), "<h1>an edit nobody recorded</h1>\n")
    resume_answered(checkpoint)

    assert_refused_before_provider("not the recorded work", worktree_path)
  end

  def test_a_recorded_digest_that_does_not_match_refuses_and_keeps_the_worktree
    checkpoint = asked_during_rework
    tampered = resealed(checkpoint) { |entry| entry["change_digest"] = "0" * 64 }
    resume_answered(checkpoint, checkpoint_block: tampered)

    assert_refused_before_provider("change_digest", worktree_path)
  end

  def test_a_moved_checkpoint_ref_refuses_and_keeps_the_worktree
    checkpoint = asked_during_rework
    git(@bare, "update-ref", checkpoint_ref_of(checkpoint), @reviewed_head)
    resume_answered(checkpoint)

    assert_refused_before_provider("moved", worktree_path)
  end

  def test_a_worktree_owned_by_another_run_refuses_and_keeps_it
    checkpoint = asked_during_rework
    ProjectCommand.own!(@root, TASK, "run_someone_else")
    resume_answered(checkpoint)

    assert_refused_before_provider("owned by a different run", worktree_path)
  end

  def test_a_foreign_origin_refuses_and_keeps_the_worktree
    checkpoint = asked_during_rework
    mirror = File.join(@scratch, "mirror.git")
    system("git", "clone", "-q", "--bare", @bare, mirror, exception: true)
    resume_answered(checkpoint)
    git(@root, "remote", "set-url", "origin", mirror)

    assert_refused_before_provider("origin", worktree_path)
  end

  def test_a_reviewed_branch_other_than_the_publication_branch_refuses_and_keeps_the_worktree
    checkpoint = asked_during_rework
    resume_answered(checkpoint, repository: reviewed_repository(branch: "specrelay/redirected"))

    assert_refused_before_provider("not to the reviewed branch", worktree_path)
  end

  def test_an_invalid_manifest_refuses_on_a_fresh_machine_before_the_reviewed_head_is_placed
    checkpoint = asked_during_rework
    other = second_machine
    resume_answered(checkpoint)
    @platform.checkpoint_payload = Base64.strict_encode64("not the recorded manifest")
    refs = remote_checkpoints

    code, output = run_cli_in(other)

    # The manifest is proved before the task workspace is built, so nothing was built at all.
    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, "checkpoint manifest"
    assert_refused_cleanly("checkpoint manifest")
    refute_path_exists worktree_path(other)
    refute system("git", "-C", other, "rev-parse", "--verify", "--quiet", "refs/heads/#{BRANCH}", out: File::NULL)
    assert_equal refs, remote_checkpoints
  end

  def test_a_missing_checkpoint_ref_refuses_on_a_fresh_machine_before_placement
    checkpoint = asked_during_rework
    git(@bare, "update-ref", "-d", checkpoint_ref_of(checkpoint))
    other = second_machine
    resume_answered(checkpoint)

    assert_refused_before_placement(other, "no longer exists")
  end

  # The pull request moved and the claim names the new head, but the work was recorded on the
  # old one. The recorded base is compared with the reviewed head before the head is placed.
  def test_a_checkpoint_base_other_than_the_reviewed_head_refuses_on_a_fresh_machine_before_placement
    checkpoint = asked_during_rework
    moved = publish_commit("<h1>Hello SpecRelay Demo</h1>\n<p>pushed later</p>\n", "moved on")
    other = second_machine
    resume_answered(checkpoint, repository: reviewed_repository(head_commit: moved))

    assert_refused_before_placement(other, "refusing to continue the recorded work on another commit")
  end

  # A fresh machine's task workspace is built by the project command on the clone's own HEAD, on a
  # new task branch. A refusal leaves it exactly there; fetched objects alone are allowed.
  def assert_refused_before_placement(machine, reason)
    built_on = git(machine, "rev-parse", "HEAD").strip
    refs = remote_checkpoints
    code, output = run_cli_in(machine)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes output, reason
    assert_refused_cleanly(reason)
    assert_equal built_on, git(machine, "rev-parse", "refs/heads/#{BRANCH}").strip, "the task branch must not move"
    assert_equal built_on, git(worktree_path(machine), "rev-parse", "HEAD").strip
    assert_equal "", git(worktree_path(machine), "status", "--porcelain", "--untracked-files=all")
    assert_equal refs, remote_checkpoints
  end

  # --- probes --------------------------------------------------------------

  # Changes one tracked file and adds one untracked evidence note, then asks and waits briefly.
  def asking_executor
    path = File.join(@scratch, "asking-executor")
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      prompt = File.read(ARGV.last.to_s)
      request = prompt[%r{`([^`]*/question-request\.json)`}, 1]
      abort "[asking-executor] the prompt named no bridge" if request.nil?
      file = "demo-app/index.html"
      File.write(file, File.read(file).sub("round one", "round one, interrupted"))
      system("git", "commit", "-qam", "local work on the reviewed branch", exception: true) unless
        ENV["ASKING_EXECUTOR_COMMIT_FIRST"].to_s.empty?
      File.write("evidence-note.md", "review evidence in progress\n")
      SELECTION.call
      File.write("#{request}.partial", ENV.fetch("FAKE_EXECUTOR_QUESTION_JSON"))
      File.rename("#{request}.partial", request)
      puts "[asking-executor] asked"
      deadline = Time.now + 5
      sleep 0.05 until Time.now > deadline || File.file?(File.join(File.dirname(request), "question-answer.json"))
    RUBY
    File.write(path, DemoWorkspace.with_selection_reporter(File.read(path)) + "\nexit 0\n")
    FileUtils.chmod(0o755, path)
    path
  end

  # Records what it was handed and what it started on, outside the worktree, then finishes the
  # paused edit.
  def recording_executor
    path = File.join(@scratch, "recording-executor")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      File.write(#{prompt_path.inspect}, File.read(ARGV.last))
      File.write(#{observed_head_path.inspect}, `git rev-parse HEAD`)
      File.write(#{observed_status_path.inspect}, `git status --porcelain --untracked-files=all`)
      File.write(#{observed_diff_path.inspect}, `git diff HEAD`)
      File.write(#{observed_reflog_path.inspect}, `git reflog`)
      puts "[recording-executor] started"
      file = "demo-app/index.html"
      File.write(file, File.read(file).sub("interrupted", "resumed"))
      #{DemoWorkspace.selection_snippet}
      exit 0
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end

  def prompt_path = File.join(@scratch, "prompt.txt")
  def observed_head_path = File.join(@scratch, "observed-head.txt")
  def observed_status_path = File.join(@scratch, "observed-status.txt")
  def observed_diff_path = File.join(@scratch, "observed-diff.txt")
  def observed_reflog_path = File.join(@scratch, "observed-reflog.txt")
end
