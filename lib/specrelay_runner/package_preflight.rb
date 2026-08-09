# frozen_string_literal: true

module SpecrelayRunner
  # The implementation lane's specification-package PREFLIGHT (MVP-0034 CR-001).
  #
  # Its own namespace rather than a member of {Specification}, because the two are opposite
  # directions across the same boundary: `Specification` WRITES a package to GitHub for the
  # specification lane, and this READS one back so an implementation run can be authorized by it.
  # They share `GitCommands` and `ExistingPullRequest`, which is exactly the overlap that should
  # be shared — how to run `gh` safely, and what makes a pull request usable.
  module PackagePreflight
  end
end

require_relative "package_preflight/assignment"
require_relative "package_preflight/reader"
require_relative "package_preflight/execution"
