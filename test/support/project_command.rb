# frozen_string_literal: true

require "fileutils"

# The ownership half of a fixture project's `bin/worktree`, in one place.
#
# Four workspace fixtures build a project-owned task environment, and they differ in what
# CREATE means — one worktree, several linked worktrees, a cloned component. None of them
# differ in what OWNERSHIP means, and that is what the runner is being tested against: the
# accepted project records the owning Run at allocation, reports it from `status --json`,
# refuses `release --run-id` for any other identity, and proves `absent` when it holds nothing.
#
# Four hand-written copies of that contract is four chances for one of them to drift into
# agreeing with a runner that got it wrong. So the shell fragments live here and each fixture
# supplies only its own create and remove steps.
#
# The owner record is a file per task under `.runs/owners`, written by the project command
# itself. Tests read and write it through {MultiRepositoryWorkspace.recorded_owner} and the
# fixtures' own `own!`, so an allocation belonging to another run — or to a person — is set up
# through the same file the command reads.
module ProjectCommand
  module_function

  # Positional verb and task, then flags — the order the runner sends them. A fixture that read
  # `$2` positionally would silently treat `--run-id` as part of the task id and pass anyway.
  def arguments
    <<~SH
      VERB="${1:-}"
      [ $# -gt 0 ] && shift
      TASK="${1:-}"
      [ $# -gt 0 ] && shift
      RUN_ID=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --run-id) RUN_ID="${2:-}"; shift 2 ;;
          --json) shift ;;
          *) echo "unknown option: $1" >&2; exit 2 ;;
        esac
      done
      OWNERS="$ROOT_DIR/.runs/owners"
      OWNER_FILE="$OWNERS/$TASK"
      mkdir -p "$OWNERS"
    SH
  end

  # Recorded at allocation, and empty for an allocation made without one — which is exactly how
  # a manual environment is distinguished from an owned one.
  def record_owner = %(printf '%s' "$RUN_ID" > "$OWNER_FILE")

  def status_case
    <<~SH
      if [ ! -f "$OWNER_FILE" ]; then
        echo '{"error":"unknown task environment"}'
        exit 4
      fi
      OWNER="$(cat "$OWNER_FILE")"
      if [ -n "$OWNER" ]; then OWNER_JSON="\\"$OWNER\\""; else OWNER_JSON=null; fi
      printf '{"task_id":"%s","branch":"%s","state":"READY","owner_run_id":%s}\\n' \\
        "$TASK" "$TASK" "$OWNER_JSON"
    SH
  end

  # `list --json`: every environment this project holds, each with the owner recorded at
  # allocation — null for a manual one — read from the same owner files `status` reads.
  def list_case
    <<~SH
      printf '{"environments":['
      SEP=""
      for FILE in "$OWNERS"/*; do
        [ -f "$FILE" ] || continue
        OWNER="$(cat "$FILE")"
        if [ -n "$OWNER" ]; then OWNER_JSON="\\"$OWNER\\""; else OWNER_JSON=null; fi
        printf '%s{"task_id":"%s","owner_run_id":%s}' "$SEP" "$(basename "$FILE")" "$OWNER_JSON"
        SEP=","
      done
      printf ']}\\n'
    SH
  end

  # Run before anything is removed. An unowned release (no `--run-id`) is the manual command and
  # is left exactly as each fixture had it.
  def release_guard
    <<~SH
      if [ -n "$RUN_ID" ]; then
        if [ ! -f "$OWNER_FILE" ]; then
          printf '{"task_id":"%s","outcome":"absent"}\\n' "$TASK"
          exit 0
        fi
        if [ "$(cat "$OWNER_FILE")" != "$RUN_ID" ]; then
          printf '{"task_id":"%s","outcome":"refused"}\\n' "$TASK"
          exit 3
        fi
      fi
    SH
  end

  # Run after the fixture's own removal step. `manual_line` is whatever that fixture already
  # printed on the unowned path, preserved so the manual command's output does not change.
  def release_report(manual_line = nil)
    lines = [ %(rm -f "$OWNER_FILE"),
              %(if [ -n "$RUN_ID" ]; then),
              %(  printf '{"task_id":"%s","outcome":"released","owner_run_id":"%s"}\\n' ) +
                %("$TASK" "$RUN_ID") ]
    lines += [ "else", "  #{manual_line}" ] if manual_line
    (lines + [ "fi", "" ]).join("\n")
  end

  # The state a foreign allocation presents: another run's id, or an empty string for a manual
  # environment. Written through the same file the project command reads.
  def own!(root, task_id, run_id)
    owners = File.join(root, ".runs", "owners")
    FileUtils.mkdir_p(owners)
    File.write(File.join(owners, task_id), run_id.to_s)
  end

  def recorded_owner(root, task_id)
    path = File.join(root, ".runs", "owners", task_id)
    File.exist?(path) ? File.read(path) : nil
  end

  # A project that owns the run-aware command and holds NO task environment, so every release is
  # answered with its proof of absence. For a lane test whose environment is not what it is about:
  # a Run's ending still asks the project, and a project without the command would be refused.
  def install_without_environments(root)
    FileUtils.mkdir_p(File.join(root, "bin"))
    path = File.join(root, "bin", "worktree")
    File.write(path, <<~SH)
      #!/usr/bin/env sh
      set -u
      ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
      #{arguments}
      case "$VERB" in
        release) #{release_guard} ;;
        *) echo '{"error":"unknown task environment"}'; exit 4 ;;
      esac
    SH
    FileUtils.chmod(0o755, path)
  end
end
