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
  def checkout_snapshot(root)
    Dir.glob("#{root}/**/*", File::FNM_DOTMATCH)
       .reject { |path| path.include?("/.git/") || path.end_with?("/.git") }
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

  def build_source(source, graph:)
    FileUtils.mkdir_p(File.join(source, "app", "services"))
    FileUtils.mkdir_p(File.join(source, "bin"))
    File.write(File.join(source, "app", "services", "export_report.rb"),
               "class ExportReport\n  def call = :exported\nend\n")
    File.write(File.join(source, "app", "services", "report_row.rb"),
               "class ReportRow\n  def to_csv = \"row\"\nend\n")
    write_graph_wrappers(source, graph) unless graph == :missing
  end

  # `fresh` exits 0 and prints a plausible check/query result; `stale` exits 3, which the
  # runner must treat as "not evidence" rather than querying anyway.
  #
  # Both wrappers print ABSOLUTE paths, exactly as the real ones do (`bin/graph-check` prints
  # its workspace root and graph path; `bin/graph-query` prints absolute source locations).
  # The first version of these stubs printed only relative paths, and that omission is why the
  # unit suite passed while the live pass failed on a host path reaching a generated file.
  # A stub that is politer than the tool it stands in for tests nothing.
  def write_graph_wrappers(source, graph)
    exit_code = graph == :stale ? 3 : 0
    freshness = graph == :stale ? "STALE" : "FRESH"
    write_executable(File.join(source, "bin", "graph-check"), <<~SH)
      #!/bin/sh
      echo "graphify version:  graphify 0.9.28"
      echo "workspace root:    #{source}"
      echo "graph path:        #{source}/graphify-out/graph.json"
      echo "freshness:         #{freshness}"
      exit #{exit_code}
    SH
    write_executable(File.join(source, "bin", "graph-query"), <<~SH)
      #!/bin/sh
      echo "NODE ExportReport [src=#{source}/app/services/export_report.rb loc=L1]"
      echo "NODE ReportRow [src=#{source}/app/services/report_row.rb loc=L1]"
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
end
