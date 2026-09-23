# frozen_string_literal: true

require "fileutils"
require "open3"

# Builds a real, hermetic on-disk git workspace shaped like the external Tiny
# Demo workspace, for the standalone runner flow test (MVP-0010). It mirrors the
# Platform-side RunnerWorkspace spec support so the runner exercises real
# worktree creation, real process launch, and real git diff capture — with a
# deterministic fake executor, never a remote AI provider.
module DemoWorkspace
  module_function

  # Create the workspace repo + a fake executor and return [root, executor_path].
  def build(initial_heading: "Hello Demo", expected_heading: "Hello SpecRelay Demo")
    root = Dir.mktmpdir("specrelay-runner-ws-")
    FileUtils.mkdir_p(File.join(root, "demo-app"))
    FileUtils.mkdir_p(File.join(root, "bin"))
    File.write(File.join(root, "demo-app", "index.html"), "<h1>#{initial_heading}</h1>\n")
    write_worktree(root)
    write_test(root, expected_heading)
    executor = write_fake_executor(root)
    git_init(root)
    [ root, executor ]
  end

  def write_worktree(root)
    path = File.join(root, "bin", "worktree")
    File.write(path, <<~SH)
      #!/usr/bin/env sh
      set -u
      ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
      WT_ROOT="$ROOT_DIR/.runs/worktrees"
      #{ProjectCommand.arguments}
      case "$VERB" in
        create)
          mkdir -p "$WT_ROOT"
          if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/heads/$TASK"; then
            git -C "$ROOT_DIR" worktree add "$WT_ROOT/$TASK" "$TASK" || exit 1
          else
            git -C "$ROOT_DIR" worktree add -b "$TASK" "$WT_ROOT/$TASK" HEAD || exit 1
          fi
          #{ProjectCommand.record_owner}
          ;;
        status)
          #{ProjectCommand.status_case}
          ;;
        release)
          #{ProjectCommand.release_guard}
          git -C "$ROOT_DIR" worktree remove --force "$WT_ROOT/$TASK"
          #{ProjectCommand.release_report}
          ;;
        list) git -C "$ROOT_DIR" worktree list ;;
        *) echo "usage: worktree create|status|release|list <task>" >&2; exit 1 ;;
      esac
    SH
    FileUtils.chmod(0o755, path)
  end

  # MAPIAI-84 S06 — a checkout with NO project-owned `bin/worktree`, so the runner falls back to
  # the native single-repository git worktree the assignment names. `bin/dev` exists and records
  # every invocation, because "the runner never uses bin/dev to discover or create a workspace" is
  # only provable against a `bin/dev` that would have logged it.
  def without_project_command(root)
    FileUtils.rm_f(File.join(root, "bin", "worktree"))
    dev = File.join(root, "bin", "dev")
    File.write(dev, <<~SH)
      #!/usr/bin/env sh
      echo "$*" >> "$(cd "$(dirname "$0")/.." && pwd)/.runs/dev.log"
    SH
    FileUtils.chmod(0o755, dev)
    FileUtils.mkdir_p(File.join(root, ".runs"))
    File.join(root, ".runs", "dev.log")
  end

  def write_test(root, expected_heading)
    path = File.join(root, "bin", "test")
    File.write(path, <<~SH)
      #!/usr/bin/env sh
      set -eu
      DIR="$(cd "$(dirname "$0")/.." && pwd)"
      if grep -q "#{expected_heading}" "$DIR/demo-app/index.html"; then
        echo "test passed: heading present"; exit 0
      fi
      echo "test failed: expected heading not found" >&2; exit 1
    SH
    FileUtils.chmod(0o755, path)
  end

  # A deterministic fake executor: applies one idempotent edit to the demo file.
  # It intentionally prints a fake-secret-shaped token to stdout so the runner's
  # client-side transcript redaction can be asserted.
  #
  # MVP-0034: it also reports, for every specification-package document the prompt names, whether
  # that document is readable FROM THE EXECUTOR at the moment it runs. A real executor reads them;
  # this stand-in only proves they arrived, which is what makes "the executor received all
  # documents, not only spec.md" a deterministic assertion rather than a live-run observation.
  def write_fake_executor(root)
    path = File.join(root, "bin", "fake-executor")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      puts "leaking sk-live-DO-NOT-LEAK-0123456789 to stdout"
      prompt = ARGV.last.to_s
      if File.file?(prompt)
        File.read(prompt).scan(%r{^\\s+- `(\\S*/specification-package/\\S+)`$}).flatten.each do |document|
          state = File.readable?(document) ? "readable" : "MISSING"
          puts "[fake-executor] package document \#{state}: \#{document.split('/specification-package/').last}"
        end
      end
      file = "demo-app/index.html"
      content = File.read(file)
      changed = content.include?("Hello Demo")
      if changed
        File.write(file, content.gsub("Hello Demo", "Hello SpecRelay Demo"))
        puts "[fake-executor] applied edit"
      end
      #{selection_snippet(changed: "changed")}
      exit 0
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end

  # MAPIAI-84 — the executor's structured repository selection, written exactly where the prompt
  # names it. Every fake executor writes it, because a run whose executor reports nothing is a
  # run the runner refuses: the document IS how a repository becomes publishable.
  #
  # `changed` is the caller's own expression, so each executor reports what it actually did.
  # `FAKE_EXECUTOR_SELECTION_JSON` replaces the whole document with raw bytes, so a test can send a
  # malformed, escaping, or duplicated selection without this script sanitizing it first, and
  # `FAKE_EXECUTOR_SELECTION_SKIP` writes none at all.
  #
  # MAPIAI-93 — each entry also names the verification the executor selected for that repository.
  # This fixture selects the workspace's own `bin/test`, so the single-repository flow keeps
  # proving a REAL command run against the final files rather than an empty plan.
  def selection_snippet(changed: "true", paths: nil)
    "#{selection_reporter(changed: changed, paths: paths)}\nSELECTION.call"
  end

  # The same document as a REUSABLE lambda, so an executor that must report BEFORE it asks a
  # question — which every question-asking provider now must, because SpecRelay checkpoints the
  # repositories the selection names — can call it at the right moment rather than only on exit.
  def selection_reporter(changed: "true", paths: nil)
    reported = paths || %([ { "path" => ".", "commands" => [ [ "bin/test" ] ] } ])
    <<~RUBY.strip
      SELECTION = lambda do
        unless ENV["FAKE_EXECUTOR_SELECTION_SKIP"]
          require "json"
          _prompt = ARGV.last.to_s
          _prompt = File.read(_prompt) if File.file?(_prompt)
          _selection = _prompt[%r{`([^`]*/#{SELECTION_FILENAME})`}, 1]
          abort "the prompt named no repository selection document" if _selection.nil?
          _document = ENV["FAKE_EXECUTOR_SELECTION_JSON"] ||
                      JSON.generate({ "repositories" => ((#{changed}) ? #{reported} : []) })
          File.write(_selection + ".partial", _document)
          File.rename(_selection + ".partial", _selection)
        end
      end
    RUBY
  end

  # Put that lambda into a fixture script written as a single quoted heredoc, immediately after
  # its shebang, so the script can call it wherever it needs to.
  def with_selection_reporter(source, changed: "true", paths: nil)
    shebang, rest = source.split("\n", 2)
    [ shebang, selection_reporter(changed: changed, paths: paths), rest ].join("\n")
  end

  # The document's name, stated once here so a fixture can never drift from the production
  # constant without this file being the thing that fails.
  SELECTION_FILENAME = "changed-repositories\\.json"

  # MVP-0036 — a fake executor that uses the QUESTION BRIDGE. It reads the bridge path out of
  # the prompt exactly as a real provider must (the prompt is the only place it is named),
  # writes one request, then blocks on the answer — so the test exercises the real
  # same-session wait rather than a stubbed one.
  #
  # `FAKE_EXECUTOR_QUESTION_JSON` is the raw request bytes, so a test can send a malformed or oversized
  # document without this script sanitizing it first.
  def write_question_executor(root)
    path = File.join(root, "bin", "question-executor")
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      require "json"
      prompt = File.read(ARGV.last.to_s)
      request = prompt[%r{`([^`]*/question-request\.json)`}, 1]
      abort "[question-executor] the prompt named no bridge" if request.nil?
      answer = File.join(File.dirname(request), "question-answer.json")
      error = File.join(File.dirname(request), "question-error.json")

      # Echo the instructions back so a test can prove the prompt really told the provider what
      # a valid request must contain, rather than only that a bridge path was named.
      puts "[question-executor] instructions #{prompt[/^\s*- `continuation_context` requires:.*$/].to_s.strip}"

      # MVP-0036 Stage 2a: the real shape of the pause this MVP exists for — the provider has
      # already CHANGED files when it stops to ask, so the worktree a later resume must prove is
      # genuinely dirty rather than merely present.
      if ENV["FAKE_EXECUTOR_QUESTION_EDIT_FIRST"]
        file = "demo-app/index.html"
        File.write(file, File.read(file).sub("Hello Demo", "Hello Interrupted Demo"))
        puts "[question-executor] edited before asking"
      end

      SELECTION.call
      File.write("#{request}.partial", ENV.fetch("FAKE_EXECUTOR_QUESTION_JSON"))
      File.rename("#{request}.partial", request)
      puts "[question-executor] asked"

      deadline = Time.now + ENV.fetch("FAKE_EXECUTOR_QUESTION_TIMEOUT_SECONDS", "20").to_f
      until Time.now > deadline
        if File.file?(answer)
          puts "[question-executor] answered #{JSON.parse(File.read(answer))['answers'].to_json}"
          break
        end
        if File.file?(error)
          puts "[question-executor] refused #{JSON.parse(File.read(error))['error']}"
          break
        end
        sleep 0.05
      end

      file = "demo-app/index.html"
      content = File.read(file)
      File.write(file, content.gsub("Hello Demo", "Hello SpecRelay Demo")) if content.include?("Hello Demo")
      puts "[question-executor] applied edit"
    RUBY
    File.write(path, with_selection_reporter(File.read(path)) + "\nSELECTION.call\nexit 0\n")
    FileUtils.chmod(0o755, path)
    path
  end

  # MVP-0036 Stage 2a — a FRESH provider resuming someone else's paused work. It proves the
  # handoff by echoing it: a session that received no answers cannot print them.
  def write_resume_executor(root)
    path = File.join(root, "bin", "resume-executor")
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      prompt = File.read(ARGV.last.to_s)
      section = prompt[/## Answers to your earlier questions.*/m].to_s
      abort "[resume-executor] the prompt carried no answers" if section.empty?
      puts "[resume-executor] resumed #{section.lines.map(&:strip).reject(&:empty?).join(' | ')}"

      file = "demo-app/index.html"
      File.write(file, File.read(file).sub("Hello Interrupted Demo", "Hello Resumed Demo"))
      puts "[resume-executor] applied edit"
    RUBY
    File.write(path, with_selection_reporter(File.read(path)) + "\nSELECTION.call\nexit 0\n")
    FileUtils.chmod(0o755, path)
    path
  end

  # MVP-0036 CR-004 F3 — a resumed provider that does its first REAL action before printing
  # anything, which is what a provider given a complete handoff actually does. It never writes to
  # stdout or stderr, so output cannot stand in for "this process received its input".
  #
  # With `FAKE_EXECUTOR_RESUME_NEXT_QUESTION` that first action is ordinal N+1, which Platform can only
  # accept once the batch being continued has been acknowledged.
  def write_silent_resume_executor(root)
    path = File.join(root, "bin", "silent-resume-executor")
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      prompt = File.read(ARGV.last.to_s)
      abort "the prompt carried no answers" unless prompt.include?("## Answers to your earlier questions")

      if (asked = ENV["FAKE_EXECUTOR_RESUME_NEXT_QUESTION"])
        request = prompt[%r{`([^`]*/question-request\.json)`}, 1]
        abort "the prompt named no bridge" if request.nil?
        SELECTION.call
        File.write("#{request}.partial", asked)
        File.rename("#{request}.partial", request)
        sleep 30
        exit 0
      end

      file = "demo-app/index.html"
      File.write(file, File.read(file).sub("Hello Interrupted Demo", "Hello SpecRelay Demo"))
    RUBY
    File.write(path, with_selection_reporter(File.read(path)) + "\nSELECTION.call\nexit 0\n")
    FileUtils.chmod(0o755, path)
    path
  end

  # MVP-0036 CR-001 F1 — a provider that asks a valid question and then DIES before any
  # verdict arrives. The exit code is scripted so the test can prove the outcome is decided by
  # the unanswered question rather than by whether the provider happened to exit cleanly.
  def write_abandoning_executor(root)
    path = File.join(root, "bin", "abandoning-executor")
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      prompt = File.read(ARGV.last.to_s)
      request = prompt[%r{`([^`]*/question-request\.json)`}, 1]
      abort "[abandoning-executor] the prompt named no bridge" if request.nil?
      SELECTION.call
      File.write("#{request}.partial", ENV.fetch("FAKE_EXECUTOR_QUESTION_JSON"))
      File.rename("#{request}.partial", request)
      puts "[abandoning-executor] asked, then leaving"
      # Long enough for the parent to submit the batch to Platform, so the question really is
      # durable when this process disappears. With a leave file named, it leaves as soon as that
      # file appears instead — within the same bound — and removes it on the way out, so a test
      # can place this exit at an exact point in the parent's answer poll.
      wait = ENV.fetch("FAKE_EXECUTOR_QUESTION_ASK_SECONDS", "3").to_f
      leave = ENV["FAKE_EXECUTOR_QUESTION_LEAVE_FILE"]
      if leave
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
        sleep 0.05 until File.exist?(leave) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        File.delete(leave) if File.exist?(leave)
      else
        sleep wait
      end
      exit ENV.fetch("FAKE_EXECUTOR_QUESTION_EXIT_CODE", "0").to_i
    RUBY
    File.write(path, with_selection_reporter(File.read(path)))
    FileUtils.chmod(0o755, path)
    path
  end

  def git_init(root)
    %w[init\ -q].each { |a| git(root, *a.split) }
    git(root, "config", "user.email", "runner@example.test")
    git(root, "config", "user.name", "Runner Test")
    git(root, "config", "commit.gpgsign", "false")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "initial")
    identify(root, "tiny-demo-workspace")
  end

  # MAPIAI-84 — the runner now reads a repository's identity and default branch from the
  # repository itself rather than from an assignment entry, so every fixture repository must
  # carry both. No network and no bare remote are involved: `origin` is a url and
  # `refs/remotes/origin/HEAD` is a symbolic ref, and a test that also PUSHES replaces the url
  # with one FakeGithub serves locally.
  def identify(root, name, default_branch: "main")
    git(root, "remote", "add", "origin", "git@github.com:SpecRelay/#{name}.git")
    git(root, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/#{default_branch}")
  end

  def git(root, *args)
    out, status = Open3.capture2e("git", "-C", root, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end
end
