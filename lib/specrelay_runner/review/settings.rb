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
    #       args: [--print, --output-format, stream-json, --verbose,
    #              --dangerously-skip-permissions]
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

      # The reviewer's ONE supported output mode (MAPIAI-103, replacing MAPIAI-78 design 1).
      #
      # The reviewer now reads the SAME structured stream the implementation and specification
      # lanes read, decoded by the SAME {ClaudeStream}: that is what makes its public activity
      # visible while it works, and its review document that decoder's one terminal result. Direct
      # text is gone rather than kept as a second accepted shape — two shapes would mean two
      # result parsers and no way to prove which one produced a verdict, which is exactly how the
      # live MAPIAI-73 review was stranded.
      #
      # {ClaudeProfile} owns WHICH flags request that stream and is asked rather than copied. An
      # explicit operator list stays authoritative and is REFUSED rather than corrected when it
      # does not request the stream: a flag added silently here would mean the effective
      # invocation is not the one the operator can read in their own YAML.
      UNSUPPORTED_OUTPUT = "runner.reviewer.args must request the supported structured reviewer " \
                           "stream (#{ClaudeProfile::PRINT_FLAGS.first} with " \
                           "#{ClaudeProfile.required_description}); the review document is " \
                           "decoded from that stream"

      # The supported invocation when the operator wrote no `args:` at all — the guided-setup
      # path, which stores a provider identifier and no launch configuration (MAPIAI-91).
      # `--dangerously-skip-permissions` is MAPIAI-100's tool-enabled reviewer default.
      DEFAULT_ARGS = [ "--print", "--output-format", ClaudeProfile::STREAM_FORMAT, "--verbose",
                       "--dangerously-skip-permissions" ].freeze

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

      # The argv that launches ONE fresh reviewer process. An operator who wrote no `args:` gets
      # the supported default; one who wrote an unsupported list is told what is missing here,
      # before an expensive provider runs against output nothing can decode.
      def argv(prompt)
        raise Error, "no reviewer provider is configured (set runner.reviewer.provider)" unless configured?

        launch = effective_args
        raise Error, UNSUPPORTED_OUTPUT if claude? && !ClaudeProfile.structured_stream?(launch)

        [ resolved_command, *launch, prompt ]
      end

      private

      attr_reader :env

      def resolved_command
        return command if command

        claude? ? ClaudeProfile::EXECUTABLE : (raise Error, "runner.reviewer.command is required for the fake provider")
      end

      # An empty list gets the supported default; anything the operator wrote is launched exactly
      # as written (MAPIAI-100 acceptance 2) and refused above when it does not request the
      # supported stream.
      def effective_args = claude? && args.empty? ? DEFAULT_ARGS : args

      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
