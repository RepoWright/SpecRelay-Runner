# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

# MAPIAI-84 — a real, hermetic PROJECT-OWNED task workspace: one workspace repository whose
# `bin/worktree create <TASK-ID>` builds a composite environment containing several INDEPENDENT
# git repositories, each with its own origin, default branch and change set.
#
# It is deliberately not a variant of {DemoWorkspace}. That fixture is one repository, which is
# the shape this ticket replaces; keeping both means the single-repository path stays proven by
# the fixture that always proved it, and the multi-repository path is proven by a workspace that
# genuinely has several remotes rather than by one repository counted twice.
#
# Nothing here reaches a network. Every origin is the GitHub url the runner must normalize, and
# {FakeGithub.serve_locally} answers it from a local bare repository over real git transport.
module MultiRepositoryWorkspace
  COMPONENTS = %w[component-a component-b component-c].freeze
  SLUG_OWNER = "SpecRelay"

  module_function

  # Returns a Struct with the workspace root, the executor path, each component's bare remote,
  # and the log the project-owned command records its invocations in.
  Built = Struct.new(:root, :executor, :bares, :worktree_log, keyword_init: true)

  def build(components: COMPONENTS)
    root = Dir.mktmpdir("specrelay-runner-multi-")
    FileUtils.mkdir_p(File.join(root, "bin"))
    File.write(File.join(root, "workspace.txt"), "workspace\n")
    # `/escape` is ignored so a test can plant a symlink escaping the task workspace without
    # that symlink itself dirtying the workspace repository, which would refuse for the wrong
    # reason and prove nothing about path containment.
    File.write(File.join(root, ".gitignore"),
               components.map { |c| "/#{c}/\n" }.join + "/.runs/\n/escape\n")
    write_project_command(root, components)
    write_test(root)
    executor = write_selecting_executor(root)

    bares = {}
    DemoWorkspace.git_init(root)
    bares["."] = FakeGithub.add_remote(root, name: "multi-demo-workspace")
    components.each do |name|
      bares[name] = init_component(root, name)
    end
    Built.new(root: root, executor: executor, bares: bares,
              worktree_log: File.join(root, ".runs", "worktree.log"))
  end

  # The project-owned command. It is the ONE authority for constructing the task environment:
  # the workspace repository on the canonical branch, and every component repository as its own
  # linked worktree on that same branch. It records every invocation, so "invoked exactly once
  # with `create <TASK-ID>`" is an observable fact rather than an inference.
  def write_project_command(root, components)
    path = File.join(root, "bin", "worktree")
    File.write(path, <<~SH)
      #!/usr/bin/env sh
      set -eu
      ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
      mkdir -p "$ROOT_DIR/.runs"
      echo "$*" >> "$ROOT_DIR/.runs/worktree.log"
      WT="$ROOT_DIR/.runs/worktrees/${2:-}"
      case "${1:-}" in
        create)
          mkdir -p "$ROOT_DIR/.runs/worktrees"
          git -C "$ROOT_DIR" worktree add -b "$2" "$WT" HEAD
          for repo in #{components.join(' ')}; do
            git -C "$ROOT_DIR/$repo" worktree add -b "$2" "$WT/$repo" HEAD
          done
          echo "created $WT"
          ;;
        release) git -C "$ROOT_DIR" worktree remove --force "$WT" ;;
        *) echo "usage: worktree create|release <task>" >&2; exit 1 ;;
      esac
    SH
    FileUtils.chmod(0o755, path)
  end

  def write_test(root)
    path = File.join(root, "bin", "test")
    File.write(path, "#!/usr/bin/env sh\necho \"test passed\"\nexit ${FAKE_TEST_EXIT:-0}\n")
    FileUtils.chmod(0o755, path)
  end

  # The executor. `FAKE_EDITED` names the repositories it actually changes (comma-separated
  # relative paths, "." for the workspace repository); `FAKE_SELECTED` names what it REPORTS,
  # defaulting to what it edited — so "reported but unchanged" is expressible.
  def write_selecting_executor(root)
    path = File.join(root, "bin", "multi-executor")
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      require "json"

      prompt = ARGV.last.to_s
      prompt = File.read(prompt) if File.file?(prompt)
      selection = prompt[%r{`([^`]*/changed-repositories\.json)`}, 1]
      abort "the prompt named no repository selection document" if selection.nil?
      abort "the prompt must not name a Platform-assigned repository list" if prompt.include?("Assigned repositories")

      edited = ENV.fetch("FAKE_EDITED", "component-a,component-b").split(",").reject(&:empty?)
      edited.each do |relative|
        file = relative == "." ? "workspace.txt" : File.join(relative, "app.txt")
        File.write(file, "#{File.read(file)}edited by the executor\n")
        puts "[multi-executor] edited #{relative}"
      end

      reported = ENV.fetch("FAKE_SELECTED", edited.join(",")).split(",").reject(&:empty?)
      document = ENV["FAKE_SELECTION_JSON"] ||
                 JSON.generate({ "repositories" => reported.map { |path| { "path" => path } } })
      unless ENV["FAKE_SELECTION_SKIP"]
        File.write("#{selection}.partial", document)
        File.rename("#{selection}.partial", selection)
      end
      exit 0
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end

  # One independent repository inside the workspace checkout, with its own history, its own
  # GitHub origin and its own default branch. It is NOT a submodule and not tracked by the
  # workspace repository — which is exactly why the workspace repository's own `git status`
  # cannot see its changes, and why per-repository measurement is required.
  def init_component(root, name)
    path = File.join(root, name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "app.txt"), "#{name}\n")
    DemoWorkspace.git_init(path)
    FakeGithub.add_remote(path, name: name)
  end

  def slug(name) = "#{SLUG_OWNER}/#{name == '.' ? 'multi-demo-workspace' : name}"

  # Where the project-owned command put the task workspace.
  def task_workspace(root, task_id) = File.join(root, ".runs", "worktrees", task_id)

  def worktree_invocations(log) = File.exist?(log) ? File.read(log).lines.map(&:strip).reject(&:empty?) : []
end
