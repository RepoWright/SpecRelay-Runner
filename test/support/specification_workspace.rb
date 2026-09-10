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

  # ------------------------------------------------------------ the real-provider PATH seam

  # A stand-in for a real provider CLI, written to disk as an executable under the exact BARE name
  # the approved profile launches, inside its own bin directory. A test prepends that directory to
  # the child PATH, so the runner exercises its real code path — exact-profile resolution, PATH
  # resolution, the approved argv, the profile's own prompt delivery and the provider's structured
  # output — with no model, no network and no account.
  #
  # It is the explicit test seam that replaced configuring an arbitrary executable as the
  # generation provider. There is no production bypass here: the profile is always the canonical
  # one, and what a bare name resolves to on a host is the host's business.
  #
  # WHAT IT ANSWERS is one of three things. `files` or `answer` bake a fixed reply into the script,
  # which is what the boundary tests need — a real model cannot be asked for malformed output on
  # demand. `compose: true` instead runs the deterministic {Composer} over the packet the runner
  # actually sent, which is how the lane tests that assert on generated CONTENT keep a stable,
  # inspectable answer. The composer is no longer a production provider; standing in for one in a
  # test is the utility role it keeps.
  # A minimal but STRUCTURALLY VALID package: every required section present with enough body to
  # clear the emptiness floor. One copy, because every lane test that needs a provider to succeed
  # needs the same thing from it, and several drifting copies of the document contract would be
  # several places to update when {DocumentSet} changes.
  def valid_documents(issue_key = "SR-700")
    sections = SpecrelayRunner::Specification::DocumentSet::REQUIRED_SECTIONS
    body = "Filler content for this section, long enough to pass the minimum length check.\n\n"
    {
      "spec.md" => "# #{issue_key} — a specification\n\n" +
        sections.fetch("spec.md").map { |heading| "## #{heading}\n\n#{body}" }.join,
      "analysis/business.md" => "# Business analysis — #{issue_key}\n\n" +
        sections.fetch("analysis/business.md").map { |heading| "## #{heading}\n\n#{body}" }.join,
      "analysis/technical.md" => "# Technical analysis — #{issue_key}\n\n" +
        sections.fetch("analysis/technical.md").map { |heading| "## #{heading}\n\n#{body}" }.join,
      "analysis/input-evidence.md" => "# Input evidence\n\nNo supporting input beyond the ticket.\n"
    }
  end

  # `analyzer_answer` is what the SAME double replies with when it is asked the OTHER question
  # this profile answers — the optional external-reference analysis. One bare name, two questions,
  # exactly as a real host resolves them.
  def claude_stub(root, files: nil, answer: nil, compose: false, exit_code: 0, capture_prompt_to: nil,
                  analyzer_answer: nil)
    provider_stub(root, "claude", delivery: :argument, exit_code: exit_code,
                                  capture_prompt_to: capture_prompt_to, analyzer_answer: analyzer_answer,
                                  answer: answer_source(files, answer, compose), emit: CLAUDE_FRAMES)
  end

  def codex_stub(root, files: nil, answer: nil, compose: false, exit_code: 0, capture_prompt_to: nil)
    provider_stub(root, "codex", delivery: :stdin, exit_code: exit_code,
                                 capture_prompt_to: capture_prompt_to, analyzer_answer: nil,
                                 answer: answer_source(files, answer, compose), emit: CODEX_FRAMES)
  end

  # The structured shape the Claude profile is contracted for: an init frame, one PUBLIC narration
  # line, and one terminal result carrying the answer. The tool it reports names a path OUTSIDE any
  # repository, because this lane is assigned none — so a local path reaching the operator at all
  # is a defect this double is able to expose.
  CLAUDE_FRAMES = <<~RUBY
    say("type" => "system", "subtype" => "init")
    say("type" => "assistant", "message" => { "content" => [
      { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/elsewhere/notes.md" } } ] })
    say("type" => "result", "subtype" => "success", "is_error" => false, "result" => answer)
  RUBY

  # The observed Codex thread shape: a started thread and turn, private reasoning the decoder must
  # withhold, one public message carrying the answer, and exactly one terminal event.
  CODEX_FRAMES = <<~RUBY
    say("type" => "thread.started", "thread_id" => "th_fixture")
    say("type" => "turn.started")
    say("type" => "item.completed",
        "item" => { "id" => "item_0", "type" => "reasoning", "text" => CODEX_PRIVATE_REASONING })
    say("type" => "item.completed",
        "item" => { "id" => "item_1", "type" => "agent_message", "text" => answer })
    say("type" => "turn.completed", "usage" => { "input_tokens" => 12 })
  RUBY

  # The private reasoning a Codex stream carries and no surface may ever show.
  CODEX_PRIVATE_REASONING = "private-codex-reasoning-do-not-publish"

  # The safe version line the Codex readiness probe is contracted to accept, for the tests that
  # select a provider LOCALLY and therefore cross that probe before claiming.
  CODEX_VERSION_LINE = "codex-cli 9.9.9"

  LIB_ROOT = File.expand_path("../../lib", __dir__)

  # The Ruby expression the double evaluates to produce its terminal answer.
  def answer_source(files, answer, compose)
    return "JSON.generate(SpecrelayRunner::Specification::Composer.call(packet))" if compose
    return answer.inspect if answer

    JSON.generate(files || valid_documents).inspect
  end

  # The one prompt every generation carries, and the only reliable way a double can tell which
  # question it was asked.
  GENERATION_MARKER = "You are writing a software specification package"

  def provider_stub(root, name, answer:, emit:, delivery:, exit_code:, capture_prompt_to:, analyzer_answer:)
    dir = Dir.mktmpdir("#{name}-stub", root)
    write_executable(File.join(dir, name), <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      require "json"

      # The bounded readiness probes, answered so a LOCAL selection reaches generation.
      if ARGV.first == "--version"
        puts #{name == 'codex' ? CODEX_VERSION_LINE.inspect : '"1.0.0"'}
        exit 0
      end
      exit 0 if %w[auth login].include?(ARGV.first)

      CODEX_PRIVATE_REASONING = #{CODEX_PRIVATE_REASONING.inspect}
      def say(event) = puts(JSON.generate(event))

      prompt = #{delivery == :stdin ? '$stdin.read.to_s' : 'ARGV.last.to_s'}
      #{capture_prompt_to ? "File.write(#{capture_prompt_to.inspect}, prompt)" : ''}
      exit #{exit_code} unless #{exit_code}.zero?

      if #{answer.include?('Composer').inspect}
        $LOAD_PATH.unshift(#{LIB_ROOT.inspect})
        require "specrelay_runner"
        packet = JSON.parse(SpecrelayRunner::Specification::BalancedJson
                              .extract_object(prompt.split("EVIDENCE (JSON):").last))
      end
      answer = #{answer}
      #{analyzer_answer ? "answer = #{analyzer_answer.inspect} unless prompt.include?(#{GENERATION_MARKER.inspect})" : ''}

      #{emit.gsub("\n", "\n      ")}
    RUBY
    dir
  end

  # The child PATH that resolves the approved provider name to a stub directory.
  def provider_path(stub_dir, base: ENV["PATH"])
    [ stub_dir, base.to_s ].reject { |entry| entry.to_s.empty? }.join(File::PATH_SEPARATOR)
  end

  # The packet a provider was handed, read back out of the captured prompt. The evidence travels
  # inside the one reviewable prompt document, so a test asserting what crossed the boundary reads
  # it the same way a provider would.
  def captured_packet(prompt_path)
    JSON.parse(SpecrelayRunner::Specification::BalancedJson
                 .extract_object(File.read(prompt_path).split("EVIDENCE (JSON):").last))
  end
end
