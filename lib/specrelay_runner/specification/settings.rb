# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # The operator-owned, NON-SECRET local configuration for the specification lane
    # (MVP-0026). It answers the questions Platform deliberately cannot: where this machine
    # keeps its clone of the specification repository, which generation provider it is
    # allowed to run, and — for each capability the lane requires — whether it is available
    # or has an explicitly recorded substitute.
    #
    # It lives under `runner.specification:` in the same YAML the rest of the runner reads,
    # and every value may be overridden from the environment, so a guided connection (which
    # writes no YAML at all) can still be pointed at a checkout without hand-authoring a
    # config file.
    #
    #   runner:
    #     specification:
    #       provider:
    #         kind: composed             # composed | command  (`fake` is an accepted alias)
    #         command: /abs/path/to/spec-writer
    #         args: []
    #         timeout_seconds: 900
    #       repository_roots:
    #         "SpecRelay/SpecRelay-Specs": /abs/path/to/specs-checkout
    #       on_existing_package: replace # replace | refuse
    #       graphify:
    #         substitute: "<why, when the wrappers are absent>"
    #       context_plus:
    #         available: false
    #         substitute: "<why, and what was used instead>"
    #         queries:                   # optional: the semantic themes the operator searched
    #           - "<query theme>"
    #         evidence: "<the material hits, in the operator's own words>"
    #       external_references:
    #         available: false
    #         substitute: "<why, when the bundle defers a reference to the runner>"
    #
    # THE SUBSTITUTE KEYS ARE NOT AN OFF SWITCH. Each one is a sentence the operator writes
    # and the runner copies verbatim into `analysis/technical.md` and into the tool-evidence
    # summary Platform stores. Recording the gap is what makes proceeding honest; omitting
    # the key is what makes preflight refuse. That asymmetry is the design — the spec's
    # "silent omission blocks acceptance" rule expressed as behaviour rather than as a
    # documentation promise.
    #
    # No secret is read here or stored here. The provider command is a local executable
    # path, and the credential the runner uses to reach Platform is resolved elsewhere.
    class Settings
      Error = Class.new(StandardError)

      # The built-in provider is `composed`, and it is named that everywhere an operator can
      # see it: in the configuration, in the log, in the manifest, and in the diagnostics
      # Platform persists.
      #
      # It used to be configured as `fake` while reporting itself as `composed`, so the run
      # page told an operator the DEFAULT production path was a fake. It is not a fake — it
      # composes real documents from the real bundle and the real source evidence, and it is a
      # weak writer rather than a pretend one. `fake` stays accepted as an alias so no
      # operator's existing config or env var breaks; it normalizes to `composed` on the way
      # in, so there is exactly one value downstream.
      PROVIDER_COMPOSED = "composed"
      PROVIDER_FAKE = "fake"
      PROVIDER_COMMAND = "command"
      # MVP-0028 remediation — the operator's real Claude profile, the one already configured
      # under `runner.executor` for the implementation lane, used to WRITE the specification.
      # Before this existed the specification lane had no way to name the real provider at all,
      # which is why an operator who selected "Claude Code (real provider)" in guided setup still
      # got the deterministic composer: they had configured the only provider the product offered
      # them, and the specification lane was not looking at it.
      PROVIDER_CLAUDE = "claude"
      PROVIDER_KINDS = [ PROVIDER_COMPOSED, PROVIDER_COMMAND, PROVIDER_CLAUDE ].freeze
      PROVIDER_ALIASES = { PROVIDER_FAKE => PROVIDER_COMPOSED }.freeze

      # What to do when a package for this issue already exists locally. MVP-0026 scope 10
      # requires ONE documented behaviour; `replace` is it, and `refuse` exists for an
      # operator who wants a hand-edited package protected from an automated overwrite.
      #
      # `replace` is the default because the alternative makes the ordinary case — a
      # re-run after a bad generation — require a manual `rm -rf` before the runner will
      # work, and an operator who does that under time pressure is one slip away from
      # deleting the wrong directory. The replacement is atomic and is recorded in the
      # manifest, so nothing is lost silently.
      REPLACE = "replace"
      REFUSE = "refuse"
      EXISTING_POLICIES = [ REPLACE, REFUSE ].freeze

      DEFAULT_TIMEOUT_SECONDS = 900

      # Per-repository root override, e.g.
      # SPECRELAY_RUNNER_SPEC_REPOSITORY_ROOT_SPECRELAY_SPECRELAY_SPECS. Mirrors the
      # established SPECRELAY_RUNNER_WORKSPACE_ROOT_<KEY> convention rather than inventing
      # a second shape, so an operator who has mapped a workspace already knows this one.
      REPOSITORY_ROOT_ENV = "SPECRELAY_RUNNER_SPEC_REPOSITORY_ROOT"
      PROVIDER_KIND_ENV = "SPECRELAY_RUNNER_SPEC_PROVIDER"
      PROVIDER_COMMAND_ENV = "SPECRELAY_RUNNER_SPEC_PROVIDER_COMMAND"
      EXISTING_POLICY_ENV = "SPECRELAY_RUNNER_SPEC_ON_EXISTING_PACKAGE"

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

      attr_reader :provider_kind, :provider_command, :provider_args, :provider_timeout_seconds,
                  :repository_roots, :on_existing_package, :graphify, :context_plus, :external_references

      def self.from(config, env: ENV) = new(config.specification_settings, env: env)

      def initialize(document, env: ENV)
        @document = document.is_a?(Hash) ? document.transform_keys(&:to_s) : {}
        @env = env
        provider = subsection("provider")
        @provider_kind = resolve_provider_kind(provider)
        @provider_command = presence(env[PROVIDER_COMMAND_ENV]) || presence(provider["command"])
        @provider_args = Array(provider["args"]).map(&:to_s)
        @provider_timeout_seconds = positive_int(provider["timeout_seconds"]) || DEFAULT_TIMEOUT_SECONDS
        @repository_roots = string_map(@document["repository_roots"])
        @on_existing_package = resolve_existing_policy
        @graphify = capability("graphify", default_available: true)
        @context_plus = capability("context_plus", default_available: false, operator_evidence: true)
        @external_references = capability("external_references", default_available: false)
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

      def replace_existing? = on_existing_package == REPLACE

      # NOT "is the kind unset or composed". An unset kind is a question for {Provider.resolve},
      # which knows what else the operator configured; answering it here as `composed` is exactly
      # the silent substitution this remediation removes.
      def composed_provider? = provider_kind == PROVIDER_COMPOSED
      def claude_provider? = provider_kind == PROVIDER_CLAUDE
      def provider_kind_configured? = !provider_kind.nil?

      private

      attr_reader :document, :env

      # nil when nothing selects a provider, and that is the whole point of this method.
      #
      # It used to default to `composed`. An absent `runner.specification` section is the ordinary
      # state of a guided setup — which writes no runner YAML at all — so the default silently
      # decided the most important question in the lane, and decided it wrongly for every operator
      # who had configured a real provider elsewhere. Returning nil moves the decision to
      # {Provider.resolve}, which can see the operator's executor profile; nothing downstream may
      # read nil as "composed".
      def resolve_provider_kind(provider)
        configured = presence(env[PROVIDER_KIND_ENV]) || presence(provider["kind"])
        return nil if configured.nil?

        kind = PROVIDER_ALIASES.fetch(configured, configured)
        raise Error, "runner.specification.provider.kind must be one of: #{PROVIDER_KINDS.join(', ')}" unless
          PROVIDER_KINDS.include?(kind)

        kind
      end

      def resolve_existing_policy
        policy = presence(env[EXISTING_POLICY_ENV]) || presence(document["on_existing_package"]) || REPLACE
        raise Error, "runner.specification.on_existing_package must be one of: #{EXISTING_POLICIES.join(', ')}" unless
          EXISTING_POLICIES.include?(policy)

        policy
      end

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
