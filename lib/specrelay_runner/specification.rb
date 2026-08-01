# frozen_string_literal: true

module SpecrelayRunner
  # The runner's SPECIFICATION-CREATION lane (MVP-0026).
  #
  # A sibling of the implementation lane, not a mode of it. Where {Execution} creates a
  # worktree, launches an executor, runs a project's tests, publishes a branch, and uploads
  # an execution report, this lane reads an assignment, inspects a source checkout read-only,
  # generates three Markdown documents into the operator's specification repository checkout,
  # and reports what it wrote. It never commits, pushes, opens a pull request, writes a Jira
  # field, or transitions an issue — MVP-0027 and MVP-0028 own those.
  #
  # The pipeline, in the order it runs and in the order these files are required:
  #
  #   Markdown        fenced-block rules, shared by everything that embeds untrusted text
  #   Assignment      parse and validate the payload Platform sent
  #   Settings        the operator's local, non-secret lane configuration
  #   PackagePath     the deterministic, contained destination
  #   InputEvidence   which recorded inputs this machine can actually use
  #   SourceEvidence  read-only source inspection + Graphify/Context+ evidence
  #   Preflight       every check that must pass BEFORE a byte is written
  #   Packet          the sanitized input handed to a provider
  #   Composer        the deterministic built-in document author
  #   Provider        the provider boundary (built-in composer, or a configured command)
  #   DocumentSet     structural validation of whatever a provider returned
  #   PackageWriter   stage, redact, verify, digest, and ONE atomic rename into place
  #   Generation      the orchestrator that runs the above against a live claim
  #
  # Two properties hold across the whole lane and are worth stating once here:
  #
  #   1. Nothing writes before Preflight returns Ready. A missing capability is a refusal
  #      with zero output files, not a partial package plus a warning.
  #   2. Nothing in this namespace requires Rails, ActiveRecord, or any Platform constant.
  #      The runner remains a thin client that talks to Platform only over HTTP.
  module Specification
    # The version of the packet contract handed to a generation provider. Separate from the
    # manifest's contract version because they are read by different audiences — a provider
    # author reads this one, a tool inspecting a package on disk reads the other — and they
    # will not necessarily change together.
    PACKET_CONTRACT_VERSION = "mvp-0026"
  end
end

require_relative "specification/markdown"
require_relative "specification/assignment"
require_relative "specification/settings"
require_relative "specification/package_path"
require_relative "specification/input_evidence"
require_relative "specification/source_evidence"
require_relative "specification/packet"
require_relative "specification/composer"
require_relative "specification/document_set"
require_relative "specification/provider"
require_relative "specification/package_writer"
require_relative "specification/preflight"
require_relative "specification/generation"
