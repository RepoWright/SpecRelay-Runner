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
      set -eu
      ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
      WT_ROOT="$ROOT_DIR/.runs/worktrees"
      case "${1:-}" in
        create)
          mkdir -p "$WT_ROOT"
          if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/heads/$2"; then
            git -C "$ROOT_DIR" worktree add "$WT_ROOT/$2" "$2"
          else
            git -C "$ROOT_DIR" worktree add -b "$2" "$WT_ROOT/$2" HEAD
          fi
          ;;
        release) git -C "$ROOT_DIR" worktree remove "$WT_ROOT/$2" ;;
        list) git -C "$ROOT_DIR" worktree list ;;
        *) echo "usage: worktree create|release|list <task>" >&2; exit 1 ;;
      esac
    SH
    FileUtils.chmod(0o755, path)
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
  def write_fake_executor(root)
    path = File.join(root, "bin", "fake-executor")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      puts "leaking sk-live-DO-NOT-LEAK-0123456789 to stdout"
      file = "demo-app/index.html"
      content = File.read(file)
      if content.include?("Hello Demo")
        File.write(file, content.gsub("Hello Demo", "Hello SpecRelay Demo"))
        puts "[fake-executor] applied edit"
      end
      exit 0
    RUBY
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
  end

  def git(root, *args)
    out, status = Open3.capture2e("git", "-C", root, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end
end
