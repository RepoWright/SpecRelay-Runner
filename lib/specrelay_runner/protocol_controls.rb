# frozen_string_literal: true

module SpecrelayRunner
  # MVP-0013 deterministic, NON-SECRET protocol test controls, read from the
  # environment. Every control DEFAULTS OFF and only reproduces a protocol anomaly
  # the spec requires evidence for (out-of-order delivery, an idempotent duplicate
  # retry, a same-sequence conflict, a forced terminal failure). They only change
  # HOW the runner delivers its own already-computed events; they can never weaken
  # Platform's safety behavior — Platform still classifies, dedupes, and validates
  # exactly as in production. They are ignored unless explicitly set to "true"/"1".
  #
  #   SPECRELAY_RUNNER_EVENT_OUT_OF_ORDER=true  # send one adjacent pair reversed
  #   SPECRELAY_RUNNER_EVENT_DUPLICATE=true     # re-send one event (same seq+payload)
  #   SPECRELAY_RUNNER_EVENT_CONFLICT=true      # re-send one seq with a different payload
  #   SPECRELAY_RUNNER_FORCE_TERMINAL_FAILURE=true  # submit a failed terminal envelope
  class ProtocolControls
    OUT_OF_ORDER_ENV = "SPECRELAY_RUNNER_EVENT_OUT_OF_ORDER"
    DUPLICATE_ENV = "SPECRELAY_RUNNER_EVENT_DUPLICATE"
    CONFLICT_ENV = "SPECRELAY_RUNNER_EVENT_CONFLICT"
    FORCE_TERMINAL_FAILURE_ENV = "SPECRELAY_RUNNER_FORCE_TERMINAL_FAILURE"

    def initialize(env: ENV)
      @env = env
    end

    def out_of_order? = flag?(OUT_OF_ORDER_ENV)
    def duplicate? = flag?(DUPLICATE_ENV)
    def conflict? = flag?(CONFLICT_ENV)
    def force_terminal_failure? = flag?(FORCE_TERMINAL_FAILURE_ENV)
    def any? = out_of_order? || duplicate? || conflict?

    private

    def flag?(name)
      %w[true 1].include?(@env[name].to_s.strip.downcase)
    end
  end
end
