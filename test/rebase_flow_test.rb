# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# A Rebase run: the ticket's complete accepted package moved onto each repository's current main,
# then verified and published through the ordinary path.
#
# Every git fact is real. Each accepted head exists only on its repository's own bare remote, main
# advances on that remote after acceptance, and preflight blockers are real remote or `gh` state.
class RebaseFlowTest < Minitest::Test
  def fixture_dir = @fixture_dir ||= fixture_bin
  TASK = "RB-0001"
  BRANCH = TASK
  ROOT_SLUG = "SpecRelay/multi-demo-workspace"
  CHILD_SLUG = "SpecRelay/component-a"
  OTHER_SLUG = "SpecRelay/component-b"
  PR_URLS = {
    ROOT_SLUG => "https://github.com/SpecRelay/multi-demo-workspace/pull/31",
    CHILD_SLUG => "https://github.com/SpecRelay/component-a/pull/32",
    OTHER_SLUG => "https://github.com/SpecRelay/component-b/pull/33",
    "SpecRelay/component-c" => "https://github.com/SpecRelay/component-c/pull/34"
  }.freeze
  # The repositories whose main moves on after acceptance. component-c holds the approved
  # specification and stays as published.
  ADVANCING = [ ROOT_SLUG, CHILD_SLUG, OTHER_SLUG ].freeze

  def setup
    @built = MultiRepositoryWorkspace.build
    @root = @built.root
    @scratch = Dir.mktmpdir("specrelay-rebase-")
    @bares = { ROOT_SLUG => @built.bares["."], CHILD_SLUG => @built.bares["component-a"],
               OTHER_SLUG => @built.bares["component-b"], "SpecRelay/component-c" => @built.bares["component-c"] }
    @bares.each_key { |slug| git(checkout_of(slug), "push", "-q", "origin", "HEAD:refs/heads/main") }
    @accepted = { ROOT_SLUG => commit_on(ROOT_SLUG, BRANCH, "accepted.txt", "accepted round\n"),
                  CHILD_SLUG => commit_on(CHILD_SLUG, BRANCH, "accepted.txt", "accepted round\n") }
  end

  def teardown
    @platform&.stop
    [ @root, @scratch ].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  # --- clean rebase in two repositories ------------------------------------

  def test_a_clean_rebase_publishes_both_branches_onto_main_with_the_same_pull_requests
    mains = advance_main_everywhere
    start(executor_env: selecting(".", "component-a"))
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    assert_equal "succeeded", @platform.last_terminal_result["outcome"]
    assert_equal [ CHILD_SLUG, ROOT_SLUG ], results.map { |repo| repo["id"] }.sort
    results.each do |repo|
      slug = repo["id"]
      pushed = remote_head(slug)
      assert_equal pushed, repo["head_commit"]
      assert_equal PR_URLS.fetch(slug), repo["pull_request_url"], "#{slug} keeps its pull request"
      assert_equal mains.fetch(slug), repo["base_commit"], "#{slug}'s base is its main commit"
      assert ancestor?(slug, mains.fetch(slug), pushed), "#{slug} descends from its main commit"
      refute ancestor?(slug, @accepted.fetch(slug), pushed), "#{slug} was rebased, not merged"
      assert_equal "accepted round\n", git(@bares.fetch(slug), "show", "#{pushed}:accepted.txt")
    end
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
    refute(FakeGithub.invocations(@gh_log).any? { |line| line.match?(/\Apr (merge|review)/) }, "no pull request is merged or approved")
    assert_equal 2, verification_results.length, "both repositories were verified"
    [ ROOT_SLUG, CHILD_SLUG ].each do |slug|
      assert(progress.any? { |line| line.include?("Rebase of #{slug} from #{@accepted.fetch(slug)[0, 12]} onto main " \
                                                   "#{mains.fetch(slug)[0, 12]}: clean") }, progress.inspect)
    end
  end

  def test_a_commit_main_already_contains_is_reported_as_dropped
    mains = advance_main_everywhere
    # main received the accepted change of component-a itself, so replaying it leaves nothing.
    contained = commit_on(CHILD_SLUG, "main", "accepted.txt", "accepted round\n")
    start(executor_env: selecting(".", "component-a"))
    run_cli

    line = progress.find { |text| text.include?("Rebase of #{CHILD_SLUG}") }
    assert_includes line, "onto main #{contained[0, 12]}: clean; 1 commit already in main dropped"
    refute_nil mains
  end

  def test_a_repository_left_unrebased_fails_the_proof_and_publishes_nothing
    advance_main_everywhere
    start(executor: undoing_executor, executor_env: selecting(".", "component-a"))
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_equal "rebase_refused", @platform.last_terminal_result.dig("core", "error_classification")
    assert_includes report_failure, "#{CHILD_SLUG} does not descend from main"
    assert_remote_heads_unchanged
  end

  def test_a_repository_missing_from_the_selection_fails_the_proof
    advance_main_everywhere
    start(executor_env: selecting("."))
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes report_failure, "#{CHILD_SLUG} was not reported for verification"
    assert_remote_heads_unchanged
  end

  def test_failed_verification_names_the_repository_and_publishes_nothing
    advance_main_everywhere
    env = selecting(".", "component-a")
    env["FAKE_EXECUTOR_COMMANDS"] = { "." => [ [ "git", "status", "--short" ] ], "component-a" => [ [ "bin/verify" ] ] }.to_json
    start(executor_env: env)
    run_cli

    assert_equal "failed", @platform.last_terminal_result["outcome"]
    assert_equal "verification failed in component-a", report_failure
    assert_remote_heads_unchanged
  end

  # --- conflicts --------------------------------------------------------------

  def test_a_conflict_is_handed_to_the_executor_resolved_verified_and_published
    mains = advance_main_everywhere
    commit_on(CHILD_SLUG, "main", "accepted.txt", "fixed on main\n")
    mains[CHILD_SLUG] = git(@bares.fetch(CHILD_SLUG), "rev-parse", "refs/heads/main").strip
    start(executor: resolving_executor, executor_env: selecting(".", "component-a"))
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    prompt = File.read(prompt_path)
    assert_includes prompt, "## Rebase onto main"
    assert_includes prompt, "`#{CHILD_SLUG}` (#{PR_URLS.fetch(CHILD_SLUG)}), main commit `#{mains.fetch(CHILD_SLUG)}`: " \
                            "conflicts in `accepted.txt`."
    assert_includes prompt, "`#{ROOT_SLUG}` (#{PR_URLS.fetch(ROOT_SLUG)}), main commit `#{mains.fetch(ROOT_SLUG)}`: rebased cleanly"
    assert(progress.any? { |line| line.include?("Rebase of #{CHILD_SLUG}") && line.include?("conflicts in accepted.txt; handed to the executor") })
    assert(progress.any? { |line| line.include?("Rebase of #{CHILD_SLUG}") && line.include?("conflicting paths resolved") })

    pushed = remote_head(CHILD_SLUG)
    assert ancestor?(CHILD_SLUG, mains.fetch(CHILD_SLUG), pushed)
    assert_equal "resolved\n", git(@bares.fetch(CHILD_SLUG), "show", "#{pushed}:accepted.txt")
    assert_equal 2, verification_results.length
  end

  def test_a_conflict_that_needs_a_decision_asks_instead_of_publishing
    advance_main_everywhere
    commit_on(CHILD_SLUG, "main", "accepted.txt", "fixed on main\n")
    start(executor: asking_executor, executor_env: selecting(".", "component-a").merge("FAKE_EXECUTOR_QUESTION_JSON" => QUESTION.to_json))
    # The approved specification is published, as it is for a real run, so component-c is unchanged.
    git(File.join(@root, "component-c"), "push", "-q", "origin", "HEAD:refs/heads/main")
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    assert_equal 1, @platform.executor_questions.length, "the conflict became a question"
    assert_empty @platform.requests_to("/api/runner/reports"), "nothing was reported or published"
    assert_remote_heads_unchanged
  end

  # --- preflight ----------------------------------------------------------------

  def test_every_blocked_pull_request_is_named_and_nothing_is_rebased_or_pushed
    @accepted[OTHER_SLUG] = commit_on(OTHER_SLUG, BRANCH, "accepted.txt", "accepted round\n")
    moved = commit_on(CHILD_SLUG, BRANCH, "late.txt", "pushed after acceptance\n")
    advance_main_everywhere
    seed = open_pull_requests(ROOT_SLUG, CHILD_SLUG, OTHER_SLUG).map do |row|
      row["repo"] == ROOT_SLUG ? row.merge("state" => "CLOSED") : row
    end
    start(slugs: [ ROOT_SLUG, CHILD_SLUG, OTHER_SLUG ], seed: seed, fail_view_for: OTHER_SLUG,
          executor: observing_executor)
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    failure = report_failure
    assert_includes failure, "3 of 3 accepted pull requests block this run"
    assert_includes failure, "- #{ROOT_SLUG} #{PR_URLS.fetch(ROOT_SLUG)}: the accepted pull request of '#{ROOT_SLUG}' is closed, not open"
    assert_includes failure, "- #{CHILD_SLUG} #{PR_URLS.fetch(CHILD_SLUG)}: the pull-request head of '#{CHILD_SLUG}' moved " \
                             "from #{@accepted.fetch(CHILD_SLUG)[0, 12]} to #{moved[0, 12]}"
    assert_includes failure, "- #{OTHER_SLUG} #{PR_URLS.fetch(OTHER_SLUG)}: SpecRelay could not read the accepted pull request"
    assert_preflight_stopped
    assert_equal moved, remote_head(CHILD_SLUG)
  end

  def test_a_single_merged_pull_request_stops_the_run
    advance_main_everywhere
    seed = open_pull_requests(ROOT_SLUG, CHILD_SLUG).map do |row|
      row["repo"] == CHILD_SLUG ? row.merge("state" => "MERGED") : row
    end
    start(seed: seed, executor: observing_executor)
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes report_failure, "1 of 2 accepted pull requests block this run"
    assert_includes report_failure, "the accepted pull request of '#{CHILD_SLUG}' is merged, not open"
    assert_preflight_stopped
  end

  def test_a_repository_that_cannot_be_located_does_not_stop_the_others_being_inspected
    absent = { "repository" => "SpecRelay/component-z", "clone_url" => "https://github.com/SpecRelay/component-z",
               "branch" => BRANCH, "head_commit" => "c" * 40,
               "pull_request_url" => "https://github.com/SpecRelay/component-z/pull/35" }
    seed = open_pull_requests(ROOT_SLUG, CHILD_SLUG).map do |row|
      row["repo"] == CHILD_SLUG ? row.merge("state" => "CLOSED") : row
    end
    start(seed: seed, extra: [ absent ], executor: observing_executor)
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_includes report_failure, "2 of 3 accepted pull requests block this run"
    assert_includes report_failure, "- SpecRelay/component-z https://github.com/SpecRelay/component-z/pull/35:"
    assert_includes report_failure, "the accepted pull request of '#{CHILD_SLUG}' is closed, not open"
    assert_preflight_stopped
  end

  # --- publication ---------------------------------------------------------------

  def test_a_branch_moved_after_preflight_is_not_overwritten
    advance_main_everywhere
    start(executor: interfering_executor, executor_env: selecting(".", "component-a"))
    _code, output = run_cli

    assert_equal "failed", @platform.last_terminal_result["outcome"], output
    child = results.find { |repo| repo["id"] == CHILD_SLUG }
    assert_includes child["publication_error"], "no longer holds the accepted head #{@accepted.fetch(CHILD_SLUG)[0, 12]}"
    assert_equal File.read(interference_path).strip, remote_head(CHILD_SLUG), "the moved branch was not overwritten"
    assert_equal 1, push_attempts(output, CHILD_SLUG), "no other push followed the refusal"
  end

  def test_a_marker_on_a_rework_round_is_inert
    payload = { "rebase" => true, "previous_accepted_package" => package_block([ ROOT_SLUG ]),
                "rework" => { "repositories" => [] } }

    assert_nil SpecrelayRunner::Rebase.for(payload)
    assert_nil SpecrelayRunner::Rebase.lease(payload, ROOT_SLUG, BRANCH)
    rebase = payload.except("rework")
    assert_equal @accepted.fetch(ROOT_SLUG), SpecrelayRunner::Rebase.lease(rebase, ROOT_SLUG.downcase, BRANCH)
    assert_nil SpecrelayRunner::Rebase.lease(rebase, ROOT_SLUG, "main"), "only the accepted branch is leased"
  end

  def test_a_rebase_never_publishes_onto_the_default_branch
    clone = File.join(@scratch, "default-branch")
    system("git", "clone", "-q", @bares.fetch(ROOT_SLUG), clone, exception: true)
    before = git(@bares.fetch(ROOT_SLUG), "rev-parse", "refs/heads/main").strip
    payload = claim_payload_for(task_id: TASK, publication: {})
                .merge("rebase" => true, "previous_accepted_package" => package_block([ ROOT_SLUG ]))
    payload["previous_accepted_package"]["implementation_pull_requests"].first["branch"] = "main"
    repository = SpecrelayRunner::Workspace::Repository.new(
      id: ROOT_SLUG, relative_path: ".", path: clone, clone_url: "https://github.com/#{ROOT_SLUG}",
      default_branch: "main", branch: "main", base_commit: before, changed_files: [ "workspace.txt" ], diff: ""
    )
    result = SpecrelayRunner::Publication.new(payload: payload, repository: repository, io: StringIO.new).call

    assert_includes result.publication_error, "refusing to publish onto main"
    assert_equal before, git(@bares.fetch(ROOT_SLUG), "rev-parse", "refs/heads/main").strip
  end

  # --- harness ---------------------------------------------------------------------

  QUESTION = {
    "questions" => [ { "prompt" => "Which side of the accepted.txt conflict should win?" } ],
    "continuation_context" => {
      "progress" => "component-a conflicts", "changed_areas" => "accepted.txt",
      "why_it_matters" => "the resolution changes behaviour", "next_step" => "resolve the conflict",
      "remaining_work" => "verification", "do_not_repeat" => "the clean rebase"
    }
  }.freeze

  def start(slugs: [ ROOT_SLUG, CHILD_SLUG ], executor: nil, executor_env: {}, seed: nil, fail_view_for: nil,
            extra: [])
    use_fixture(fixture_dir, executor || @built.executor, env: executor_env)
    payload = claim_payload_for(task_id: TASK, root: @root, specification_repository: "component-c",
                                publication: {})
    payload = payload.merge("rebase" => true, "previous_accepted_package" => package_block(slugs, extra: extra))
    @platform&.stop
    @platform = FakePlatform.new(claim_payload: payload).start
    @gh_dir, @gh_log, = FakeGithub.gh_bin(fail_view_for: fail_view_for, urls: PR_URLS, bares: @bares,
                                          seed: seed || open_pull_requests(*slugs))
    @config_path = write_config
  end

  def package_block(slugs, extra: [])
    { "package_id" => "art_accepted", "checksum" => "e" * 64, "source_run_id" => "run_accepted",
      "approved_specification" => { "reference" => "https://github.com/SpecRelay/specs/pull/7", "digest" => "f" * 64 },
      "implementation_pull_requests" => slugs.map do |slug|
        { "repository" => slug, "clone_url" => "https://github.com/#{slug}", "branch" => BRANCH,
          "head_commit" => @accepted.fetch(slug), "pull_request_url" => PR_URLS.fetch(slug) }
      end + extra }
  end

  def open_pull_requests(*slugs)
    slugs.map do |slug|
      { "url" => PR_URLS.fetch(slug), "state" => "OPEN", "headRefName" => BRANCH, "repo" => slug, "headRefOid" => "live" }
    end
  end

  # Verified with a command that passes on any tree, so verification is about where it ran.
  def selecting(*paths)
    { "FAKE_EXECUTOR_EDITED" => "", "FAKE_EXECUTOR_SELECTED" => paths.join(","),
      "FAKE_EXECUTOR_COMMANDS" => paths.to_h { |path| [ path, [ [ "git", "status", "--short" ] ] ] }.to_json }
  end

  # One new commit on +branch+ of +slug+'s remote, written from a separate clone.
  def commit_on(slug, branch, file, content)
    clone = File.join(@scratch, "clone-#{slug.tr('/', '-')}-#{rand(1 << 30)}")
    system("git", "clone", "-q", @bares.fetch(slug), clone, exception: true)
    git(clone, "config", "user.email", "runner@example.test")
    git(clone, "config", "user.name", "Runner Test")
    git(clone, "config", "commit.gpgsign", "false")
    exists = system("git", "-C", clone, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/#{branch}", out: File::NULL)
    git(clone, "checkout", "-q", "-B", branch, exists ? "origin/#{branch}" : "origin/main")
    File.write(File.join(clone, file), content)
    git(clone, "add", file)
    git(clone, "commit", "-qm", "#{branch}: #{file}")
    git(clone, "push", "-q", "origin", "HEAD:refs/heads/#{branch}")
    git(clone, "rev-parse", "HEAD").strip
  end

  # main moves on in every repository after acceptance, in a file the accepted round never touched.
  def advance_main_everywhere
    ADVANCING.to_h { |slug| [ slug, commit_on(slug, "main", "main-fix.txt", "fixed on main\n") ] }
  end

  def write_config
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
        tiny-demo-workspace: #{@root}
    YAML
    path
  end

  def run_cli
    io = StringIO.new
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => "#{fixture_dir}:#{@gh_dir}:#{ENV['PATH']}",
            "HOME" => ENV["HOME"].to_s }
    code = SpecrelayRunner::CLI.run(%W[claim-once --config #{@config_path}], out: io, err: io, env: env)
    [ code, io.string ]
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  def checkout_of(slug)
    return @root if slug == ROOT_SLUG

    File.join(@root, slug.split("/").last)
  end

  def remote_head(slug) = git(@bares.fetch(slug), "rev-parse", "refs/heads/#{BRANCH}").strip
  def ancestor?(slug, candidate, descendant) =
    system("git", "-C", @bares.fetch(slug), "merge-base", "--is-ancestor", candidate, descendant)

  def results = @platform.last_terminal_result["repositories"]
  def progress = @platform.protocol_events.select { |event| event["event_type"] == "core.progress" }.map { |event| event["public_summary"] }
  def report_failure = YAML.safe_load(report_file("manifest.yml"))["sanitized_failure_details"].to_s

  def verification_results
    YAML.safe_load(report_file("manifest.yml")).fetch("repository_verifications", [])
  end

  def report_file(path)
    Base64.strict_decode64(@platform.last_report.dig(:body, "report", "files")
      .find { |file| file["relative_path"] == path }["content_base64"])
  end

  def push_attempts(output, slug) = output.scan(/Publication blocked for #{Regexp.escape(slug)}/).length

  def assert_remote_heads_unchanged
    @accepted.each { |slug, head| assert_equal head, remote_head(slug), "#{slug} must not have been pushed" }
  end

  # A preflight stop ends the run as failed — a report, no claim release — before any base is
  # pinned, any branch is moved, any provider starts or anything is pushed.
  def assert_preflight_stopped
    assert_equal "failed", @platform.last_terminal_result["outcome"]
    assert_equal "rebase_refused", @platform.last_terminal_result.dig("core", "error_classification")
    assert_empty @platform.requests_to("/api/runner/claim_releases"), "the run is not left claimable"
    assert_empty @platform.requests_to("/api/runner/initial_repository_bases"), "nothing was rebased"
    refute File.exist?(prompt_path), "the executor never started"
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
    @accepted.each do |slug, head|
      next if slug == CHILD_SLUG && remote_head(slug) != head

      assert_equal head, remote_head(slug), "#{slug} must not have been pushed"
    end
  end

  def prompt_path = File.join(@scratch, "prompt.txt")
  def interference_path = File.join(@scratch, "interference.txt")

  def observing_executor
    executor("observing") { "" }
  end

  # Undoes the runner's rebase of component-a, then reports both repositories.
  def undoing_executor
    executor("undoing") { %(system("git", "-C", "component-a", "reset", "-q", "--hard", "ORIG_HEAD", exception: true)) }
  end

  # Rebases component-a itself, resolving the conflict, as the prompt asks.
  def resolving_executor
    executor("resolving") { <<~'RUBY' }
      main = prompt[/`SpecRelay\/component-a` \([^)]*\), main commit `(\h{40})`: conflicts/, 1]
      abort "no conflicting repository in the prompt" if main.nil?
      Dir.chdir("component-a") do
        system("git", "rebase", "-q", main, out: File::NULL, err: File::NULL)
        File.write("accepted.txt", "resolved\n")
        system("git", "add", "accepted.txt", exception: true)
        system({ "GIT_EDITOR" => "true" }, "git", "rebase", "--continue", exception: true, out: File::NULL)
      end
    RUBY
  end

  # Reports both repositories, then asks the Product Owner instead of choosing a side.
  def asking_executor
    executor("asking") { <<~'RUBY' }
      require "json"
      selection = prompt[%r{`([^`]*/changed-repositories\.json)`}, 1]
      File.write(selection, JSON.generate("repositories" => [ { "path" => ".", "commands" => [] },
                                                              { "path" => "component-a", "commands" => [] } ]))
      request = prompt[%r{`([^`]*/question-request\.json)`}, 1]
      File.write("#{request}.partial", ENV.fetch("FAKE_EXECUTOR_QUESTION_JSON"))
      File.rename("#{request}.partial", request)
      deadline = Time.now + 5
      sleep 0.05 until Time.now > deadline || File.file?(File.join(File.dirname(request), "question-answer.json"))
      exit 0
    RUBY
  end

  # Somebody pushes to component-a's pull-request branch after preflight.
  def interfering_executor
    path = interference_path
    executor("interfering") { <<~RUBY }
      clone = Dir.mktmpdir("interfering-")
      system("git", "clone", "-q", #{@bares.fetch(CHILD_SLUG).inspect}, clone, exception: true)
      Dir.chdir(clone) do
        system("git", "checkout", "-q", #{BRANCH.inspect}, exception: true)
        File.write("late.txt", "somebody else\\n")
        system("git", "add", "late.txt", exception: true)
        system("git", "-c", "user.name=X", "-c", "user.email=x@example.test", "commit", "-qm", "late", exception: true)
        system("git", "push", "-q", "origin", "HEAD:refs/heads/#{BRANCH}", exception: true)
        File.write(#{path.inspect}, `git rev-parse HEAD`)
      end
    RUBY
  end

  # Records the prompt, runs the given body, then runs the selecting executor's own logic.
  def executor(name)
    path = File.join(@scratch, "#{name}-executor")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      require "tmpdir"
      prompt = ARGV.last.to_s
      prompt = File.read(prompt) if File.file?(prompt)
      File.write(#{prompt_path.inspect}, prompt)
      #{yield}
      load #{@built.executor.inspect}
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end
end
