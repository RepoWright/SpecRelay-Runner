# frozen_string_literal: true

require_relative "test_helper"

# CR-001 criterion 10 / review-001 finding 8(b). The runner echoes git and `gh` output
# into publication_error, its own console, and uploaded transcripts, so redaction has to
# cover the shapes that can actually appear there — including a credential-bearing
# remote URL, which no token pattern matches.
class RedactionTest < Minitest::Test
  R = SpecrelayRunner::Redaction

  def test_fine_grained_forge_tokens_are_redacted
    assert_equal "token [REDACTED]", R.redact("token github_pat_11ABCDEFG0abcdefghijklmnop")
    assert_equal "token [REDACTED]", R.redact("token glpat-ABCDEFGHIJ1234567890")
  end

  def test_classic_token_shapes_still_redacted
    assert_equal "[REDACTED]", R.redact("ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    assert_equal "[REDACTED]", R.redact("sk-live-DO-NOT-LEAK-0123456789")
  end

  # The whole point of finding 8(b): `git push` can fail quoting the remote it used.
  def test_url_userinfo_is_stripped_from_a_raw_git_error
    raw = "fatal: unable to access 'https://octocat:s3cr3t-p4ssw0rd@github.com/SpecRelay/tiny-demo-runs.git/'"

    redacted = R.redact(raw)

    refute_match(/s3cr3t-p4ssw0rd/, redacted)
    refute_match(/octocat:/, redacted)
    assert_match(%r{https://\[REDACTED\]@github\.com/SpecRelay/tiny-demo-runs}, redacted,
                 "the host and path are evidence and must survive")
  end

  def test_userinfo_stripping_covers_a_bare_token_in_the_url
    redacted = R.redact("remote: https://github_pat_11ABCDEFG0abcdefghij@github.com/o/r.git")

    refute_match(/github_pat_11/, redacted)
    assert_match(/@github\.com/, redacted)
  end

  # An scp-like git remote carries no secret; rewriting it would destroy evidence for
  # no benefit.
  def test_scp_style_remote_is_not_touched
    assert_equal "git@github.com:SpecRelay/tiny-demo-runs.git",
                 R.redact("git@github.com:SpecRelay/tiny-demo-runs.git")
  end

  # Commit shas and branch names are structured evidence, not free text.
  def test_commits_and_branches_survive_redaction
    text = "pushed 8819084d8c18f8a963c2b43182885395d44fc177 to specrelay/MAPIAI-25"
    assert_equal text, R.redact(text)
  end

  def test_nil_is_passed_through
    assert_nil R.redact(nil)
  end

  # --- review-003 finding 3: residual gaps it measured ---------------------

  def test_npm_token_is_redacted
    assert_equal "[REDACTED]", R.redact("npm_abcdefghijklmnopqrstuvwxyz0123")
  end

  # The webhook URL IS the credential: its path segment is the secret.
  def test_slack_webhook_url_is_redacted
    redacted = R.redact("posting to https://hooks.slack.com/services/T000/B000/XXXXsecretXXXX now")

    refute_match(/XXXXsecretXXXX/, redacted)
    refute_match(%r{services/T000}, redacted)
    assert_match(/posting to \[REDACTED\] now/, redacted)
  end

  # A \b before "token" cannot match inside CI_JOB_TOKEN, because the underscore is a
  # word character — so the prefixed forms need explicit coverage.
  def test_prefixed_token_variables_are_redacted
    [ "CI_JOB_TOKEN=abc123opaquevalue",
      "GITHUB_TOKEN=ghs_notarealtokenvalue",
      "MY_API_KEY: opaque-value-here" ].each do |line|
      assert_equal "[REDACTED]", R.redact(line), line
    end
  end

  def test_private_key_body_is_redacted_not_just_its_header
    pem = <<~KEY
      -----BEGIN OPENSSH PRIVATE KEY-----
      b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtz
      c2gtZWQyNTUxOQAAACDfakebodyfakebodyfakebodyfakebodyfakebodyAAAJ
      -----END OPENSSH PRIVATE KEY-----
    KEY

    redacted = R.redact(pem)

    refute_match(/b3BlbnNzaC1rZXk/, redacted, "the key BODY must not survive")
    refute_match(/fakebody/, redacted)
    assert_match(/\[REDACTED\]/, redacted)
  end

  # The prefixed-label pattern must not swallow ordinary prose or evidence.
  def test_labelled_pattern_does_not_eat_evidence
    assert_equal "pushed to specrelay/MAPIAI-25 at 8819084d8c18",
                 R.redact("pushed to specrelay/MAPIAI-25 at 8819084d8c18")
    assert_equal "the token was rejected", R.redact("the token was rejected")
  end
end
