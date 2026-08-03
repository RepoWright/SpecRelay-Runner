# frozen_string_literal: true

require "json"

module SpecrelayRunner
  module Specification
    # The generation-provider BOUNDARY (MVP-0026 scope 9).
    #
    # Everything that turns evidence into prose goes through one interface with two methods:
    #
    #   describe -> String          # what an operator sees in the log and in the manifest
    #   generate(packet) -> Hash    # { "spec.md" => "...", "analysis/business.md" => "...", ... }
    #
    # Two implementations ship. `Composed` is the default and is deterministic: same packet,
    # same bytes, no network, no model — which is what lets the digests, the atomic replace,
    # and the Platform evidence be asserted in tests instead of smoke-checked. `Command` runs
    # an operator-configured local executable, which is where a real model-backed writer
    # plugs in.
    #
    # The boundary is narrow on purpose. Scope 9 requires that "the runner must not embed
    # unreviewable prompt strings deep inside command glue", so the entire input a provider
    # receives is the Packet — one reviewable, redacted document built in one place — and the
    # entire output it may produce is a file map that DocumentSet then validates. A provider
    # cannot reach the assignment, the Platform client, the filesystem, or the environment
    # through this interface, because none of them is passed to it.
    #
    # Neither implementation writes a file. Writing is PackageWriter's job and happens after
    # validation, so a provider failure — including a command that dies halfway through its
    # output — cannot leave a partial package anywhere.
    module Provider
      # Raised at PREFLIGHT: the configured provider cannot be used at all. Distinct from
      # Failed because it must refuse before any staging happens.
      Unavailable = Class.new(StandardError)
      # Raised DURING generation: the provider ran and did not produce usable output.
      Failed = Class.new(StandardError)

      # Read from the configured command's stdout. Bounded so a runaway provider cannot
      # exhaust runner memory, and small enough that anything larger is a bug rather than a
      # very thorough specification.
      MAX_OUTPUT_BYTES = 4_000_000

      # The configured kind and the resolved provider's own `kind` are the SAME vocabulary —
      # `composed`, `command` and `claude` — so the diagnostics Platform persists cannot
      # contradict the manifest. They used to: the default was configured as `fake` and reported
      # itself as `composed`, and the run page told operators the production default was a fake.
      #
      # **An unset kind is a question, not a default** (MVP-0028 remediation, defect 1). It used
      # to resolve to `Composed`, so an operator whose guided setup wrote no runner YAML — the
      # ordinary case — got the deterministic composer while believing they had selected the real
      # provider. The live MAPIAI-52 run proved it: `runner.executor` named the real Claude
      # profile and the specification lane never looked at it.
      #
      # So the precedence is: an EXPLICIT kind always wins, because an operator who names one has
      # decided; otherwise the operator's real Claude profile is used if they configured one; and
      # if neither exists this REFUSES. Falling back to the composer is what this method must
      # never do again, because the composer's output is plausible enough that nobody notices.
      def self.resolve(settings:, claude_profile: nil, env: ENV)
        return Composed.new if settings.composed_provider?
        return Command.build(settings: settings, env: env) if settings.provider_kind == Settings::PROVIDER_COMMAND
        return Claude.build(profile: claude_profile, settings: settings) if settings.claude_provider?
        return Claude.new(profile: claude_profile, settings: settings) if claude_profile

        raise Unavailable, UNCONFIGURED
      end

      # Named here rather than inlined because it is the sentence an operator reads when the lane
      # cannot proceed, and it has to name every way out — including the fixture, so that choosing
      # the composer stays a real option rather than something only the source reveals.
      UNCONFIGURED =
        "no specification generation provider is configured. Set runner.specification.provider.kind " \
        "to `claude` to use this runner's configured Claude profile, to `command` with " \
        "runner.specification.provider.command for another executable, or to `composed` to use the " \
        "built-in deterministic composer as an explicit fixture. Configuring a runner.executor " \
        "Claude profile also selects `claude` for specifications."

      # The deterministic, built-in provider. It composes the documents from the packet with
      # no model call, which makes it both the test double the spec asks for and a genuinely
      # usable default: its output is grounded in the real bundle and the real source
      # evidence, so it is a weak writer rather than a fake one — which is why the
      # configuration value that selects it is `composed`.
      class Composed
        KIND = "composed"

        def describe = "built-in deterministic composer (no model, no network)"
        def kind = KIND

        def generate(packet)
          Composer.call(packet)
        rescue StandardError => e
          # A composer bug must surface as a generation failure the run records, not as an
          # unhandled crash that leaves the claim held and the operator with a backtrace.
          raise Failed, "the built-in composer could not produce a package: #{e.class}"
        end
      end

      # The operator's REAL Claude profile, writing the specification.
      #
      # It is a distinct kind from {Command} even though both spawn a process, because the two
      # answer to different configuration and different failure advice: `command` is "an
      # executable I chose for this lane", while this is "the Claude profile this runner already
      # validated for execution". Collapsing them would make the refusal messages wrong for one of
      # them, and would hide the fact that no separate configuration is needed at all.
      #
      # The profile owns the argv, the timeout, the prompt delivery and the child environment —
      # this class adds none of them. That is what makes the provider that writes a specification
      # verifiably the same one an operator configured and the readiness check probed.
      class Claude
        KIND = "claude"

        MISSING_PROFILE =
          "runner.specification.provider.kind is `claude` but this runner has no Claude profile: " \
          "configure runner.executor with provider `claude`, or select another specification " \
          "provider kind."

        def self.build(profile:, settings:)
          raise Unavailable, MISSING_PROFILE if profile.nil?

          new(profile: profile, settings: settings)
        end

        def initialize(profile:, settings:, env: ENV, command_runner: CommandRunner)
          @profile = profile
          @settings = settings
          @env = env
          @command_runner = command_runner
        end

        def kind = KIND

        # Already redacted by the profile, and it names the executable and how the prompt is
        # delivered — enough for an operator to recognise which provider ran, with nothing that
        # could carry a credential.
        def describe = "Claude profile — #{profile.describe}"

        # The packet reaches the model as ONE argv element, exactly as the implementation lane
        # delivers its prompt, and the model must answer with the same JSON file map every
        # provider answers with. Both halves are deliberate: the instruction lives here in
        # reviewable source rather than "deep inside command glue" (MVP-0026 scope 9), and the
        # output contract is the provider boundary's, not this class's, so {DocumentSet} validates
        # a Claude package exactly as it validates any other.
        def generate(packet)
          result = run(prompt_for(packet))
          raise Failed, "the Claude specification provider timed out" if result.timed_out?
          raise Failed, "the Claude specification provider exited #{result.exit_code}" unless result.success?

          parse(result.stdout)
        end

        private

        attr_reader :profile, :settings, :env, :command_runner

        # PATH to find the executable and HOME to find the operator's own Claude credentials —
        # the same two the implementation lane forwards, and nothing else. The profile's own
        # `extra_env` is merged last because it is the operator's explicit choice, and it is part
        # of the profile identity the readiness check already validated.
        FORWARDED_ENV = %w[PATH HOME].freeze

        def run(prompt)
          Dir.mktmpdir("specrelay-spec-claude-") do |workdir|
            command_runner.run([ profile.command, *profile.args, prompt ], chdir: workdir,
                                                                          env: child_env,
                                                                          timeout_seconds: profile.timeout_seconds)
          end
        end

        def child_env
          FORWARDED_ENV.each_with_object({}) { |name, acc| acc[name] = env[name].to_s unless env[name].nil? }
                       .merge(profile.extra_env)
        end

        # The whole instruction, in one place a reviewer can read. It says what to produce and in
        # what shape, and nothing about WHAT to write — that is the packet's job, and a prompt
        # that restated the content requirements would be a second, diverging specification of
        # them.
        def prompt_for(packet)
          <<~PROMPT
            You are writing a software specification package for SpecRelay.

            Return ONLY a JSON object mapping file paths to file contents, with no prose before or
            after it and no code fence. The keys must be exactly:
            "spec.md", "analysis/business.md", "analysis/technical.md".

            Base every statement on the evidence below. Do not invent requirements, and where the
            evidence is insufficient say so in the document rather than guessing.

            EVIDENCE (JSON):
            #{JSON.generate(packet)}
          PROMPT
        end

        # A model may wrap JSON in a fence or add a sentence despite being asked not to, so the
        # first balanced object is extracted rather than the whole stdout parsed. Anything else is
        # a failure the run records — never a partial package.
        def parse(stdout)
          text = stdout.to_s
          raise Failed, "the Claude specification provider produced more output than the runner will accept" if
            text.bytesize > MAX_OUTPUT_BYTES

          document = JSON.parse(json_object(text))
          raise Failed, "the Claude specification provider did not return a JSON object of file paths" unless
            document.is_a?(Hash)

          document.to_h { |name, content| [ name.to_s, content.to_s ] }
        rescue JSON::ParserError
          raise Failed, "the Claude specification provider did not return valid JSON"
        end

        # Genuinely balanced, not "first `{` to last `}`" (review-004 non-blocking note): a
        # brace inside a quoted string is not counted, so a trailing sentence or aside the model
        # appended despite instruction — one that itself happens to contain braces — cannot pull
        # the match past the object's own close. Only real object nesting inside the JSON can.
        # {BalancedJson} is the shared implementation; {ReferenceAnalyzer::Claude} (MVP-0028
        # remediation, defect 2) needs the identical judgment call against the same real profile.
        def json_object(text)
          BalancedJson.extract_object(text)
        rescue BalancedJson::NotFound
          raise Failed, "the Claude specification provider returned no JSON object"
        end
      end

      # An operator-configured local executable. The packet is handed to it as JSON on
      # stdin; it must return the file map as JSON on stdout. No shell is involved (argv
      # array), no environment is inherited beyond PATH, and the working directory is the
      # operator's own choice of a temporary directory — the provider is never given the
      # specification checkout to write into, because writing is not its job.
      class Command
        KIND = "command"

        def self.build(settings:, env: ENV)
          command = settings.provider_command
          raise Unavailable, "runner.specification.provider.kind is `command` but no provider command is " \
                             "configured (set runner.specification.provider.command or " \
                             "#{Settings::PROVIDER_COMMAND_ENV})" if command.nil?
          raise Unavailable, "the configured generation provider is not an executable file: #{command}" unless
            File.file?(command) && File.executable?(command)

          new(command: command, args: settings.provider_args, timeout_seconds: settings.provider_timeout_seconds,
              env: env)
        end

        def initialize(command:, args: [], timeout_seconds: Settings::DEFAULT_TIMEOUT_SECONDS, env: ENV,
                       command_runner: CommandRunner)
          @command = command
          @args = Array(args).map(&:to_s)
          @timeout_seconds = timeout_seconds
          @env = env
          @command_runner = command_runner
        end

        def kind = KIND
        def describe = "configured provider command `#{File.basename(command)}`"

        def generate(packet)
          result = run(JSON.generate(packet))
          raise Failed, "the generation provider timed out after #{timeout_seconds}s" if result.timed_out?
          raise Failed, "the generation provider exited #{result.exit_code}: #{first_line(result)}" unless
            result.success?

          parse(result.stdout)
        end

        private

        attr_reader :command, :args, :timeout_seconds, :env, :command_runner

        # Run in a throwaway directory, not in either checkout. A provider that decides to
        # write next to itself then cannot touch the specification repository or the source
        # tree — the atomicity guarantee in scope 10 is only as strong as the set of places
        # something can write.
        def run(stdin_data)
          Dir.mktmpdir("specrelay-spec-provider-") do |workdir|
            command_runner.run([ command, *args ], chdir: workdir, env: { "PATH" => env["PATH"].to_s },
                                                   timeout_seconds: timeout_seconds, stdin_data: stdin_data)
          end
        end

        def parse(stdout)
          raise Failed, "the generation provider produced more output than the runner will accept" if
            stdout.to_s.bytesize > MAX_OUTPUT_BYTES

          document = JSON.parse(stdout.to_s)
          raise Failed, "the generation provider did not return a JSON object of file paths" unless
            document.is_a?(Hash)

          document.to_h { |name, content| [ name.to_s, content.to_s ] }
        rescue JSON::ParserError
          raise Failed, "the generation provider did not return valid JSON on stdout"
        end

        # Only the FIRST line of the provider's stderr reaches the failure message, redacted.
        # A provider's full output may contain anything, including its own configuration, and
        # this string is persisted by Platform and shown on the run page.
        def first_line(result)
          text = [ result.stderr, result.stdout ].map { |value| value.to_s.strip }.find { |value| !value.empty? }
          Redaction.redact(text.to_s.each_line.first.to_s.strip)[0, 300].to_s
        end
      end
    end
  end
end
