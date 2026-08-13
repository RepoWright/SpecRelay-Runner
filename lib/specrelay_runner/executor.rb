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

    # `launch_error` is set when the configured executable could not be started at
    # all (it is not installed on this host, or not executable). It is a distinct
    # fact from "the executor ran and failed", so the terminal report can say
    # `executor_unavailable` instead of blaming the task — and, critically, the
    # runner reports it instead of dying on an unhandled Errno and leaving the run
    # stuck CLAIMED forever.
    Result = Struct.new(:exit_code, :stdout, :stderr, :duration_seconds, :timed_out, :argv, :launch_error,
                        keyword_init: true) do
      def success? = !timed_out && launch_error.nil? && exit_code == 0
    end

    # `env` is the runner's effective process environment. It is threaded in
    # explicitly (not read from the global ENV) so the PATH the readiness probe
    # resolved `claude` on is the same PATH this launch resolves it on.
    def initialize(config:, worktree_path:, staging_dir:, env: ENV)
      @config = config
      @worktree_path = worktree_path.to_s
      @staging_dir = staging_dir.to_s
      @env = env
    end

    # prompt_text is the approved-spec-derived handoff prompt (with a runner-local
    # preamble prepended by Execution). Returns the process Result plus the
    # sanitized argv for report evidence.
    #
    # `on_output` (MVP-0018) receives `(stream, line)` for each complete line the
    # executor writes, while it is still running. It is passed straight through to
    # CommandRunner, which guarantees it can neither change nor fail the captured
    # result — this method's contract is unchanged when it is nil.
    #
    # `stop_check` (MVP-0036) is passed straight through to CommandRunner, which owns the one
    # bounded shutdown grace. It is how a provider whose question window closed is ended
    # without this object learning anything about questions.
    #
    # `on_start` (MVP-0036 CR-004) is passed through the same way: CommandRunner owns the one
    # instant at which the child exists and has its prompt, and this object still learns nothing
    # about what a caller does with that fact.
    def run(prompt_text, on_output: nil, stop_check: nil, on_start: nil)
      prompt_path = write_prompt(prompt_text)
      result = CommandRunner.run(
        launch_argv(prompt_text, prompt_path),
        chdir: worktree_path, env: process_env,
        timeout_seconds: timeout_seconds, stdin_data: (prompt_text if stdin_prompt?),
        on_output: on_output, stop_check: stop_check, on_start: on_start
      )
      Result.new(exit_code: result.exit_code, stdout: result.stdout, stderr: result.stderr,
                 duration_seconds: result.duration_seconds, timed_out: result.timed_out,
                 argv: sanitized_argv(prompt_path))
    rescue SystemCallError => e
      # The executable is absent or not runnable on this host. Reported as a
      # failed attempt with a redacted reason, never raised: an unhandled Errno
      # here would kill the runner mid-claim and leave the run stuck on Platform.
      launch_failure(e, prompt_path)
    end

    # The executable to launch. A bare name that this repository ships resolves to
    # the bundled absolute path; anything else — an absolute path, a relative path,
    # or a provider CLI like `claude` — is passed through untouched for the normal
    # PATH/filesystem lookup. Never a shell string.
    def command
      raw = config.fetch("command", "claude").to_s
      self.class.bundled(raw) || raw
    end

    # The absolute file a configured command will ACTUALLY launch, resolved exactly
    # the way #command + Process.spawn resolve it: a bundled bare name first, then
    # the effective PATH. Returns nil when nothing executable resolves.
    #
    # This is the one authoritative answer to "which file are we about to run", and
    # it is deliberately shared with ClaudeProfile so the readiness probe, the
    # fail-closed comparison, and the launch all reason about the SAME file. When
    # they disagreed, readiness could pass against one `claude` while execution ran
    # another (review-001 finding F1).
    #
    # Symlinks are resolved, so two paths naming the same executable compare equal.
    def self.resolve_command(raw, env: ENV)
      raw = raw.to_s.strip
      return nil if raw.empty?

      candidate = raw.include?(File::SEPARATOR) ? File.expand_path(raw) : (bundled(raw) || path_lookup(raw, env))
      return nil unless candidate && File.executable?(candidate)

      File.realpath(candidate)
    rescue SystemCallError
      nil
    end

    # An executable this repository ships, or nil. A name containing a separator is
    # never ours to resolve.
    def self.bundled(raw)
      return nil if raw.to_s.include?(File::SEPARATOR)

      path = File.join(BUNDLED_BIN, raw.to_s)
      File.executable?(path) ? path : nil
    end

    def self.path_lookup(raw, env)
      env["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
        next if dir.to_s.strip.empty?

        candidate = File.join(dir, raw)
        return candidate if File.executable?(candidate)
      end
      nil
    end

    private

    def launch_failure(error, prompt_path)
      reason = Redaction.redact("could not launch the configured executor: #{error.message}")
      Result.new(exit_code: nil, stdout: "", stderr: reason, duration_seconds: 0.0,
                 timed_out: false, argv: sanitized_argv(prompt_path), launch_error: reason)
    end

    attr_reader :config, :worktree_path, :staging_dir, :env

    def args = Array(config["args"]).map(&:to_s)
    def prompt_delivery = %w[argument file_argument stdin].include?(config["prompt_delivery"].to_s) ? config["prompt_delivery"].to_s : "argument"
    def stdin_prompt? = prompt_delivery == "stdin"
    def timeout_seconds = (config["timeout_seconds"].to_i.positive? ? config["timeout_seconds"].to_i : 1800)
    def extra_env = (config["env"] || {}).to_h.transform_keys(&:to_s).transform_values(&:to_s)

    # Process.spawn MERGES this hash into the inherited environment (it does not
    # clear it — `unsetenv_others` is deliberately not set), so a real provider
    # keeps the operator's own HOME/XDG/keychain context and authenticates as
    # itself. The runner therefore never has to read, copy, or forward a provider
    # credential to give the executor a working login (MVP-0016).
    def process_env = { "PATH" => env["PATH"].to_s }.merge(extra_env)

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
