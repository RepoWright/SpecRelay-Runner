# frozen_string_literal: true

require "open3"
require_relative "test_helper"

# MVP-0028 remediation slice 2, defect 5 — the hidden specification-checkout setup step.
#
# The live clean E2E needed `SPECRELAY_RUNNER_SPEC_REPOSITORY_ROOT_SPECRELAY_TINY_DEMO_WORKSPACE`
# even though the specification destination WAS the assigned source workspace repository, whose
# checkout this runner had already validated under `workspace_roots`. A guided connection writes
# no runner YAML at all, so that second, duplicate mapping was a hidden setup step no ordinary
# operator could have satisfied.
#
# Every test here runs the real CLI against a real fake Platform, exactly like
# specification_preflight_test.rb, because "the package landed in the workspace checkout" and
# "the run refused" are facts about the operator's disk and the reported failure class — not
# statements about which private method returned what.
class SpecificationSourceCheckoutReuseTest < Minitest::Test
  ISSUE = "SR-700"
  # The default `spec_creation_payload_for` specification_target: owner SpecRelay, repository
  # SpecRelay-Specs — so this is the slug a workspace checkout's remote must resolve to for
  # reuse to be offered.
  TARGET_SLUG = "SpecRelay/SpecRelay-Specs"

  def setup
    @source, @specs, @temp = SpecificationWorkspace.build
    @io = StringIO.new
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@temp) if @temp && File.directory?(@temp)
  end

  # ------------------------------------------------------------------ reuse, verified

  def test_the_same_repository_reuses_the_validated_workspace_checkout_with_no_extra_mapping
    git_init_with_remote(@source, "https://github.com/#{TARGET_SLUG}.git")
    start_platform(spec_creation_payload_for(issue_key: ISSUE))

    exit_code = run_cli(config: build_config(repository_roots: false))

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    assert File.exist?(File.join(@source, "specs", "SR-700-add-an-export-button", "spec.md")),
           "the package should have been written into the reused workspace checkout"
    refute File.exist?(File.join(@specs, "specs", "SR-700-add-an-export-button", "spec.md")),
           "nothing should have been written into the unrelated specs fixture"
  end

  # ------------------------------------------------------------------ explicit mapping preserved

  def test_a_separate_specification_repository_still_uses_the_explicit_mapping
    # The workspace checkout is ALSO a real git repo, but for a different repository entirely —
    # proving the explicit mapping wins regardless of what the workspace checkout's remote is.
    git_init_with_remote(@source, "https://github.com/SpecRelay/tiny-demo-workspace.git")
    start_platform(spec_creation_payload_for(issue_key: ISSUE))

    exit_code = run_cli(config: build_config(repository_roots: true))

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    assert File.exist?(File.join(@specs, "specs", "SR-700-add-an-export-button", "spec.md")),
           "the explicitly mapped specification checkout should have received the package"
    refute File.exist?(File.join(@source, "specs")),
           "the source workspace checkout must not be touched when an explicit mapping exists"
  end

  # ------------------------------------------------------------------ fail closed

  def test_a_workspace_checkout_with_the_wrong_remote_is_not_reused
    git_init_with_remote(@source, "https://github.com/SpecRelay/some-unrelated-repo.git")
    before = snapshot(@source)
    start_platform(spec_creation_payload_for(issue_key: ISSUE))

    exit_code = run_cli(config: build_config(repository_roots: false))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    generation = @platform.last_specification_generation
    assert_equal "specification_repository_unresolved", generation["failure_class"]
    assert_equal before, snapshot(@source), "a mismatched remote must never be written into"
  end

  def test_an_unverifiable_workspace_checkout_is_not_reused
    # No git repository at all under the workspace root — the ordinary state for a checkout
    # this operator never intended as a specification destination.
    start_platform(spec_creation_payload_for(issue_key: ISSUE))

    exit_code = run_cli(config: build_config(repository_roots: false))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    generation = @platform.last_specification_generation
    assert_equal "specification_repository_unresolved", generation["failure_class"]
    assert_includes generation["message"], "runner.specification.repository_roots"
  end

  # ------------------------------------------------------------------------- helpers

  def git_init_with_remote(dir, remote_url)
    run_git(dir, "init", "-q")
    run_git(dir, "remote", "add", "origin", remote_url)
  end

  def run_git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?
  end

  def snapshot(root)
    Dir.glob("#{root}/**/*", File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort.to_h do |path|
      [ path.delete_prefix("#{root}/"), Digest::SHA256.hexdigest(File.binread(path)) ]
    end
  end

  def start_platform(payload)
    @platform = FakePlatform.new(claim_payload: payload).start
  end

  def build_config(repository_roots:)
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
        specification:
          provider:
            kind: fake
          repository_roots:
            #{repository_roots ? "\"#{TARGET_SLUG}\": #{@specs}" : '{}'}
          context_plus:
            available: true
      workspace_roots:
        tiny-demo-workspace: #{@source}
    YAML
    SpecrelayRunner::Config.load(path)
  end

  def run_cli(config:)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{config.source_path}], out: @io, err: @io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] })
  end
end
