# frozen_string_literal: true

module SpecrelayRunner
  # MAPIAI-84 — THE normalizer for a repository's GitHub identity, and the only place in this
  # runner that turns a git remote url into `owner/repo`.
  #
  # It exists because identity is now READ FROM THE REPOSITORY rather than declared by Platform.
  # Several decisions depend on getting the same answer from the same url: which repository `gh`
  # is asked about, which repository a pull-request URL must belong to, and whether two selected
  # working trees are secretly the same repository. A second copy of these rules would let those
  # answers disagree, which is exactly how one repository receives two current pull requests.
  #
  # It is deliberately narrow. Only the https and scp-like ssh forms SpecRelay configures are
  # accepted, only on github.com, and credential userinfo in an https remote is DROPPED rather
  # than carried into a command line or a log. Anything else is `nil` — not a guess.
  module GithubRemote
    HOST = "github.com"
    SLUG = %r{\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\z}
    SSH_PREFIX = "git@#{HOST}:"
    HTTPS_PREFIX = %r{\Ahttps?://(?:[^@/]+@)?#{Regexp.escape(HOST)}/}
    GIT_SUFFIX = ".git"

    module_function

    # "owner/repo", case preserved because `gh --repo` and a pull-request URL both use it, or nil.
    def slug(url)
      text = url.to_s.strip
      return nil if text.empty?

      candidate =
        if text.start_with?(SSH_PREFIX)
          text.delete_prefix(SSH_PREFIX)
        elsif text.match?(HTTPS_PREFIX)
          text.sub(HTTPS_PREFIX, "")
        end
      candidate = candidate.to_s.delete_suffix("/").delete_suffix(GIT_SUFFIX)
      SLUG.match?(candidate) ? candidate : nil
    end

    # The comparison key for "is this the same GitHub repository". GitHub owner and repository
    # names are case-insensitive, so two remotes differing only in case are ONE repository and
    # must be rejected as duplicates rather than published twice.
    def identity(url)
      resolved = slug(url)
      resolved&.downcase
    end
  end
end
