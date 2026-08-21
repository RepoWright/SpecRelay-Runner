# frozen_string_literal: true

require "uri"

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
  # accepted, and only on github.com. Anything else is `nil` — not a guess.
  #
  # It is also the boundary a credential stops at. Both answers are DERIVED from the slug, so a
  # remote's credential userinfo is read here and never leaves: see #clone_url.
  module GithubRemote
    HOST = "github.com"
    SLUG = %r{\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\z}
    SSH_PREFIX = "git@#{HOST}:"
    HTTPS_PREFIX = %r{\Ahttps?://(?:[^@/]+@)?#{Regexp.escape(HOST)}/}
    GIT_SUFFIX = ".git"
    CLONE_URL = "https://%s/%s#{GIT_SUFFIX}"
    PULL_REQUEST_PATH = %r{\A/(?<slug>[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/pull/\d+\z}

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

    # The canonical, CREDENTIAL-FREE clone url for a supported remote, or nil.
    #
    # A repository's configured `origin` may carry credential userinfo — a token-authenticated
    # https remote is exactly that shape. Reading it locally is necessary; transmitting it is not,
    # and a result, a report, a log or a Platform request is forever. So identity inspection ends
    # at this call: everything downstream carries this derived url, which holds nothing but the
    # host and the slug already validated above.
    def clone_url(url)
      resolved = slug(url)
      resolved && format(CLONE_URL, HOST, resolved)
    end

    # MAPIAI-88 — the repository a github.com PULL-REQUEST url belongs to, or nil.
    #
    # Here rather than beside its caller for the reason this module exists at all: "which repository
    # is this?" must have one answer. The retirement boundary compares this against the repository
    # Platform planned, so a url that resolves to a different repository — or to nothing — never
    # reaches `gh`.
    #
    # Deliberately stricter than {#slug}: HTTPS only, no credential userinfo, and the path must be
    # EXACTLY `/owner/repo/pull/<number>`. A near miss is nil, not a guess.
    def pull_request_slug(url)
      uri = URI.parse(url.to_s.strip)
      return nil unless uri.is_a?(URI::HTTPS) && uri.host&.downcase == HOST && uri.userinfo.nil?

      match = PULL_REQUEST_PATH.match(uri.path.to_s)
      match && SLUG.match?(match[:slug]) ? match[:slug] : nil
    rescue URI::InvalidURIError
      nil
    end
  end
end
