# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"

# The boundary between the Runner's own process environment and the project commands it launches.
#
# The Runner is itself a Ruby program, so its parent shell may carry Ruby, gem and Bundler
# activation that belongs to the Runner's interpreter. A project child that inherits it can load
# the Runner's libraries or install into the Runner's gem directory. Every example here spawns a
# real child and reads what that child actually saw; none of them asserts a helper's return value.
#
# The polluted keys are set on this test process's own ENV (and restored), because inheritance
# from the real parent environment is exactly the path under test.
class ProjectEnvironmentTest < Minitest::Test
  RUNNER_ACTIVATION = %w[GEM_HOME GEM_PATH RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_PATH].freeze

  # Host, authentication and user configuration a project command still needs. Synthetic values:
  # these are presence/equality sentinels, never real credentials.
  HOST_CONTEXT = {
    "XDG_CONFIG_HOME" => "/sentinel/xdg-config",
    "SSH_AUTH_SOCK" => "/sentinel/ssh-agent.sock",
    "HTTPS_PROXY" => "http://proxy.sentinel.invalid:3128",
    "SSL_CERT_FILE" => "/sentinel/certs.pem",
    "ANTHROPIC_API_KEY" => "sentinel-provider-auth",
    "BUNDLE_RUBYGEMS__PKG__GITHUB__COM" => "sentinel-package-auth",
    "BUNDLE_APP_CONFIG" => "/sentinel/bundle-app-config",
    "BUNDLE_USER_HOME" => "/sentinel/bundle-user-home"
  }.freeze

  Repository = Struct.new(:id, :relative_path, :path, keyword_init: true)

  def setup
    @dir = Dir.mktmpdir("project-environment-")
    @runner_gems = File.join(@dir, "runner-gems")
    FileUtils.mkdir_p(@runner_gems)
    File.write(File.join(@runner_gems, "installed.txt"), "runner dependency\n")
    @runner_lib = File.join(@dir, "runner-lib")
    FileUtils.mkdir_p(@runner_lib)
    File.write(File.join(@runner_lib, "runner_only_library.rb"), "# loaded only by the Runner\n")
    @project = File.join(@dir, "project")
    FileUtils.mkdir_p(File.join(@project, "bin"))
    @dump = File.join(@dir, "child-env.txt")
    @probe = script("env-probe", %(#!/bin/sh\n/usr/bin/env > "$ENV_PROBE_OUT"\n))
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  # --- CommandRunner: a nil value really removes the key --------------------

  def test_a_nil_value_removes_an_inherited_key_from_the_child_rather_than_emptying_it
    with_parent_env("SPECRELAY_DELETION_SENTINEL" => "parent", "ENV_PROBE_OUT" => @dump) do
      result = SpecrelayRunner::CommandRunner.run([ @probe ], chdir: @dir,
                                                  env: { "SPECRELAY_DELETION_SENTINEL" => nil, "COERCED" => 42 })

      assert result.success?, result.stderr
      refute child_env.key?("SPECRELAY_DELETION_SENTINEL"), "a deleted key must be absent, not empty"
      assert_equal "42", child_env["COERCED"], "non-nil values are still stringified"
      assert_equal "parent", ENV["SPECRELAY_DELETION_SENTINEL"], "the parent environment is never changed"
    end
  end

  # Opt-in, not global: readiness, publication, git and preview commands keep today's inheritance.
  def test_an_ordinary_command_keeps_the_inherited_environment
    with_polluted_parent do
      assert SpecrelayRunner::CommandRunner.run([ @probe ], chdir: @dir, env: {}).success?

      RUNNER_ACTIVATION.each { |key| assert_equal ENV[key], child_env[key], key }
    end
  end

  # --- Executor ------------------------------------------------------------

  def test_the_executor_child_loses_runner_activation_and_keeps_host_and_authentication_context
    with_polluted_parent do
      result = executor(command: @probe, extra: { "PROFILE_EXTRA" => "kept" }).run("prompt")

      assert result.success?, result.stderr
      RUNNER_ACTIVATION.each { |key| refute child_env.key?(key), "#{key} must not reach the executor" }
      HOST_CONTEXT.each { |key, value| assert_equal value, child_env[key], key }
      assert_equal ENV["HOME"], child_env["HOME"]
      assert_equal ENV["PATH"], child_env["PATH"], "the PATH that resolved the executor is kept"
      assert_equal "kept", child_env["PROFILE_EXTRA"]
      assert_parent_unchanged
    end
  end

  # A descendant the executor launches inherits the same corrected environment, so the project's
  # own install step writes to the project, and the Runner's gem directory is untouched.
  def test_an_executor_descendant_installs_into_the_project_not_the_runner
    project_install_script
    driver = script("executor-driver", %(#!/bin/sh\ncd #{Shellwords.escape(@project)} && exec bin/install\n))

    with_polluted_parent do
      before = snapshot(@runner_gems)
      result = executor(command: driver).run("prompt")

      assert result.success?, result.stderr
      assert_equal "fixture dependency\n", File.read(File.join(@project, "vendor", "gems", "fixture-dep"))
      assert_equal before, snapshot(@runner_gems), "the Runner dependency directory stays byte-identical"
    end
  end

  # --- RepositoryVerification ----------------------------------------------

  def test_independent_replay_loses_runner_activation_and_keeps_host_context
    with_polluted_parent do
      result = verify([ [ @probe ] ])

      assert result.passed?, result.attempts.map(&:output).join
      RUNNER_ACTIVATION.each { |key| refute child_env.key?(key), "#{key} must not reach verification" }
      HOST_CONTEXT.each { |key, value| assert_equal value, child_env[key], key }
      assert_equal ENV["PATH"], child_env["PATH"]
    end
  end

  # A real Ruby child: before the boundary, the Runner's RUBYOPT/RUBYLIB injected its own library
  # into every project Ruby process.
  def test_a_replayed_ruby_command_does_not_load_the_runner_injected_library
    probe = [ RbConfig.ruby, "-e", "print $LOADED_FEATURES.grep(/runner_only_library/).size" ]

    with_polluted_parent do
      result = verify([ probe ])

      assert result.passed?, result.attempts.map(&:output).join
      assert_equal "0", result.attempts.first.output.strip
    end
  end

  def test_a_replayed_install_writes_to_the_project_and_leaves_the_runner_dependencies_intact
    project_install_script

    with_polluted_parent do
      before = snapshot(@runner_gems)
      result = verify([ [ "bin/install" ] ])

      assert result.passed?, result.attempts.map(&:output).join
      assert File.file?(File.join(@project, "vendor", "gems", "fixture-dep"))
      assert_equal before, snapshot(@runner_gems)
    end
  end

  # Missing activation is the command's own failure, carried by the existing failed outcome; it is
  # never a fallback to the Runner's interpreter and never `not_found`.
  def test_a_missing_project_runtime_fails_its_command_with_the_reason
    script_in_project("check", <<~SH)
      #!/bin/sh
      command -v specrelay-missing-runtime >/dev/null 2>&1 || { echo "required runtime specrelay-missing-runtime is not installed" >&2; exit 127; }
      echo "dependent step ran"
    SH

    with_polluted_parent do
      result = verify([ [ "bin/check" ] ])

      assert_equal SpecrelayRunner::RepositoryVerification::FAILED, result.status
      assert_equal 127, result.attempts.first.exit_code
      assert_includes result.attempts.first.output, "required runtime specrelay-missing-runtime is not installed"
      refute_includes result.attempts.first.output, "dependent step ran"
    end
  end

  # --- Workspace: the project-owned create command --------------------------

  def test_the_project_create_command_runs_without_runner_activation_and_the_task_is_located
    root = File.join(@dir, "checkout")
    FileUtils.mkdir_p(File.join(root, "bin"))
    File.write(File.join(root, "bin", "worktree"), <<~SH)
      #!/bin/sh
      /usr/bin/env > "$ENV_PROBE_OUT"
      git worktree add -q -b "$2" ".worktrees/$2" HEAD
    SH
    FileUtils.chmod(0o755, File.join(root, "bin", "worktree"))
    DemoWorkspace.git_init(root)

    with_polluted_parent do
      info = SpecrelayRunner::Workspace.new(root: root, canonical_branch: "DEMO-7", task_id: "DEMO-7",
                                            create_command: "").create

      assert info.created?
      assert_equal File.realpath(File.join(root, ".worktrees", "DEMO-7")), File.realpath(info.path)
      refute_nil info.base_commit, "git bookkeeping still reads the created task"
      RUNNER_ACTIVATION.each { |key| refute child_env.key?(key), "#{key} must not reach project creation" }
      HOST_CONTEXT.each { |key, value| assert_equal value, child_env[key], key }
    end
  end

  private

  def executor(command:, extra: {})
    staging = File.join(@dir, "staging")
    FileUtils.mkdir_p(staging)
    SpecrelayRunner::Executor.new(config: { "command" => command, "prompt_delivery" => "file_argument",
                                            "timeout_seconds" => 30, "env" => extra },
                                  worktree_path: @project, staging_dir: staging)
  end

  def verify(commands)
    SpecrelayRunner::RepositoryVerification.call(
      repository: Repository.new(id: "SpecRelay/project", relative_path: ".", path: @project),
      commands: commands, env: ENV, timeout_seconds: 30
    )
  end

  # The project's dependency tool honours an inherited GEM_HOME the way RubyGems does, and uses the
  # project's own destination otherwise.
  def project_install_script
    script_in_project("install", <<~'SH')
      #!/bin/sh
      set -eu
      dest="${GEM_HOME:-$PWD/vendor/gems}"
      mkdir -p "$dest"
      printf 'fixture dependency\n' > "$dest/fixture-dep"
    SH
  end

  def with_polluted_parent(&)
    activation = {
      "GEM_HOME" => @runner_gems, "GEM_PATH" => @runner_gems,
      "RUBYOPT" => "-rrunner_only_library", "RUBYLIB" => @runner_lib,
      "BUNDLE_GEMFILE" => "/sentinel/runner/Gemfile", "BUNDLE_BIN_PATH" => "/sentinel/runner/bundle",
      "BUNDLE_PATH" => @runner_gems
    }
    @parent_before = activation.merge(HOST_CONTEXT)
    with_parent_env(@parent_before.merge("ENV_PROBE_OUT" => @dump), &)
  end

  def with_parent_env(values)
    saved = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  def assert_parent_unchanged
    @parent_before.each { |key, value| assert_equal value, ENV[key], "parent #{key} changed" }
  end

  def child_env
    File.readlines(@dump, chomp: true).filter_map { |line| line.split("=", 2) if line.include?("=") }.to_h
  end

  def snapshot(dir)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).sort.map do |relative|
      path = File.join(dir, relative)
      [ relative, File.file?(path) ? File.binread(path) : :directory ]
    end
  end

  def script(name, body)
    path = File.join(@dir, name)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
    path
  end

  def script_in_project(name, body)
    path = File.join(@project, "bin", name)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
    path
  end
end
