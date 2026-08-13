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
# MVP-0017 guided connection: the OS secret store, the local checkout validator, the
# non-secret local connection record, and the `connect` operation that drives them.
require_relative "specrelay_runner/secret_store"
require_relative "specrelay_runner/repository_check"
require_relative "specrelay_runner/connection_store"
require_relative "specrelay_runner/connect"
# MVP-0021 local control center: the readiness test, the one implementation of every
# connection-management action, its two presentations (a keyboard-driven dashboard and the
# scriptable `connections` commands), and the shared non-secret rendering rules.
require_relative "specrelay_runner/connection_view"
require_relative "specrelay_runner/connection_diagnosis"
require_relative "specrelay_runner/connection_operations"
require_relative "specrelay_runner/connections_command"
require_relative "specrelay_runner/terminal_menu"
# RUNNER-0001: the one terminal write boundary shared by loop status and live
# executor output — transient rows for what is true now, durable lines for the record.
require_relative "specrelay_runner/terminal_presenter"
require_relative "specrelay_runner/workspace_view"
require_relative "specrelay_runner/dashboard"
require_relative "specrelay_runner/workspace"
require_relative "specrelay_runner/executor"
require_relative "specrelay_runner/report_bundle"
require_relative "specrelay_runner/heartbeater"
require_relative "specrelay_runner/protocol_controls"
require_relative "specrelay_runner/event_emitter"
require_relative "specrelay_runner/executor_log_stream"
# MVP-0027: the pull-request reuse decision, shared by both publication lanes.
require_relative "specrelay_runner/pull_request_reuse"
require_relative "specrelay_runner/publication"
require_relative "specrelay_runner/terminal_result"
# MVP-0034: the pinned package the executor implements, verified and written read-only before
# `execution` launches a provider on it.
require_relative "specrelay_runner/specification_package"
# MVP-0033: the REVIEWER role. Loaded before `rework` and `execution`, which reuse its read-only
# git seam to prove a reviewed head is still the one the remote shows.
require_relative "specrelay_runner/review"
# MVP-0035: the change-request round — continuing an implementation from the exact reviewed
# pull-request head, with the reviewer's findings.
require_relative "specrelay_runner/rework"
require_relative "specrelay_runner/execution"
# MVP-0026: turning that recognized assignment into a generated specification package.
# The whole lane lives under one namespace; see specification.rb for the pipeline order.
require_relative "specrelay_runner/specification"
require_relative "specrelay_runner/package_preflight"
require_relative "specrelay_runner/poll_interval"
require_relative "specrelay_runner/presence"
require_relative "specrelay_runner/loop_runner"
require_relative "specrelay_runner/cli"
