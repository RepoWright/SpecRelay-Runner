# frozen_string_literal: true

module SpecrelayRunner
  # The standalone runner version. The runner became a real product component in
  # MVP-0015, when it was extracted out of the development workspace's temporary
  # `scripts/runner/` spike location into this repository.
  VERSION = "0.1.0"

  # The runner API contract version this runner speaks. It must match the
  # Platform RunPayload contract version. The MVP-0015 extraction moved code
  # between repositories and deliberately did NOT change the protocol, so this
  # value stays exactly as the spike negotiated it.
  CONTRACT_VERSION = "mvp-0010"
end
