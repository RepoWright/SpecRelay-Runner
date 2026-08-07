# frozen_string_literal: true

require_relative "test_helper"

# MVP-0014 proof for the STANDALONE runner's GitHub publication path, against a
# REAL bare git remote and a real `gh` argv boundary (a scriptable fake binary on
# PATH). Every assertion below is an observable fact — a ref that actually exists
# in the remote, an argv the CLI actually issued — not a stubbed return value.
#
# Covered: changed detection, safe commit creation, the Platform-assigned branch,
# push success, draft pull-request create and reuse (idempotency, no duplicate PR),
# unchanged repositories, read-only repositories, publication failure (push
# rejection and gh unavailable/failing), the publication.* events, and secret
# redaction in publication output.
class PublicationFlowTest < Minitest::Test
  TASK = "MAPIAI-901"
  BRANCH = "specrelay/#{TASK}"

  def setup
    @root, @executor = DemoWorkspace.build
    @bare = FakeGithub.add_remote(@root)
    # `bare:` lets the fake resolve real head shas, so headRefOid is a fact.
    @gh_dir, @gh_log, = FakeGithub.gh_bin(bare: @bare)
  end

  def teardown
    remove_emfile_injection
    @platform&.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # --- harness -------------------------------------------------------------

  def start(publication: {}, executor_command: nil)
    payload = claim_payload_for(task_id: TASK, executor_command: executor_command || @executor,
                                publication: publication)
    @platform = FakePlatform.new(claim_payload: payload).start
    @config_path = write_config
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

  # `gh` is resolved from PATH, so the fake binary's directory comes first. HOME is
  # forwarded because git needs it for config resolution.
  def run_cli(extra_env = {}, gh_dir: @gh_dir)
    io = StringIO.new
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
            "PATH" => "#{gh_dir}:#{ENV['PATH']}",
            "HOME" => ENV["HOME"].to_s }.merge(extra_env)
    code = SpecrelayRunner::CLI.run(%W[claim-once --config #{@config_path}], out: io, err: io, env: env)
    [ code, io.string ]
  end

  def repository_result = @platform.last_terminal_result["repositories"].first
  def event_types = @platform.protocol_events.map { |event| event["event_type"] }

  # --- successful publication ---------------------------------------------

  def test_changed_repository_is_committed_pushed_and_gets_a_draft_pull_request
    start
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    repo = repository_result
    assert repo["changed"], "the executor changed the repository"
    assert_equal BRANCH, repo["branch"], "the runner must publish the Platform-assigned branch"
    assert_match(/\A[0-9a-f]{40,64}\z/, repo["base_commit"])
    assert_match(/\A[0-9a-f]{40,64}\z/, repo["head_commit"])
    refute_equal repo["base_commit"], repo["head_commit"], "publication must create a real commit"
    assert_equal "https://github.com/SpecRelay/tiny-demo-workspace/pull/7", repo["pull_request_url"]
    assert_nil repo["publication_error"]

    # The branch really exists in the remote, at exactly the reported head commit.
    branches = FakeGithub.remote_branches(@bare)
    assert_equal repo["head_commit"], branches[BRANCH], "remote #{BRANCH} must point at the reported head"
    refute_includes branches.keys, "main", "the default branch must never be pushed"
  end

  def test_publication_events_are_emitted_in_order
    start
    run_cli
    types = event_types
    assert_includes types, "publication.started"
    assert_includes types, "publication.completed"
    assert_operator types.index("publication.started"), :<, types.index("publication.completed")
    assert_operator types.index("verification.completed"), :<, types.index("publication.started")
    assert_equal "attempt.completed", types.last, "publication must precede finalization"

    sequences = @platform.protocol_events.map { |event| event["sequence"] }
    assert_equal (1..sequences.max).to_a, sequences.uniq.sort, "the sequence must stay dense"
  end

  def test_pull_request_body_and_commit_carry_no_secret
    start
    _code, output = run_cli
    # The fake executor prints a secret-shaped token; it must not survive into any
    # runner output, and the commit subject must identify the task, not the prompt.
    refute_match(/sk-live-DO-NOT-LEAK/, output)
    refute_match(/sk-live-DO-NOT-LEAK/, FakeGithub.invocations(@gh_log).join("\n"))

    subject = FakeGithub.git(@bare, "log", "-1", "--format=%s", BRANCH).strip
    assert_equal "#{TASK}: SpecRelay automated execution output", subject
    body = FakeGithub.git(@bare, "log", "-1", "--format=%b", BRANCH)
    refute_match(/sk-live-DO-NOT-LEAK/, body)
    assert_match(/run_test123/, body, "the commit must reference the SpecRelay run")
  end

  # --- idempotency ---------------------------------------------------------

  def test_republishing_reuses_the_same_branch_and_pull_request
    start
    run_cli
    first = repository_result
    assert_equal 1, FakeGithub.pr_creates(@gh_log)

    # Replay the publication step for the same run/repository/branch, as a network or
    # API retry would. The tree is already committed and the remote already has the
    # commit, so every step must be a safe no-op that reuses what exists.
    second = republish(first)

    assert_equal first["branch"], second.branch
    assert_equal first["pull_request_url"], second.pull_request_url
    assert_equal first["head_commit"], second.head_commit, "the retry must reuse the same commit"
    assert_nil second.publication_error
    assert_equal 1, FakeGithub.pr_creates(@gh_log),
                 "a retry must reuse the existing pull request, never create a second one"
    assert_equal [ BRANCH ], FakeGithub.remote_branches(@bare).keys
  end

  # Re-run publication against the worktree the first attempt left behind, with the
  # same observed changes the first publication saw.
  def republish(first, gh_dir: @gh_dir)
    worktree = File.join(@root, ".runs", "worktrees", TASK)
    changes = SpecrelayRunner::Workspace::Changes.new(
      changed_files: [ "demo-app/index.html" ], diff: "", head_commit: first["head_commit"]
    )
    SpecrelayRunner::Publication.new(
      payload: claim_payload_for(task_id: TASK, executor_command: @executor, publication: {}),
      worktree_path: worktree, changes: changes, base_commit: first["base_commit"],
      test: { command: "./bin/test", exit_code: 0 },
      env: { "PATH" => "#{gh_dir}:#{ENV['PATH']}", "HOME" => ENV["HOME"].to_s }, io: StringIO.new
    ).call.first
  end

  # --- unchanged and read-only --------------------------------------------

  def test_unchanged_repository_is_reported_without_publishing
    # An executor that changes nothing: the heading is already the expected value.
    FileUtils.rm_rf(@root)
    @root, @executor = DemoWorkspace.build(initial_heading: "Hello SpecRelay Demo")
    @bare = FakeGithub.add_remote(@root)
    start
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    repo = repository_result
    refute repo["changed"], "nothing changed, so changed must be false"
    assert_nil repo["head_commit"], "an unchanged repository must not claim a head commit"
    assert_nil repo["branch"]
    assert_nil repo["pull_request_url"]
    assert_nil repo["publication_error"]
    assert_empty FakeGithub.remote_branches(@bare), "no branch may be pushed for an unchanged repository"
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
    refute_includes event_types, "publication.started", "publication is not attempted with no changes"
  end

  # CR-001 criterion 3. A read-only repository is a POLICY outcome, not a failure.
  # This asserts the TERMINAL OUTCOME as well as the repository fields — omitting that
  # assertion is what hid review-001 finding 3 from the suite.
  def test_changed_read_only_repository_is_reported_without_failing_the_run
    start(publication: { access: "read" })
    code, output = run_cli

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    terminal = @platform.last_terminal_result
    assert_equal "succeeded", terminal["outcome"],
                 "a read-only repository must not fail a run whose executor and tests succeeded"
    assert_nil terminal.dig("core", "error_classification")
    assert_equal 0, terminal.dig("core", "exit_code")

    repo = repository_result
    assert repo["changed"], "the change is still reported truthfully"
    assert_nil repo["branch"]
    assert_nil repo["pull_request_url"]
    assert_nil repo["publication_error"], "not attempted by policy is not a publication failure"
    assert_match(/read-only/, repo["publication_skipped_reason"])
    assert_empty FakeGithub.remote_branches(@bare), "a read-only repository must never be pushed"
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
  end

  # --- CR-001: the publication lookup must fail closed ---------------------

  # CR-001 criterion 1. A failing `gh pr list` is NOT "no pull request exists".
  def test_failing_pull_request_lookup_never_creates_a_pull_request
    start
    gh_dir, gh_log, = FakeGithub.gh_bin(mode: "list_fails", bare: @bare)
    run_cli({}, gh_dir: gh_dir)

    terminal = @platform.last_terminal_result
    assert_equal "failed", terminal["outcome"], "an undetermined pull request must fail the attempt"
    assert_equal "publication_failed", terminal.dig("core", "error_classification")
    repo = repository_result
    assert_equal BRANCH, repo["branch"], "the branch is still pushed"
    assert_nil repo["pull_request_url"]
    assert_match(/could not determine whether a pull request already exists/, repo["publication_error"])
    assert_match(/release and re-run/, repo["publication_error"], "the reason must name a next step")
    assert_equal 0, FakeGithub.pr_creates(gh_log),
                 "a lookup failure must never fall through to creating a pull request"
  end

  # CR-001 criterion 1, second half: after the transient error clears, the retry
  # reuses the pull request instead of opening a second one.
  def test_retry_after_a_transient_lookup_failure_creates_exactly_one_pull_request
    start
    gh_dir, gh_log, = FakeGithub.gh_bin(mode: "list_fails_once", bare: @bare)
    run_cli({}, gh_dir: gh_dir)
    assert_equal 0, FakeGithub.pr_creates(gh_log), "attempt 1 fails closed without creating"

    first = repository_result
    second = republish(first, gh_dir: gh_dir)   # the lookup now succeeds

    assert_nil second.publication_error, "the retry must succeed once the lookup works"
    assert_equal BRANCH, second.branch
    refute_nil second.pull_request_url
    assert_equal 1, FakeGithub.pr_creates(gh_log), "exactly one pull request for one run branch"

    third = republish(first, gh_dir: gh_dir)    # and a further retry reuses it
    assert_equal second.pull_request_url, third.pull_request_url
    assert_equal 1, FakeGithub.pr_creates(gh_log), "a further retry must reuse, never create"
    assert_equal [ BRANCH ], FakeGithub.remote_branches(@bare).keys
  end

  def test_unreadable_pull_request_list_fails_closed
    start
    gh_dir, gh_log, = FakeGithub.gh_bin(mode: "list_garbage", bare: @bare)
    run_cli({}, gh_dir: gh_dir)

    repo = repository_result
    assert_nil repo["pull_request_url"]
    assert_match(/could not read the pull-request list/, repo["publication_error"])
    assert_equal 0, FakeGithub.pr_creates(gh_log)
  end

  # CR-001 criterion 2. A closed or merged pull request on the same deterministic
  # branch must never be reported as this round's output.
  def test_merged_pull_request_on_the_same_branch_is_never_reused
    assert_not_reused("MERGED", "https://github.com/SpecRelay/tiny-demo-workspace/pull/3")
  end

  def test_closed_pull_request_on_the_same_branch_is_never_reused
    assert_not_reused("CLOSED", "https://github.com/SpecRelay/tiny-demo-workspace/pull/4")
  end

  # The stale pull request is seeded with a foreign head sha, exactly as a previous
  # round's merged pull request would carry.
  def assert_not_reused(state, stale_url)
    start
    seed = [ { "url" => stale_url, "state" => state, "headRefName" => BRANCH,
               "headRefOid" => "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" } ]
    fresh_url = "https://github.com/SpecRelay/tiny-demo-workspace/pull/9"
    gh_dir, gh_log, = FakeGithub.gh_bin(mode: "ok", pull_request_url: fresh_url, bare: @bare, seed: seed)
    code, output = run_cli({}, gh_dir: gh_dir)

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    repo = repository_result
    refute_equal stale_url, repo["pull_request_url"],
                 "a #{state} pull request does not track the branch and must not be reported"
    assert_equal fresh_url, repo["pull_request_url"], "a fresh pull request must be opened instead"
    assert_equal 1, FakeGithub.pr_creates(gh_log)
    # And the runner must have asked only for OPEN pull requests.
    assert(FakeGithub.invocations(gh_log).any? { |line| line.include?("--state open") },
           "reuse must be restricted to open pull requests")
    refute(FakeGithub.invocations(gh_log).any? { |line| line.include?("--state all") })
  end

  # CR-002 criteria 1 and 4. An OPEN pull request already exists for the assigned branch
  # — an earlier attempt opened it and lost its lease, or a second round is running on
  # the same Jira key — and this run then COMMITS and pushes. The pull request tracks the
  # branch, so its head becomes exactly the commit we pushed and it must be reused.
  #
  # This drives the full Execution path deliberately: `changes.head_commit` is then the
  # PRE-commit head that real execution produces, which differs from the pushed commit.
  # The `republish` helper below cannot catch this class because it hand-builds Changes
  # with the POST-commit head — the gap that let CR-001's guard ship comparing the wrong
  # commit (review-003 finding 1). The fake runs in its faithful `headRefOid: "live"`
  # mode, refreshed from the bare remote, which is how GitHub actually tracks a tip.
  def test_existing_open_pull_request_is_reused_when_this_run_creates_the_commit
    start
    existing = "https://github.com/SpecRelay/tiny-demo-workspace/pull/11"
    seed = [ { "url" => existing, "state" => "OPEN", "headRefName" => BRANCH,
               "headRefOid" => "live" } ]
    gh_dir, gh_log, = FakeGithub.gh_bin(mode: "ok", bare: @bare, seed: seed)

    code, output = run_cli({}, gh_dir: gh_dir)

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    terminal = @platform.last_terminal_result
    assert_equal "succeeded", terminal["outcome"],
                 "reusing the pull request that tracks our branch is a success, not a failure"
    assert_nil terminal.dig("core", "error_classification")

    repo = repository_result
    assert_nil repo["publication_error"]
    assert_equal existing, repo["pull_request_url"], "the existing open pull request must be reused"
    assert_equal BRANCH, repo["branch"]
    assert_equal 0, FakeGithub.pr_creates(gh_log), "reuse must never create a second pull request"

    # The commit really was created by this run, so the pre-commit head the guard used to
    # compare against genuinely differs from the pushed head.
    assert_equal repo["head_commit"], FakeGithub.remote_branches(@bare)[BRANCH],
                 "the reported head must be the commit actually on the remote"
    refute_equal repo["base_commit"], repo["head_commit"],
                 "this scenario only bites when publication creates a commit"
  end

  # --- CR-003: the reuse predicate, enumerated ------------------------------

  # CR-003 criteria 2 and 3. THE table. Four consecutive rounds produced four fail-opens
  # in this one predicate because each was fixed at its reported instance while the rest of
  # the input space stayed unexercised. Every row of `reuse_decision` is asserted here
  # against a REAL commit chain — `ancestor?` really shells out to `git merge-base
  # --is-ancestor` — so a synthetic string cannot make a row pass vacuously.
  #
  # The chain, built once below:
  #
  #     base ── mid ── tip          (linear history)
  #        └──── sibling            (a real divergent commit, not an unknown object)
  #
  # If a new input class is ever discovered it belongs in this table, not in a new branch.
  def test_the_reuse_decision_table_holds_for_every_row
    chain = build_commit_chain
    publication = predicate_publication(chain[:repo])

    #   reported             pushed         expected decision       reuse?  label
    rows = [
      [ chain[:tip],         chain[:tip],   :head_matches,          true,  "equal" ],
      [ chain[:mid],         chain[:tip],   :reported_is_ancestor,  true,  "reported is ancestor of pushed (GitHub lag)" ],
      [ chain[:tip],         chain[:mid],   :reported_head_ahead,   false, "pushed is ancestor of reported (PR ahead of us)" ],
      [ chain[:sibling],     chain[:tip],   :heads_diverged,        false, "real divergent sibling" ],
      [ "d" * 40,            chain[:tip],   :heads_diverged,        false, "reported is an unknown object" ],
      [ "",                  chain[:tip],   :reported_head_unknown, false, "reported empty — the R4-F1 row" ],
      [ chain[:tip],         "",            :pushed_head_unknown,   false, "pushed empty" ],
      [ "",                  "",            :pushed_head_unknown,   false, "both empty" ]
    ]
    assert_equal 8, rows.length, "CR-003 enumerates eight rows; assert all of them"

    rows.each do |reported, pushed, expected_decision, reusable, label|
      decision = publication.send(:reuse_decision, reported.to_s, pushed.to_s)
      assert_equal expected_decision, decision, "row #{label.inspect}: wrong decision"
      assert_equal reusable,
                   SpecrelayRunner::Publication::REUSABLE_DECISIONS.include?(decision),
                   "row #{label.inspect}: wrong reuse verdict"
    end

    # Exactly two decisions may reuse; anything else added later must be refused by
    # default rather than silently joining the reusable set. `reusable` now derives its
    # behaviour from this same constant (R5-F2), so pinning it here pins production.
    assert_equal %i[head_matches reported_is_ancestor],
                 SpecrelayRunner::Publication::REUSABLE_DECISIONS
    assert_equal 6, rows.map { |r| r[2] }.uniq.length, "all six decision values are exercised"
  ensure
    FileUtils.remove_entry(chain[:repo]) if chain && File.directory?(chain[:repo])
  end

  # review-005 R5-F1. The refusal for a pull request that is AHEAD of us must not repeat
  # the diverged wording: git has just proven the pull request contains our commit, so
  # "may not contain this run's commit" states the opposite of the measured fact. The
  # decision stays refuse; only the explanation is under test here.
  def test_a_pull_request_ahead_of_this_run_is_refused_with_a_truthful_reason
    chain = build_commit_chain
    publication = predicate_publication(chain[:repo])
    entries = [ { "url" => "https://github.com/SpecRelay/tiny-demo-workspace/pull/71",
                  "state" => "OPEN", "headRefName" => BRANCH, "headRefOid" => chain[:tip] } ]

    lookup = publication.send(:reusable, entries, BRANCH, chain[:mid])

    assert_nil lookup.url, "a pull request carrying unvalidated commits is not this run's output"
    reason = lookup.error
    refute_match(/may not contain this run's commit/, reason,
                 "the ancestor relation proves containment; the message must not deny it")
    refute_match(/diverged/i, reason, "one head strictly contains the other — nothing diverged")
    assert_match(/contains this run's commit #{chain[:mid]}/, reason)
    assert_match(/1 later commit\b/, reason, "the extra commit is counted, not left vague")
    assert_match(/git log #{chain[:mid]}\.\.#{chain[:tip]}/, reason, "names the commits to review")
    assert_match(/release and re-run the task/, reason,
                 "R5-F1: this refusal offered no next step, unlike the other two")
  ensure
    FileUtils.remove_entry(chain[:repo]) if chain && File.directory?(chain[:repo])
  end

  # The count is decoration; losing it must not lose the refusal. A repository where the
  # rev-list cannot run degrades to unquantified wording and still refuses.
  def test_an_unquantifiable_ahead_count_still_refuses
    publication = predicate_publication(Dir.mktmpdir("no-repo"))
    pull_request = { "url" => "https://example.invalid/pull/1", "headRefOid" => "b" * 40 }

    reason = publication.send(:ahead_head_refusal, pull_request, BRANCH, "a" * 40)

    assert_match(/plus later commits SpecRelay did not execute or validate/, reason)
    assert_match(/release and re-run the task/, reason)
  end

  # CR-003 criterion 3: the GitHub-lag row must reuse end-to-end, not merely decide.
  def test_a_lagging_reported_head_reuses_the_pull_request
    chain = build_commit_chain
    publication = predicate_publication(chain[:repo])
    entries = [ { "url" => "https://github.com/SpecRelay/tiny-demo-workspace/pull/70",
                  "state" => "OPEN", "headRefName" => BRANCH, "headRefOid" => chain[:mid] } ]

    lookup = publication.send(:reusable, entries, BRANCH, chain[:tip])

    assert_equal "https://github.com/SpecRelay/tiny-demo-workspace/pull/70", lookup.url,
                 "a head that is an ancestor of ours is contained by the branch"
    assert_nil lookup.error
  ensure
    FileUtils.remove_entry(chain[:repo]) if chain && File.directory?(chain[:repo])
  end

  # CR-003 criterion 1, end to end. review-004 drove these two through the full CLI and
  # got `outcome: succeeded` with an unrelated pre-existing pull request linked as the
  # round's reviewable artifact. Both must now fail closed and create nothing.
  def test_an_open_pull_request_with_an_absent_head_is_not_reused_end_to_end
    assert_undetermined_head_fails_closed(
      { "url" => "https://github.com/SpecRelay/tiny-demo-workspace/pull/77",
        "state" => "OPEN", "headRefName" => BRANCH }               # key omitted entirely
    )
  end

  def test_an_open_pull_request_with_an_empty_head_is_not_reused_end_to_end
    assert_undetermined_head_fails_closed(
      { "url" => "https://github.com/SpecRelay/tiny-demo-workspace/pull/78",
        "state" => "OPEN", "headRefName" => BRANCH, "headRefOid" => "" }
    )
  end

  def assert_undetermined_head_fails_closed(seeded)
    start
    gh_dir, gh_log, = FakeGithub.gh_bin(mode: "ok", bare: @bare, seed: [ seeded ])

    run_cli({}, gh_dir: gh_dir)

    terminal = @platform.last_terminal_result
    repo = repository_result
    assert_equal "failed", terminal["outcome"],
                 "an unverified pull request must not be reported as this run's output"
    assert_equal "publication_failed", terminal.dig("core", "error_classification")
    assert_nil repo["pull_request_url"]
    refute_equal seeded["url"], repo["pull_request_url"]
    assert_match(/reported no head commit/, repo["publication_error"].to_s)
    assert_equal 0, FakeGithub.pr_creates(gh_log), "it must not create one either"
    # The branch itself is still published — only the pull-request claim is withheld.
    assert_equal BRANCH, repo["branch"]
  end

  # CR-003 criterion 1, at the predicate boundary: an undetermined reported head refuses
  # with an operator-readable reason naming a next step.
  def test_an_undetermined_reported_head_refuses_with_a_next_step
    chain = build_commit_chain
    publication = predicate_publication(chain[:repo])
    entries = [ { "url" => "https://github.com/SpecRelay/tiny-demo-workspace/pull/77",
                  "state" => "OPEN", "headRefName" => BRANCH } ] # headRefOid absent entirely

    lookup = publication.send(:reusable, entries, BRANCH, chain[:tip])

    assert_nil lookup.url
    assert_match(/reported no head commit/, lookup.error.to_s)
    assert_match(/release and re-run the task/, lookup.error.to_s)
  ensure
    FileUtils.remove_entry(chain[:repo]) if chain && File.directory?(chain[:repo])
  end

  # CR-003 criterion 5: a non-SHA from `git rev-parse` must not satisfy the equality row.
  def test_a_non_sha_head_is_refused_by_resolved_head
    chain = build_commit_chain
    publication = predicate_publication(chain[:repo])

    ok = publication.send(:resolved_head)
    assert_equal chain[:tip], ok.head_commit
    assert_nil ok.error

    publication.define_singleton_method(:head_commit) { "HEAD-is-not-a-sha" }
    bad = publication.send(:resolved_head)
    assert_nil bad.head_commit
    assert_match(/not a commit sha/, bad.error)
  ensure
    FileUtils.remove_entry(chain[:repo]) if chain && File.directory?(chain[:repo])
  end

  # A real repository with a real ancestor chain and a real divergent sibling, so
  # `git merge-base --is-ancestor` is genuinely consulted.
  def build_commit_chain
    repo = Dir.mktmpdir("predicate-chain-")
    g = ->(*args) { FakeGithub.git(repo, *args) }
    FakeGithub.git(".", "init", "-q", repo)
    g.call("config", "user.email", "t@e.test")
    g.call("config", "user.name", "T")
    g.call("config", "commit.gpgsign", "false")
    File.write(File.join(repo, "f"), "base\n")
    g.call("add", "-A"); g.call("commit", "-q", "-m", "base")
    base = g.call("rev-parse", "HEAD").strip
    File.write(File.join(repo, "f"), "mid\n")
    g.call("add", "-A"); g.call("commit", "-q", "-m", "mid")
    mid = g.call("rev-parse", "HEAD").strip
    File.write(File.join(repo, "f"), "tip\n")
    g.call("add", "-A"); g.call("commit", "-q", "-m", "tip")
    tip = g.call("rev-parse", "HEAD").strip
    # A sibling off base: present in the repo, but on no path to tip.
    g.call("checkout", "-q", "-b", "sibling", base)
    File.write(File.join(repo, "f"), "sibling\n")
    g.call("add", "-A"); g.call("commit", "-q", "-m", "sibling")
    sibling = g.call("rev-parse", "HEAD").strip
    g.call("checkout", "-q", "-")
    { repo: repo, base: base, mid: mid, tip: tip, sibling: sibling }
  end

  def predicate_publication(repo)
    SpecrelayRunner::Publication.new(
      payload: {}, worktree_path: repo, changes: nil, base_commit: nil, test: {},
      env: { "PATH" => ENV["PATH"].to_s, "HOME" => ENV["HOME"].to_s }, io: StringIO.new
    )
  end

  # The fallback lookup after a silent `gh pr create`. This path was unreachable in the
  # suite, which is how it kept a stale call arity through CR-002's signature change.
  def test_pull_request_url_is_recovered_when_create_prints_nothing
    start
    created_url = "https://github.com/SpecRelay/tiny-demo-workspace/pull/12"
    gh_dir, gh_log, = FakeGithub.gh_bin(mode: "create_silent", pull_request_url: created_url, bare: @bare)

    code, output = run_cli({}, gh_dir: gh_dir)

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    repo = repository_result
    assert_nil repo["publication_error"]
    assert_equal created_url, repo["pull_request_url"], "the URL must be recovered by lookup"
    assert_equal 1, FakeGithub.pr_creates(gh_log), "exactly one create, then a lookup"
  end

  # An OPEN pull request whose head is not the commit we pushed is not proof that our
  # commit is reviewable, so it fails closed rather than being reported.
  def test_open_pull_request_with_a_foreign_head_fails_closed
    start
    seed = [ { "url" => "https://github.com/SpecRelay/tiny-demo-workspace/pull/5", "state" => "OPEN",
               "headRefName" => BRANCH, "headRefOid" => "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" } ]
    gh_dir, gh_log, = FakeGithub.gh_bin(mode: "ok", bare: @bare, seed: seed)
    run_cli({}, gh_dir: gh_dir)

    repo = repository_result
    assert_nil repo["pull_request_url"]
    assert_match(/refusing to report a pull request that may not contain this run's commit/,
                 repo["publication_error"])
    assert_equal 0, FakeGithub.pr_creates(gh_log)
  end

  # CR-001 criterion 6. The runner keeps its own half of "never push the default
  # branch", independent of Platform's branch policy.
  def test_runner_refuses_an_assignment_targeting_the_default_branch
    start(publication: { branch: "main" })
    run_cli

    terminal = @platform.last_terminal_result
    assert_equal "failed", terminal["outcome"]
    assert_equal "publication_failed", terminal.dig("core", "error_classification")

    repo = repository_result
    assert_nil repo["branch"], "the default branch must never be reported as published"
    assert_match(/default branch/, repo["publication_error"])
    assert_empty FakeGithub.remote_branches(@bare), "nothing may be pushed, least of all main"
    assert_equal 0, FakeGithub.pr_creates(@gh_log)
    # CR-001 criterion 4: the phase that failed must be visible on the timeline.
    assert_includes event_types, "publication.started"
    assert_includes event_types, "publication.completed"
  end

  # --- publication failure -------------------------------------------------

  def test_unauthenticated_gh_pushes_the_branch_but_reports_a_publication_error
    start
    gh_dir, = FakeGithub.gh_bin(mode: "unauthenticated")
    run_cli({}, gh_dir: gh_dir)

    repo = repository_result
    assert_equal BRANCH, repo["branch"], "the push still succeeded"
    assert_nil repo["pull_request_url"]
    assert_match(/gh auth login/, repo["publication_error"], "the operator needs the exact remedy")
    assert_equal repo["head_commit"], FakeGithub.remote_branches(@bare)[BRANCH]
  end

  # A pushed branch without its policy-required pull request is INCOMPLETE. The
  # attempt must be reported as FAILED — the tests passed, but nothing became
  # reviewable — so Platform records a durable reason and leaves Jira alone.
  def test_publication_failure_downgrades_the_attempt_to_failed
    start
    gh_dir, = FakeGithub.gh_bin(mode: "unauthenticated")
    run_cli({}, gh_dir: gh_dir)

    terminal = @platform.last_terminal_result
    assert_equal "failed", terminal["outcome"]
    assert_equal "publication_failed", terminal.dig("core", "error_classification")
    assert_equal 0, terminal.dig("core", "exit_code"), "the project tests still passed"

    report = @platform.last_report[:body].fetch("report")
    manifest = YAML.safe_load(Base64.strict_decode64(
      report["files"].find { |f| f["relative_path"] == "manifest.yml" }["content_base64"]
    ))
    assert_equal "failed", manifest["execution_status"]
    assert_match(/repository publication failed/, manifest.to_s,
                 "the report must blame publication, not the tests")
  end

  def test_failing_pull_request_creation_reports_a_publication_error
    start
    gh_dir, = FakeGithub.gh_bin(mode: "create_fails")
    run_cli({}, gh_dir: gh_dir)

    repo = repository_result
    assert_equal BRANCH, repo["branch"]
    assert_nil repo["pull_request_url"]
    assert_match(/gh pr create failed/, repo["publication_error"])
  end

  def test_diverged_remote_branch_fails_closed_without_force_pushing
    start
    # Someone else's commit already occupies the branch, so a fast-forward is
    # impossible. SpecRelay must refuse rather than overwrite it.
    other = Dir.mktmpdir("other-clone-")
    FakeGithub.git(".", "clone", "-q", @bare, other)
    File.write(File.join(other, "unrelated.txt"), "someone else's work\n")
    FakeGithub.git(other, "-c", "user.email=o@e.test", "-c", "user.name=Other", "checkout", "-q", "-b", BRANCH)
    FakeGithub.git(other, "add", "-A")
    FakeGithub.git(other, "-c", "user.email=o@e.test", "-c", "user.name=Other", "commit", "-q", "-m", "unrelated")
    FakeGithub.git(other, "push", "-q", "origin", BRANCH)
    foreign_head = FakeGithub.remote_branches(@bare)[BRANCH]

    run_cli
    repo = repository_result
    assert_nil repo["pull_request_url"]
    reason = repo["publication_error"].to_s
    assert_match(/diverged|force-push|rejected/, reason)
    assert_equal foreign_head, FakeGithub.remote_branches(@bare)[BRANCH],
                 "the foreign commit must be untouched — no force push"
    # CR-001 criterion 7: the reason must name a next step, like the gh case does.
    assert_match(/git push origin --delete/, reason)
    assert_match(/release and re-run the task/, reason)
  end

  # --- CR-001: no failure reason may be empty ------------------------------

  # CR-002 / review-003 finding 4. The end-to-end version: a real `gh` that hangs, a real
  # CommandRunner timeout that kills the process group, and the reason the operator
  # actually sees. The unit-level check below still covers the message shapes.
  def test_a_real_command_timeout_produces_a_non_empty_reason_end_to_end
    start
    gh_dir, gh_log, = FakeGithub.gh_bin(mode: "list_hangs", bare: @bare)

    with_gh_timeout(1) { run_cli({}, gh_dir: gh_dir) }

    repo = repository_result
    assert_equal BRANCH, repo["branch"], "the branch is pushed before the pull-request step"
    assert_nil repo["pull_request_url"]
    reason = repo["publication_error"].to_s
    refute_empty reason.strip, "a timeout must never produce a blank operator message"
    assert_match(/gh pr list timed out after \d+s/, reason)
    assert_match(/release and re-run the task/, reason, "the reason must name a next step")
    assert_equal 0, FakeGithub.pr_creates(gh_log), "an undetermined lookup must not create"
  end

  # Lowers the gh timeout for one block. The constant is production configuration, so it
  # is restored even on failure; this exercises the real timeout machinery rather than
  # simulating its result.
  def with_gh_timeout(seconds)
    klass = SpecrelayRunner::Publication
    original = klass::GH_TIMEOUT_SECONDS
    klass.send(:remove_const, :GH_TIMEOUT_SECONDS)
    klass.const_set(:GH_TIMEOUT_SECONDS, seconds)
    yield
  ensure
    klass.send(:remove_const, :GH_TIMEOUT_SECONDS)
    klass.const_set(:GH_TIMEOUT_SECONDS, original)
  end

  # CR-001 criterion 8. A timeout leaves exit_code nil and no output, which used to
  # render as the bare reason "git push failed: " and a blank operator message.
  def test_a_timed_out_command_produces_a_non_empty_secret_safe_reason
    timed_out = SpecrelayRunner::CommandRunner::Result.new(
      exit_code: nil, stdout: "", stderr: "", duration_seconds: 300.0, timed_out: true
    )
    publication = SpecrelayRunner::Publication.new(
      payload: {}, worktree_path: @root, changes: nil, base_commit: nil, test: {}
    )

    reason = publication.send(:push_error, timed_out)

    refute_empty reason.strip
    assert_match(/timed out after 300s/, reason)
    refute_match(/diverged/, reason, "a timeout is not a divergence")
    # And a plain non-zero exit with no output still names something.
    silent = SpecrelayRunner::CommandRunner::Result.new(
      exit_code: 128, stdout: "", stderr: "", duration_seconds: 0.1, timed_out: false
    )
    assert_match(/exit status 128 and no output/, publication.send(:failure_reason, silent, "git push"))
  end

  # --- CR-001 criterion 5: unmeasurable is not unchanged -------------------

  # A single transient spawn failure during change detection must never be reported as
  # "no code changes" while the executor's diff is on disk (review-002 finding N1).
  # EMFILE is injected into the FIRST spawn only; everything else behaves normally.
  def test_a_transient_spawn_error_during_change_detection_fails_closed
    start
    inject_emfile_on_first_spawn

    run_cli

    terminal = @platform.last_terminal_result
    assert_equal "failed", terminal["outcome"],
                 "an unmeasurable worktree must fail the run, not pass as unchanged"
    assert_equal "worktree_unmeasurable", terminal.dig("core", "error_classification")

    repo = repository_result
    refute repo["branch"], "nothing may be published when the diff is unknown"
    assert_match(/change detection failed/, repo["publication_error"].to_s,
                 "changed: false must never be presented as a clean fact here")
    # review-003 finding 2 (reporting this as unknown rather than false) is NOT done:
    # Platform's envelope validator requires a boolean. What must hold is that the false
    # is never readable as a clean fact, so the reason is asserted above and the head
    # commit is absent.
    refute repo["changed"]
    assert_nil repo["head_commit"]
    assert_empty FakeGithub.remote_branches(@bare)
    assert_equal 0, FakeGithub.pr_creates(@gh_log)

    # The executor's change really was made — this is exactly the false-success setup.
    worktree = File.join(@root, ".runs", "worktrees", TASK)
    assert_match(/Hello SpecRelay Demo/, File.read(File.join(worktree, "demo-app", "index.html")))
  end

  # Raise Errno::EMFILE once, on the first CommandRunner spawn after the executor has
  # run. Patching the spawn boundary keeps the rest of the flow real.
  def inject_emfile_on_first_spawn
    fired = false
    guard = ->(argv) { argv.first == "git" && argv.include?("status") && !fired }
    SpecrelayRunner::CommandRunner.class_eval do
      alias_method :spawn_process_without_injection, :spawn_process
      define_method(:spawn_process) do |argv|
        if guard.call(argv)
          fired = true
          raise Errno::EMFILE, "Too many open files"
        end
        spawn_process_without_injection(argv)
      end
    end
    @emfile_injected = true
  end

  def remove_emfile_injection
    return unless @emfile_injected

    SpecrelayRunner::CommandRunner.class_eval do
      alias_method :spawn_process, :spawn_process_without_injection
      remove_method :spawn_process_without_injection
    end
    @emfile_injected = false
  end

  def test_no_publication_policy_means_no_publication_attempt
    # A pre-MVP-0014 Platform sends no repositories/repository_policy blocks.
    start(publication: nil)
    code, output = run_cli
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output

    repo = repository_result
    assert repo["changed"]
    assert_nil repo["branch"], "nothing may be published when Platform asked for nothing"
    assert_nil repo["publication_error"], "an absent policy is not a failure"
    assert_empty FakeGithub.remote_branches(@bare)
  end
end
