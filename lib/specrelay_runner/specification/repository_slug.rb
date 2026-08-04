# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # Parses a git remote URL into a GitHub `owner/repo` slug, or nil when it does not resolve
    # to one.
    #
    # Extracted from {GitPublisher} (MVP-0028 remediation, defect 5) because a SECOND place now
    # needs the identical judgment call: {Preflight} verifying that a workspace checkout it is
    # about to REUSE for the specification lane is truly a clone of the repository Platform
    # assigned, not merely a checkout that happens to share a workspace key. Two independent
    # re-implementations of "which owner/repo does this remote resolve to" would be two places
    # that could silently disagree about what counts as a match.
    #
    # The comparison this enables is deliberately narrow: a remote that does not resolve to a
    # GitHub owner/repo (an ssh alias, an internal mirror, a `url.insteadOf` rewrite, a local
    # path) is not evidence of a MATCH or a MISMATCH. A caller that needs certainty before
    # acting — committing to it, or reusing it as another lane's checkout — must treat a nil
    # as "cannot verify" and fail closed rather than guess.
    module RepositorySlug
      def self.for(url)
        text = url.to_s
        return nil if text.strip.empty?

        slug =
          if text.start_with?("git@github.com:")
            text.delete_prefix("git@github.com:")
          else
            text.sub(%r{\Ahttps?://(?:[^@/]+@)?github\.com/}, "")
          end
        slug = slug.delete_suffix(".git")
        slug.match?(%r{\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\z}) ? slug : nil
      end
    end
  end
end
