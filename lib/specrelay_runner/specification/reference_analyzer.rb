# frozen_string_literal: true

require "json"

module SpecrelayRunner
  module Specification
    # WHICH real capability actually fetches and analyses an external reference a bundle defers
    # to the runner (MVP-0028 remediation, defect 2 — review-005 finding F2).
    #
    # The first cut of this boundary shipped only an explicit `external_references.command`
    # extension point, and the product configured none — so the ordinary connected Runner,
    # including the one behind the clean MAPIAI-52 E2E, could never actually analyse a Jam link
    # without the Product Owner first writing, installing, and wiring an executable nobody had
    # built. That is a hidden setup step, not a shipped capability.
    #
    # The precedence mirrors {Provider.resolve} for the same reason: an operator who names an
    # explicit command has decided, and that decision keeps working for an advanced or
    # separate-repository setup. The ORDINARY path is the real Claude profile this runner already
    # validated for generation (defect 1) — nothing new to install, nothing new to configure: an
    # operator who fixed D1 already has this.
    module ReferenceAnalyzer
      # Bounded so a runaway analyzer cannot exhaust runner memory, and small enough that
      # anything larger is a bug rather than a very thorough reference.
      MAX_OUTPUT_BYTES = 200_000
      MAX_SUMMARY_CHARS = 2_000

      Outcome = Struct.new(:verdict, :summary, keyword_init: true) do
        def contributed? = verdict == :contributed
      end

      # An explicit command always wins — an operator who configured one has decided, exactly the
      # way {Provider.resolve} treats an explicit provider kind. Otherwise, the real Claude profile
      # this runner already validated for generation. Otherwise nil: no real capability exists,
      # and {InputEvidence} treats that exactly as it treats no capability being declared at all.
      def self.resolve(settings:, claude_profile: nil, env: ENV, command_runner: CommandRunner)
        return Command.new(command: settings.external_reference_command,
                           timeout_seconds: settings.external_reference_timeout_seconds,
                           env: env, command_runner: command_runner) if settings.external_reference_command

        return Claude.new(profile: claude_profile, settings: settings, env: env,
                          command_runner: command_runner) if claude_profile

        nil
      end

      # The STRICT evidence contract every adapter's output is judged against (review-005 finding
      # F1). `contributed: true` used to be taken at face value even when `summary` was blank,
      # missing, or not a string — `InputEvidence` then invented the sentence "the analyzer
      # reported success but recorded no summary" and treated the reference as read. That is not
      # evidence FROM the reference; it recreates the original false-confidence defect behind a
      # different flag. A contributed result now REQUIRES a nonblank string summary, or it is
      # `:failed` — an analyzer that claims success and hands back nothing is a malfunction to
      # report, not a fact to accept.
      def self.evaluate(document)
        return Outcome.new(verdict: :failed, summary: "the analyzer did not return a JSON object") unless
          document.is_a?(Hash)

        contributed = document["contributed"] == true
        summary = document["summary"]
        usable = summary.is_a?(String) && !summary.strip.empty?
        return Outcome.new(verdict: :failed, summary: "the analyzer reported contributed=true but returned no " \
                                                       "usable summary") if contributed && !usable

        Outcome.new(verdict: contributed ? :contributed : :not_contributed,
                   summary: usable ? clip(Redaction.redact(summary)) : "found no usable evidence")
      end

      def self.clip(text) = text.to_s[0, MAX_SUMMARY_CHARS].to_s

      def self.parse_output(stdout)
        text = stdout.to_s
        return Outcome.new(verdict: :failed,
                          summary: "the analyzer produced more output than this runner will accept") if
          text.bytesize > MAX_OUTPUT_BYTES

        evaluate(JSON.parse(text))
      rescue JSON::ParserError
        Outcome.new(verdict: :failed, summary: "the analyzer did not return valid JSON")
      end

      # An operator-configured local executable. Kept for an advanced or genuinely separate
      # specification-repository setup (a Jam-reading service this runner's host cannot reach
      # through Claude, a different MCP boundary entirely) — never required for the ordinary
      # connected Runner, which uses {Claude} instead.
      class Command
        def initialize(command:, timeout_seconds:, env: ENV, command_runner: CommandRunner)
          @command = command
          @timeout_seconds = timeout_seconds
          @env = env
          @command_runner = command_runner
        end

        def analyze(kind:, reference:)
          result = command_runner.run([ command, kind.to_s, reference.to_s ], chdir: Dir.pwd,
                                      env: { "PATH" => env["PATH"].to_s }, timeout_seconds: timeout_seconds)
          return Outcome.new(verdict: :failed, summary: "the analyzer timed out") if result.timed_out?
          return Outcome.new(verdict: :failed, summary: "the analyzer exited #{result.exit_code}") unless
            result.success?

          ReferenceAnalyzer.parse_output(result.stdout)
        rescue SystemCallError => e
          Outcome.new(verdict: :failed, summary: "the analyzer could not be launched: #{e.message}")
        end

        private

        attr_reader :command, :timeout_seconds, :env, :command_runner
      end

      # The operator's REAL Claude profile — the same one already validated for execution and,
      # since MVP-0028's D1 correction, for specification generation — asked to fetch and analyse
      # ONE external reference through whatever tool or MCP capability it has configured. This
      # class adds no new argv, no new credential, and no new configuration: the profile owns all
      # of that already, which is what makes the analyzer that reads a reference verifiably the
      # same one the readiness check probed.
      class Claude
        def initialize(profile:, settings:, env: ENV, command_runner: CommandRunner)
          @profile = profile
          @settings = settings
          @env = env
          @command_runner = command_runner
        end

        def analyze(kind:, reference:)
          result = run(prompt_for(kind, reference))
          return Outcome.new(verdict: :failed, summary: "the analyzer timed out") if result.timed_out?
          return Outcome.new(verdict: :failed, summary: "the analyzer exited #{result.exit_code}") unless
            result.success?

          parse(result.stdout)
        end

        private

        attr_reader :profile, :settings, :env, :command_runner

        # The same two variables {Provider::Claude} forwards, and for the same reason: PATH to
        # find the executable, HOME to find the operator's own Claude credentials. The profile's
        # own `extra_env` is merged last because it is the operator's explicit, already-validated
        # choice.
        FORWARDED_ENV = %w[PATH HOME].freeze

        def run(prompt)
          Dir.mktmpdir("specrelay-reference-claude-") do |workdir|
            command_runner.run([ profile.command, *profile.args, prompt ], chdir: workdir, env: child_env,
                                                                          timeout_seconds:
                                                                            settings.external_reference_timeout_seconds)
          end
        end

        def child_env
          FORWARDED_ENV.each_with_object({}) { |name, acc| acc[name] = env[name].to_s unless env[name].nil? }
                       .merge(profile.extra_env)
        end

        # The whole instruction, in one place a reviewer can read. It asks the profile to use
        # whatever REAL tool or MCP capability it has for this kind of reference, and to say so
        # honestly rather than guess — the same "do not invent, say so instead" discipline the
        # generation prompt uses.
        def prompt_for(kind, reference)
          <<~PROMPT
            You are analysing ONE external reference for a SpecRelay specification. Use any tool
            or MCP capability you have configured that can read this kind of reference — a web
            fetch, a Jam recording reader, a Confluence reader, or similar. Do not guess at
            content you could not actually read.

            Reference kind: #{kind}
            Reference: #{reference}

            Return ONLY a JSON object mapping exactly these two keys, with no prose before or
            after it and no code fence:

            If you could read it: {"contributed": true, "summary": "<1-3 sentences of what you actually found>"}
            If you could not read it with any tool available to you: {"contributed": false, "summary": "<why not>"}
          PROMPT
        end

        def parse(stdout)
          text = stdout.to_s
          return Outcome.new(verdict: :failed,
                            summary: "the analyzer produced more output than this runner will accept") if
            text.bytesize > ReferenceAnalyzer::MAX_OUTPUT_BYTES

          ReferenceAnalyzer.evaluate(JSON.parse(BalancedJson.extract_object(text)))
        rescue BalancedJson::NotFound
          Outcome.new(verdict: :failed, summary: "the analyzer returned no JSON object")
        rescue JSON::ParserError
          Outcome.new(verdict: :failed, summary: "the analyzer did not return valid JSON")
        end
      end
    end
  end
end
