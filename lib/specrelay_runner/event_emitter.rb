# frozen_string_literal: true

require "time"

module SpecrelayRunner
  # MVP-0013 — owns the runner's per-attempt monotonic sequence counter and builds
  # the v1 protocol event envelope for POST /api/runner/events. It is the single
  # place the runner assigns a sequence, so a sequence is never reused for a
  # different payload: `emit` always advances the counter, and the deterministic
  # duplicate/conflict/out-of-order controls reuse a REMEMBERED envelope verbatim
  # (duplicate), mutate only the summary at a used sequence (conflict), or send an
  # adjacent NEW pair in reversed order (out-of-order) — never inventing a new
  # payload at an old sequence.
  #
  # It stays thin: it delegates every send to PlatformClient and hands each
  # response back to the caller (Execution) so lease/stop observation stays in one
  # place. It holds no Rails/ActiveRecord dependency.
  class EventEmitter
    CONTRACT_VERSION = "1"
    SCHEMA_VERSION = 1

    attr_reader :sequence

    def initialize(client:, run_id:, attempt_id:, clock: Time)
      @client = client
      @run_id = run_id
      @attempt_id = attempt_id
      @clock = clock
      @sequence = 0
      @sent = {}
    end

    # Emit the next ordered event and return Platform's parsed response.
    def emit(event_type, public_summary, **attributes)
      send_envelope(build(next_sequence, event_type, public_summary, attributes))
    end

    # Emit one adjacent pair with the HIGHER sequence sent first, proving Platform
    # accepts out-of-order delivery and still presents canonical sequence order.
    # Returns both responses.
    def emit_out_of_order_pair(event_type, summary_lower, summary_higher, **attributes)
      lower = next_sequence
      higher = next_sequence
      higher_response = send_envelope(build(higher, event_type, summary_higher, attributes))
      lower_response = send_envelope(build(lower, event_type, summary_lower, attributes))
      [ lower_response, higher_response ]
    end

    # Re-send an already-sent event verbatim (same sequence, same payload); Platform
    # returns it as an idempotent duplicate. No-op if the sequence was never sent.
    def resend_duplicate(sequence)
      envelope = @sent[sequence]
      envelope ? send_envelope(envelope) : nil
    end

    # Re-send a used sequence with a materially different payload; Platform records
    # a conflict WITHOUT overwriting the original. No-op if never sent.
    def resend_conflict(sequence, conflicting_summary)
      envelope = @sent[sequence]
      return nil unless envelope

      send_envelope(envelope.merge("public_summary" => conflicting_summary))
    end

    private

    attr_reader :client, :run_id, :attempt_id, :clock

    def next_sequence = @sequence += 1

    def build(sequence, event_type, public_summary, attributes)
      envelope = {
        "contract_version" => CONTRACT_VERSION,
        "run_id" => run_id,
        "attempt_id" => attempt_id,
        "sequence" => sequence,
        "event_type" => event_type,
        "schema_version" => SCHEMA_VERSION,
        "occurred_at" => clock.now.utc.iso8601,
        "public_summary" => Redaction.redact(public_summary.to_s),
        "attributes" => stringify(attributes)
      }
      @sent[sequence] = envelope
      envelope
    end

    def send_envelope(envelope)
      client.submit_protocol_event(claim: attempt_id, event: envelope)
    end

    def stringify(attributes)
      attributes.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value }
    end
  end
end
