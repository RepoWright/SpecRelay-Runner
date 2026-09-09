# frozen_string_literal: true

require "json"

module SpecrelayRunner
  # The ONE exact-profile authority on this side of the wire: Claude, Codex, or the shipped
  # deterministic fixture, each with a canonical identity, and nothing else.
  #
  # It is deliberately a small explicit map and NOT a provider registry, a plugin system, a base
  # class or a discovery mechanism. Nothing registers itself; adding a third real provider means
  # editing this list and writing that provider's own profile, which is the visible, reviewable
  # change it should be.
  #
  # Why the comparison is EXACT rather than rule-based. The first version asked each profile whether
  # it would *tolerate* a payload — a basename check plus a denylist — and returned `nil` for the
  # fixture without looking at any other field. Reviewer probes then launched an arbitrary
  # executable under `provider: fake` and an attacker-controlled absolute file named `codex`, both
  # of which reached worktree creation. A tolerant validator can only refuse what someone thought to
  # forbid; an exact identity refuses everything nobody approved. The payload comes from Platform
  # over HTTP, so this is the last boundary before this host runs a process.
  #
  # The fixture resolves to NO profile, which is what keeps the offline regression path free of any
  # provider readiness check: there is no real CLI to be installed, authenticated or compared.
  module ImplementationProfile
    Error = Class.new(StandardError)

    # The deterministic test/demo fixture the runner repository ships in its own `bin/`. It is a
    # scripted executable, not a provider, so it has no readiness, no identity comparison and no
    # failure taxonomy of its own.
    FIXTURE = "fake"
    FIXTURE_COMMAND = "specrelay-fake-executor"

    # The fixture's environment is its SCRIPT. The shipped executable reads these values to decide
    # which files it rewrites and what it writes into them, so an environment a payload could vary
    # is a payload that chooses what this host does to a repository — the same authority as an
    # arbitrary command, arriving through a field that merely looks like configuration. It is
    # therefore pinned to the one document Platform serves and compared literally, exactly like
    # every other identity dimension.
    #
    # The edits are the demo change the deterministic pipeline applies; Platform holds the same
    # ordered list. The two repositories cannot share a constant, so the agreement is asserted in
    # implementation_profile_test.rb rather than assumed.
    FIXTURE_EDITS = [
      { "file" => "demo-app/index.html", "from" => "Hello Demo", "to" => "SpecRelay Runner Repository Extraction" },
      { "file" => "demo-app/test/homepage.test.mjs", "from" => "Hello Demo",
        "to" => "SpecRelay Runner Repository Extraction" }
    ].freeze
    FIXTURE_CANONICAL = {
      "provider" => FIXTURE, "command" => FIXTURE_COMMAND, "mode" => "print", "args" => [],
      "prompt_delivery" => "file_argument", "timeout_seconds" => 120,
      # Frozen with the profile it belongs to: it is the one canonical environment with content in
      # it, and a caller that merged into it in place would rewrite the approved profile for the
      # whole process.
      "env" => { "FAKE_EXECUTOR_MODE" => "success",
                 "FAKE_EXECUTOR_EDITS_JSON" => JSON.generate(FIXTURE_EDITS) }.freeze
    }.freeze

    OWNERS = { ClaudeProfile::PROVIDER => ClaudeProfile, CodexProfile::PROVIDER => CodexProfile }.freeze
    CANONICAL = {
      ClaudeProfile::PROVIDER => ClaudeProfile::CANONICAL,
      CodexProfile::PROVIDER => CodexProfile::CANONICAL,
      FIXTURE => FIXTURE_CANONICAL
    }.freeze
    PROVIDERS = CANONICAL.keys.freeze

    module_function

    # The selected profile, or nil for the deterministic fixture.
    #
    # Raises unless the claimed executor block IS one of the three canonical hashes: the same keys,
    # the same values, nothing missing, nothing extra, nothing spelled differently. The claim is
    # read exactly as it arrived — it is not trimmed, case-folded, coerced or completed from a
    # default first. A gate that tidies a claim up before comparing it is not comparing the claim;
    # it is comparing what it wishes the claim had said, and it admitted four noncanonical Codex
    # shapes on exactly that reasoning. Platform always emits the complete hash, so an incomplete or
    # decorated one has no legitimate source.
    #
    # That refusal must happen before a worktree is created and before any process is launched;
    # every caller on the implementation path treats it as a terminal refusal, never as a downgrade
    # to the fixture.
    def for(executor_config)
      raise Error, "executor must be a configuration block" unless executor_config.is_a?(Hash)

      provider = executor_config["provider"]
      canonical = CANONICAL[provider] or raise Error, unsupported(provider)

      refuse_difference!(canonical, executor_config, provider)
      OWNERS[provider]&.new(executor_config)
    end

    # The canonical executor block for a provider-only selection — the shape both Platform and this
    # runner accept. A machine names a provider; neither side lets it describe one.
    def canonical(provider)
      key = provider.to_s.strip.downcase
      CANONICAL[key] or raise Error, unsupported(key)
    end

    def provider_of(executor_config)
      return "" unless executor_config.is_a?(Hash)

      executor_config.transform_keys(&:to_s)["provider"].to_s.strip.downcase
    end

    # One comparison, in three named steps so a refusal says which one failed. Nothing is compared
    # field-by-field until the two hashes describe the same set of fields, because "your timeout is
    # wrong" is the wrong thing to tell an operator who did not send a timeout at all.
    def refuse_difference!(canonical, claim, provider)
      return if claim == canonical

      absent = canonical.keys - claim.keys
      raise Error, "executor is missing #{absent.join(', ')} for the approved #{provider} profile" if absent.any?

      extra = claim.keys - canonical.keys
      raise Error, "executor carries #{Redaction.redact(extra.join(', '))}, which is not part of " \
                   "the approved #{provider} profile" if extra.any?

      # Equal key sets and unequal hashes: some value differs, so this always finds one.
      field = canonical.keys.find { |name| claim[name] != canonical[name] }
      raise Error, difference(provider, field, canonical[field])
    end

    # Names the dimension and what it must be. The claimed VALUE is never echoed: it is remote input
    # and may itself be the thing that should not be repeated into a log.
    def difference(provider, field, expected)
      "executor.#{field} is not the approved #{provider} profile (expected #{expected_description(expected)})"
    end

    # An environment is described by its KEYS. The approved values are not secret, but one of them
    # is a whole JSON document, and a refusal an operator reads should name the dimension rather
    # than reprint the profile at them. A profile that carries none says so, because "expected
    # nothing" is the actionable half of that refusal.
    def expected_description(expected)
      case expected
      when Hash then expected.empty? ? "no environment" : Redaction.redact(expected.keys.join(", "))
      when Array then expected.empty? ? "no arguments" : Redaction.redact(expected.join(" "))
      else Redaction.redact(expected.to_s)
      end
    end

    # The provider is looked up as written, so a padded or differently cased spelling names nothing
    # in the closed set and lands here rather than being folded into a match.
    def unsupported(provider)
      return "executor.provider is required" if provider.nil? || provider.to_s.empty?

      "executor.provider #{Redaction.redact(provider.to_s)} is not supported by this runner " \
        "(supported: #{PROVIDERS.join(', ')})"
    end
  end
end
