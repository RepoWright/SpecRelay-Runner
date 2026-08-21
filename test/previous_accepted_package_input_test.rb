# frozen_string_literal: true

require_relative "test_helper"

# MAPIAI-87 CR-001 F1 — `previous_accepted_package` is INPUT, and this proves both lanes read it
# as one.
#
# The contract makes the field required and nullable precisely so absence cannot be mistaken for
# the explicit null a first run carries. Reading an absent, scalar, partial or open-shaped value
# as "no previous implementation" would start a continued run from the default branch and
# silently discard accepted work, and would hand the specification writer a block that looks
# complete because the missing parts were coerced into empty strings.
#
# So every case below is checked against BOTH lanes, and the refusal reasons are compared: one
# validator, or the two lanes drift.
class PreviousAcceptedPackageInputTest < Minitest::Test
  ISSUE = "SR-700"
  HEAD = "0123456789abcdef0123456789abcdef01234567"
  # There is no Ruby value for "the key is not there", and nil is the one input that must be
  # ACCEPTED, so absence needs its own marker.
  ABSENT = :absent
  # Deliberately NOT token-shaped: {Redaction} masks a `ghp_`-prefixed string, so a test using one
  # would prove the redactor works rather than that the validator never echoed the key.
  SECRET_KEY = "x-SECRETVALUE-a3f9c1"

  def valid(overrides = {})
    { "package_id" => "art_previous123", "checksum" => "c" * 64, "source_run_id" => "run_previous",
      "approved_specification" => { "reference" => "https://github.com/SpecRelay/SpecRelay-Specs/pull/6",
                                    "digest" => "d" * 64 },
      "implementation_pull_requests" => [ accepted_row ] }.merge(overrides)
  end

  def accepted_row(overrides = {})
    { "repository" => "SpecRelay/Specrelay-Platform",
      "clone_url" => "https://github.com/SpecRelay/Specrelay-Platform",
      "branch" => "#{ISSUE}-add-an-export-button", "head_commit" => HEAD,
      "pull_request_url" => "https://github.com/SpecRelay/Specrelay-Platform/pull/45" }.merge(overrides)
  end

  def without(key) = valid.tap { |block| block.delete(key) }
  def specification(overrides) = valid("approved_specification" => overrides)
  def rows(*entries) = valid("implementation_pull_requests" => entries)

  # --- the two lanes -------------------------------------------------------

  def implementation_claim(input)
    payload = { "run" => { "canonical_branch" => ISSUE } }
    payload["previous_accepted_package"] = input unless input == ABSENT
    SpecrelayRunner::PreviousAcceptedPackage.read(payload)
  end

  def specification_payload(input)
    payload = spec_creation_payload_for(issue_key: ISSUE)
    payload.delete("previous_accepted_package") if input == ABSENT
    payload["previous_accepted_package"] = input unless input == ABSENT
    payload
  end

  def specification_assignment(input)
    SpecrelayRunner::Specification::Assignment.parse(specification_payload(input))
  end

  # --- accepted input ------------------------------------------------------

  def test_both_lanes_accept_the_explicit_null_of_a_first_run
    claim = implementation_claim(nil)

    assert claim.ok?, claim.reason
    assert_nil claim.package
    assert_nil specification_assignment(nil).previous_accepted_package
  end

  def test_both_lanes_accept_the_closed_populated_block
    claim = implementation_claim(valid)

    assert claim.ok?, claim.reason
    assert_instance_of SpecrelayRunner::PreviousAcceptedPackage, claim.package
    assert_equal valid, specification_assignment(valid).previous_accepted_package
  end

  # S09 — an accepted package that changed nothing is valid input, not an empty document.
  def test_both_lanes_accept_a_valid_empty_pull_request_list
    empty = valid("implementation_pull_requests" => [])

    assert implementation_claim(empty).ok?
    assert_equal [], specification_assignment(empty).previous_accepted_package["implementation_pull_requests"]
  end

  # --- refused input -------------------------------------------------------

  # Every input class F1 names, stated once. Each is a whole assignment field, so each is checked
  # against both lanes by the one test below.
  def malformed_inputs
    {
      "an absent field" => ABSENT,
      "a string" => "art_previous123",
      "a number" => 7,
      "a list" => [ valid ],
      "a boolean" => true,
      "a block missing package_id" => without("package_id"),
      "a block missing its accepted pull requests" => without("implementation_pull_requests"),
      "a block carrying an unknown field" => valid("uncommitted_files" => [ "app.rb" ]),
      "a checksum that is not a digest" => valid("checksum" => "not-a-digest"),
      "an oversized package id" => valid("package_id" => "ghp_SECRETVALUE#{'x' * 500}"),
      "an approved specification that is not an object" => valid("approved_specification" => "pull/6"),
      "an approved specification missing its digest" =>
        specification("reference" => "https://github.com/SpecRelay/SpecRelay-Specs/pull/6"),
      "an approved specification carrying an unknown field" =>
        specification("reference" => "https://github.com/SpecRelay/SpecRelay-Specs/pull/6",
                      "digest" => "d" * 64, "body" => "the whole specification"),
      "an approved specification reference that is not an https url" =>
        specification("reference" => "git@github.com:SpecRelay/SpecRelay-Specs.git", "digest" => "d" * 64),
      "a credential-bearing approved specification reference" =>
        specification("reference" => "https://ghp_SECRETVALUE@github.com/SpecRelay/SpecRelay-Specs/pull/6",
                      "digest" => "d" * 64),
      "accepted pull requests that are not a list" => valid("implementation_pull_requests" => {}),
      "a pull request that is not an object" =>
        rows("https://github.com/SpecRelay/Specrelay-Platform/pull/45"),
      "a pull request missing its head commit" => rows(accepted_row.tap { |r| r.delete("head_commit") }),
      "a pull request carrying an unknown field" => rows(accepted_row("local_path" => "/checkouts/a")),
      "a head commit that is not a commit sha" => rows(accepted_row("head_commit" => "HEAD")),
      "a credential-bearing clone url" =>
        rows(accepted_row("clone_url" => "https://ghp_SECRETVALUE@github.com/SpecRelay/Specrelay-Platform")),
      "an empty repository identity" => rows(accepted_row("repository" => "   ")),
      "an oversized branch name" => rows(accepted_row("branch" => "b" * 501)),
      "more accepted pull requests than the bound allows" =>
        valid("implementation_pull_requests" => Array.new(101) { accepted_row }),
      # CR-002 F1 — the key itself is attacker-controlled text.
      "an unknown field whose NAME is a secret" => valid(SECRET_KEY => "1"),
      "an unknown approved-specification field whose NAME is a secret" =>
        specification("reference" => "https://github.com/SpecRelay/SpecRelay-Specs/pull/6",
                      "digest" => "d" * 64, SECRET_KEY => "1"),
      "an unknown pull-request field whose NAME is a secret" => rows(accepted_row(SECRET_KEY => "1")),
      # CR-002 F2 — "https-shaped" is not a URL.
      "an https url with no host" => specification("reference" => "https:///no-host", "digest" => "d" * 64),
      "a non-https url" =>
        specification("reference" => "http://github.com/SpecRelay/SpecRelay-Specs/pull/6", "digest" => "d" * 64),
      "a url with no scheme" => rows(accepted_row("clone_url" => "github.com/SpecRelay/Specrelay-Platform")),
      "a url containing whitespace" =>
        rows(accepted_row("clone_url" => "https://github.com/SpecRelay/Specrelay Platform")),
      "an oversized url" =>
        rows(accepted_row("pull_request_url" => "https://github.com/SpecRelay/Specrelay-Platform/pull/#{'1' * 500}"))
    }
  end

  def test_both_lanes_refuse_every_malformed_input_for_the_same_stated_reason
    malformed_inputs.each do |name, input|
      claim = implementation_claim(input)

      refute claim.ok?, "the implementation lane accepted #{name}"
      assert_nil claim.package, "#{name} produced a materializer"
      refute_empty claim.reason.to_s, "#{name} refused without a reason"

      error = assert_raises(SpecrelayRunner::Specification::Assignment::Malformed,
                            "the specification lane accepted #{name}") { specification_assignment(input) }

      assert_equal claim.reason, error.message,
                   "#{name} is refused by two different validators"
      # The reason reaches an operator log and Platform, so it names fields, never values.
      refute_includes claim.reason, "SECRETVALUE", "#{name} echoed the value it refused"
    end
  end

  # CR-002 F1 — an unknown key is attacker-controlled TEXT, and this refusal travels into operator
  # logs and, on the specification lane, into the refusal payload Platform stores. So it names the
  # containing field path and the fact that unrecognised fields are there, and nothing else.
  def test_an_unknown_field_refusal_names_the_path_and_never_the_key
    {
      "previous_accepted_package" => valid(SECRET_KEY => "1"),
      "previous_accepted_package.approved_specification" =>
        specification("reference" => "https://github.com/SpecRelay/SpecRelay-Specs/pull/6",
                      "digest" => "d" * 64, SECRET_KEY => "1"),
      "previous_accepted_package.implementation_pull_requests[0]" => rows(accepted_row(SECRET_KEY => "1"))
    }.each do |path, input|
      reason = implementation_claim(input).reason

      assert_includes reason, path
      refute_includes reason, "SECRETVALUE"
    end
  end

  # CR-002 F2 — one predicate for every `:url` field: parsed, HTTPS, a real host, no userinfo, and
  # bounded. "https-shaped" is not enough; `https:///no-host` names nothing to reach.
  def test_the_url_predicate_accepts_only_a_parsed_credential_free_https_url
    {
      "https:///no-host" => false,
      "github.com/SpecRelay/SpecRelay-Specs" => false,
      "http://github.com/SpecRelay/SpecRelay-Specs" => false,
      "https://github.com/SpecRelay/SpecRelay Specs" => false,
      "https://ghp_token@github.com/SpecRelay/SpecRelay-Specs" => false,
      "https://github.com/SpecRelay/#{'x' * 500}" => false,
      "https://github.com/SpecRelay/SpecRelay-Specs/pull/6" => true
    }.each do |url, accepted|
      claim = implementation_claim(specification("reference" => url, "digest" => "d" * 64))

      assert_equal accepted, claim.ok?,
                   "#{url} was #{claim.ok? ? 'accepted' : "refused: #{claim.reason}"}"
    end
  end

  # The bound is a refusal, not a trim. A silently shortened list is a document the writer would
  # read as the complete accepted implementation.
  def test_an_oversized_list_is_refused_rather_than_truncated
    claim = implementation_claim(valid("implementation_pull_requests" => Array.new(101) { accepted_row }))

    assert_match(/at most 100/, claim.reason)
  end
end
