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

  # The executor. `FAKE_EDITED` names the repositories it actually changes (comma-separated
  # relative paths, "." for the workspace repository); `FAKE_SELECTED` names what it REPORTS,
  # defaulting to what it edited — so "reported but unchanged" is expressible.
  #
  # MAPIAI-93 — it also reports the VERIFICATION it selected per repository, and (with
  # `FAKE_RUN_SELECTED`) really runs it from that repository before it exits, repairing and
  # rerunning when `FAKE_REPAIR` is set. That is the executor half of the contract: the runner's
  # replay is the independent final gate, but the repair opportunity is here.
  #
  #   FAKE_COMMANDS  - JSON object mapping a reported path to its ordered argv commands.
  #                    Defaults to `bin/verify` for every reported component repository.
  #   FAKE_BREAK     - comma-separated repositories whose edit is left in a state `bin/verify`
  #                    rejects, so an unresolved failure is expressible.
  #   FAKE_REPAIR    - after a selected command fails, fix the edit and rerun it.
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

      def target(relative) = relative == "." ? "workspace.txt" : File.join(relative, "app.txt")

      # Echoed back so the test can prove the prompt really told the executor to run, diagnose,
      # repair and rerun its own selection — not merely that a document path was named.
      puts "[multi-executor] instructions #{prompt[/^- Run what you select.*$/].to_s.strip}"

      broken = ENV.fetch("FAKE_BREAK", "").split(",").reject(&:empty?)
      edited = ENV.fetch("FAKE_EDITED", "component-a,component-b").split(",").reject(&:empty?)
      edited.each do |relative|
        marker = broken.include?(relative) ? "half-edited by the executor" : "edited by the executor"
        File.write(target(relative), "#{File.read(target(relative))}#{marker}\n")
        puts "[multi-executor] edited #{relative}"
      end

      reported = ENV.fetch("FAKE_SELECTED", edited.join(",")).split(",").reject(&:empty?)
      selected = JSON.parse(ENV.fetch("FAKE_COMMANDS", "{}"))
      commands_for = ->(relative) do
        selected.fetch(relative, relative == "." ? [] : [ [ "bin/verify" ] ])
      end

      # The executor runs what it selected while it still controls the implementation, and
      # repairs what it can. Reported to stdout so "it ran, it diagnosed, it reran" is an
      # observable fact rather than an inference from a passing runner replay.
      if ENV["FAKE_RUN_SELECTED"]
        reported.each do |relative|
          commands_for.call(relative).each do |argv|
            ok = system(*argv, chdir: (relative == "." ? "." : relative), out: File::NULL, err: File::NULL)
            puts "[multi-executor] ran #{argv.join(' ')} in #{relative}: #{ok ? 'passed' : 'failed'}"
            next if ok || ENV["FAKE_REPAIR"].nil?

            File.write(target(relative), File.read(target(relative)).sub("half-edited by the executor",
                                                                        "edited by the executor"))
            repaired = system(*argv, chdir: (relative == "." ? "." : relative), out: File::NULL, err: File::NULL)
            puts "[multi-executor] repaired #{relative} and reran #{argv.join(' ')}: #{repaired ? 'passed' : 'failed'}"
          end
        end
      end

      document = ENV["FAKE_SELECTION_JSON"] ||
                 JSON.generate({ "repositories" => reported.map do |path|
                   { "path" => path, "commands" => commands_for.call(path) }
                 end })
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
    FileUtils.mkdir_p(File.join(path, "bin"))
    File.write(File.join(path, "app.txt"), "#{name}\n")
    File.write(File.join(path, ".gitignore"), "/#{IGNORED_OUTPUT}/\n")
    write_component_verify(path)
    write_component_side_effects(path)
    DemoWorkspace.git_init(path)
    FakeGithub.add_remote(path, name: name)
  end

  # Where a verification command may legitimately drop its own scratch output. It is git-ignored,
  # so it is not publishable state and must not fail a run.
  IGNORED_OUTPUT = "tmp-verify-output"

  # MAPIAI-93 CR-001 F1 — verification commands that SUCCEED and yet leave the repository in a
  # different publishable state than the one the runner measured before replay. Each is a real
  # script committed in the repository that owns it, so the runner replays it exactly as it would
  # replay a formatter, a snapshot updater or a lockfile-writing build.
  #
  #   bin/mutate         - rewrites a tracked file (the formatter/snapshot case)
  #   bin/commit-it      - commits, moving HEAD out from under the measurement
  #   bin/revert-it      - undoes the executor's edit, leaving nothing to publish
  #   bin/verify-ignored - writes only git-ignored scratch output, which is harmless
  def write_component_side_effects(path)
    write_script(path, "mutate", "echo 'rewritten by the verification command' >> app.txt")
    write_script(path, "commit-it", <<~SH)
      git add -A
      git -c user.email=v@example.test -c user.name=V commit -q -m "committed by verification"
    SH
    write_script(path, "revert-it", "git checkout -- app.txt")
    write_script(path, "verify-ignored", <<~SH)
      mkdir -p #{IGNORED_OUTPUT}
      echo scratch > #{IGNORED_OUTPUT}/log.txt
    SH
  end

  def write_script(path, name, body)
    script = File.join(path, "bin", name)
    File.write(script, "#!/usr/bin/env sh\nset -eu\n#{body.strip}\nexit 0\n")
    FileUtils.chmod(0o755, script)
  end

  # MAPIAI-93 — the repository's OWN verification, committed in the repository that owns it.
  #
  # It reads `app.txt` by a relative path, so it passes only when it is launched with that
  # repository's root as its working directory, and only when the file already holds the
  # executor's final edit. A run against the base tree, or against the workspace root above it,
  # fails — which is what makes "the runner replayed the FINAL files, in the right place" an
  # observable fact rather than a claim.
  def write_component_verify(path)
    script = File.join(path, "bin", "verify")
    File.write(script, <<~SH)
      #!/usr/bin/env sh
      set -eu
      if grep -q "^edited by the executor$" app.txt; then
        echo "verify passed: $(basename "$(pwd)") is final"
        exit 0
      fi
      echo "verify failed: app.txt is not final" >&2
      exit 1
    SH
    FileUtils.chmod(0o755, script)
  end

  def slug(name) = "#{SLUG_OWNER}/#{name == '.' ? 'multi-demo-workspace' : name}"

  # Where the project-owned command put the task workspace.
  def task_workspace(root, task_id) = File.join(root, ".runs", "worktrees", task_id)

  def worktree_invocations(log) = File.exist?(log) ? File.read(log).lines.map(&:strip).reject(&:empty?) : []
end
