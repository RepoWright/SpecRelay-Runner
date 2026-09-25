# frozen_string_literal: true

module SpecrelayRunner
  # MAPIAI-93 — the runner's INDEPENDENT replay of the verification the executor selected for one
  # changed repository, and the only place a repository's outcome is decided.
  #
  # WHY replay at all. The executor already ran these commands; that is where it diagnosed and
  # repaired what it could. But an executor's account of its own work is a claim, and it was made
  # before its last edit was necessarily final. This runs the same argv again, from the verified
  # repository root, against the files that are actually about to be published.
  #
  # Three outcomes and no fourth. {NOT_FOUND} is a first-class answer for a repository the
  # executor found no applicable verification for: it is valid, it does not block publication,
  # and it is never converted into a fabricated command or a borrowed exit code zero.
  #
  # It decides nothing beyond the repository in front of it. Whether publication may proceed,
  # whether the attempt succeeded, and whether the lease is still live all belong to
  # {Execution}, which owns them for every other phase too.
  class RepositoryVerification
    PASSED = "passed"
    NOT_FOUND = "not_found"
    FAILED = "failed"

    # The same ceiling the singular project test command had. Per command rather than per
    # repository, because each selected command is an independent process.
    TIMEOUT_SECONDS = 900
    # Enough to carry a failing command's actual message; small enough that fifty repositories
    # of runaway output cannot become one unbounded report upload.
    MAX_OUTPUT_BYTES = 4_000

    # One command the runner really launched. `exit_code` is nil when the process never ran
    # (`launch_error`) or was killed at the deadline (`timed_out`) — three distinct facts,
    # because an operator fixes each of them differently.
    Attempt = Struct.new(:argv, :exit_code, :timed_out, :launch_error, :output, keyword_init: true) do
      def passed? = launch_error.nil? && !timed_out && exit_code == 0
    end

    Result = Struct.new(:repository_path, :repository_id, :status, :attempts, keyword_init: true) do
      def passed? = status == PASSED
      def failed? = status == FAILED
    end

    def self.call(**kwargs) = new(**kwargs).call

    # THE rule. Stated once so execution, the report projection and the tests cannot each hold
    # their own idea of what a repository's outcome is.
    def self.status_for(attempts)
      return NOT_FOUND if attempts.empty?

      attempts.all?(&:passed?) ? PASSED : FAILED
    end

    def initialize(repository:, commands:, env: {}, timeout_seconds: TIMEOUT_SECONDS)
      @repository = repository
      @commands = Array(commands)
      # The same child environment rule the executor runs under, so the replay and the executor's
      # own commands start from one environment and only the project's entrypoint activates more.
      @env = CommandRunner.project_env("PATH" => env["PATH"].to_s)
      @timeout_seconds = timeout_seconds
    end

    def call
      attempts = commands.map { |argv| attempt(argv) }
      Result.new(repository_path: repository.relative_path, repository_id: repository.id,
                 status: self.class.status_for(attempts), attempts: attempts)
    end

    private

    attr_reader :repository, :commands, :env, :timeout_seconds

    # An ordinary failure does not stop the remaining commands: every changed repository gets a
    # COMPLETE outcome, so an operator sees all of what failed rather than only the first thing.
    def attempt(argv)
      result = CommandRunner.run(argv, chdir: repository.path, env: env, timeout_seconds: timeout_seconds)
      build(argv, exit_code: result.exit_code, timed_out: result.timed_out?,
                  output: [ result.stdout, result.stderr ].join("\n"))
    rescue StandardError => e
      # The command could not be launched at all — a missing program, a directory that is not
      # executable. Not a passing repository, and not an absent one either.
      build(argv, launch_error: "#{e.class}: #{e.message}")
    end

    # Everything recorded here becomes report evidence, a pull-request body line and terminal
    # output, so the argv is redacted for the same reason the captured output is.
    def build(argv, exit_code: nil, timed_out: false, launch_error: nil, output: "")
      Attempt.new(argv: Array(argv).map { |element| Redaction.redact(element.to_s) },
                  exit_code: exit_code, timed_out: timed_out,
                  launch_error: launch_error && Redaction.redact(launch_error),
                  output: bounded(Redaction.redact(output.to_s)))
    end

    # The TAIL is kept: a long build log ends with the reason it failed.
    def bounded(text)
      return text if text.bytesize <= MAX_OUTPUT_BYTES

      text.byteslice(-MAX_OUTPUT_BYTES, MAX_OUTPUT_BYTES).to_s.scrub("")
    end
  end
end
