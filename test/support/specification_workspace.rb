# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

# A throwaway pair of checkouts for the specification lane's tests (MVP-0026).
#
# The lane spans TWO repositories on the operator's disk and they are not the same one: the
# SOURCE checkout is the code a specification is written about, and the SPECIFICATION checkout
# is where the generated package lands. Most of the interesting failures — a package escaping
# its folder, a host path leaking into generated Markdown, an atomic replace — are only
# observable when the two are genuinely separate directories, so this builds them that way
# rather than pointing both at one fixture.
#
# The source checkout also gets executable `bin/graph-check` and `bin/graph-query` stubs,
# because Graphify usability is a real preflight gate and a test that skipped it would only
# ever exercise the substitute path.
module SpecificationWorkspace
  module_function

  SPECS_REMOTE = "https://github.com/SpecRelay/SpecRelay-Specs.git"
  WORKSPACE_REMOTE = "https://github.com/SpecRelay/tiny-demo-workspace.git"
  COMPONENT_REMOTE = "https://github.com/SpecRelay/tiny-demo-component.git"

  # The workspace repository's own component checkout, materialized into every task environment
  # by the project's `bin/worktree` exactly as the real workspace does. It exists so a test can
  # tell "the task environment holds several repositories" from "the task environment is one
  # checkout": the change boundary is asserted across all of them, and a fixture with a single
  # repository could never exercise that.
  COMPONENT_DIR = "component-app"

  # Returns [source_root, specification_root, temp_root]. Both checkouts are real directories
  # under one temp root so a single `remove_entry` cleans up.
  #
  # MAPIAI-62 made the specification checkout a real GIT repository with a commit and an
  # `origin`, because it is now a SEED: the runner creates a detached worktree from it, and a
  # fixture that was only a directory could never exercise the thing under test.
  def build(graph: :fresh, specs_remote: SPECS_REMOTE)
    root = Dir.mktmpdir("specrelay-spec-lane-")
    source = File.join(root, "tiny-demo-workspace")
    specs = File.join(root, "SpecRelay-Specs")
    build_source(source, graph: graph)
    build_specs(specs, remote: specs_remote)
    [ source, specs, root ]
  end

  # The Runner-owned state root for isolated package workspaces, under the same temp root so it
  # is cleaned up with everything else — and, critically, NOT inside either checkout, which is
  # the property every test about "the operator's checkout is unchanged" depends on.
  #
  # Derived from the home directory rather than from a dedicated variable: review-001 F1 deleted
  # the override, so the only thing that decides where runner state lives is HOME.
  def package_workspace_root(root)
    File.join(root, SpecrelayRunner::Specification::PackageWorkspaceStore::DEFAULT_RELATIVE_PATH)
  end

  # The environment additions every specification-lane CLI test needs: the runner must not write
  # its package workspaces into the developer's real home directory while the suite runs.
  def lane_env(root) = { "HOME" => root }

  # Every isolated package workspace the runner created for a temp root, oldest first. Tests
  # find the package through this rather than by constructing a path: the id is opaque and
  # random by design, and a test that could predict it would be testing a fixture instead.
  def isolated_workspaces(root)
    base = package_workspace_root(root)
    return [] unless File.directory?(base)

    Dir.children(base).select { |name| name.start_with?("swp_") && File.directory?(File.join(base, name)) }
       .map { |name| File.join(base, name) }
       .sort_by { |dir| isolated_metadata(dir).to_h["created_at"].to_s + dir }
  end

  def latest_isolated_workspace(root) = isolated_workspaces(root).last

  # THE workspace, when a test has run exactly one generation. It raises rather than picking one
  # so a test that accidentally generated twice fails on the ambiguity instead of asserting
  # against whichever directory happened to sort first.
  def sole_isolated_workspace(root)
    found = isolated_workspaces(root)
    raise "expected exactly one isolated package workspace, found #{found.length}" unless found.one?

    found.first
  end

  def isolated_worktree(root) = File.join(sole_isolated_workspace(root), "worktree")

  def isolated_metadata(workspace_dir)
    JSON.parse(File.read(File.join(workspace_dir, "workspace.json")))
  rescue JSON::ParserError, SystemCallError
    nil
  end

  # A checkout's WORKING-TREE files with their digests, so "nothing was modified" is asserted
  # over content rather than over mtimes, which a copy would also preserve.
  #
  # `.git` is excluded, and the exclusion is a decision worth reading rather than a convenience.
  # What criterion 1 and criterion 12 are about is the operator's own content: tracked files,
  # staged files, untracked scratch, HEAD, and the branch they are on. Git's OBJECT DATABASE and
  # remote-tracking refs are shared plumbing that `git fetch` legitimately writes — MVP-0027
  # already relied on that being safe — and `git worktree add` writes its linked-worktree record
  # under `.git/worktrees/`. Folding those into a byte comparison would make this assertion fail
  # for reasons that have nothing to do with the operator's work.
  #
  # The git-level half is asserted separately and explicitly by {git_state} and by
  # `test_the_seed_git_directory_gains_only_worktree_bookkeeping`, so nothing is waved through:
  # HEAD, the branch, every local ref and `git status` are all compared.
  #
  # `.runs/` is excluded for the same reason: it is where the project's own task-environment
  # command builds the ticket worktree, which the specification lane now creates on purpose. What
  # the operator's checkout must not gain is CONTENT, and that is what remains compared.
  def checkout_snapshot(root)
    Dir.glob("#{root}/**/*", File::FNM_DOTMATCH)
       .reject { |path| path.include?("/.git/") || path.end_with?("/.git") }
       .reject { |path| path.include?("/.runs/") }
       .select { |path| File.file?(path) }.sort.to_h do |path|
      [ path.delete_prefix("#{root}/"), Digest::SHA256.hexdigest(File.binread(path)) ]
    end
  end

  # The git-level facts an operator would notice: where HEAD points, which branch they are on,
  # every local branch tip, and what `git status` says about their working tree.
  def git_state(root)
    {
      head: git!(root, "rev-parse", "HEAD").strip,
      branch: git!(root, "rev-parse", "--abbrev-ref", "HEAD").strip,
      refs: git!(root, "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads"),
      status: git!(root, "status", "--porcelain")
    }
  end

  # `git` returns [output, status] for a command whose FAILURE is the thing under test;
  # `git!` raises, for the ordinary case where a failure is a broken fixture.
  def git(dir, *args) = Open3.capture2e("git", "-C", dir, *args)

  def git!(dir, *args)
    out, status = git(dir, *args)
    raise "git #{args.join(' ')} failed in #{dir}: #{out}" unless status.success?

    out
  end

  # A repository with one real commit. `-c user.*` rather than `git config`, so the fixture
  # never depends on — or writes to — the developer's global git identity.
  def git_init(dir, remote: nil)
    FileUtils.mkdir_p(dir)
    git!(dir, "init", "-q", "-b", "main")
    File.write(File.join(dir, ".gitkeep"), "")
    git!(dir, "add", "-A")
    git!(dir, "-c", "user.email=fixture@specrelay.local", "-c", "user.name=SpecRelay Fixture",
         "commit", "-q", "-m", "fixture")
    git!(dir, "remote", "add", "origin", remote) if remote
    dir
  end

  # Re-point an already-initialized checkout's `origin`.
  #
  # The workspace checkout is a real repository from the moment it is built, because the lane
  # needs one to build a task worktree from. A test that cares about WHICH repository it claims
  # to be therefore changes the remote rather than re-initializing: a second `git_init` has
  # nothing to commit and would fail on the existing `origin`.
  def repoint(root, remote:)
    git(root, "remote", "remove", "origin")
    git!(root, "remote", "add", "origin", remote)
    git!(root, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
    root
  end

  # The workspace checkout: a real git repository with the project-owned task-environment
  # command, because the specification lane now builds the ticket's canonical task worktree from
  # it before a provider runs. A plain directory could not be worktree'd and would only ever
  # exercise the refusal path.
  def build_source(source, graph:)
    FileUtils.mkdir_p(File.join(source, "app", "services"))
    FileUtils.mkdir_p(File.join(source, "bin"))
    File.write(File.join(source, "app", "services", "export_report.rb"),
               "class ExportReport\n  def call = :exported\nend\n")
    File.write(File.join(source, "app", "services", "report_row.rb"),
               "class ReportRow\n  def to_csv = \"row\"\nend\n")
    File.write(File.join(source, ".gitignore"), ".runs/\n#{COMPONENT_DIR}/\n")
    write_graph_wrappers(source, graph) unless graph == :missing
    write_worktree_command(source)
    git_init(source, remote: WORKSPACE_REMOTE)
    build_component(File.join(source, COMPONENT_DIR))
    source
  end

  # A second repository the project keeps beside the workspace one and clones into every task
  # environment. Ignored by the workspace repository, exactly as the real component checkouts are.
  def build_component(path)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "server.rb"), "puts :component\n")
    git_init(path, remote: COMPONENT_REMOTE)
  end

  # The project's own task-environment command, the single authority the runner invokes for
  # `create`. It builds the canonical branch worktree and materializes the component checkout
  # inside it, which is what makes a task environment several repositories rather than one.
  def write_worktree_command(source)
    write_executable(File.join(source, "bin", "worktree"), <<~SH)
      #!/usr/bin/env sh
      set -eu
      ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
      WT_ROOT="$ROOT_DIR/.runs/worktrees"
      case "${1:-}" in
        create)
          mkdir -p "$WT_ROOT"
          if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/heads/$2"; then
            git -C "$ROOT_DIR" worktree add -q "$WT_ROOT/$2" "$2"
          else
            git -C "$ROOT_DIR" worktree add -q -b "$2" "$WT_ROOT/$2" HEAD
          fi
          if [ -d "$ROOT_DIR/#{COMPONENT_DIR}" ] && [ ! -d "$WT_ROOT/$2/#{COMPONENT_DIR}" ]; then
            git clone -q "$ROOT_DIR/#{COMPONENT_DIR}" "$WT_ROOT/$2/#{COMPONENT_DIR}"
            git -C "$WT_ROOT/$2/#{COMPONENT_DIR}" remote set-url origin "#{COMPONENT_REMOTE}"
            git -C "$WT_ROOT/$2/#{COMPONENT_DIR}" checkout -q -B "$2"
          fi
          ;;
        release) git -C "$ROOT_DIR" worktree remove --force "$WT_ROOT/$2" ;;
        *) echo "usage: worktree create|release <task>" >&2; exit 1 ;;
      esac
    SH
  end

  # The task environment the project's command builds for `task_id`, or nil before it exists.
  def task_worktree(source, task_id)
    path = File.join(source, ".runs", "worktrees", task_id)
    File.directory?(path) ? path : nil
  end

  def task_worktrees(source)
    base = File.join(source, ".runs", "worktrees")
    File.directory?(base) ? Dir.children(base).sort : []
  end

  # `fresh` exits 0 and prints a plausible check/query result; `stale` exits 3, which the
  # runner must treat as "not evidence" rather than querying anyway.
  #
  # Both wrappers print ABSOLUTE paths, exactly as the real ones do (`bin/graph-check` prints
  # its workspace root and graph path; `bin/graph-query` prints absolute source locations). They
  # print the directory they were INVOKED from, because the real wrappers pin the graph to the
  # checkout they live in and a task worktree carries its own copy of them.
  # The first version of these stubs printed only relative paths, and that omission is why the
  # unit suite passed while the live pass failed on a host path reaching a generated file.
  # A stub that is politer than the tool it stands in for tests nothing.
  def write_graph_wrappers(source, graph)
    exit_code = graph == :stale ? 3 : 0
    freshness = graph == :stale ? "STALE" : "FRESH"
    write_executable(File.join(source, "bin", "graph-check"), <<~SH)
      #!/bin/sh
      HERE="$(pwd)"
      echo "graphify version:  graphify 0.9.28"
      echo "workspace root:    $HERE"
      echo "graph path:        $HERE/graphify-out/graph.json"
      echo "freshness:         #{freshness}"
      exit #{exit_code}
    SH
    write_executable(File.join(source, "bin", "graph-query"), <<~SH)
      #!/bin/sh
      HERE="$(pwd)"
      echo "NODE ExportReport [src=$HERE/app/services/export_report.rb loc=L1]"
      echo "NODE ReportRow [src=$HERE/app/services/report_row.rb loc=L1]"
      exit 0
    SH
  end

  def write_executable(path, body)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end

  # The specification repository SEED: a real git repository, with the configured folder already
  # present and a committed history the runner can create a detached worktree from.
  def build_specs(specs, remote: SPECS_REMOTE)
    FileUtils.mkdir_p(File.join(specs, "specs"))
    File.write(File.join(specs, "README.md"), "# SpecRelay specifications\n")
    File.write(File.join(specs, "specs", ".gitkeep"), "")
    git_init(specs, remote: remote)
  end

  # A provider command that returns whatever `files` describes, as JSON on stdout. Used to
  # exercise the Command provider without a model: the boundary is what is under test, not
  # the writer behind it.
  def write_provider(path, files:, exit_code: 0, stdout: nil)
    body = stdout || JSON.generate(files)
    write_executable(path, <<~SH)
      #!/bin/sh
      cat > /dev/null
      cat <<'SPECRELAY_PROVIDER_EOF'
      #{body}
      SPECRELAY_PROVIDER_EOF
      exit #{exit_code}
    SH
    path
  end

  # A provider that records the packet it was handed, so a test can assert what actually
  # crossed the boundary rather than what the Packet class says it builds.
  def write_recording_provider(path, capture_to:, files:)
    write_executable(path, <<~SH)
      #!/bin/sh
      cat > "#{capture_to}"
      cat <<'SPECRELAY_PROVIDER_EOF'
      #{JSON.generate(files)}
      SPECRELAY_PROVIDER_EOF
    SH
    path
  end

  # ---------------------------------------------------------- canonical task environment

  # A SPECIFICATION workspace that owns a real task environment.
  #
  # The other builder above models two unrelated directories, which is all the lane needed while
  # analysis ran in an empty temporary directory. Workspace-grounded generation needs the shape
  # the product actually deploys: ONE repository that is both the specification destination and
  # the workspace whose `bin/worktree create <TASK-ID>` assembles the task environment, plus
  # independent component repositories that the created environment holds as siblings, each with
  # its own remote and history.
  #
  # A single-repository fixture could not tell "the provider can read every registered
  # repository" from "the provider can read the one directory it was given", and a fixture whose
  # task environment were faked rather than built by the project's own command could not prove
  # the runner invokes that command exactly once.
  TaskEnvironment = Struct.new(:root, :temp, :bares, :worktree_log, keyword_init: true) do
    # Where the project-owned command puts the task environment for `task_id`. Tests assert
    # against git's own answer wherever they can; this is for the cases that must look at the
    # directory before the runner has been asked about it.
    def task_workspace(task_id) = File.join(root, ".runs", "worktrees", task_id)
  end

  SPECS_REPOSITORY = "SpecRelay-Specs"
  TASK_COMPONENTS = %w[component-a component-b].freeze

  def build_task_environment(components: TASK_COMPONENTS)
    temp = Dir.mktmpdir("specrelay-spec-task-")
    root = File.join(temp, SPECS_REPOSITORY)
    FileUtils.mkdir_p(File.join(root, "bin"))
    FileUtils.mkdir_p(File.join(root, "specs"))
    File.write(File.join(root, "specs", ".gitkeep"), "")
    File.write(File.join(root, "README.md"), "# SpecRelay specifications\n")
    File.write(File.join(root, ".gitignore"),
               components.map { |name| "/#{name}/\n" }.join + "/.runs/\n/graphify-out/\n")
    MultiRepositoryWorkspace.write_project_command(root, components)
    write_relocatable_graph_wrappers(root)

    bares = {}
    DemoWorkspace.git_init(root)
    bares["."] = FakeGithub.add_remote(root, name: SPECS_REPOSITORY)
    components.each { |name| bares[name] = build_task_component(root, name) }
    push_default_branches(root, components, bares)
    TaskEnvironment.new(root: root, temp: temp, bares: bares,
                        worktree_log: File.join(root, ".runs", "worktree.log"))
  end

  # One independent component repository, with its own GitHub identity, its own history and one
  # readable source file. It is deliberately NOT tracked by the workspace repository, which is
  # what makes "every contained repository was inspected" a real question rather than a property
  # of one `git status`.
  def build_task_component(root, name)
    path = File.join(root, name)
    FileUtils.mkdir_p(File.join(path, "app", "services"))
    File.write(File.join(path, "app", "services", "export_report.rb"),
               "class ExportReport\n  def call = :exported\nend\n")
    DemoWorkspace.git_init(path)
    FakeGithub.add_remote(path, name: name)
  end

  # Every repository's default branch on its own bare remote, so a later fetch of an accepted
  # head resolves against real remote state rather than a stub.
  def push_default_branches(root, components, bares)
    ([ "." ] + components).each do |relative|
      next if bares[relative].nil?

      git!(File.join(root, relative == "." ? "" : relative), "push", "-q", "origin", "HEAD:refs/heads/main")
    end
  end

  # Graphify wrappers that resolve their own root AT RUN TIME, from their own location.
  #
  # The wrappers written by {write_graph_wrappers} bake one absolute path in, which was correct
  # while there was only ever one checkout to report. It is exactly wrong here: the property
  # under test is that Graphify answers about the TASK ENVIRONMENT the provider runs in, and a
  # stub that printed a different checkout's path would report a graph for the wrong tree while
  # appearing to pass — and would then leak that other path into generated evidence.
  #
  # The query names a file inside a COMPONENT repository, because "the graph resolved from the
  # task environment" and "the task environment holds the registered repositories" are the same
  # claim seen from two sides.
  def write_relocatable_graph_wrappers(root)
    write_executable(File.join(root, "bin", "graph-check"), <<~SH)
      #!/bin/sh
      ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
      echo "graphify version:  graphify 0.9.28"
      echo "workspace root:    $ROOT_DIR"
      echo "graph path:        $ROOT_DIR/graphify-out/graph.json"
      echo "freshness:         FRESH"
      exit 0
    SH
    write_executable(File.join(root, "bin", "graph-query"), <<~SH)
      #!/bin/sh
      ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
      echo "NODE ExportReport [src=$ROOT_DIR/component-a/app/services/export_report.rb loc=L1]"
      echo "NODE Specifications [src=$ROOT_DIR/README.md loc=L1]"
      exit 0
    SH
  end
end
