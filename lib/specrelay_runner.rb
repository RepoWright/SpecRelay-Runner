# frozen_string_literal: true

# The SpecRelay standalone runner: the execution plane (MVP-0010, extracted into
# this repository in MVP-0015).
#
# A thin, developer-installed execution client that talks to Platform ONLY over
# the runner HTTP API. It deliberately shares NO code and NO process with the
# Rails control plane: there is no `require "rails"`, no ActiveRecord, and no
# Platform constant anywhere in this repository. That process separation is the
# whole point — Platform is the control plane, this is the execution plane.
#
# See README.md for setup, the trust boundary, and the posture for a runner that
# may later ship as a proprietary binary on a customer machine.
module SpecrelayRunner
end

require_relative "specrelay_runner/version"
require_relative "specrelay_runner/redaction"
require_relative "specrelay_runner/config"
require_relative "specrelay_runner/platform_client"
require_relative "specrelay_runner/command_runner"
require_relative "specrelay_runner/claude_profile"
require_relative "specrelay_runner/workspace"
require_relative "specrelay_runner/executor"
require_relative "specrelay_runner/report_bundle"
require_relative "specrelay_runner/heartbeater"
require_relative "specrelay_runner/protocol_controls"
require_relative "specrelay_runner/event_emitter"
require_relative "specrelay_runner/publication"
require_relative "specrelay_runner/terminal_result"
require_relative "specrelay_runner/execution"
require_relative "specrelay_runner/cli"
