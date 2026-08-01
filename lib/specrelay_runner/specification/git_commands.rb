# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # The one place the specification-publication path runs a `git` or `gh` process
    # (MVP-0027 scope 2).
    #
    # Extracted so {GitPublisher} and {PullRequestPublisher} describe WHAT they do to a
    # repository while this describes HOW a command is run, which environment it may see, and
    # what a failure of one is allowed to look like. The three rules it holds are the ones a
    # publication cannot be safe without:
    #
    #   1. Every command is an argv array. No shell is involved, so a branch name, a path, or a
    #      pull-request body can never be interpolated into a command line.
    #   2. Only named environment variables are forwarded, and no value of any of them is ever
    #      logged. Publication needs more of the operator's environment than generation does —
    #      HOME for git/gh config, SSH_AUTH_SOCK for an agent key, GH_*/GIT_* for a credential
    #      helper — and each one is a way a credential could reach a log if this were casual.
    #   3. A failure becomes a REASON, never an exception and never a blank. A missing binary
    #      (`gh` is optional infrastructure) surfaces as a reported failure with the operator's
    #      remedy, and a timeout — which leaves exit_code nil and both streams empty — produces
    #      a sentence rather than "git push failed: ".
    #
    # Every string that leaves here has been through {Redaction}, because a git or gh error
    # legitimately echoes the remote URL it failed on, and that URL can carry credential
    # userinfo.
    class GitCommands
      GIT_TIMEOUT_SECONDS = 300
      GH_TIMEOUT_SECONDS = 120

      # The same forwarded set the implementation lane's publication uses, and for the same
      # reasons. Restated rather than reached for across lanes: this is a security boundary, and
      # a security boundary that is defined in another lane's class is one a change to that lane
      # can widen by accident.
      FORWARDED_ENV = %w[PATH HOME SSH_AUTH_SOCK SSH_AGENT_PID GH_TOKEN GH_CONFIG_DIR
                         GIT_SSH_COMMAND GIT_CONFIG_GLOBAL XDG_CONFIG_HOME].freeze

      def initialize(checkout_root:, env: {})
        @checkout_root = checkout_root.to_s
        @env = env
      end

      def git(args, extra_env: {}) = run([ "git", "-C", checkout_root, *args ], GIT_TIMEOUT_SECONDS, extra_env)
      def gh(args) = run([ "gh", *args ], GH_TIMEOUT_SECONDS, {})

      # The trimmed stdout of a command that succeeded, or nil. The convenience the plumbing
      # sequence is built from: every step of it reads one short value out of git.
      def git_value(args, extra_env: {})
        result = git(args, extra_env: extra_env)
        result.success? ? result.stdout.to_s.strip : nil
      end

      def success?(args) = git(args).success?

      # A single place that turns a failed CommandRunner result into a non-empty, secret-safe
      # reason.
      def failure_reason(result, label)
        return "#{label} timed out after #{result.duration_seconds.round}s on this runner host" if
          result.timed_out?

        detail = first_line(result)
        return "#{label} failed with exit status #{result.exit_code.inspect} and no output" if detail.empty?

        "#{label} failed: #{detail}"
      end

      private

      attr_reader :checkout_root, :env

      def run(argv, timeout_seconds, extra_env)
        CommandRunner.run(argv, chdir: checkout_root, env: forwarded_env.merge(extra_env),
                                timeout_seconds: timeout_seconds)
      rescue SystemCallError => e
        # A missing or non-executable binary must degrade into a reported failure, never crash
        # the attempt. Process spawn failures surface as Errno subclasses, so SystemCallError is
        # the narrowest boundary that covers them.
        CommandRunner::Result.new(exit_code: 127, stdout: "", stderr: e.message.to_s,
                                  duration_seconds: 0.0, timed_out: false)
      end

      def forwarded_env
        @forwarded_env ||= FORWARDED_ENV.each_with_object({}) do |name, acc|
          value = env[name]
          acc[name] = value.to_s unless value.nil?
        end
      end

      def first_line(result)
        combined = [ result.stderr, result.stdout ].join("\n")
        Redaction.redact(combined.strip).each_line.map(&:strip).find { |line| !line.empty? }.to_s
      end
    end
  end
end
