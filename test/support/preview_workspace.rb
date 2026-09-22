# frozen_string_literal: true

require "fileutils"
require "json"

# MAPIAI-97 — a real project-owned task environment whose `bin/worktree` supports the COMPLETE
# preview lifecycle: create, up, status --json and release.
#
# It is {MultiRepositoryWorkspace} with a richer project command, not a second workspace fixture:
# that one already builds a composite environment of independent repositories with their own
# GitHub identities, which is exactly the substrate a preview reconstructs. Only the lifecycle
# command differs, so only the lifecycle command is replaced.
#
# Every invocation is logged as "<working directory>\t<arguments>", which is what makes "exact
# argv, exact root, exact order" an observed fact rather than an inference from the runner's own
# narration. Failures are injected through control files under `.runs/`, so no test mutates the
# environment of the process it is testing.
module PreviewWorkspace
  COMPONENTS = %w[component-a component-b].freeze

  Built = Struct.new(:root, :bares, :log, :runs, keyword_init: true) do
    # Every invocation as [working directory, "verb task --flags"].
    def invocations
      return [] unless File.exist?(log)

      File.readlines(log, chomp: true).map { |line| line.split("\t", 2) }
    end

    def verbs = invocations.map { |(_root, arguments)| arguments.split(" ").first }

    def fail!(verb) = File.write(File.join(runs, "fail"), verb.to_s)
    def succeed! = FileUtils.rm_f(File.join(runs, "fail"))
    # The project-owned lifecycle's own "unknown task environment" answer.
    def absent! = File.write(File.join(runs, "absent"), "1")
    # Print, then hang: the shape a real `up` or `release` has when it stops making progress.
    def hang!(verb) = File.write(File.join(runs, "hang"), verb.to_s)
    # A project command that prints something it should not. Real ones do — the project's own
    # create names the host directory it made, and `status --json` reports every worktree path.
    def leak!(verb, text) = File.write(File.join(runs, "leak.#{verb}"), text.to_s)
    def leak_stderr!(verb, text) = File.write(File.join(runs, "leakerr.#{verb}"), text.to_s)

    # One unterminated line written in two pieces, far enough apart that the reader returns them
    # separately. That is the only way `CommandRunner`'s bounded partial-line fallback fires, and
    # `head` must be at least MAX_PENDING_LINE_BYTES for it to fire at all.
    def split!(verb, head, tail)
      File.write(File.join(runs, "splithead.#{verb}"), head)
      File.write(File.join(runs, "splittail.#{verb}"), tail)
    end
    def status!(document) = File.write(File.join(runs, "status.json"), JSON.generate(document))

    # An environment the project already holds for somebody: another run, or — with an empty
    # `run_id` — a person.
    def own!(task_id, run_id) = ProjectCommand.own!(File.dirname(runs), task_id, run_id)
  end

  module_function

  def build(components: COMPONENTS)
    built = MultiRepositoryWorkspace.build(components: components)
    write_command(built.root, components)
    DemoWorkspace.git(built.root, "add", "-A")
    DemoWorkspace.git(built.root, "commit", "-q", "-m", "preview lifecycle")
    runs = File.join(built.root, ".runs")
    FileUtils.mkdir_p(runs)
    Built.new(root: built.root, bares: built.bares, runs: runs,
              log: File.join(runs, "worktree.log"))
  end

  # A pull request head that really exists: a commit on its own branch in the component
  # repository, with the default branch left where it was. The task worktree shares that
  # repository's object store, so placing it is a genuine reconstruction of another branch's head
  # rather than a no-op checkout of what was already there.
  def pull_request_head(root, component, marker)
    path = File.join(root, component)
    default = DemoWorkspace.git(path, "rev-parse", "--abbrev-ref", "HEAD").to_s.strip
    DemoWorkspace.git(path, "checkout", "-q", "-b", "pr-#{marker}")
    File.write(File.join(path, "app.txt"), "#{marker}\n")
    DemoWorkspace.git(path, "add", "-A")
    DemoWorkspace.git(path, "commit", "-q", "-m", "pull request #{marker}")
    head = DemoWorkspace.git(path, "rev-parse", "HEAD").to_s.strip
    DemoWorkspace.git(path, "checkout", "-q", default)
    head
  end

  # The rich status document the real engine produces: the closed four fields per service, an
  # internal service whose url is explicitly null, and the operational detail a preview page must
  # never receive.
  def status_document(task_id)
    { "task_id" => task_id, "branch" => task_id, "state" => "RUNNING", "slot" => 4,
      "port_block" => [ 5100, 5199 ], "compose_project" => "srt-#{task_id}",
      "primary_url" => "http://127.0.0.1:5173", "data_warning" => nil,
      "development_data_modes" => { "platform.postgres" => "schema_only" },
      "services" => [
        { "service" => "dashboard", "state" => "running", "health" => "healthy",
          "host_port" => 5173, "url" => "http://127.0.0.1:5173" },
        { "service" => "postgres", "state" => "running", "health" => "none",
          "host_port" => 5432, "url" => nil }
      ],
      "repositories" => [ { "repository" => "component-a", "worktree_path" => "/private/tmp/x",
                            "dirty" => false } ],
      "missing_repositories" => [] }
  end

  def write_command(root, components)
    path = File.join(root, "bin", "worktree")
    File.write(path, command_body(components))
    FileUtils.chmod(0o755, path)
  end

  def command_body(components)
    <<~SH
      #!/usr/bin/env sh
      set -u
      ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
      RUNS="$ROOT_DIR/.runs"
      mkdir -p "$RUNS"
      printf '%s\\t%s\\n' "$PWD" "$*" >> "$RUNS/worktree.log"
      #{ProjectCommand.arguments}
      if [ -f "$RUNS/leak.$VERB" ]; then cat "$RUNS/leak.$VERB"; fi
      if [ -f "$RUNS/leakerr.$VERB" ]; then cat "$RUNS/leakerr.$VERB" >&2; fi
      if [ -f "$RUNS/splithead.$VERB" ]; then
        printf '%s' "$(cat "$RUNS/splithead.$VERB")"
        sleep 1
        printf '%s\\n' "$(cat "$RUNS/splittail.$VERB")"
      fi
      WT="$RUNS/worktrees/$TASK"
      FAIL="$(cat "$RUNS/fail" 2>/dev/null || true)"
      HANG="$(cat "$RUNS/hang" 2>/dev/null || true)"
      COMPONENTS="#{components.join(' ')}"
      if [ "$FAIL" = "$VERB" ]; then
        echo "the project refused to $VERB $TASK" >&2
        exit 1
      fi
      if [ "$HANG" = "$VERB" ]; then
        echo "still $VERB-ing $TASK"
        sleep 120
        exit 0
      fi
      case "$VERB" in
        create)
          mkdir -p "$RUNS/worktrees"
          git -C "$ROOT_DIR" worktree add -b "$TASK" "$WT" HEAD >/dev/null 2>&1 || exit 1
          for repo in $COMPONENTS; do
            git -C "$ROOT_DIR/$repo" worktree add -b "$TASK" "$WT/$repo" HEAD >/dev/null 2>&1 || exit 1
          done
          #{ProjectCommand.record_owner}
          echo "created $WT"
          ;;
        up)
          echo "starting $TASK"
          ;;
        status)
          if [ -f "$RUNS/absent" ]; then
            echo '{"error":"unknown task environment"}'
            exit 4
          fi
          cat "$RUNS/status.json"
          ;;
        release)
          if [ -f "$RUNS/absent" ]; then
            if [ -n "$RUN_ID" ]; then
              printf '{"task_id":"%s","outcome":"absent"}\\n' "$TASK"
              exit 0
            fi
            echo "unknown task environment '$TASK'" >&2
            exit 4
          fi
          #{ProjectCommand.release_guard}
          for repo in $COMPONENTS; do
            git -C "$ROOT_DIR/$repo" worktree remove --force "$WT/$repo" >/dev/null 2>&1 || true
          done
          git -C "$ROOT_DIR" worktree remove --force "$WT" >/dev/null 2>&1 || true
          #{ProjectCommand.release_report(%(echo "released $TASK"))}
          ;;
        *)
          echo "usage: worktree create|up|status|release <task>" >&2
          exit 2
          ;;
      esac
    SH
  end
end
