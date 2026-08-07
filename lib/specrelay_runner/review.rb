# frozen_string_literal: true

module SpecrelayRunner
  # MVP-0033 — the REVIEWER role.
  #
  # A separate namespace from the implementation lane, because a review shares almost nothing
  # with an execution: it creates no worktree, edits no file, runs no test suite of its own on
  # behalf of the ticket, pushes nothing, and finishes with a verdict rather than a report.
  # What it does share — the claim, the lease, the heartbeat — it reuses verbatim.
  #
  # Pipeline order, which is also the require order below:
  #   Settings  - the operator's local reviewer configuration and its bounded public identity
  #   Assignment- the claimed packet, read through named accessors
  #   Checkout  - proof that this machine really holds the pinned remote and head
  #   Packet    - the reviewer's entire input, rendered once
  #   Result    - strict parsing and redaction of the provider's stdout
  #   Execution - the orchestration, and the only place that submits
  module Review
  end
end

require_relative "review/settings"
require_relative "review/assignment"
require_relative "review/checkout"
require_relative "review/packet"
require_relative "review/result"
require_relative "review/execution"
