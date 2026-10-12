# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "yaml"

# MAPIAI-87 proof for continuing an IMPLEMENTATION run from the ticket's previous accepted
# package, against a real project-owned task workspace, real independent git repositories, real
# bare remotes and a real `gh` argv boundary.
#
# Scenarios: S05 (an exact clean task workspace is reused, never reset backward), S06 (a missing
# workspace is created once and every accepted repository is placed on the canonical branch at its
# verified head), S07 (open pull request, repository identity, branch and head all agree before the
# provider starts), S08 (the refusal matrix, every entry fail-closed before any external write),
# S09 (an accepted package that changed nothing), S10 (same-run authority outranks the older
# package).
class PreviousAcceptedPackageTest < Minitest::Test
  # The one directory on the child PATH that provides the approved fixture name. The PAYLOAD is
  # always the canonical fixture profile; which script that approved name resolves to on this
  # host is the test's choice, exactly as it is the operator's choice on a real machine.
  def fixture_dir = @fixture_dir ||= fixture_bin
  TASK = "MAPIAI-87"
  ACCEPTED = %w[component-a component-b].freeze
  PR_URLS = {
    "SpecRelay/component-a" => "https://github.com/SpecRelay/component-a/pull/21",
    "SpecRelay/component-b" => "https://github.com/SpecRelay/component-b/pull/22",
    "SpecRelay/component-c" => "https://github.com/SpecRelay/component-c/pull/23",
    "SpecRelay/multi-demo-workspace" => "https://github.com/SpecRelay/multi-demo-workspace/pull/24"
  }.freeze

  # The file that exists ONLY at the accepted head. Its presence in a worktree is direct evidence
  # that the canonical branch was placed on that commit; its absence is evidence that it was not.
  ACCEPTED_FILE = "accepted.txt"

  def setup
    @built = MultiRepositoryWorkspace.build
    use_fixture(fixture_dir, @built.executor)
    @root = @built.root
    @root_slug = "SpecRelay/multi-demo-workspace"
    @bares = @built.bares.to_h { |name, bare| [ slug_for(name), bare ] }
    @heads = ACCEPTED.to_h { |name| [ name, publish_accepted_head(name) ] }
    @clones = []
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    @clones.each { |path| FileUtils.remove_entry(path) if File.directory?(path) }
  end

  # --- fixture -------------------------------------------------------------

  # The workspace repository's own slug differs between the two fixtures, so it is a field rather
  # than a constant: the same helpers then describe a project-owned workspace and a single
  # repository without a second copy of any of them.
  def slug_for(name) = name == "." ? @root_slug : "SpecRelay/#{name}"

  # The accepted head, created where an accepted implementation really lives: on the REMOTE. The
  # workspace's own clone never held the commit, so the runner has to fetch it — which is the
  # difference between reconstructing accepted work and rediscovering a local leftover.
  def publish_accepted_head(component)
    DemoWorkspace.git(File.expand_path(component, @root), "push", "--quiet", "origin", "HEAD:refs/heads/#{TASK}")
    clone = Dir.mktmpdir("specrelay-accepted-")
    @clones = (@clones || []) << clone
    DemoWorkspace.git(clone, "clone", "-q", "--branch", TASK, @bares.fetch(slug_for(component)), ".")
    DemoWorkspace.git(clone, "config", "user.email", "accepted@example.test")
    DemoWorkspace.git(clone, "config", "user.name", "Accepted")
    File.write(File.join(clone, ACCEPTED_FILE), "accepted by the previous round\n")
    DemoWorkspace.git(clone, "add", "-A")
    DemoWorkspace.git(clone, "commit", "-q", "-m", "accepted implementation")
    DemoWorkspace.git(clone, "push", "--quiet", "origin", "HEAD:refs/heads/#{TASK}")
    DemoWorkspace.git(clone, "rev-parse", "HEAD").strip
  end

  # The block Platform's one projection builds (Runner::Api::PreviousAcceptedPackage).
  def continuation(components: ACCEPTED, overrides: {})
    { "package_id" => "art_previous123", "checksum" => "c" * 64, "source_run_id" => "run_previous",
      "approved_specification" => { "reference" => "https://github.com/SpecRelay/specs/pull/6",
                                    "digest" => "d" * 64 },
      "implementation_pull_requests" => components.map { |name| accepted_row(name) } }.merge(overrides)
  end

  def accepted_row(name, overrides = {})
    slug = slug_for(name)
    { "repository" => slug, "clone_url" => "https://github.com/#{slug}",
      "branch" => TASK, "head_commit" => @heads.fetch(name),
      "pull_request_url" => PR_URLS.fetch(slug, "https://github.com/#{slug}/pull/31") }.merge(overrides)
  end

  # `gh pr view` answers for exactly the pull requests seeded here.
  def gh_bin(rows: nil, mode: "ok")
    rows ||= ACCEPTED.map { |name| open_pull_request(name) }
    FakeGithub.gh_bin(mode: mode, urls: PR_URLS, bares: @bares, seed: rows)
  end

  def open_pull_request(name, overrides = {})
    slug = slug_for(name)
    { "url" => PR_URLS.fetch(slug), "state" => "OPEN", "headRefName" => TASK, "repo" => slug,
      "headRefOid" => @heads.fetch(name) }.merge(overrides)
  end

  # The prepared task workspace, built by the project's own command exactly as the runner builds
  # one. Returns its path.
  def create_task_workspace
    DemoWorkspace.git(@root, "worktree", "list") # ensure the fixture repository is usable
    out, status = Open3.capture2e(File.join(@root, "bin", "worktree"), "create", TASK,
                                  "--run-id", IMPL_RUN, chdir: @root)
    raise out unless status.success?

    File.join(@root, ".runs", "worktrees", TASK)
  end

  def materializer(block = continuation, gh_dir: nil)
    dir = gh_dir || gh_bin.first
    claim = SpecrelayRunner::PreviousAcceptedPackage.read(
      { "previous_accepted_package" => block, "run" => { "canonical_branch" => TASK } },
      env: { "PATH" => "#{dir}:#{ENV['PATH']}", "HOME" => ENV["HOME"].to_s }
    )
    raise claim.reason unless claim.ok?

    claim.package
  end

  def head_of(task_root, component) = DemoWorkspace.git(File.join(task_root, component), "rev-parse", "HEAD").strip
  def branch_of(task_root, component)
    DemoWorkspace.git(File.join(task_root, component), "symbolic-ref", "--short", "HEAD").strip
  end

  # --- S06 / S07: a created workspace is reconstructed at the verified heads ----------------

  def test_places_every_accepted_repository_on_the_canonical_branch_at_its_verified_head
    task_root = create_task_workspace

    result = materializer.materialize(task_root: task_root)

    assert result.ok?, result.reason
    ACCEPTED.each do |component|
      assert_equal TASK, branch_of(task_root, component)
      assert_equal @heads.fetch(component), head_of(task_root, component)
      assert_path_exists File.join(task_root, component, ACCEPTED_FILE)
    end
    refute_path_exists File.join(task_root, "component-c", ACCEPTED_FILE)
  end

  def test_maps_targets_by_normalized_origin_identity_not_by_directory_name
    task_root = create_task_workspace
    renamed = continuation(components: [ "component-a" ])
    renamed["implementation_pull_requests"] = [ accepted_row("component-a", "repository" => "specrelay/COMPONENT-A") ]

    result = materializer(renamed).materialize(task_root: task_root)

    assert result.ok?, result.reason
    assert_equal @heads.fetch("component-a"), head_of(task_root, "component-a")
  end

  def test_leaves_the_workspace_untouched_when_the_accepted_package_changed_nothing
    task_root = create_task_workspace
    before = ACCEPTED.to_h { |name| [ name, head_of(task_root, name) ] }
    gh_dir, gh_log, = gh_bin

    result = materializer(continuation(components: []), gh_dir: gh_dir).materialize(task_root: task_root)

    assert result.ok?, result.reason
    assert_equal before, ACCEPTED.to_h { |name| [ name, head_of(task_root, name) ] }
    assert_equal 0, FakeGithub.pr_views(gh_log)
  end

  # --- S08: the refusal matrix ---------------------------------------------

  def test_refuses_every_stale_or_unsafe_continuation_before_touching_a_repository
    task_root = create_task_workspace
    before = ACCEPTED.to_h { |name| [ name, head_of(task_root, name) ] }

    refusals = {
      "missing pull request" => -> { materializer(continuation(components: [ "component-a" ]),
                                                  gh_dir: gh_bin(rows: []).first) },
      "unreadable pull request" => -> { materializer(continuation(components: [ "component-a" ]),
                                                     gh_dir: gh_bin(mode: "view_fails").first) },
      "branch mismatch" => -> { materializer(continuation(components: [ "component-a" ]),
                                             gh_dir: gh_bin(rows: [ open_pull_request("component-a", "headRefName" => "other") ]).first) },
      "repository not in the workspace" => lambda {
        block = continuation(components: [])
        block["implementation_pull_requests"] = [
          { "repository" => "SpecRelay/absent", "clone_url" => "https://github.com/SpecRelay/absent",
            "branch" => TASK, "head_commit" => "a" * 40,
            "pull_request_url" => "https://github.com/SpecRelay/absent/pull/1" }
        ]
        materializer(block)
      },
      "pull request on another repository" => lambda {
        block = continuation(components: [])
        block["implementation_pull_requests"] = [ accepted_row("component-a", "pull_request_url" => PR_URLS.fetch("SpecRelay/component-b")) ]
        materializer(block)
      },
      "duplicate accepted identity" => lambda {
        block = continuation(components: [])
        block["implementation_pull_requests"] = [ accepted_row("component-a"), accepted_row("component-a") ]
        materializer(block)
      }
    }

    refusals.each do |name, build|
      result = build.call.materialize(task_root: task_root)

      refute result.ok?, "#{name} was accepted"
      refute_empty result.reason.to_s, "#{name} refused without a reason"
      assert_equal before, ACCEPTED.to_h { |component| [ component, head_of(task_root, component) ] },
                   "#{name} moved a repository before refusing"
    end
  end

  def test_refuses_a_dirty_repository_and_a_commit_the_remote_no_longer_has
    task_root = create_task_workspace
    File.write(File.join(task_root, "component-a", "app.txt"), "uncommitted\n", mode: "a")

    dirty = materializer(continuation(components: [ "component-a" ])).materialize(task_root: task_root)

    refute dirty.ok?
    assert_match(/uncommitted|clean/i, dirty.reason)

    DemoWorkspace.git(File.join(task_root, "component-a"), "checkout", "--", "app.txt")
    unknown = "0" * 40
    gh_dir, = gh_bin(rows: [ open_pull_request("component-a", "headRefOid" => unknown) ])
    block = continuation(components: [])
    block["implementation_pull_requests"] = [ accepted_row("component-a", "head_commit" => unknown) ]

    missing = materializer(block, gh_dir: gh_dir).materialize(task_root: task_root)

    refute missing.ok?
    assert_match(/does not contain/i, missing.reason)
  end

  def test_refuses_a_task_workspace_it_cannot_resolve
    result = materializer.materialize(task_root: File.join(@root, "no-such-workspace"))

    refute result.ok?
    refute_empty result.reason.to_s
  end

  # --- S05 / S06 / S10: the execution wiring -------------------------------

  def start(continuation_block: nil, restart: nil, absent: false)
    # Which repository the double edits is a host-side control, installed behind the approved bare
    # name; the assignment carries the canonical fixture profile and nothing else.
    use_fixture(fixture_dir, @built.executor, env: { "FAKE_EXECUTOR_EDITED" => "component-a" })
    payload = claim_payload_for(task_id: TASK, root: @root,
                                specification_repository: "component-c",
                                publication: {}, restart: restart)
    absent ? payload.delete("previous_accepted_package") :
      payload["previous_accepted_package"] = continuation_block
    @payload = payload
    @platform = FakePlatform.new(claim_payload: payload).start
    @config_path = write_config
  end

  def write_config(root = @root)
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
    path
  end

  def run_cli(gh_dir)
    io = StringIO.new
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => "#{fixture_dir}:#{gh_dir}:#{ENV['PATH']}",
            "HOME" => ENV["HOME"].to_s }
    code = SpecrelayRunner::CLI.run(%W[claim-once --config #{@config_path}], out: io, err: io, env: env)
    [ code, io.string ]
  end

  def worktree_invocations
    File.exist?(@built.worktree_log) ? File.read(@built.worktree_log).lines.map(&:strip) : []
  end

  def test_creates_the_missing_task_workspace_once_and_reconstructs_it
    gh_dir, gh_log, = gh_bin
    start(continuation_block: continuation)

    code, = run_cli(gh_dir)

    assert_equal 0, code
    # MAPIAI-97 — a successful implementation hands its task environment back before this
    # machine claims anything else, so `release` is part of the expected sequence.
    assert_equal [ "create #{TASK} --run-id #{IMPL_RUN}", "status #{TASK} --json",
                   "release #{TASK} --run-id #{IMPL_RUN} --json" ], worktree_invocations
    # Read from each component repository's canonical branch rather than from the task workspace:
    # the successful run handed that environment back, and the branch it placed the accepted head
    # on is the durable half of the same reconstruction.
    ACCEPTED.each do |component|
      assert_equal "accepted by the previous round",
                   DemoWorkspace.git(File.join(@root, component), "show", "#{TASK}:#{ACCEPTED_FILE}").strip,
                   "#{component} was not reconstructed at its accepted head"
    end
    assert_equal ACCEPTED.length, FakeGithub.pr_views(gh_log)
  end

  def test_reuses_an_exact_clean_task_workspace_and_reconciles_it_without_recreating_it
    gh_dir, gh_log, = gh_bin
    # The assignment's package is committed by `start`, so the environment is built AFTER it: one
    # created earlier predates the approved specification and could not show it, which is a
    # different refusal from the reuse this test is about.
    start(continuation_block: continuation)
    task_root = create_task_workspace
    File.truncate(@built.worktree_log, 0)
    before = ACCEPTED.to_h { |name| [ name, head_of(task_root, name) ] }
    # Read when the report arrives: a recorded result then hands the environment back.
    at_report = []
    observe = -> { [ File.exist?(File.join(task_root, "component-b", ACCEPTED_FILE)), head_of(task_root, "component-b") ] }
    original = @platform.method(:report)
    @platform.define_singleton_method(:report) do |request|
      at_report << observe.call
      original.call(request)
    end

    code, = run_cli(gh_dir)

    assert_equal 0, code
    # No second allocation and no reset — only the ownership proof this run must pass before it
    # may continue in an environment that was already there, and the release that follows the
    # recorded result. The reused environment is reconciled: it was merely behind the accepted
    # head, so it is fast-forwarded to it.
    assert_equal [ "status #{TASK} --json", "release #{TASK} --run-id run_test123 --json" ],
                 worktree_invocations
    assert_equal ACCEPTED.length, FakeGithub.pr_views(gh_log)
    refute_equal @heads.fetch("component-b"), before["component-b"]
    assert_equal [ [ true, @heads.fetch("component-b") ] ], at_report
  end

  # S06 — a checkout with no run-aware project command refuses the automatic run, so there is
  # no environment to reconstruct an accepted implementation into.
  #
  # This replaces the native single-repository fallback for this lane. That command records no
  # owner, so a run reconstructing accepted work into it could neither prove the environment was
  # its own on a later attempt nor release it at the end. The refusal happens before the
  # continuation is materialized and before any external write.
  def test_a_checkout_without_the_run_aware_project_command_refuses_before_reconstructing
    FileUtils.remove_entry(@root)
    @root, executor = DemoWorkspace.build
    use_fixture(fixture_dir, executor)
    DemoWorkspace.without_project_command(@root)
    slug = @root_slug = "SpecRelay/tiny-demo-workspace"
    bare = FakeGithub.add_remote(@root)
    @bares = { slug => bare }
    @heads = { "." => publish_accepted_head(".") }
    url = "https://github.com/#{slug}/pull/31"
    gh_dir, gh_log, = FakeGithub.gh_bin(
      urls: { slug => url }, bares: @bares,
      seed: [ { "url" => url, "state" => "OPEN", "headRefName" => TASK, "repo" => slug,
                "headRefOid" => @heads.fetch(".") } ]
    )

    payload = claim_payload_for(task_id: TASK, publication: {}, root: @root,
                                worktree_create_command: "git worktree add .runs/worktrees/#{TASK} -b #{TASK}")
    payload["previous_accepted_package"] = continuation(components: [ "." ]).merge(
      "implementation_pull_requests" => [ accepted_row(".", "pull_request_url" => url) ]
    )
    @platform = FakePlatform.new(claim_payload: payload).start
    @config_path = write_config

    _code, output = run_cli(gh_dir)

    assert_match(/preflight_failed/, output)
    assert_includes output, "no run-aware"
    refute_path_exists File.join(@root, ".runs", "worktrees", TASK)
    assert_equal 0, FakeGithub.pr_creates(gh_log), "nothing may be published"
  end

  # S08 at the execution boundary — a stale continuation stops the whole attempt BEFORE the
  # provider runs, so nothing is committed, nothing is pushed, no pull request moves, and no
  # report claims a result.
  def test_a_stale_continuation_refuses_before_the_provider_and_before_any_external_write
    gh_dir, gh_log, = gh_bin(rows: [ open_pull_request("component-a", "headRefName" => "other"),
                                     open_pull_request("component-b") ])
    start(continuation_block: continuation)

    code, output = run_cli(gh_dir)

    refute_equal 0, code, output
    assert_match(/is on branch "other"/, output)
    assert_nil @platform.last_terminal_result
    assert_equal 0, FakeGithub.pr_creates(gh_log)
    task_root = File.join(@root, ".runs", "worktrees", TASK)
    refute_includes File.read(File.join(task_root, "component-a", "app.txt")), "edited by the executor"
    ACCEPTED.each { |component| refute_path_exists File.join(task_root, component, ACCEPTED_FILE) }
  end

  # An ordinary continuation places a repository already in main at that commit and carries it
  # forward from the package: the executor need not list it, and nothing is published for it.
  def test_an_untouched_repository_already_in_main_is_placed_at_main_and_needs_no_selection_entry
    main = DemoWorkspace.git(File.join(@root, "component-b"), "rev-parse", "HEAD").strip
    block = continuation(components: [ "component-a" ])
    block["implementation_pull_requests"] << accepted_row("component-b", "head_commit" => main, "already_in_main" => true)
    gh_dir, gh_log, = gh_bin
    start(continuation_block: block)

    code, output = run_cli(gh_dir)

    assert_equal SpecrelayRunner::CLI::SUCCESS, code, output
    assert_equal [ "SpecRelay/component-a" ], @platform.last_terminal_result["repositories"].map { |repo| repo["id"] }
    assert_equal main, DemoWorkspace.git(File.join(@root, "component-b"), "rev-parse", "refs/heads/#{TASK}").strip,
                 "its canonical branch was placed at main"
    assert_equal @heads.fetch("component-b"),
                 DemoWorkspace.git(@bares.fetch("SpecRelay/component-b"), "rev-parse", "refs/heads/#{TASK}").strip,
                 "its historical branch was not pushed"
    assert_equal 0, FakeGithub.pr_creates(gh_log)
  end

  # CR-001 F1 at the execution boundary — the continuation field is authority, so an absent or
  # open-shaped one stops the attempt before the task workspace is even created. Reading it as
  # "no previous implementation" would build a workspace on the default branch and hand the
  # executor a base that silently discards the accepted implementation.
  def test_an_absent_continuation_field_refuses_before_the_task_workspace_is_created
    gh_dir, gh_log, = gh_bin
    start(absent: true)

    code, output = run_cli(gh_dir)

    refute_equal 0, code, output
    assert_match(/previous_accepted_package/, output)
    assert_empty worktree_invocations
    refute_path_exists File.join(@root, ".runs", "worktrees", TASK)
    assert_equal 0, FakeGithub.pr_views(gh_log)
    assert_equal 0, FakeGithub.pr_creates(gh_log)
    assert_nil @platform.last_terminal_result
  end

  # The same refusal against a workspace that is already there and reusable: the attempt must not
  # read it, run in it, or leave anything behind in it.
  def test_a_malformed_continuation_refuses_without_touching_a_reusable_task_workspace
    task_root = create_task_workspace
    File.truncate(@built.worktree_log, 0)
    before = ACCEPTED.to_h { |name| [ name, head_of(task_root, name) ] }
    gh_dir, gh_log, = gh_bin
    start(continuation_block: continuation(overrides: { "uncommitted_files" => [ "app.txt" ] }))

    code, output = run_cli(gh_dir)

    refute_equal 0, code, output
    assert_match(/does not recognise/, output)
    assert_empty worktree_invocations
    assert_equal before, ACCEPTED.to_h { |name| [ name, head_of(task_root, name) ] }
    assert_equal 0, FakeGithub.pr_views(gh_log)
    assert_equal 0, FakeGithub.pr_creates(gh_log)
    assert_nil @platform.last_terminal_result
    refute_includes File.read(File.join(task_root, "component-a", "app.txt")), "edited by the executor"
  end

  # CR-002 F1 at the implementation entry point — an unknown key is attacker-controlled text, so
  # nothing this attempt writes may carry it: not the operator log, not the claim release, not any
  # request Platform records. The key is deliberately not token-shaped, so this proves the
  # validator never named it rather than that {Redaction} masked it afterwards.
  SECRET_KEY = "x-SECRETVALUE-a3f9c1"

  def test_an_unknown_continuation_field_never_reaches_the_operator_or_platform
    gh_dir, gh_log, = gh_bin
    start(continuation_block: continuation(overrides: { SECRET_KEY => "ghp_livetoken" }))

    code, output = run_cli(gh_dir)

    refute_equal 0, code, output
    refute_includes output, "SECRETVALUE"
    refute_includes @platform.requests.to_json, "SECRETVALUE"
    assert_empty worktree_invocations
    assert_equal 0, FakeGithub.pr_views(gh_log)
    assert_nil @platform.last_terminal_result
  end

  def test_same_run_restart_authority_outranks_the_older_accepted_package
    gh_dir, gh_log, = gh_bin
    restart = { "repositories" => [ { "repository_key" => "SpecRelay/component-a",
                                      "clone_url" => "https://github.com/SpecRelay/component-a",
                                      "branch" => TASK, "head_commit" => @heads.fetch("component-a"),
                                      "pull_request_url" => PR_URLS.fetch("SpecRelay/component-a") } ] }
    start(continuation_block: continuation, restart: restart)

    run_cli(gh_dir)

    assert_equal 0, FakeGithub.pr_views(gh_log),
                 "the previous accepted package must not be materialized when a restart target exists"
  end

  # --- initial repository bases: every repository is decided before the provider ---------------

  INITIAL_ROOT = "."

  def repo_path(base, name) = name == "." ? base : File.join(base, name)
  def bare_of(name) = @bares.fetch(slug_for(name))
  def remote_main(name) = DemoWorkspace.git(bare_of(name), "rev-parse", "refs/heads/main").strip
  def remote_refs(name) = DemoWorkspace.git(bare_of(name), "for-each-ref", "--format=%(refname) %(objectname)")
  def resolved_bases(task_root) = SpecrelayRunner::PreviousAcceptedPackage.initial_bases(task_root)

  # A commit only the remote default branch holds: the primary checkout never fetched it.
  def advance_remote_main(name, file: "upstream.txt")
    clone = Dir.mktmpdir("specrelay-upstream-")
    @clones << clone
    DemoWorkspace.git(clone, "clone", "-q", "--branch", "main", bare_of(name), ".")
    DemoWorkspace.git(clone, "config", "user.email", "upstream@example.test")
    DemoWorkspace.git(clone, "config", "user.name", "Upstream")
    File.write(File.join(clone, file), "published on the default branch\n")
    DemoWorkspace.git(clone, "add", "-A")
    DemoWorkspace.git(clone, "commit", "-q", "-m", "default branch moved")
    DemoWorkspace.git(clone, "push", "--quiet", "origin", "HEAD:refs/heads/main")
    DemoWorkspace.git(clone, "rev-parse", "HEAD").strip
  end

  # A commit the primary checkout holds and never published — what a dirty earlier run leaves.
  def leave_local_commit(name, file: "leftover.txt")
    path = repo_path(@root, name)
    File.write(File.join(path, file), "left behind by an earlier run\n")
    DemoWorkspace.git(path, "add", "-A")
    DemoWorkspace.git(path, "commit", "-q", "-m", "local leftover")
    DemoWorkspace.git(path, "rev-parse", "HEAD").strip
  end

  # The approved specification committed into component-c, as the anchor the package check builds.
  def specification_anchor(task_root)
    pinned = commit_specification_package(@root, "specs/#{TASK}", [ [ "specification", "spec.md", "# spec\n" ] ],
                                          repository: "component-c")
    { repository: pinned["repository_slug"], path: File.join(task_root, "component-c"),
      head: pinned["head_sha"], package_path: "specs/#{TASK}" }
  end

  def heads_of(task_root) = ([ "." ] + MultiRepositoryWorkspace::COMPONENTS).to_h { |name| [ name, head_of(task_root, name) ] }

  # Scenario 1: accepted runs, a dirty leftover and a fresh run — package repositories at the
  # accepted heads, the specification repository at the approved specification head, everything
  # else at the stored base and never at the local leftover or a later default-branch tip.
  def test_a_new_environment_places_accepted_specification_and_stored_base_heads
    root_base = remote_main(".")
    leave_local_commit(".")
    task_root = create_task_workspace
    assert_path_exists File.join(task_root, "leftover.txt"), "the project command starts from the local head"
    anchor = specification_anchor(task_root)
    bases = resolved_bases(task_root)
    advance_remote_main(".")

    result = materializer.materialize(task_root: task_root, specification: anchor, initial_bases: bases)

    assert result.ok?, result.reason
    ACCEPTED.each { |component| assert_equal @heads.fetch(component), head_of(task_root, component) }
    assert_equal anchor[:head], head_of(task_root, "component-c")
    assert_equal root_base, head_of(task_root, ".")
    refute_path_exists File.join(task_root, "leftover.txt")
    refute_path_exists File.join(task_root, "upstream.txt")
    ([ "." ] + MultiRepositoryWorkspace::COMPONENTS).each { |name| assert_equal TASK, branch_of(task_root, name) }
  end

  # Each authority's own branch: the stored default branch for the workspace repository, the
  # accepted pull request's branch, and the task branch for the approved specification head.
  def decided(task_root, heads)
    heads.map do |name, commit|
      { repository: slug_for(name), path: File.realpath(repo_path(task_root, name)), commit: commit,
        ref: name == "." ? "refs/heads/main" : "refs/heads/#{TASK}" }
    end.sort_by { |base| base[:repository] }
  end

  # Scenarios 2–3 for a question's checkpoint: the decision that placed every contained repository
  # is also its checkpoint base — the accepted heads, the approved specification head, and each
  # other repository's stored base — whichever entry point placed it, and never a default-branch
  # tip that moved on afterwards.
  def test_the_decided_heads_of_every_contained_repository_are_its_checkpoint_bases
    task_root = create_task_workspace
    anchor = specification_anchor(task_root)
    bases = resolved_bases(task_root)
    stored_root = bases.find { |base| base["repository"] == @root_slug }["commit"]
    advance_remote_main(".")
    advance_remote_main("component-a")

    placed = materializer.materialize(task_root: task_root, specification: anchor, initial_bases: bases)
    reconciled = materializer.reconcile(task_root: task_root, specification: anchor, initial_bases: bases)

    expected = decided(task_root, "." => stored_root, "component-a" => @heads.fetch("component-a"),
                                  "component-b" => @heads.fetch("component-b"), "component-c" => anchor[:head])
    [ placed, reconciled ].each do |result|
      assert result.ok?, result.reason
      assert_equal expected, result.bases.sort_by { |base| base[:repository] }
    end
  end

  # A resumed question's restored repository keeps the base its work was recorded on. That base
  # must BE the head this owner decides; the restored work is never placed over, and every other
  # repository is placed as usual.
  def test_a_restored_repository_keeps_its_recorded_base_and_its_work
    task_root = create_task_workspace
    bases = resolved_bases(task_root)
    restored = File.join(task_root, "component-a")
    DemoWorkspace.git(restored, "fetch", "-q", "origin", TASK)
    DemoWorkspace.git(restored, "reset", "-q", "--hard", @heads.fetch("component-a"))
    File.write(File.join(restored, "app.txt"), "restored work\n")
    recorded = [ recorded_entry("component-a", @heads.fetch("component-a")) ]

    result = materializer.materialize(task_root: task_root, initial_bases: bases, recorded: recorded)

    assert result.ok?, result.reason
    assert_equal "restored work\n", File.read(File.join(restored, "app.txt"))
    assert_equal @heads.fetch("component-b"), head_of(task_root, "component-b")
    assert_includes result.bases, decided(task_root, "component-a" => @heads.fetch("component-a")).first
  end

  def test_a_recorded_base_that_is_not_the_decided_head_refuses_before_placement
    task_root = create_task_workspace
    bases = resolved_bases(task_root)
    before = heads_of(task_root)
    recorded = [ recorded_entry("component-a", remote_main("component-a")) ]

    result = materializer.materialize(task_root: task_root, initial_bases: bases, recorded: recorded)

    refute result.ok?
    assert_match(/"component-a" was recorded on #{remote_main('component-a')[0, 12]}, not on the accepted head/, result.reason)
    assert_equal before, heads_of(task_root), "nothing was placed"
  end

  def recorded_entry(name, base)
    { "path" => name, "origin" => slug_for(name), "base_sha" => base, "base_ref" => "refs/heads/#{TASK}" }
  end

  def test_the_resolved_set_names_every_contained_repository_at_its_remote_default_branch_tip
    leave_local_commit("component-a")
    task_root = create_task_workspace

    bases = resolved_bases(task_root)

    expected = ([ "." ] + MultiRepositoryWorkspace::COMPONENTS).map do |name|
      { "repository" => slug_for(name), "default_branch" => "main", "commit" => remote_main(name) }
    end
    assert_equal expected.sort_by { |b| b["repository"] }, bases.sort_by { |b| b["repository"] }
  end

  # Scenario 5: no accepted package — every repository without an anchor is at its stored base.
  def test_with_no_accepted_package_every_repository_is_at_its_stored_base
    task_root = create_task_workspace
    bases = resolved_bases(task_root)
    leave_local_commit("component-b")
    advance_remote_main("component-b")
    placer = SpecrelayRunner::PreviousAcceptedPackage.for_specification(TASK)

    result = placer.materialize(task_root: task_root, initial_bases: bases)

    assert result.ok?, result.reason
    bases.each do |base|
      name = base["repository"] == @root_slug ? "." : base["repository"].split("/").last
      assert_equal base["commit"], head_of(task_root, name)
      assert_equal TASK, branch_of(task_root, name)
    end
  end

  # Scenario 2: the accepted package is the authority, not the live pull request. One accepted
  # pull request was merged and its branch deleted; the other's branch was force-moved by a later
  # attempt. Both still yield the exact accepted commits, and no remote ref changes.
  def test_a_merged_or_moved_accepted_pull_request_still_yields_the_exact_accepted_heads
    DemoWorkspace.git(bare_of("component-a"), "update-ref", "refs/heads/main", @heads.fetch("component-a"))
    DemoWorkspace.git(bare_of("component-a"), "update-ref", "-d", "refs/heads/#{TASK}")
    replaced = DemoWorkspace.git(bare_of("component-b"), "-c", "user.email=later@example.test",
                                 "-c", "user.name=Later", "commit-tree", "#{@heads.fetch('component-b')}^{tree}",
                                 "-m", "a later attempt's publication").strip
    DemoWorkspace.git(bare_of("component-b"), "update-ref", "refs/heads/#{TASK}", replaced)
    gh_dir, = gh_bin(rows: [ open_pull_request("component-a", "state" => "MERGED"),
                             open_pull_request("component-b", "headRefOid" => replaced) ])
    task_root = create_task_workspace
    bases = resolved_bases(task_root)
    refs = ACCEPTED.to_h { |name| [ name, remote_refs(name) ] }

    result = materializer(continuation, gh_dir: gh_dir).materialize(task_root: task_root, initial_bases: bases)

    assert result.ok?, result.reason
    ACCEPTED.each { |component| assert_equal @heads.fetch(component), head_of(task_root, component) }
    assert_equal refs, ACCEPTED.to_h { |name| [ name, remote_refs(name) ] }, "a remote ref was changed"
  end

  def test_an_accepted_pull_request_on_another_branch_is_still_refused
    gh_dir, = gh_bin(rows: [ open_pull_request("component-a", "headRefName" => "other"), open_pull_request("component-b") ])
    task_root = create_task_workspace

    result = materializer(continuation, gh_dir: gh_dir).materialize(task_root: task_root,
                                                                    initial_bases: resolved_bases(task_root))

    refute result.ok?
    assert_match(/is on branch "other"/, result.reason)
  end

  # Scenario 7, at the placement owner: every unverifiable repository refuses before ANY
  # repository is moved, and names the repository.
  def test_every_unverifiable_initial_base_refuses_before_any_repository_moves
    task_root = create_task_workspace
    bases = resolved_bases(task_root)
    before = heads_of(task_root)
    placer = -> { SpecrelayRunner::PreviousAcceptedPackage.for_specification(TASK) }
    root_entry = ->(overrides) { bases.map { |b| b["repository"] == @root_slug ? b.merge(overrides) : b } }

    refusals = {
      "a stored commit the remote does not have" =>
        [ root_entry.call("commit" => "0" * 40), /does not contain the stored initial base 000000000000/ ],
      "a stored entry the environment does not contain" =>
        [ bases + [ { "repository" => "SpecRelay/absent", "default_branch" => "main", "commit" => "a" * 40 } ],
          /"SpecRelay\/absent" is not a repository of the prepared task workspace/ ],
      "a contained repository with no stored base" =>
        [ bases.reject { |b| b["repository"] == "SpecRelay/component-c" }, /no initial base is stored .*component-c/ ],
      "an empty set" => [ [], /no usable initial repository bases/ ],
      "an unusable entry" => [ root_entry.call("commit" => "abc"), /unusable initial repository base/ ]
    }

    refusals.each do |name, (set, reason)|
      result = placer.call.materialize(task_root: task_root, initial_bases: set)

      refute result.ok?, "#{name} was accepted"
      assert_match reason, result.reason, name
      assert_equal before, heads_of(task_root), "#{name} moved a repository before refusing"
    end
  end

  def test_a_contained_repository_without_a_github_identity_refuses
    identified = [ ".", "component-a", "component-b" ].map do |name|
      { "repository" => slug_for(name), "default_branch" => "main", "commit" => remote_main(name) }
    end
    DemoWorkspace.git(File.join(@root, "component-c"), "remote", "set-url", "origin", "/tmp/not-github.git")
    task_root = create_task_workspace
    before = heads_of(task_root)

    resolved = resolved_bases(task_root)
    placed = SpecrelayRunner::PreviousAcceptedPackage.for_specification(TASK)
                                                     .materialize(task_root: task_root, initial_bases: identified)

    assert_equal "\"component-c\" in the prepared task workspace has no GitHub identity", resolved
    refute placed.ok?
    assert_match(/has no GitHub identity/, placed.reason)
    assert_equal before, heads_of(task_root)
  end

  def test_an_origin_that_cannot_be_read_refuses_resolution
    task_root = create_task_workspace
    FileUtils.remove_entry(bare_of("component-b"))

    assert_match(/could not read the default branch of "SpecRelay\/component-b"/, resolved_bases(task_root))
  end

  # Scenario 6, at the placement owner: a reused environment is reconciled to the same set —
  # left alone when it already carries it, refused when it has diverged.
  def test_a_reused_environment_is_reconciled_to_the_stored_set_and_divergence_refuses
    task_root = create_task_workspace
    bases = resolved_bases(task_root)
    placer = -> { SpecrelayRunner::PreviousAcceptedPackage.for_specification(TASK) }
    assert placer.call.materialize(task_root: task_root, initial_bases: bases).ok?
    placed = heads_of(task_root)

    kept = placer.call.reconcile(task_root: task_root, initial_bases: bases)

    assert kept.ok?, kept.reason
    assert_equal placed, heads_of(task_root)

    root = repo_path(task_root, ".")
    diverged = DemoWorkspace.git(root, "commit-tree", "HEAD^{tree}", "-m", "diverged").strip
    DemoWorkspace.git(root, "reset", "-q", "--hard", diverged)

    refused = placer.call.reconcile(task_root: task_root, initial_bases: bases)

    refute refused.ok?
    assert_match(/has diverged from the stored initial base/, refused.reason)
    assert_equal diverged, head_of(task_root, ".")
  end

  # --- initial repository bases at the execution boundary --------------------------------------

  def requests_to(path) = @platform.requests.select { |request| request[:path] == path }
  def core_started? = @platform.protocol_events.any? { |event| event["event_type"] == "core.started" }

  def test_the_first_claim_records_the_set_and_places_the_set_platform_returned
    gh_dir, = gh_bin
    start(continuation_block: continuation)
    stored_root = remote_main(".")
    later_root = advance_remote_main(".")
    seeded = ([ "." ] + MultiRepositoryWorkspace::COMPONENTS).map do |name|
      { "repository" => slug_for(name), "default_branch" => "main", "commit" => name == "." ? stored_root : remote_main(name) }
    end
    @platform.initial_bases = seeded
    observed = []
    original = @platform.method(:report)
    task_root = File.join(@root, ".runs", "worktrees", TASK)
    @platform.define_singleton_method(:report) do |request|
      observed << DemoWorkspace.git(task_root, "rev-parse", "HEAD").strip
      original.call(request)
    end

    code, output = run_cli(gh_dir)

    assert_equal 0, code, output
    offered = requests_to("/api/runner/initial_repository_bases").map { |r| r[:body]["repositories"] }
    assert_equal 1, offered.length
    assert_equal later_root, offered.first.find { |b| b["repository"] == @root_slug }["commit"],
                 "the machine offers the tip it resolved"
    assert_equal [ stored_root ], observed, "only the set Platform returned is placed"
    assert core_started?
    assert_match(/Prepared #{TASK} at /, output)
  end

  def test_an_unconfirmed_recording_refuses_before_the_provider_and_releases_the_claim
    gh_dir, gh_log, = gh_bin
    start(continuation_block: continuation)
    @platform.initial_bases_response = [ 503, { error: "unavailable" } ]

    code, output = run_cli(gh_dir)

    refute_equal 0, code, output
    assert_match(/Platform did not confirm the initial repository bases/, output)
    refute core_started?
    assert_equal 1, requests_to("/api/runner/claim_releases").length
    assert_nil @platform.last_terminal_result
    assert_equal 0, FakeGithub.pr_creates(gh_log)
    refute_match(/Prepared #{TASK} at /, output)
  end

  def test_a_recording_answered_without_a_set_refuses_before_the_provider
    gh_dir, = gh_bin
    start(continuation_block: continuation)
    @platform.initial_bases_response = [ 200, {} ]

    code, output = run_cli(gh_dir)

    refute_equal 0, code, output
    assert_match(/Platform did not confirm the initial repository bases/, output)
    refute core_started?
    assert_equal 1, requests_to("/api/runner/claim_releases").length
  end

  def test_an_unreadable_origin_refuses_before_recording_or_launching
    gh_dir, = gh_bin
    start(continuation_block: continuation)
    FileUtils.remove_entry(bare_of("component-c"))

    code, output = run_cli(gh_dir)

    refute_equal 0, code, output
    assert_match(/could not read the default branch of "SpecRelay\/component-c"/, output)
    assert_empty requests_to("/api/runner/initial_repository_bases")
    refute core_started?
    assert_equal 1, requests_to("/api/runner/claim_releases").length
    assert_nil @platform.last_terminal_result
  end

  def test_a_stored_commit_missing_from_the_remote_refuses_before_the_provider
    gh_dir, = gh_bin
    start(continuation_block: continuation)
    @platform.initial_bases = ([ "." ] + MultiRepositoryWorkspace::COMPONENTS).map do |name|
      { "repository" => slug_for(name), "default_branch" => "main", "commit" => "0" * 40 }
    end

    code, output = run_cli(gh_dir)

    refute_equal 0, code, output
    assert_match(/does not contain the stored initial base/, output)
    refute core_started?
    assert_equal 1, requests_to("/api/runner/claim_releases").length
  end

  # Scenario 6 at the execution boundary: the first attempt placed the environment and was then
  # refused; the retry reuses that environment, receives the first set unchanged and reconciles.
  # What the first attempt left: the environment placed at the package, the specification and the
  # set Platform stored for it.
  def first_attempt_placement
    task_root = create_task_workspace
    bases = resolved_bases(task_root)
    pinned = @payload.fetch("specification_package")
    anchor = { repository: pinned["repository_slug"], head: pinned["head_sha"], package_path: pinned["package_path"] }
    placed = materializer.materialize(task_root: task_root, specification: anchor, initial_bases: bases)
    raise placed.reason unless placed.ok?

    @platform.initial_bases = bases
    File.truncate(@built.worktree_log, 0)
    [ task_root, bases ]
  end

  def test_a_retry_reconciles_its_reused_environment_to_the_first_set
    gh_dir, = gh_bin
    start(continuation_block: continuation)
    task_root, bases = first_attempt_placement
    first_root = head_of(task_root, ".")
    later_root = advance_remote_main(".")
    observed = []
    original = @platform.method(:report)
    @platform.define_singleton_method(:report) do |request|
      observed << DemoWorkspace.git(task_root, "rev-parse", "HEAD").strip
      original.call(request)
    end

    code, output = run_cli(gh_dir)

    assert_equal 0, code, output
    assert_equal "status #{TASK} --json", worktree_invocations.first, "the environment was reused"
    offered = requests_to("/api/runner/initial_repository_bases").map { |r| r[:body]["repositories"] }
    assert_equal later_root, offered.first.find { |b| b["repository"] == @root_slug }["commit"]
    assert_equal bases, @platform.initial_bases, "Platform keeps the first set"
    assert_equal [ first_root ], observed
    assert core_started?
  end

  def test_a_retry_whose_reused_environment_diverged_refuses_before_the_provider
    gh_dir, = gh_bin
    start(continuation_block: continuation)
    task_root, = first_attempt_placement
    diverged = DemoWorkspace.git(task_root, "commit-tree", "HEAD^{tree}", "-m", "diverged").strip
    DemoWorkspace.git(task_root, "reset", "-q", "--hard", diverged)

    code, output = run_cli(gh_dir)

    refute_equal 0, code, output
    assert_match(/has diverged from the stored initial base/, output)
    refute core_started?
    assert_equal 1, requests_to("/api/runner/claim_releases").length
    assert_equal diverged, head_of(task_root, ".")
  end

  # Scenario 6 when the first attempt was refused BEFORE placement — what an unreadable origin, an
  # unconfirmed recording or a missing commit leaves: the environment exists, owned by this run,
  # holding only what the project command built from the local checkouts and no work of this run.
  def first_attempt_refused_before_placement
    task_root = create_task_workspace
    File.truncate(@built.worktree_log, 0)
    task_root
  end

  # `[branch, head]` of each named checkout when the report is made, before the run releases it.
  def checkouts_at_report(task_root, names)
    observed = []
    original = @platform.method(:report)
    @platform.define_singleton_method(:report) do |request|
      observed << names.to_h do |name|
        path = File.join(task_root, name)
        [ name, [ DemoWorkspace.git(path, "branch", "--show-current").strip,
                  DemoWorkspace.git(path, "rev-parse", "HEAD").strip ] ]
      end
      original.call(request)
    end
    observed
  end

  def test_a_retry_after_a_refusal_before_placement_places_the_stored_set_not_local_commits
    gh_dir, = gh_bin
    start(continuation_block: continuation)
    stored_root = remote_main(".")
    local = leave_local_commit(".")
    task_root = first_attempt_refused_before_placement
    assert_equal local, head_of(task_root, "."), "the project command starts from the local head"
    observed = checkouts_at_report(task_root, [ "." ])

    code, output = run_cli(gh_dir)

    assert_equal 0, code, output
    assert_equal "status #{TASK} --json", worktree_invocations.first, "the environment was reused"
    assert_equal [ { "." => [ TASK, stored_root ] } ], observed, "never the unpublished local commit"
    assert core_started?
    assert_match(/Prepared #{TASK} at /, output)
  end

  def test_a_retry_after_a_refusal_before_placement_places_detached_components
    gh_dir, = gh_bin
    start(continuation_block: continuation)
    FileUtils.mkdir_p(File.join(@root, ".runs"))
    FileUtils.touch(File.join(@root, ".runs", "detach-components"))
    task_root = first_attempt_refused_before_placement
    MultiRepositoryWorkspace::COMPONENTS.each do |name|
      assert_equal "", DemoWorkspace.git(File.join(task_root, name), "branch", "--show-current").strip
    end
    observed = checkouts_at_report(task_root, MultiRepositoryWorkspace::COMPONENTS)

    code, output = run_cli(gh_dir)

    assert_equal 0, code, output
    assert_equal "status #{TASK} --json", worktree_invocations.first, "the environment was reused"
    assert_equal 1, observed.length
    observed.first.each_value { |branch, _head| assert_equal TASK, branch }
    assert_equal @heads.fetch("component-b"), observed.first.fetch("component-b").last
    assert core_started?
  end

  # --- a question on the accepted continuation --------------------------------------------------

  QUESTION = {
    "questions" => [ { "prompt" => "Which component owns the total?" } ],
    "continuation_context" => {
      "progress" => "the first edit landed", "changed_areas" => "component-a/app.txt",
      "why_it_matters" => "ownership decides where the rule lives", "next_step" => "apply the rule",
      "remaining_work" => "the rule and its tests", "do_not_repeat" => "the first edit"
    }
  }.freeze

  def question_submissions = @platform.question_submissions
  def checkpoint_entries(submission) = submission[:body]["checkpoint"]["repositories"].to_h { |e| [ e["path"], e ] }

  # Changes every kind of file in the workspace repository, an accepted repository and the
  # specification repository, then asks. A resumed session records what it was handed, outside
  # the task workspace, changes one more file and asks again.
  def question_executor
    path = File.join(Dir.mktmpdir("specrelay-question-"), "question-executor")
    @clones << File.dirname(path)
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      require "yaml"
      prompt = File.read(ARGV.last.to_s)
      request = prompt[%r{`([^`]*/question-request\.json)`}, 1]
      abort "[question-executor] the prompt named no bridge" if request.nil?

      if prompt.include?("## Answers to your earlier questions")
        File.write(ENV.fetch("FAKE_OBSERVED"), YAML.dump(%w[. component-a component-b component-c].to_h do |repo|
          [ repo, { "branch" => `git -C #{repo} branch --show-current`.strip, "head" => `git -C #{repo} rev-parse HEAD`.strip,
                    "accepted" => File.file?(File.join(repo, "accepted.txt")),
                    "status" => `git -C #{repo} status --porcelain --untracked-files=all`.lines.map(&:strip).sort } ]
        end))
        File.write("component-a/app.txt", "#{File.read('component-a/app.txt')}resumed by the provider\n")
        puts "[question-executor] resumed and asking again"
      else
        File.write("workspace.txt", "#{File.read('workspace.txt')}interrupted\n")
        File.write("component-a/app.txt", "#{File.read('component-a/app.txt')}interrupted\n")
        File.binwrite("component-a/logo.bin", "\x00\x01\xFF".b)
        File.chmod(0o755, "component-a/app.txt")
        File.delete("component-a/bin/revert-it")
        File.write("component-c/app.txt", "#{File.read('component-c/app.txt')}interrupted\n")
        puts "[question-executor] edited before asking"
      end
      File.write("#{request}.partial", ENV.fetch("FAKE_EXECUTOR_QUESTION_JSON"))
      File.rename("#{request}.partial", request)
      deadline = Time.now + 20
      sleep 0.05 until Time.now > deadline
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end

  # Placement's stored set is the remote default branches as they were; every origin then moves
  # on, so its advertised tip is in no placed checkout's history — the observed incident.
  def ask_on_an_advanced_main(gh_dir)
    start(continuation_block: continuation)
    use_fixture(fixture_dir, question_executor, env: { "FAKE_EXECUTOR_QUESTION_JSON" => QUESTION.to_json })
    @platform.initial_bases = ([ "." ] + MultiRepositoryWorkspace::COMPONENTS).map do |name|
      { "repository" => slug_for(name), "default_branch" => "main", "commit" => remote_main(name) }
    end
    [ ".", "component-a", "component-c" ].each { |name| advance_remote_main(name) }
    run_cli(gh_dir)
  end

  # The observed chain, closed at its first link: an accepted continuation asks after the origin's
  # main moved on, and the question is checkpointed on the bases placement decided — the stored
  # base, the accepted head and the approved specification head — instead of failing capture.
  def test_a_question_after_main_moved_is_checkpointed_on_the_decided_bases
    gh_dir, = gh_bin

    code, output = ask_on_an_advanced_main(gh_dir)

    assert_equal 0, code, output
    assert_includes output, "[question-executor] edited before asking"
    assert_match(/awaiting_input/, output)
    assert_empty @platform.capture_failures, output
    entries = checkpoint_entries(question_submissions.first)
    assert_equal %w[. component-a component-c], entries.keys.sort
    assert_equal @platform.initial_bases.find { |b| b["repository"] == @root_slug }["commit"], entries["."]["base_sha"]
    assert_equal @heads.fetch("component-a"), entries["component-a"]["base_sha"]
    assert_equal @payload.dig("specification_package", "head_sha"), entries["component-c"]["base_sha"]
    entries.each do |name, entry|
      files = DemoWorkspace.git(bare_of(name), "ls-tree", "-r", "--name-only", entry["snapshot_sha"])
      refute_includes files, "upstream.txt", "#{name}'s checkpoint imported its origin's later commits"
    end
    assert_empty @platform.requests_to("/api/runner/reports")
  end

  # Scenario 5 — the answered question continues on a machine that never held the work. The fresh
  # workspace gets the recorded work on its recorded bases, the untouched accepted repository at
  # its accepted head, and the session's next question is checkpointed on the same bases.
  def test_a_fresh_machine_restores_the_accepted_work_and_asks_again_on_the_same_bases
    gh_dir, = gh_bin
    DemoWorkspace.git(File.join(@root, "component-c"), "push", "-q", "origin", "HEAD:refs/heads/spec-#{TASK}")
    code, output = ask_on_an_advanced_main(gh_dir)
    assert_equal 0, code, output
    first = question_submissions.first[:body]["checkpoint"]
    stored = @platform.initial_bases

    second = second_machine
    observed = File.join(Dir.mktmpdir("specrelay-observed-"), "observed.yml")
    @clones << File.dirname(observed)
    use_fixture(fixture_dir, question_executor,
                env: { "FAKE_EXECUTOR_QUESTION_JSON" => QUESTION.to_json, "FAKE_OBSERVED" => observed })
    resume_on(second, first, stored)
    code, output = run_cli(gh_dir)

    assert_equal 0, code, output
    assert_includes output, "[question-executor] resumed and asking again"
    handed = YAML.safe_load(File.read(observed))
    first_entries = first["repositories"].to_h { |entry| [ entry["path"], entry ] }
    first_entries.each do |name, entry|
      assert_equal [ TASK, entry["base_sha"] ], handed.fetch(name).values_at("branch", "head")
    end
    assert_equal [ TASK, @heads.fetch("component-b"), [] ], handed.fetch("component-b").values_at("branch", "head", "status")
    assert handed.fetch("component-a")["accepted"], "the accepted code is in the fresh workspace"
    assert handed.fetch("component-b")["accepted"]
    assert_equal [ "?? logo.bin", "D bin/revert-it", "M app.txt" ], handed.fetch("component-a")["status"]
    assert_equal 0o755, File.stat(File.join(MultiRepositoryWorkspace.task_workspace(second, TASK), "component-a", "app.txt")).mode & 0o777
    again = checkpoint_entries(question_submissions.first)
    assert_equal first_entries.transform_values { |e| e["base_sha"] }, again.transform_values { |e| e["base_sha"] }
    assert_empty @platform.capture_failures, output
  end

  # A machine holding the same project, answered by the SAME remotes the first one pushed to.
  def second_machine
    second = File.join(Dir.mktmpdir("specrelay-accepted-second-"), "workspace")
    @clones << File.dirname(second)
    clone_from(bare_of("."), second, "multi-demo-workspace")
    MultiRepositoryWorkspace.write_project_command(second, MultiRepositoryWorkspace::COMPONENTS)
    MultiRepositoryWorkspace::COMPONENTS.each { |name| clone_from(bare_of(name), File.join(second, name), name) }
    second
  end

  def clone_from(bare, target, name)
    system("git", "clone", "-q", bare, target, exception: true)
    { "user.email" => "runner@example.test", "user.name" => "Runner Test", "commit.gpgsign" => "false" }
      .each { |key, value| DemoWorkspace.git(target, "config", key, value) }
    DemoWorkspace.git(target, "remote", "set-url", "origin", "git@github.com:SpecRelay/#{name}.git")
    FakeGithub.serve_locally(target, bare)
  end

  # The same run claimed again with the answers and the recorded manifest, and the stored set
  # Platform answers every later attempt with.
  def resume_on(root, checkpoint, stored)
    @platform.stop
    payload = @payload.merge(
      "resume" => { "question_id" => "exq_fake",
                    "checkpoint" => checkpoint.except("payload")
                                              .merge("download_path" => "/api/runner/executor_questions/exq_fake/checkpoint"),
                    "continuation_context" => QUESTION["continuation_context"], "questions" => QUESTION["questions"],
                    "answers" => [ { "text" => "component-a owns it." } ] }
    )
    @platform = FakePlatform.new(claim_payload: payload).start
    @platform.checkpoint_payload = checkpoint["payload"]
    @platform.delivery_response = [ 200, { question: { id: "exq_fake", state: "RESUMED" } } ]
    @platform.initial_bases = stored
    @config_path = write_config(root)
  end

  # --- a resumed checkpoint is proved against the decided inputs before it is placed -------------

  # The answered checkpoint with component-a's work re-recorded on the accepted head's PARENT — the
  # earlier main commit a pre-correction capture could choose — and every other term valid: the
  # ref exists, the snapshot's sole parent is that base and the digest matches.
  def recorded_on_the_earlier_main(checkpoint)
    entries = Marshal.load(Marshal.dump(checkpoint["repositories"]))
    entry = entries.find { |row| row["path"] == "component-a" }
    repo = File.join(MultiRepositoryWorkspace.task_workspace(@root, TASK), "component-a")
    earlier = DemoWorkspace.git(repo, "rev-parse", "#{@heads.fetch('component-a')}^").strip
    tree = DemoWorkspace.git(repo, "rev-parse", "#{entry['snapshot_sha']}^{tree}").strip
    snapshot = DemoWorkspace.git(repo, "commit-tree", tree, "-p", earlier, "-m", "checkpoint on the earlier main").strip
    ref = "refs/heads/runner-checkpoints/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    DemoWorkspace.git(repo, "push", "-q", "origin", "#{snapshot}:#{ref}")
    entry.merge!("base_sha" => earlier, "base_ref" => "refs/heads/main", "snapshot_sha" => snapshot,
                 "checkpoint_ref" => ref,
                 "change_digest" => SpecrelayRunner::Checkpoint.change_digest(repo, earlier, tree))
    sealed = SpecrelayRunner::Checkpoint.seal(entries)
    raise sealed.error unless sealed.ok?

    [ sealed.checkpoint, earlier ]
  end

  # Every branch, HEAD, index, status and working-tree byte of each repository in a task workspace.
  def destination_state(task_root)
    ([ "." ] + MultiRepositoryWorkspace::COMPONENTS).to_h do |name|
      dir = repo_path(task_root, name)
      files = Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).reject { |e| e == ".git" || e.start_with?(".git/") || e.end_with?("/.") }
      [ name, [ DemoWorkspace.git(dir, "branch", "--show-current"), DemoWorkspace.git(dir, "rev-parse", "HEAD"),
                DemoWorkspace.git(dir, "ls-files", "--stage"),
                DemoWorkspace.git(dir, "status", "--porcelain", "--untracked-files=all", "--ignored"),
                files.sort.map { |e| full = File.join(dir, e); File.file?(full) ? [ e, File.stat(full).mode, File.binread(full) ] : [ e ] } ] ]
    end
  end

  # The resumed run, with the destination recorded at the moment `Checkpoint.restore` is entered:
  # after the workspace was created or found and before any checkpoint placement could begin.
  def resume_observing_restore(gh_dir)
    observe = method(:destination_state)
    entered = []
    original = SpecrelayRunner::Checkpoint.method(:restore)
    SpecrelayRunner::Checkpoint.define_singleton_method(:restore) do |*args, **kwargs, &block|
      entered << observe.call(kwargs.fetch(:task_root))
      original.call(*args, **kwargs, &block)
    end
    code, output = run_cli(gh_dir)
    [ code, output, entered ]
  ensure
    SpecrelayRunner::Checkpoint.define_singleton_method(:restore, original)
  end

  # Nothing past the refusal: no provider, no acknowledged delivery, no question, report or
  # publication, and no release of the task environment.
  def assert_refused_before_anything_ran(destination_root, output)
    refute_includes output, "[question-executor] resumed"
    refute @platform.protocol_events.any? { |event| event["event_type"] == "core.started" }
    assert_empty @platform.delivery_acknowledgements
    assert_empty @platform.executor_questions
    assert_empty @platform.requests_to("/api/runner/reports")
    log = File.join(destination_root, ".runs", "worktree.log")
    refute_match(/^release /, File.exist?(log) ? File.read(log) : "", "the task environment was released")
  end

  def asked_once(gh_dir)
    DemoWorkspace.git(File.join(@root, "component-c"), "push", "-q", "origin", "HEAD:refs/heads/spec-#{TASK}")
    code, output = ask_on_an_advanced_main(gh_dir)
    assert_equal 0, code, output
    [ question_submissions.first[:body]["checkpoint"], @platform.initial_bases ]
  end

  # A fresh machine: the checkpoint's base disagrees with the accepted head, so the resume refuses
  # with every repository exactly as the workspace was built.
  def test_a_checkpoint_on_another_base_is_refused_before_a_fresh_machine_places_it
    gh_dir, = gh_bin
    checkpoint, stored = asked_once(gh_dir)
    mismatched, earlier = recorded_on_the_earlier_main(checkpoint)
    second = second_machine
    resume_on(second, mismatched, stored)

    code, output, entered = resume_observing_restore(gh_dir)

    refute_equal 0, code, output
    assert_match(/"component-a" was recorded on #{earlier[0, 12]}, not on the accepted head/, output)
    assert_equal 1, entered.length, output
    assert_equal entered.first, destination_state(MultiRepositoryWorkspace.task_workspace(second, TASK)),
                 "the refused checkpoint changed the fresh workspace"
    assert_refused_before_anything_ran(second, output)
  end

  # The machine that asked: its task workspace still holds the work, and a refused checkpoint
  # neither resets it onto the other base nor rewrites a file.
  def test_a_checkpoint_on_another_base_is_refused_before_the_asking_machine_places_it
    gh_dir, = gh_bin
    checkpoint, stored = asked_once(gh_dir)
    mismatched, earlier = recorded_on_the_earlier_main(checkpoint)
    task_root = MultiRepositoryWorkspace.task_workspace(@root, TASK)
    resume_on(@root, mismatched, stored)

    code, output, entered = resume_observing_restore(gh_dir)

    refute_equal 0, code, output
    assert_match(/"component-a" was recorded on #{earlier[0, 12]}, not on the accepted head/, output)
    assert_equal 1, entered.length, output
    assert_equal entered.first, destination_state(task_root), "the refused checkpoint changed the asking workspace"
    assert_equal @heads.fetch("component-a"), head_of(task_root, "component-a")
    assert_refused_before_anything_ran(@root, output)
  end

  # Inputs the resume cannot fully decide — a stored set missing a contained repository, or naming
  # one this workspace does not hold — refuse at the same boundary, before any placement.
  def test_an_incomplete_or_foreign_stored_set_is_refused_before_a_resume_places_anything
    gh_dir, = gh_bin
    checkpoint, stored = asked_once(gh_dir)
    {
      "no initial base is stored for the contained repository" =>
        stored.reject { |base| base["repository"] == @root_slug },
      "is not a repository of the prepared task workspace" =>
        stored + [ { "repository" => "SpecRelay/elsewhere", "default_branch" => "main", "commit" => "0" * 40 } ]
    }.each do |reason, set|
      second = second_machine
      resume_on(second, checkpoint, set)

      code, output, entered = resume_observing_restore(gh_dir)

      refute_equal 0, code, "#{reason}: #{output}"
      assert_includes output, reason
      assert_equal 1, entered.length, output
      assert_equal entered.first, destination_state(MultiRepositoryWorkspace.task_workspace(second, TASK)), reason
      assert_refused_before_anything_ran(second, output)
    end
  end
end
