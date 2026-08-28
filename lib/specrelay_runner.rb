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
  # MAPIAI-97 — raised when this machine finished its work but could not release the task
  # environment it created. It ends the session rather than failing one run: the next claim would
  # be built on top of an environment nobody accounted for.
  CleanupRequired = Class.new(StandardError)
end

require_relative "specrelay_runner/version"
require_relative "specrelay_runner/redaction"
# MAPIAI-97 CR-006 — the one private-host-path rule, beside the one secret rule. Loaded here
# because both the specification analyzer and the preview lane depend on it.
require_relative "specrelay_runner/private_paths"
require_relative "specrelay_runner/config"
require_relative "specrelay_runner/platform_client"
require_relative "specrelay_runner/command_runner"
require_relative "specrelay_runner/claude_profile"
# MAPIAI-60: the one decoder that turns the supported profile's structured output into safe
# progress and a terminal result. Loaded here because both execution lanes depend on it.
require_relative "specrelay_runner/claude_stream"
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
# MAPIAI-84: the one GitHub-identity normalizer, and the executor's bounded repository selection.
# Both are loaded before `workspace`, which verifies a selection against the repositories on disk.
require_relative "specrelay_runner/github_remote"
require_relative "specrelay_runner/repository_selection"
require_relative "specrelay_runner/workspace"
require_relative "specrelay_runner/repository_verification"
require_relative "specrelay_runner/executor"
require_relative "specrelay_runner/report_bundle"
require_relative "specrelay_runner/heartbeater"
require_relative "specrelay_runner/protocol_controls"
require_relative "specrelay_runner/event_emitter"
require_relative "specrelay_runner/executor_log_stream"
require_relative "specrelay_runner/question_bridge"
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
# MVP-0035 / MVP-0036 Stage 2b: proving a worktree holds the exact recorded head, and the change
# request that is one of the two reasons to require it. `continued_target` first — `rework` is
# built on it.
# MAPIAI-87 — the PREVIOUS accepted package's own materializer, beside `continued_target` because
# the two are siblings rather than variants: this one reconstructs several repositories an earlier
# run had accepted, and yields to that one's same-run authority whenever both could apply.
require_relative "specrelay_runner/contained_repositories"
require_relative "specrelay_runner/previous_accepted_package"
# MAPIAI-97: the preview lane's own source resolver. After the accepted-package lane, because it
# reuses that lane's bounded `gh` reader rather than declaring a second one.
# MAPIAI-97: the closed preview assignment boundary, read before any source or command work.
require_relative "specrelay_runner/preview_assignment"
# MAPIAI-97 CR-006: the preview lane's own output boundary, which applies the private-path rule to
# a project command's raw output before either surface sees it.
require_relative "specrelay_runner/preview_output"
require_relative "specrelay_runner/preview_sources"
# MAPIAI-97: the project-owned status document, projected to the closed wire shape.
require_relative "specrelay_runner/preview_status"
# MAPIAI-97: the ordered preview lifecycle that drives the project's own worktree commands. Last
# of the four, because it composes the other three.
require_relative "specrelay_runner/preview_execution"
# MAPIAI-97: the claim that holds a preview open — the lifecycle above, plus the heartbeat that
# renews it and carries Stop back.
require_relative "specrelay_runner/preview_session"
# MAPIAI-97: releasing the task environment a finished run leaves behind, through the same
# project-owned authority the preview lane uses.
require_relative "specrelay_runner/task_environment"
require_relative "specrelay_runner/continued_target"
require_relative "specrelay_runner/rework"
# MVP-0036 Stage 2a: the offline resume round — continuing from this machine's own uncommitted
# work, proven unchanged. Loaded after `review` for the same reason `rework` is: both prove a
# target through its read-only git seam.
require_relative "specrelay_runner/checkpoint"
require_relative "specrelay_runner/resume"
require_relative "specrelay_runner/execution"
# MVP-0026: turning that recognized assignment into a generated specification package.
# The whole lane lives under one namespace; see specification.rb for the pipeline order.
require_relative "specrelay_runner/specification"
require_relative "specrelay_runner/package_preflight"
require_relative "specrelay_runner/poll_interval"
require_relative "specrelay_runner/presence"
require_relative "specrelay_runner/loop_runner"
require_relative "specrelay_runner/cli"
