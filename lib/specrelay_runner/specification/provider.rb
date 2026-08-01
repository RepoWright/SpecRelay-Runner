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
      # `composed` and `command` — so the diagnostics Platform persists cannot contradict the
      # manifest. They used to: the default was configured as `fake` and reported itself as
      # `composed`, and the run page told operators the production default was a fake.
      def self.resolve(settings:, env: ENV)
        settings.composed_provider? ? Composed.new : Command.build(settings: settings, env: env)
      end

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
