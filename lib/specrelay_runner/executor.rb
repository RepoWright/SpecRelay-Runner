# frozen_string_literal: true

require "fileutils"

module SpecrelayRunner
  # Launches the configured executor for one run (MVP-0010). The executor config
  # (provider/command/args/prompt_delivery/timeout/env) comes from the Platform
  # run payload — the runner does not decide which executor to run, it only runs
  # what Platform resolved. Provider credentials are NEVER passed here: a real
  # provider authenticates from the operator's own environment on this machine,
  # exactly as in the in-process runner (MVP-0009).
  #
  # The prompt is written to a staging file OUTSIDE the worktree and delivered as
  # a distinct argv element (or via stdin) — never interpolated into a shell
  # string — so arbitrary prompt content can never inject a command.
  class Executor
    PROMPT_PLACEHOLDER = "<PROMPT>"

    # Executables this repository ships (currently only the deterministic fake
    # executor). Platform names them as a bare command in the workspace executor
    # config because Platform cannot know where this repository is checked out on
    # the runner's host; the runner resolves them against its own bin/ so the
    # documented Tiny Demo path needs no absolute-path override from the operator.
    BUNDLED_BIN = File.expand_path("../../bin", __dir__)

    Result = Struct.new(:exit_code, :stdout, :stderr, :duration_seconds, :timed_out, :argv, keyword_init: true) do
      def success? = !timed_out && exit_code == 0
    end

    def initialize(config:, worktree_path:, staging_dir:)
      @config = config
      @worktree_path = worktree_path.to_s
      @staging_dir = staging_dir.to_s
    end

    # prompt_text is the approved-spec-derived handoff prompt (with a runner-local
    # preamble prepended by Execution). Returns the process Result plus the
    # sanitized argv for report evidence.
    def run(prompt_text)
      prompt_path = write_prompt(prompt_text)
      result = CommandRunner.run(
        launch_argv(prompt_text, prompt_path),
        chdir: worktree_path, env: process_env,
        timeout_seconds: timeout_seconds, stdin_data: (prompt_text if stdin_prompt?)
      )
      Result.new(exit_code: result.exit_code, stdout: result.stdout, stderr: result.stderr,
                 duration_seconds: result.duration_seconds, timed_out: result.timed_out,
                 argv: sanitized_argv(prompt_path))
    end

    # The executable to launch. A bare name that this repository ships resolves to
    # the bundled absolute path; anything else — an absolute path, a relative path,
    # or a provider CLI like `claude` — is passed through untouched for the normal
    # PATH/filesystem lookup. Never a shell string.
    def command
      raw = config.fetch("command", "claude").to_s
      bundled(raw) || raw
    end

    private

    def bundled(raw)
      return nil if raw.include?(File::SEPARATOR)

      path = File.join(BUNDLED_BIN, raw)
      File.executable?(path) ? path : nil
    end

    attr_reader :config, :worktree_path, :staging_dir

    def args = Array(config["args"]).map(&:to_s)
    def prompt_delivery = %w[argument file_argument stdin].include?(config["prompt_delivery"].to_s) ? config["prompt_delivery"].to_s : "argument"
    def stdin_prompt? = prompt_delivery == "stdin"
    def timeout_seconds = (config["timeout_seconds"].to_i.positive? ? config["timeout_seconds"].to_i : 1800)
    def extra_env = (config["env"] || {}).to_h.transform_keys(&:to_s).transform_values(&:to_s)
    def process_env = { "PATH" => ENV["PATH"].to_s }.merge(extra_env)

    def write_prompt(text)
      path = File.join(staging_dir, "executor-prompt.md")
      File.write(path, text)
      path
    end

    def launch_argv(prompt_text, prompt_path)
      base = [ command, *args ]
      case prompt_delivery
      when "file_argument" then base + [ prompt_path ]
      when "stdin" then base
      else base + [ prompt_text ]
      end
    end

    def sanitized_argv(prompt_path)
      base = [ command, *args ]
      case prompt_delivery
      when "file_argument" then base + [ prompt_path ]
      when "stdin" then base
      else base + [ PROMPT_PLACEHOLDER ]
      end
    end
  end
end
