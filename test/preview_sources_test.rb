# frozen_string_literal: true

require_relative "test_helper"

# MAPIAI-97 — the preview lane's source resolution, proved at its refusal matrix.
#
# The whole value of this class is that it decides the COMPLETE source set before anything is
# created, so every refusal below is a clean failure: no worktree, no `up`, nothing to release.
# The `gh` boundary is a recording double so the exact arguments this lane passes are asserted;
# the argv the shared reader builds from them is fixed and belongs to that reader's own tests.
class PreviewSourcesTest < Minitest::Test
  REPO_A = "SpecRelay/component-a"
  REPO_B = "SpecRelay/component-b"
  URL_A = "https://github.com/SpecRelay/component-a/pull/21"
  URL_B = "https://github.com/SpecRelay/component-b/pull/22"
  HEAD_A = "a" * 40
  HEAD_B = "b" * 40

  # Records every call and answers from a table, so "read exactly once" and "never asked about a
  # url it was not given" are both observable.
  class RecordingGitHub
    attr_reader :calls

    def initialize(answers) = (@answers = answers) && (@calls = [])

    def pull_request(root:, slug:, url:, env:)
      @calls << { root: root, slug: slug, url: url }
      @answers[url]
    end
  end

  def open_pr(branch:, head:, cross: false)
    { "state" => "OPEN", "headRefName" => branch, "headRefOid" => head, "isCrossRepository" => cross }
  end

  def entries(*pairs) = pairs.map { |repository, url| { "repository" => repository, "pull_request_url" => url } }

  def resolve(entries, answers)
    github = RecordingGitHub.new(answers)
    result = SpecrelayRunner::PreviewSources.resolve(entries: entries, root: Dir.pwd, github: github)
    [ result, github ]
  end

  def test_resolves_every_open_pull_request_to_its_exact_current_head
    result, github = resolve(entries([ REPO_A, URL_A ], [ REPO_B, URL_B ]),
                             URL_A => open_pr(branch: "feature-a", head: HEAD_A),
                             URL_B => open_pr(branch: "feature-b", head: HEAD_B))

    assert result.ok?, result.reason
    assert_equal [ { "repository" => REPO_A, "pull_request_url" => URL_A,
                     "branch" => "feature-a", "head_commit" => HEAD_A },
                   { "repository" => REPO_B, "pull_request_url" => URL_B,
                     "branch" => "feature-b", "head_commit" => HEAD_B } ], result.snapshot
    # Once each, and only about the pull requests it was assigned.
    assert_equal [ [ REPO_A, URL_A ], [ REPO_B, URL_B ] ], github.calls.map { |call| [ call[:slug], call[:url] ] }
  end

  def test_a_head_that_moved_between_two_resolutions_is_simply_the_new_head
    moved = "c" * 40
    first, = resolve(entries([ REPO_A, URL_A ]), URL_A => open_pr(branch: "feature-a", head: HEAD_A))
    second, = resolve(entries([ REPO_A, URL_A ]), URL_A => open_pr(branch: "feature-a", head: moved))

    assert_equal HEAD_A, first.snapshot.first["head_commit"]
    assert_equal moved, second.snapshot.first["head_commit"]
  end

  def test_an_empty_assignment_is_refused
    result, github = resolve([], {})

    refute result.ok?
    assert_includes result.reason, "names no pull request"
    assert_empty github.calls
  end

  def test_more_than_the_bound_is_refused_before_any_github_call
    many = Array.new(SpecrelayRunner::PreviewSources::MAX_SOURCES + 1) do |index|
      { "repository" => "SpecRelay/r#{index}", "pull_request_url" => "https://github.com/SpecRelay/r#{index}/pull/1" }
    end

    result, github = resolve(many, {})

    refute result.ok?
    assert_includes result.reason, "more than"
    assert_empty github.calls
  end

  def test_a_foreign_url_never_reaches_github
    result, github = resolve(entries([ REPO_A, URL_B ]), {})

    refute result.ok?
    assert_includes result.reason, "does not belong to"
    assert_empty github.calls
  end

  def test_a_malformed_url_never_reaches_github
    result, github = resolve(entries([ REPO_A, "https://example.com/evil?x=1" ]), {})

    refute result.ok?
    assert_includes result.reason, "no readable GitHub pull request url"
    assert_empty github.calls
  end

  def test_a_duplicate_repository_is_refused
    result, = resolve(entries([ REPO_A, URL_A ], [ REPO_A, URL_A ]),
                      URL_A => open_pr(branch: "feature-a", head: HEAD_A))

    refute result.ok?
    assert_includes result.reason, "twice"
  end

  def test_a_closed_pull_request_refuses_the_whole_set
    result, = resolve(entries([ REPO_A, URL_A ], [ REPO_B, URL_B ]),
                      URL_A => open_pr(branch: "feature-a", head: HEAD_A),
                      URL_B => { "state" => "CLOSED", "headRefName" => "b", "headRefOid" => HEAD_B })

    refute result.ok?
    assert_includes result.reason, "is closed, not open"
    assert_empty result.sources
  end

  def test_a_fork_pull_request_is_refused
    result, = resolve(entries([ REPO_A, URL_A ]),
                      URL_A => open_pr(branch: "feature-a", head: HEAD_A, cross: true))

    refute result.ok?
    assert_includes result.reason, "comes from a fork"
  end

  def test_an_unreadable_pull_request_is_refused
    result, = resolve(entries([ REPO_A, URL_A ]), URL_A => nil)

    refute result.ok?
    assert_includes result.reason, "could not read"
  end

  def test_an_inexact_head_is_refused
    result, = resolve(entries([ REPO_A, URL_A ]), URL_A => open_pr(branch: "feature-a", head: "abc123"))

    refute result.ok?
    assert_includes result.reason, "no exact head commit"
  end

  def test_a_branchless_pull_request_is_refused
    result, = resolve(entries([ REPO_A, URL_A ]), URL_A => open_pr(branch: "", head: HEAD_A))

    refute result.ok?
    assert_includes result.reason, "names no branch"
  end

  # F3 — the COMPLETE assignment is judged locally before GitHub is touched at all.
  #
  # Each of these documents has a valid FIRST entry, so a resolver that validated and observed one
  # entry at a time would already have called `gh` by the time it reached the bad one. The
  # assertion is therefore the complete call list, not merely that the result refused: a document
  # this runner can refuse from its own contents must cost no external read.
  def assert_refused_without_github(document, expected_reason)
    result, github = resolve(document, URL_A => open_pr(branch: "feature-a", head: HEAD_A),
                                       URL_B => open_pr(branch: "feature-b", head: HEAD_B))

    refute result.ok?, "expected a refusal for #{document.inspect}"
    assert_includes result.reason, expected_reason
    assert_equal [], github.calls, "expected no GitHub call, got #{github.calls.inspect}"
  end

  def test_a_valid_entry_followed_by_a_malformed_url_costs_no_github_call
    assert_refused_without_github(entries([ REPO_A, URL_A ], [ REPO_B, "https://example.com/evil?x=1" ]),
                                  "no readable GitHub pull request url")
  end

  def test_a_valid_entry_followed_by_a_foreign_url_costs_no_github_call
    assert_refused_without_github(entries([ REPO_A, URL_A ], [ REPO_B, URL_A ]), "does not belong to")
  end

  def test_a_valid_entry_followed_by_a_case_different_duplicate_costs_no_github_call
    assert_refused_without_github(entries([ REPO_A, URL_A ], [ "specrelay/COMPONENT-A", URL_A ]), "twice")
  end

  def test_a_valid_entry_followed_by_a_duplicate_url_costs_no_github_call
    duplicate = [ { "repository" => REPO_A, "pull_request_url" => URL_A },
                  { "repository" => REPO_B, "pull_request_url" => URL_A } ]

    assert_refused_without_github(duplicate, "does not belong to")
  end

  def test_a_later_entry_that_is_not_a_hash_costs_no_github_call
    assert_refused_without_github([ { "repository" => REPO_A, "pull_request_url" => URL_A }, "component-b" ],
                                  "is not a pull-request entry")
  end

  def test_a_later_entry_missing_a_required_field_costs_no_github_call
    assert_refused_without_github([ { "repository" => REPO_A, "pull_request_url" => URL_A },
                                    { "repository" => REPO_B } ], "is missing")
  end

  def test_a_later_entry_with_an_extra_field_costs_no_github_call
    assert_refused_without_github([ { "repository" => REPO_A, "pull_request_url" => URL_A },
                                    { "repository" => REPO_B, "pull_request_url" => URL_B,
                                      "command" => "rm -rf /" } ], "unexpected field")
  end

  def test_a_later_entry_with_a_null_field_costs_no_github_call
    assert_refused_without_github([ { "repository" => REPO_A, "pull_request_url" => URL_A },
                                    { "repository" => REPO_B, "pull_request_url" => nil } ], "is missing")
  end

  def test_an_over_bound_repository_identity_costs_no_github_call
    long = "SpecRelay/#{'r' * SpecrelayRunner::PreviewSources::MAX_IDENTITY_BYTES}"
    assert_refused_without_github([ { "repository" => REPO_A, "pull_request_url" => URL_A },
                                    { "repository" => long,
                                      "pull_request_url" => "https://github.com/#{long}/pull/3" } ],
                                  "is longer than")
  end

  def test_an_over_bound_url_costs_no_github_call
    long = "https://github.com/SpecRelay/component-b/pull/#{'9' * SpecrelayRunner::PreviewSources::MAX_URL_BYTES}"
    assert_refused_without_github([ { "repository" => REPO_A, "pull_request_url" => URL_A },
                                    { "repository" => REPO_B, "pull_request_url" => long } ],
                                  "is longer than")
  end

  def test_a_repository_identity_of_the_wrong_shape_costs_no_github_call
    assert_refused_without_github([ { "repository" => REPO_A, "pull_request_url" => URL_A },
                                    { "repository" => "component-b", "pull_request_url" => URL_B } ],
                                  "is not an owner/repository identity")
  end

  def test_materialization_refuses_without_a_canonical_branch
    resolver = SpecrelayRunner::PreviewSources.new(entries([ REPO_A, URL_A ]), Dir.pwd)

    result = resolver.materialize(task_root: Dir.pwd, canonical_branch: "", sources: [])

    refute result.ok?
    assert_includes result.reason, "no canonical branch"
  end
end
