# frozen_string_literal: true

module SpecrelayRunner
  # Client-side secret redaction for anything the standalone runner prints to its
  # own console or writes into an uploaded transcript (MVP-0010). This is defense
  # in depth: Platform re-redacts every public event summary and report field on
  # ingest (PublicEventText / ReportDirectory), but the runner must never emit a
  # raw provider token in its OWN local logs on the developer's machine either.
  #
  # The patterns mirror the high-confidence secret shapes Platform recognizes
  # (provider API keys, AWS keys, Atlassian tokens, JWTs, labelled secrets,
  # bearer tokens). The generic high-entropy catch-all is intentionally omitted
  # from transcript redaction so legitimate diffs/hashes survive as evidence.
  module Redaction
    REDACTION = "[REDACTED]"

    SECRET_PATTERNS = [
      /\b(?:sk|pk|rk|gh[pousr]|xox[baprs])[-_][A-Za-z0-9][A-Za-z0-9\-_.]{5,}\b/i,
      # Fine-grained forge tokens. These carry their own underscores/hyphens, so the
      # short-prefix pattern above does not reach them (review-001 finding 8b).
      /\bgithub_pat_[A-Za-z0-9_]{10,}\b/,
      /\bglpat-[A-Za-z0-9\-_]{10,}\b/,
      /\bnpm_[A-Za-z0-9]{20,}\b/,
      /\bAKIA[0-9A-Z]{16}\b/,
      /\bATATT[A-Za-z0-9_\-.=]{8,}/,
      /\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\b/,
      # A webhook URL is itself the credential — the path segment is the secret.
      %r{https://hooks\.slack\.com/services/\S+},
      # A private key body, not just its header line.
      /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/,
      /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
      # Labelled secrets. The trailing-word form deliberately allows a prefix so
      # CI_JOB_TOKEN= and GITHUB_TOKEN= match: a \b before "token" does not, because the
      # underscore is a word character (review-003 finding 3).
      /\b[A-Za-z0-9_]*(?:secret|token|password|passwd|api[_-]?key|access[_-]?key)\s*[:=]\s*\S+/i,
      /\bbearer\s+[A-Za-z0-9._\-]{8,}\b/i,
      # The other Authorization scheme, where the base64 blob IS the credential. `git` and
      # `gh` both echo request headers under GIT_CURL_VERBOSE / GH_DEBUG=api, and no pattern
      # above matches a base64 blob (MVP-0027 review-001 P2-1). Anchored on the header name
      # rather than on a bare `basic ` so ordinary prose is not redacted.
      /\bauthorization\s*:\s*basic\s+\S+/i
    ].freeze

    # Credential userinfo in a URL: `https://user:token@host/…`. A raw git error can
    # echo the remote URL it failed on, and neither secret pattern above matches an
    # arbitrary password (review-001 finding 8b). The host and path are evidence and
    # are preserved; only the userinfo is replaced.
    URL_USERINFO = %r{(?<scheme>[A-Za-z][A-Za-z0-9+.\-]*://)(?<userinfo>[^/@\s]+)@}
    private_constant :URL_USERINFO

    module_function

    def redact(text)
      return text if text.nil?

      redacted = SECRET_PATTERNS.reduce(text.to_s) { |acc, pattern| acc.gsub(pattern, REDACTION) }
      strip_url_userinfo(redacted)
    end

    # Applied after the secret patterns so an already-redacted token stays redacted.
    # A bare `user@host` (an scp-like git remote, e.g. `git@github.com:owner/repo`)
    # carries no secret and is left alone — only a URL with a scheme is rewritten.
    def strip_url_userinfo(text)
      text.gsub(URL_USERINFO) { "#{Regexp.last_match(:scheme)}#{REDACTION}@" }
    end
  end
end
