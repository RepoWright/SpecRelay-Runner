# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # The operator-owned, NON-SECRET local configuration for the specification lane
    # (MVP-0026). It answers the questions Platform deliberately cannot: where this machine
    # keeps its clone of the specification repository, and — for each capability the lane
    # requires — whether it is available or has an explicitly recorded substitute.
    #
    # It does NOT choose a generation provider. That is one closed selection of an exact approved
    # profile, made once for the whole machine under `runner.executor:` or in Platform's Project
    # Setup, and read through {ImplementationProfile}. A second, lane-local answer here is what
    # let a runner generate specifications with a writer its operator had not selected.
    #
    # It lives under `runner.specification:` in the same YAML the rest of the runner reads,
    # and every value may be overridden from the environment, so a guided connection (which
    # writes no YAML at all) can still be pointed at a checkout without hand-authoring a
    # config file.
    #
    #   runner:
    #     specification:
    #       repository_roots:
    #         "SpecRelay/SpecRelay-Specs": /abs/path/to/specs-checkout   # a SEED, not a destination
    #       graphify:
    #         substitute: "<why, when the wrappers are absent>"
    #       context_plus:
    #         available: false
    #         substitute: "<why, and what was used instead>"
    #         queries:                   # optional: the semantic themes the operator searched
    #           - "<query theme>"
    #         evidence: "<the material hits, in the operator's own words>"
    #       external_references:
    #         command: /abs/path/to/reference-analyzer   # the REAL tool/MCP boundary (MVP-0028 remediation)
    #         timeout_seconds: 60
    #         substitute: "<why, when the bundle defers a reference to the runner>"
    #
    # THE SUBSTITUTE KEYS ARE NOT AN OFF SWITCH. Each one is a sentence the operator writes
    # and the runner copies verbatim into `analysis/technical.md` and into the tool-evidence
    # summary Platform stores. Recording the gap is what makes proceeding honest; omitting
    # the key is what makes preflight refuse. That asymmetry is the design — the spec's
    # "silent omission blocks acceptance" rule expressed as behaviour rather than as a
    # documentation promise.
    #
    # `external_references` has no `available:` DECLARATION to trust (MVP-0028 remediation,
    # defect 2). It used to: an operator-set `available: true` alone made a deferred reference
    # `readable`, with nothing ever fetched or analysed, and a specification generated as if it
    # had been. Availability is now a FACT this runner can prove — a `command` is configured, and
    # {InputEvidence} actually ran it against the reference — never a flag taken on trust.
    #
    # No secret is read here or stored here. The external-reference command is a local executable
    # path, and the credential the runner uses to reach Platform is resolved elsewhere.
    class Settings
      # Per-repository root override, e.g.
      # SPECRELAY_RUNNER_SPEC_REPOSITORY_ROOT_SPECRELAY_SPECRELAY_SPECS. Mirrors the
      # established SPECRELAY_RUNNER_WORKSPACE_ROOT_<KEY> convention rather than inventing
      # a second shape, so an operator who has mapped a workspace already knows this one.
      REPOSITORY_ROOT_ENV = "SPECRELAY_RUNNER_SPEC_REPOSITORY_ROOT"
      # MVP-0028 remediation, defect 2 — the REAL tool/MCP boundary that fetches and analyses an
      # external reference (a Jam smart link, a Confluence page, a screenshot) a bundle defers to
      # the runner. It is an operator-configured local executable this runner launches through
      # {CommandRunner}, never a live call this Ruby process makes itself.
      EXTERNAL_REFERENCE_COMMAND_ENV = "SPECRELAY_RUNNER_SPEC_EXTERNAL_REFERENCE_COMMAND"
      DEFAULT_EXTERNAL_REFERENCE_TIMEOUT_SECONDS = 60

      # A capability's local availability, plus the operator's recorded reason when it is
      # not available. `usable?` is deliberately "available OR substituted": both let
      # generation proceed, and the difference is what gets written into the evidence.
      #
      # `queries` and `notes` carry evidence the OPERATOR gathered by hand. They are populated
      # for Context+ only — see #capability — because Context+ is the one required capability
      # this process cannot probe, so it is the one place where a human's attestation is the
      # only semantic evidence there can be. Recording it does not make the capability
      # "contributed"; a person contributed, and SourceEvidence attributes it to them.
      Capability = Struct.new(:name, :available, :substitute, :queries, :notes, keyword_init: true) do
        def available? = available ? true : false
        def substitute? = !substitute.to_s.strip.empty?
        def usable? = available? || substitute?
        def queries = self[:queries] || []
        def recorded_evidence? = !queries.empty? || !notes.to_s.strip.empty?

        def evidence
          return "available" if available?
          return "unavailable — approved substitute: #{substitute}" if substitute?

          "unavailable, and no substitute was recorded"
        end
      end

      attr_reader :repository_roots, :graphify, :context_plus, :external_references,
                  :external_reference_command, :external_reference_timeout_seconds

      def self.from(config, env: ENV) = new(config.specification_settings, env: env)

      def initialize(document, env: ENV)
        @document = document.is_a?(Hash) ? document.transform_keys(&:to_s) : {}
        @env = env
        @repository_roots = string_map(@document["repository_roots"])
        @graphify = capability("graphify", default_available: true)
        @context_plus = capability("context_plus", default_available: false, operator_evidence: true)
        @external_references = capability("external_references", default_available: false)
        references = subsection("external_references")
        @external_reference_command = presence(env[EXTERNAL_REFERENCE_COMMAND_ENV]) || presence(references["command"])
        @external_reference_timeout_seconds = positive_int(references["timeout_seconds"]) ||
          DEFAULT_EXTERNAL_REFERENCE_TIMEOUT_SECONDS
      end

      # This machine's local clone of the specification repository, resolved by the same
      # precedence the workspace root uses: a per-repository env var, then a global one,
      # then the config map keyed by `owner/repository`. Returns nil when nothing maps —
      # Preflight turns that into a refusal with the exact variable to set, which is more
      # useful than a raised error from deep inside the writer.
      def repository_root(slug, repository_url: nil)
        presence(env[repository_root_env(slug)]) ||
          presence(env[REPOSITORY_ROOT_ENV]) ||
          presence(repository_roots[slug.to_s]) ||
          presence(repository_roots[repository_url.to_s])
      end

      # The env var name for one repository slug, so a refusal can name the exact variable
      # rather than describing its shape.
      def repository_root_env(slug)
        "#{REPOSITORY_ROOT_ENV}_#{slug.to_s.upcase.gsub(/[^A-Z0-9]+/, '_')}"
      end

      private

      attr_reader :document, :env

      # Availability defaults differ on purpose. Graphify defaults to AVAILABLE because the
      # workspace ships the wrappers and the runner probes for them anyway — the probe, not
      # this default, decides. Context+ and external-reference analysis default to
      # UNAVAILABLE because they are MCP capabilities this process cannot probe from the
      # outside, so assuming them present would let a runner claim evidence it never
      # gathered.
      # `operator_evidence` is opt-in per capability rather than read for all three, so
      # `graphify.queries` is not silently accepted-and-ignored. Graphify is probed; its
      # evidence comes from the tool, and a config key that looked like it would be reproduced
      # but never was is the kind of dead vocabulary the spec forbids adding.
      def capability(name, default_available:, operator_evidence: false)
        section = subsection(name)
        available = section.key?("available") ? truthy(section["available"]) : default_available
        Capability.new(name: name, available: available, substitute: presence(section["substitute"]),
                       queries: operator_evidence ? string_list(section["queries"]) : [],
                       notes: operator_evidence ? presence(section["evidence"]) : nil)
      end

      def string_list(value) = Array(value).map { |entry| entry.to_s.strip }.reject(&:empty?)

      def subsection(key)
        value = document[key]
        value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
      end

      def string_map(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) { |(key, entry), acc| acc[key.to_s] = entry.to_s }
      end

      def truthy(value) = [ true, "true", "yes", "1" ].include?(value.is_a?(String) ? value.downcase : value)

      def positive_int(value)
        number = value.to_i
        number.positive? ? number : nil
      end

      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
