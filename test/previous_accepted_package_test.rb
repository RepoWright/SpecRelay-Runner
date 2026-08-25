# frozen_string_literal: true

require_relative "test_helper"
require "open3"

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
    out, status = Open3.capture2e(File.join(@root, "bin", "worktree"), "create", TASK, chdir: @root)
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
      "closed pull request" => -> { materializer(continuation(components: [ "component-a" ]),
                                                 gh_dir: gh_bin(rows: [ open_pull_request("component-a", "state" => "CLOSED") ]).first) },
      "missing pull request" => -> { materializer(continuation(components: [ "component-a" ]),
                                                  gh_dir: gh_bin(rows: []).first) },
      "unreadable pull request" => -> { materializer(continuation(components: [ "component-a" ]),
                                                     gh_dir: gh_bin(mode: "view_fails").first) },
      "moved head" => -> { materializer(continuation(components: [ "component-a" ]),
                                        gh_dir: gh_bin(rows: [ open_pull_request("component-a", "headRefOid" => "9" * 40) ]).first) },
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
    payload = claim_payload_for(task_id: TASK, executor_command: @built.executor,
                                publication: {}, restart: restart)
    absent ? payload.delete("previous_accepted_package") :
      payload["previous_accepted_package"] = continuation_block
    payload["executor"]["env"] = { "FAKE_EDITED" => "component-a" }
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

  def run_cli(gh_dir)
    io = StringIO.new
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => "#{gh_dir}:#{ENV['PATH']}",
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
    assert_equal [ "create #{TASK}" ], worktree_invocations.grep(/\Acreate /),
                 "the project-owned command constructs the task environment exactly once"
    task_root = File.join(@root, ".runs", "worktrees", TASK)
    ACCEPTED.each { |component| assert_path_exists File.join(task_root, component, ACCEPTED_FILE) }
    assert_equal ACCEPTED.length, FakeGithub.pr_views(gh_log)
  end

  def test_reuses_an_exact_clean_task_workspace_without_creating_or_resetting_it
    task_root = create_task_workspace
    File.truncate(@built.worktree_log, 0)
    before = ACCEPTED.to_h { |name| [ name, head_of(task_root, name) ] }
    gh_dir, gh_log, = gh_bin
    start(continuation_block: continuation)

    code, = run_cli(gh_dir)

    assert_equal 0, code
    assert_empty worktree_invocations
    assert_equal 0, FakeGithub.pr_views(gh_log)
    refute_path_exists File.join(task_root, "component-b", ACCEPTED_FILE)
    assert_equal before["component-b"], head_of(task_root, "component-b")
  end

  # S06 — the native single-repository fallback. A checkout with no project-owned command builds
  # its task workspace from the command the assignment names, and the SAME materializer places
  # that one repository on the canonical branch at its accepted head.
  def test_a_checkout_without_the_project_command_is_reconstructed_the_same_way
    FileUtils.remove_entry(@root)
    @root, executor = DemoWorkspace.build
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

    payload = claim_payload_for(task_id: TASK, executor_command: executor, publication: {},
                                worktree_create_command: "git worktree add .runs/worktrees/#{TASK} -b #{TASK}")
    payload["previous_accepted_package"] = continuation(components: [ "." ]).merge(
      "implementation_pull_requests" => [ accepted_row(".", "pull_request_url" => url) ]
    )
    @platform = FakePlatform.new(claim_payload: payload).start
    @config_path = write_config

    code, output = run_cli(gh_dir)

    assert_equal 0, code, output
    assert_path_exists File.join(@root, ".runs", "worktrees", TASK, ACCEPTED_FILE)
    assert_equal 1, FakeGithub.pr_views(gh_log)
  end

  # S08 at the execution boundary — a stale continuation stops the whole attempt BEFORE the
  # provider runs, so nothing is committed, nothing is pushed, no pull request moves, and no
  # report claims a result.
  def test_a_stale_continuation_refuses_before_the_provider_and_before_any_external_write
    gh_dir, gh_log, = gh_bin(rows: [ open_pull_request("component-a", "state" => "CLOSED"),
                                     open_pull_request("component-b") ])
    start(continuation_block: continuation)

    code, output = run_cli(gh_dir)

    refute_equal 0, code, output
    assert_match(/is closed, not open/, output)
    assert_nil @platform.last_terminal_result
    assert_equal 0, FakeGithub.pr_creates(gh_log)
    task_root = File.join(@root, ".runs", "worktrees", TASK)
    refute_includes File.read(File.join(task_root, "component-a", "app.txt")), "edited by the executor"
    ACCEPTED.each { |component| refute_path_exists File.join(task_root, component, ACCEPTED_FILE) }
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
end
