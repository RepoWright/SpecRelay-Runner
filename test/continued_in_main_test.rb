# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# A rework or restart that continues a repository whose code is already in main: it is placed at
# that main commit, must be listed in the executor's selection with the verification chosen for
# this round, and is reported at that commit with nothing published. A later change to it reaches
# its historical branch only by an ordinary push.
#
# Every git fact is real. The workspace repository is an ordinary continued target with its own
# open pull request; component-a's recorded head is its main commit, and its branch still holds
# the head its pull request was reviewed at.
class ContinuedInMainTest < Minitest::Test
  def fixture_dir = @fixture_dir ||= fixture_bin
  TASK = "CM-0001"
  BRANCH = TASK
  ROOT_SLUG = "SpecRelay/multi-demo-workspace"
  CHILD_SLUG = "SpecRelay/component-a"
  PR_URLS = {
    ROOT_SLUG => "https://github.com/SpecRelay/multi-demo-workspace/pull/41",
    CHILD_SLUG => "https://github.com/SpecRelay/component-a/pull/42",
    "SpecRelay/component-b" => "https://github.com/SpecRelay/component-b/pull/43",
    "SpecRelay/component-c" => "https://github.com/SpecRelay/component-c/pull/44"
  }.freeze

  def setup
    @built = MultiRepositoryWorkspace.build
    @root = @built.root
    @scratch = Dir.mktmpdir("specrelay-in-main-")
    @bares = { ROOT_SLUG => @built.bares["."], CHILD_SLUG => @built.bares["component-a"],
               "SpecRelay/component-b" => @built.bares["component-b"],
               "SpecRelay/component-c" => @built.bares["component-c"] }
    @bares.each_key { |slug| git(checkout_of(slug), "push", "-q", "origin", "HEAD:refs/heads/main") }
    @recorded = commit_on(ROOT_SLUG, BRANCH, "workspace.txt", "workspace\nrecorded round\n")
    @history = commit_on(CHILD_SLUG, BRANCH, "app.txt", "reviewed round\n")
    @main = main_of(CHILD_SLUG)
  end

  def teardown
    @platform&.stop
    [ @root, @scratch ].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  # --- selection and verification --------------------------------------------------

  def test_a_listed_historical_repository_is_verified_at_main_with_its_commands_and_not_published
    start(env: selecting("." => STATUS, "component-a" => [ [ "sh", "-c", "git rev-parse HEAD > #{verified_path}" ] ]))
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    assert_in_main(result_for(CHILD_SLUG))
    assert_equal @main, File.read(verified_path).strip, "its own command ran at the main commit"
    assert_equal "passed", verification_for("component-a")["status"]
    assert_equal @history, remote_head(CHILD_SLUG), "nothing was pushed to its historical branch"
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
  end

  def test_an_explicit_empty_command_list_is_valid_and_reports_no_verification_found
    start(env: selecting("." => STATUS, "component-a" => []))
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    assert_in_main(result_for(CHILD_SLUG))
    assert_equal "not_found", verification_for("component-a")["status"]
    assert_empty verification_for("component-a")["commands"]
  end

  def test_an_omitted_untouched_historical_repository_refuses_before_verification
    start(env: selecting("." => [ marker_command ]))
    assert_omission_refused
  end

  def test_an_omitted_changed_historical_repository_refuses_before_verification
    start(env: selecting("." => [ marker_command ]).merge("FAKE_EXECUTOR_EDITED" => ".,component-a"))
    assert_omission_refused
  end

  def test_the_same_path_twice_refuses_before_any_command_runs
    start(env: raw_selection([ entry(".", STATUS), entry("component-a", [ marker_command ]), entry("component-a", []) ]))
    assert_selection_refused("are the same repository")
  end

  def test_two_spellings_of_one_repository_refuse_before_any_command_runs
    start(env: raw_selection([ entry(".", STATUS), entry("./component-a", [ marker_command ]), entry("component-a", []) ]))
    assert_selection_refused("are the same repository")
  end

  def test_two_worktrees_of_one_remote_refuse_before_any_command_runs
    mirror = executor("mirroring") { %(system("git", "-C", "component-a", "worktree", "add", "-q", "-f", "../mirror-a", #{BRANCH.inspect}, exception: true)) }
    start(executor: mirror,
          env: raw_selection([ entry(".", STATUS), entry("component-a", [ marker_command ]), entry("mirror-a", []) ]))
    assert_selection_refused("resolve to the same repository #{CHILD_SLUG}")
  end

  def test_an_ordinary_entry_with_no_change_is_still_refused
    start(env: selecting("." => STATUS, "component-a" => [], "component-b" => [ marker_command ]))
    assert_selection_refused('"component-b" reports no change to publish')
  end

  def test_a_verification_that_changes_a_historical_repository_is_refused_as_drift
    start(env: selecting("." => STATUS, "component-a" => [ [ "sh", "-c", "echo drift >> app.txt" ] ]))
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_equal "verification_changed_publishable_state", classification
    assert_includes report_failure, "verification changed the publishable state of component-a"
    assert_equal @history, remote_head(CHILD_SLUG)
    assert_equal @recorded, remote_head(ROOT_SLUG)
  end

  # --- executor instructions -------------------------------------------------------

  def test_restart_instructions_name_the_historical_repository
    start(executor: executor("observing") { "" }, env: OBSERVING)
    run_cli

    assert_includes File.read(prompt_path), HISTORICAL_INSTRUCTION
  end

  def test_rework_instructions_name_the_historical_repository
    start(executor: executor("observing") { "" }, env: OBSERVING, rework: { "repositories" => targets })
    run_cli

    assert_includes File.read(prompt_path), HISTORICAL_INSTRUCTION
  end

  def test_an_ordinary_first_run_has_no_historical_instruction
    start(executor: executor("observing") { "" }, env: OBSERVING, restart: nil)
    run_cli

    refute_includes File.read(prompt_path), "- Exception:"
  end

  # --- a later change through the historical branch --------------------------------

  def test_a_change_creates_an_absent_historical_branch_and_a_new_pull_request
    git(@bares.fetch(CHILD_SLUG), "update-ref", "-d", "refs/heads/#{BRANCH}")
    start(env: changing, seed: [ open_pull_request(ROOT_SLUG) ])
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    child = result_for(CHILD_SLUG)
    assert child["changed"]
    assert_equal remote_head(CHILD_SLUG), child["head_commit"]
    assert ancestor?(CHILD_SLUG, @main, child["head_commit"])
    assert_equal 1, FakeGithub.pr_creates(@gh_log), "only the historical repository needed a new pull request"
  end

  def test_a_change_fast_forwards_a_merged_historical_branch_and_opens_a_fresh_pull_request
    merge_history_into_main
    start(env: changing, seed: [ open_pull_request(ROOT_SLUG), open_pull_request(CHILD_SLUG).merge("state" => "MERGED") ])
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    child = result_for(CHILD_SLUG)
    assert ancestor?(CHILD_SLUG, @history, child["head_commit"]), "the branch was fast-forwarded, not rewritten"
    assert_equal remote_head(CHILD_SLUG), child["head_commit"]
    assert_equal 1, FakeGithub.pr_creates(@gh_log), "a merged pull request is not reused"
  end

  def test_a_change_reuses_the_open_historical_pull_request_after_a_fast_forward
    merge_history_into_main
    start(env: changing, seed: [ open_pull_request(ROOT_SLUG), open_pull_request(CHILD_SLUG) ])
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    assert_equal PR_URLS.fetch(CHILD_SLUG), result_for(CHILD_SLUG)["pull_request_url"]
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
  end

  def test_a_change_to_a_diverged_historical_branch_is_refused_without_force
    start(env: changing)
    _code, output = run_cli

    assert_equal "failed", @platform.last_terminal_result["outcome"], output
    assert_includes result_for(CHILD_SLUG)["publication_error"], "has diverged and SpecRelay never force-pushes"
    assert_equal @history, remote_head(CHILD_SLUG), "the historical branch was not overwritten"
    refute_includes FakeGithub.invocations(@gh_log).join("\n"), "pr create --repo #{CHILD_SLUG}"
  end

  def test_a_pull_request_lookup_that_fails_is_never_read_as_no_pull_request
    merge_history_into_main
    start(env: changing, mode: "list_fails")
    _code, output = run_cli

    assert_equal "failed", @platform.last_terminal_result["outcome"], output
    refute_nil result_for(CHILD_SLUG)["publication_error"]
    assert_nil result_for(CHILD_SLUG)["pull_request_url"]
    assert_equal 0, FakeGithub.pr_creates(@gh_log), "no pull request is created after a failed lookup"
  end

  # --- harness ---------------------------------------------------------------------

  STATUS = [ [ "git", "status", "--short" ] ].freeze
  # The prompt is recorded; nothing is changed or selected, so nothing is published.
  OBSERVING = { "FAKE_EXECUTOR_EDITED" => "", "FAKE_EXECUTOR_SELECTION_SKIP" => "1" }.freeze
  HISTORICAL_INSTRUCTION = "- Exception: this round also continues component-a, already in main. " \
                           "List each of them even if you change nothing there"

  def start(env:, restart: { "repositories" => targets }, rework: nil, executor: nil, seed: nil, mode: "ok")
    use_fixture(fixture_dir, executor || @built.executor, env: { "FAKE_EXECUTOR_EDITED" => "." }.merge(env))
    payload = claim_payload_for(task_id: TASK, root: @root, specification_repository: "component-c",
                                publication: {}, rework: rework, restart: rework ? nil : restart)
    @platform&.stop
    @platform = FakePlatform.new(claim_payload: payload).start
    @gh_dir, @gh_log, = FakeGithub.gh_bin(mode: mode, urls: PR_URLS, bares: @bares,
                                          seed: seed || [ open_pull_request(ROOT_SLUG), open_pull_request(CHILD_SLUG) ])
    @config_path = write_config
  end

  # The workspace repository continues its recorded head; component-a continues main, its pull
  # request kept as history.
  def targets
    [ { "repository_key" => "multi-demo-workspace", "clone_url" => "https://github.com/#{ROOT_SLUG}",
        "branch" => BRANCH, "head_commit" => @recorded, "pull_request_url" => PR_URLS.fetch(ROOT_SLUG) },
      { "repository_key" => "component-a", "clone_url" => "https://github.com/#{CHILD_SLUG}", "branch" => BRANCH,
        "head_commit" => @main, "pull_request_url" => PR_URLS.fetch(CHILD_SLUG), "already_in_main" => true } ]
  end

  def selecting(commands)
    { "FAKE_EXECUTOR_SELECTED" => commands.keys.join(","), "FAKE_EXECUTOR_COMMANDS" => commands.to_json }
  end

  def changing = selecting("." => STATUS, "component-a" => STATUS).merge("FAKE_EXECUTOR_EDITED" => ".,component-a")
  def raw_selection(entries) = { "FAKE_EXECUTOR_SELECTION_JSON" => { "repositories" => entries }.to_json }
  def entry(path, commands) = { "path" => path, "commands" => commands }
  def marker_command = [ "sh", "-c", "touch #{marker_path}" ]

  def open_pull_request(slug)
    { "url" => PR_URLS.fetch(slug), "state" => "OPEN", "headRefName" => BRANCH, "repo" => slug, "headRefOid" => "live" }
  end

  # component-a's reviewed pull request was merged: main now holds its head, which is the main
  # commit the round continues.
  def merge_history_into_main
    git(@bares.fetch(CHILD_SLUG), "update-ref", "refs/heads/main", @history)
    @main = @history
  end

  def assert_in_main(result)
    refute_nil result
    assert_equal false, result["changed"]
    assert_equal [ @main, @main ], result.values_at("base_commit", "head_commit")
    assert_nil result["branch"]
    assert_nil result["pull_request_url"]
    assert_nil result["publication_error"]
  end

  def assert_omission_refused
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_equal "repository_selection_refused", classification
    assert_includes report_failure, "the repository selection leaves out 'component-a', a continued repository " \
                                    "already in main; list it with its verification commands, or \"commands\": [] " \
                                    "when none applies"
    assert_no_effect
  end

  def assert_selection_refused(reason)
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, code, output
    assert_equal "repository_selection_refused", classification
    assert_includes report_failure, reason
    assert_no_effect
  end

  # Nothing verified, reported, pushed or opened.
  def assert_no_effect
    refute_path_exists marker_path, "no verification command ran"
    assert_empty verification_results
    assert_empty results
    assert_equal @history, remote_head(CHILD_SLUG)
    assert_equal @recorded, remote_head(ROOT_SLUG)
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
  end

  # One new commit on +branch+ of +slug+'s remote, written from a separate clone.
  def commit_on(slug, branch, file, content)
    clone = File.join(@scratch, "clone-#{slug.tr('/', '-')}-#{rand(1 << 30)}")
    system("git", "clone", "-q", @bares.fetch(slug), clone, exception: true)
    git(clone, "config", "user.email", "runner@example.test")
    git(clone, "config", "user.name", "Runner Test")
    git(clone, "config", "commit.gpgsign", "false")
    git(clone, "checkout", "-q", "-B", branch, "origin/main")
    File.write(File.join(clone, file), content)
    git(clone, "add", file)
    git(clone, "commit", "-qm", "#{branch}: #{file}")
    git(clone, "push", "-q", "origin", "HEAD:refs/heads/#{branch}")
    git(clone, "rev-parse", "HEAD").strip
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

  # Records the prompt, runs the given body, then the selecting executor.
  def executor(name)
    path = File.join(@scratch, "#{name}-executor")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      prompt = ARGV.last.to_s
      prompt = File.read(prompt) if File.file?(prompt)
      File.write(#{prompt_path.inspect}, prompt)
      #{yield}
      load #{@built.executor.inspect}
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  def checkout_of(slug) = slug == ROOT_SLUG ? @root : File.join(@root, slug.split("/").last)
  def main_of(slug) = git(@bares.fetch(slug), "rev-parse", "refs/heads/main").strip
  def remote_head(slug) = git(@bares.fetch(slug), "rev-parse", "refs/heads/#{BRANCH}").strip
  def ancestor?(slug, candidate, descendant) =
    system("git", "-C", @bares.fetch(slug), "merge-base", "--is-ancestor", candidate, descendant)

  def results = @platform.last_terminal_result["repositories"]
  def result_for(slug) = results.find { |repo| repo["id"] == slug }
  def classification = @platform.last_terminal_result.dig("core", "error_classification")
  def report_failure = YAML.safe_load(report_file("manifest.yml"))["sanitized_failure_details"].to_s
  def verification_results = YAML.safe_load(report_file("manifest.yml")).fetch("repository_verifications", [])
  def verification_for(path) = verification_results.find { |entry| entry["repository_path"] == path }

  def report_file(path)
    Base64.strict_decode64(@platform.last_report.dig(:body, "report", "files")
      .find { |file| file["relative_path"] == path }["content_base64"])
  end

  def prompt_path = File.join(@scratch, "prompt.txt")
  def verified_path = File.join(@scratch, "verified-head.txt")
  def marker_path = File.join(@scratch, "verification-ran")
end
