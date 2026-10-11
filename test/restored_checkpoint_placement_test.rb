# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

# Continuing an answered question on a machine that never held the work, in a project whose task
# environment is several INDEPENDENT repositories prepared DETACHED at their base — end to end,
# through the CLI.
#
# The provider changes two components but reports only one of them, so the checkpoint is proven
# to come from the workspace itself rather than from the executor's selection. Neither component
# has a pull request. The second machine fetches the checkpoint refs from the SAME remotes the
# first machine pushed them to, and the fresh provider starts on both components' recorded work.
#
# The checkpoint's own capture, proof and placement boundaries are in `portable_checkpoint_test.rb`.
class RestoredCheckpointPlacementTest < Minitest::Test
  TASK = "DEMO-0207"
  CHANGED = %w[component-a component-b].freeze

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

  # What the executor REPORTS: only component-a, although it changes component-b as well.
  SELECTED = %([ { "path" => "component-a", "commands" => [] } ]).freeze

  def setup
    @built = MultiRepositoryWorkspace.build
    @scratch = Dir.mktmpdir("specrelay-placement-")
    @second = nil
    @platform = nil
  end

  def teardown
    @platform&.stop
    [ @built&.root, @second, @scratch ].compact.each do |dir|
      FileUtils.remove_entry(dir) if File.directory?(dir)
    end
  end

  # A01/A05 — the run the reporter could not continue, end to end. The question is asked and
  # released on one machine; a SECOND machine with no task worktree claims the answered run,
  # builds the environment with the project's own command, fetches every checkpoint ref, places
  # each recorded component on the canonical branch at its recorded base, restores the work, and
  # only then starts the provider with the answers.
  def test_a_second_machine_with_detached_components_continues_the_answered_run
    checkpoint = released_question
    assert_equal CHANGED, checkpoint["repositories"].map { |entry| entry["path"] },
                 "every changed repository is checkpointed, not only the reported one"
    other = second_machine
    restart_platform(resume_payload(other, checkpoint))
    @platform.checkpoint_payload = checkpoint["payload"]
    io = StringIO.new

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli_in(other, io), io.string

    assert_includes io.string, "[resume-executor] resumed"
    assert_includes io.string, "Match the recorded component."
    assert_includes io.string, "do_not_repeat: the first edit"
    # What the fresh provider was actually handed: the recorded branch, the recorded base, and the
    # interrupted bytes it has to continue from, in BOTH components.
    observed = YAML.safe_load(File.read(observed_path))
    checkpoint["repositories"].each do |entry|
      seen = observed.fetch(entry["path"])
      assert_equal TASK, seen.fetch("branch")
      assert_equal entry["base_sha"], seen.fetch("head")
      assert_includes seen.fetch("file"), "interrupted"
    end
    assert_equal 1, @platform.requests_to("/api/runner/executor_questions/exq_fake/checkpoint").size
    assert_equal 1, @platform.delivery_acknowledgements.size
    assert_equal 1, @platform.requests_to("/api/runner/reports").size
  end

  # ------------------------------------------------- end-to-end fixtures

  def fixture_dir = @fixture_dir ||= fixture_bin
  def observed_path = @observed_path ||= File.join(@scratch, "observed.yml")

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  # Phase one, on the machine that holds the work: a provider that CHANGES two components and then
  # asks. Platform releases the session at once, so the run ends with real uncommitted work here,
  # checkpoint refs on each component's remote, and the manifest on Platform.
  def released_question
    use_fixture(fixture_dir, question_executor,
                env: { "FAKE_EXECUTOR_QUESTION_JSON" => BATCH.to_json })
    @platform = FakePlatform.new(claim_payload: implementation_payload(@built.root)).start
    io = StringIO.new
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli_in(@built.root, io), io.string
    assert_includes io.string, "[question-executor] edited before asking"
    @platform.executor_questions.first[:body]["checkpoint"]
  end

  # Committed ONCE and published as component-c's default branch, as an approved specification
  # is: the second machine clones the remotes, and component-c is then unchanged on both machines.
  def approved_package
    @approved_package ||= specification_package_block(TASK, root: @built.root, repository: "component-c").tap do
      git(File.join(@built.root, "component-c"), "push", "-q", "origin", "HEAD:refs/heads/main")
    end
  end

  def implementation_payload(root)
    claim_payload_for(task_id: TASK, root: root).merge("specification_package" => approved_package)
  end

  # Phase two: the same run, claimed again, carrying the answers and the recorded manifest —
  # metadata and the one claim-bound download path.
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

  # The second machine, answered by the SAME remotes the first one pushed to, whose project command
  # leaves every component DETACHED at its base.
  def second_machine
    @second = File.join(Dir.mktmpdir("specrelay-placement-second-"), "workspace")
    clone(@built.bares.fetch("."), @second, "multi-demo-workspace")
    MultiRepositoryWorkspace.write_project_command(@second, MultiRepositoryWorkspace::COMPONENTS)
    MultiRepositoryWorkspace::COMPONENTS.each do |name|
      clone(@built.bares.fetch(name), File.join(@second, name), name)
    end
    FileUtils.mkdir_p(File.join(@second, ".runs"))
    FileUtils.touch(File.join(@second, ".runs", "detach-components"))
    @second
  end

  def clone(source, target, name)
    system("git", "clone", "-q", source, target, exception: true)
    { "user.email" => "runner@example.test", "user.name" => "Runner Test", "commit.gpgsign" => "false" }
      .each { |key, value| git(target, "config", key, value) }
    git(target, "remote", "set-url", "origin", "git@github.com:SpecRelay/#{name}.git")
    FakeGithub.serve_locally(target, source)
  end

  def restart_platform(payload)
    @platform.stop
    @platform = FakePlatform.new(claim_payload: payload).start
    @platform.delivery_response =
      [ 200, { question: { id: "exq_fake", state: "RESUMED" } } ]
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
      refused = File.join(File.dirname(request), "question-error.json")

      %w[component-a component-b].each do |component|
        file = "#{component}/app.txt"
        File.write(file, "#{File.read(file)}interrupted by the provider\n")
      end
      puts "[question-executor] edited before asking"

      SELECTION.call
      File.write("#{request}.partial", ENV.fetch("FAKE_EXECUTOR_QUESTION_JSON"))
      File.rename("#{request}.partial", request)
      puts "[question-executor] asked"

      deadline = Time.now + 10
      sleep 0.05 until Time.now > deadline || File.file?(refused)
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

      File.write(OBSERVED, YAML.dump(%w[component-a component-b].to_h do |component|
        [ component, { "branch" => `git -C #{component} branch --show-current`.strip,
                       "head" => `git -C #{component} rev-parse HEAD`.strip,
                       "file" => File.read("#{component}/app.txt") } ]
      end))

      file = "component-a/app.txt"
      File.write(file, "#{File.read(file)}resumed by the provider\n")
      puts "[resume-executor] applied edit"
      SELECTION.call
      exit 0
    RUBY
    write_executor("resume-executor", DemoWorkspace.with_selection_reporter(source, paths: SELECTED))
  end
end
