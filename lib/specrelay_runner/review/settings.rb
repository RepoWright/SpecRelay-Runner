# frozen_string_literal: true

require "digest"

module SpecrelayRunner
  module Review
    # The operator's local, NON-SECRET `runner.reviewer:` block (MVP-0033 contract 3).
    #
    #   runner:
    #     reviewer:
    #       name: Local Reviewer          # a label for the operator's own machine list
    #       provider: claude              # claude | fake
    #       command: claude               # optional; defaults to the profile's executable
    #       args: [--print, --dangerously-skip-permissions]
    #       timeout_seconds: 1800
    #
    # Two things live here and they are deliberately different shapes:
    #
    #   - the LOCAL launch configuration (command, args, timeout). It never leaves this
    #     machine. Platform stores no command, path or environment map, so none of this is
    #     ever sent.
    #   - the PUBLIC IDENTITY (`role`, `name`, `provider`, `version`, `config_digest`). That is
    #     the only thing Platform learns, and `config_digest` is a one-way hash of the local
    #     configuration — it lets an operator tell two machines apart without disclosing what
    #     either one runs.
    #
    # Reviewer configuration is INDEPENDENT of executor configuration. A machine may have one,
    # both, or neither; a missing reviewer block leaves review unavailable and does not affect
    # implementation claiming at all (S12).
    class Settings
      Error = Class.new(StandardError)

      PROVIDER_CLAUDE = "claude"
      PROVIDER_FAKE = "fake"
      PROVIDERS = [ PROVIDER_CLAUDE, PROVIDER_FAKE ].freeze
      DEFAULT_NAME = "Local Reviewer"
      DEFAULT_TIMEOUT_SECONDS = 1800

      # Environment overrides, so the demo and the automated tests can select the
      # deterministic provider without editing an operator's YAML.
      PROVIDER_ENV = "SPECRELAY_RUNNER_REVIEWER_PROVIDER"
      COMMAND_ENV = "SPECRELAY_RUNNER_REVIEWER_COMMAND"

      # The reviewer's ONE supported output mode (MAPIAI-78 design 1).
      #
      # The review document IS the provider's stdout, so the provider must be in its direct text
      # mode. `--output-format json` wraps that document in a provider envelope whose top level
      # carries no `outcome`: it parses, and it is not a review — the shape that stranded the
      # live MAPIAI-73 review. It is REFUSED rather than decoded, because a second accepted
      # output shape means a second result parser and no way to prove which one produced a
      # verdict. The executor lane makes the opposite choice for the opposite reason: it reads a
      # turn STREAM, so structured output is mandatory there (ClaudeProfile::REQUIRED_FLAGS).
      OUTPUT_FORMAT_FLAG = "--output-format"
      TEXT_OUTPUT = "text"
      UNSUPPORTED_OUTPUT = "runner.reviewer.args must leave the reviewer in its direct text " \
                           "output mode: remove #{OUTPUT_FORMAT_FLAG}, or state it exactly once " \
                           "as '#{TEXT_OUTPUT}'"

      attr_reader :name, :provider, :command, :args, :timeout_seconds

      def self.from(config, env: ENV)
        new(config.reviewer_settings, env: env)
      end

      def initialize(document, env: ENV)
        fields = (document || {}).to_h.transform_keys(&:to_s)
        @env = env
        @provider = presence(env[PROVIDER_ENV]) || presence(fields["provider"])
        @name = presence(fields["name"]) || DEFAULT_NAME
        @command = presence(env[COMMAND_ENV]) || presence(fields["command"])
        @args = Array(fields["args"]).map(&:to_s)
        @timeout_seconds = fields["timeout_seconds"].to_i.positive? ? fields["timeout_seconds"].to_i : DEFAULT_TIMEOUT_SECONDS
      end

      # True when this machine has a reviewer capability configured at all. False is a normal,
      # supported state — not an error.
      def configured? = PROVIDERS.include?(provider)

      def claude? = provider == PROVIDER_CLAUDE
      def fake? = provider == PROVIDER_FAKE

      # The bounded PUBLIC identity Platform stores. Nothing here is a command, a path, an
      # argument list or an environment value: `config_digest` stands in for all of them.
      def public_identity(version:)
        { "role" => "reviewer", "name" => name, "provider" => provider,
          "version" => version, "config_digest" => config_digest }
      end

      # A one-way digest of the LOCAL configuration. Two machines configured identically share
      # it; nothing about what they run can be recovered from it.
      def config_digest
        material = [ provider, command.to_s, args.join(" "), timeout_seconds.to_s ].join("|")
        Digest::SHA256.hexdigest(material)[0, 32]
      end

      # The argv that launches ONE fresh reviewer process. Built here so the reviewer's
      # non-interactive flags are this object's decision rather than something an operator can
      # accidentally omit.
      def argv(prompt)
        raise Error, "no reviewer provider is configured (set runner.reviewer.provider)" unless configured?
        raise Error, UNSUPPORTED_OUTPUT if claude? && wrapped_output?

        [ resolved_command, *effective_args, prompt ]
      end

      private

      attr_reader :env

      # EVERY occurrence, in both spellings. Reading only the first one let `--output-format text
      # --output-format json` pass while leaving the provider wrapped (review-001 F6).
      #
      # Exactly one selection, and it must be text. A repeated flag is refused even when its
      # values agree: which occurrence the provider honours is the provider's business, and a
      # configuration whose effective output mode has to be reasoned about is not the
      # deterministic one this boundary exists to guarantee. A flag with no value reads as an
      # empty selection and is refused by the same comparison.
      def wrapped_output?
        selections = output_format_selections
        return false if selections.empty?

        selections != [ TEXT_OUTPUT ]
      end

      def output_format_selections
        args.each_with_index.filter_map do |arg, index|
          flag, inline = arg.to_s.split("=", 2)
          next unless flag == OUTPUT_FORMAT_FLAG

          inline || args[index + 1].to_s
        end
      end

      def resolved_command
        return command if command

        claude? ? ClaudeProfile::EXECUTABLE : (raise Error, "runner.reviewer.command is required for the fake provider")
      end

      # `--print` is mandatory for the real provider: it is what makes Claude Code answer once
      # and exit rather than opening a session. A configuration that omits it gets it added
      # rather than being refused, because the operator's intent is unambiguous.
      def effective_args
        return args unless claude?
        return args if args.any? { |arg| ClaudeProfile::PRINT_FLAGS.include?(arg.to_s.split("=", 2).first) }

        [ *args, "--print" ]
      end

      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
