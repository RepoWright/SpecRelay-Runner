# frozen_string_literal: true

require "test_helper"

# MVP-0033 — the REVIEWER role on the runner side.
#
# The properties under test are the ones that make a review independent and safe on this
# machine: the checkout really is the pinned target (S23), the provider is a FRESH process
# carrying no executor context (S24), and whatever it prints is treated as untrusted input
# (S25-S27). Every example drives the real CommandRunner against a real script on disk and a
# real HTTP FakePlatform, so the process boundary is exercised rather than stubbed.
class ReviewFlowTest < Minitest::Test
  BASE = "1111111111111111111111111111111111111111"
  HEAD = "2222222222222222222222222222222222222222"
  BRANCH = "main"

  def setup
    @root = Dir.mktmpdir("review-workspace")
    # Bare origins live OUTSIDE the workspace root, so a pinned remote can never also be one of
    # the locations the resolver is allowed to consider.
    @remotes = Dir.mktmpdir("review-remotes")
    @repo = File.join(@root, "specrelay-platform")
    @io = StringIO.new
    # A review is never obtained through the claim payload in these tests — it is handed to
    # Execution directly — so the fake's claim script is irrelevant and deliberately minimal.
    @platform = FakePlatform.new(claim_payload: { "claimed" => false })
    @platform.start
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@root, true)
    FileUtils.remove_entry(@remotes, true)
  end

  # --- the pinned checkout -------------------------------------------------

  def test_refuses_a_checkout_whose_remote_differs
    build_repo(remote: "https://github.com/someone-else/other.git")

    result = run_review

    refute result.success?
    assert_includes result.message, "different remote"
    assert_empty @platform.review_results.reject { |request| refusal?(request) }
  end

  def test_refuses_when_the_pinned_head_is_absent
    build_repo(head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

    result = run_review

    refute result.success?
    assert_includes result.message, "does not contain the reviewed head"
  end

  # A git WORKTREE has a `.git` FILE, not a directory. SpecRelay's own task environments check
  # out every component repository that way, so a reviewer that only recognised plain clones
  # would refuse the primary place it runs. The first real-provider execution of this MVP
  # failed exactly here.
  def test_accepts_a_git_worktree_whose_dot_git_is_a_file
    build_repo
    worktree_root = File.join(@root, "worktree")
    FileUtils.mkdir_p(worktree_root)
    linked = File.join(worktree_root, "specrelay-platform")
    system("git -C #{@repo} worktree add --quiet --detach #{linked} #{pinned_head}",
           out: File::NULL, err: File::NULL)
    refute File.directory?(File.join(linked, ".git")), "expected a worktree .git FILE"

    verified = SpecrelayRunner::Review::Checkout.verify(
      assignment: SpecrelayRunner::Review::Assignment.new(review_payload), workspace_root: worktree_root
    )

    assert verified.ok?, verified.reason
  end

  def test_refuses_when_there_is_no_local_checkout_at_all
    result = run_review

    refute result.success?
    assert_includes result.message, "no local checkout"
  end

  # --- resolving the reviewed repository (MAPIAI-91) ------------------------
  #
  # Exactly two locations are allowed: the configured workspace root itself, and its direct
  # `repository_key` child. A guided connection stores the validated CHECKOUT as its root, so
  # unconditionally appending the key produced a duplicated, nonexistent path and refused every
  # review on a single-repository machine (MAPIAI-82).

  def test_verifies_the_workspace_root_itself_when_it_is_the_reviewed_repository
    @actual_head = build_repo_at(@root, remote: "https://github.com/SpecRelay/tiny-demo-workspace.git")

    verified = verify(@root)

    assert verified.ok?, verified.reason
    assert_equal @root, verified.roots["specrelay-platform"]
  end

  def test_verifies_the_direct_child_and_reports_it_as_the_selected_root
    build_repo

    verified = verify(@root)

    assert verified.ok?, verified.reason
    assert_equal @repo, verified.roots["specrelay-platform"]
  end

  # A mixed assignment: each entry resolves independently, against its own remote, in assignment
  # order — and neither entry decides anything for the other.
  def test_a_root_and_a_child_repository_each_resolve_to_their_own_matching_remote
    root_head = build_repo_at(@root, remote: "https://github.com/SpecRelay/tiny-demo-workspace.git")
    build_repo(remote: "https://github.com/SpecRelay/specrelay-platform.git")
    payload = review_payload
    payload["repositories"] = [
      repository_entry("tiny-demo-workspace", "https://github.com/SpecRelay/tiny-demo-workspace.git", root_head),
      repository_entry("specrelay-platform", "https://github.com/SpecRelay/specrelay-platform.git", pinned_head)
    ]

    verified = SpecrelayRunner::Review::Checkout.verify(
      assignment: SpecrelayRunner::Review::Assignment.new(payload), workspace_root: @root
    )

    assert verified.ok?, verified.reason
    assert_equal [ "tiny-demo-workspace", "specrelay-platform" ], verified.roots.keys
    assert_equal @root, verified.roots["tiny-demo-workspace"]
    assert_equal @repo, verified.roots["specrelay-platform"]
  end

  # Both allowed locations are the reviewed repository. There is no defined precedence between
  # them, so the only safe answer is to refuse rather than to pick one.
  def test_refuses_when_both_allowed_locations_are_the_reviewed_repository
    @actual_head = build_repo_at(@root, remote: "https://github.com/SpecRelay/tiny-demo-workspace.git")
    build_repo_at(@repo, remote: "https://github.com/SpecRelay/tiny-demo-workspace.git")

    result = verify(@root)

    refute result.ok?
    refute result.stale?
    assert_includes result.reason, "ambiguous"
  end

  # `git rev-parse` walks UPWARD, so a plain subdirectory of a clone answers for that clone. A
  # candidate must therefore be the repository's own top level: a matching repository in a parent
  # — or in a grandchild, or a sibling — is not one of the two allowed locations.
  def test_a_matching_repository_outside_the_two_allowed_locations_is_refused
    @actual_head = build_repo_at(@root, remote: "https://github.com/SpecRelay/tiny-demo-workspace.git")
    nested = File.join(@root, "nested")
    FileUtils.mkdir_p(File.join(nested, "specrelay-platform", "inner"))

    result = SpecrelayRunner::Review::Checkout.verify(
      assignment: SpecrelayRunner::Review::Assignment.new(review_payload), workspace_root: nested
    )

    refute result.ok?
    assert_includes result.reason, "no local checkout"
  end

  # Not merely "the right answer": the two allowed locations are the ONLY paths git is asked
  # about, so no parent, sibling, grandchild or registry can influence the result.
  def test_verification_inspects_only_the_workspace_root_and_its_direct_child
    build_repo
    recorder = RecordingGit.new

    SpecrelayRunner::Review::Checkout.verify(
      assignment: SpecrelayRunner::Review::Assignment.new(review_payload), workspace_root: @root,
      git: recorder
    )

    assert_equal [ @root, @repo ].sort, recorder.roots.uniq.sort
  end

  # Records every path it is asked about and matches nothing, so the recorded set IS the set of
  # locations the resolver considered.
  class RecordingGit
    attr_reader :roots

    def initialize = @roots = []

    def repository?(root) = record(root) && false
    def top_level(root) = record(root) && nil
    def remote_url(root) = record(root) && ""
    def remote_head(root, _branch) = record(root) && nil
    def commit?(root, _sha) = record(root) && false
    def fetch(root) = record(root)

    def record(root)
      @roots << root
      true
    end
  end

  # A refusal is REPORTED, not merely printed: Platform must record the failed attempt so the
  # run page can explain why no verdict exists. Since MAPIAI-78 it travels as an explicit
  # failure body rather than as an outcome-less review, so the reason that explains it survives.
  def test_a_refusal_is_reported_to_platform_without_a_verdict
    build_repo(remote: "https://github.com/someone-else/other.git")

    run_review

    assert_empty @platform.review_results
    assert_equal "provider_execution_failure", @platform.last_review_failure["kind"]
    assert_includes @platform.last_review_failure["reason"], "different remote"
  end

  # --- owner-qualified repository keys (MAPIAI-98) --------------------------
  #
  # Platform pins a repository by its normalized GitHub identity, so `repository_key` is
  # `owner/repository`. The direct-child candidate is named by the REPOSITORY SEGMENT of that key:
  # `RepoWright/tiny-demo-crm` is reviewed at `<root>/tiny-demo-crm`. Appending the whole key asked
  # for the nested `<root>/RepoWright/tiny-demo-crm`, which never exists — so the live MAPIAI-95
  # review saw only the workspace root and reported its different remote as the mismatch.

  # The reproduction, in the live shape: the workspace root is a real repository with its OWN
  # remote, and the reviewed repository is the direct child. Remote-head and pinned-commit
  # verification then run for real against a local bare origin.
  def test_an_owner_qualified_key_resolves_its_repository_name_child_and_verifies_the_pin
    pin_repository("tiny-demo-workspace", at: @root)
    crm = pin_repository("tiny-demo-crm", at: File.join(@root, "tiny-demo-crm"))

    verified = verify_repositories([ crm ])

    assert verified.ok?, verified.reason
    assert_equal File.join(@root, "tiny-demo-crm"), verified.roots["RepoWright/tiny-demo-crm"]
  end

  # The whole MAPIAI-95 layout in one assignment. Each key keeps its own selected root, and
  # assignment order survives.
  def test_a_three_repository_assignment_resolves_every_owner_qualified_key_independently
    verified = verify_repositories(three_repository_assignment)

    assert verified.ok?, verified.reason
    assert_equal [ "RepoWright/tiny-demo-workspace", "RepoWright/tiny-demo-dashboard",
                   "RepoWright/tiny-demo-crm" ], verified.roots.keys
    assert_equal @root, verified.roots["RepoWright/tiny-demo-workspace"]
    assert_equal File.join(@root, "tiny-demo-dashboard"),
                 verified.roots["RepoWright/tiny-demo-dashboard"]
    assert_equal File.join(@root, "tiny-demo-crm"), verified.roots["RepoWright/tiny-demo-crm"]
  end

  # The directory name is only a location hint; IDENTITY decides. An https clone URL and an
  # scp-like ssh origin for the same repository still compare equal.
  def test_https_and_scp_like_ssh_forms_of_one_owner_qualified_repository_still_match
    head = build_repo_at(File.join(@root, "tiny-demo-crm"),
                         remote: "git@github.com:RepoWright/tiny-demo-crm.git")

    verified = verify_repositories(
      [ repository_entry("RepoWright/tiny-demo-crm",
                         "https://github.com/RepoWright/tiny-demo-crm.git", head) ]
    )

    assert verified.ok?, verified.reason
    assert_equal File.join(@root, "tiny-demo-crm"), verified.roots["RepoWright/tiny-demo-crm"]
  end

  # The right NAME is not enough. This child is a real repository in the one allowed child
  # location with a different origin, so the whole assignment refuses and no reviewer starts.
  def test_a_repository_name_child_with_a_different_remote_refuses_before_the_reviewer_starts
    entries = three_repository_assignment
    git_in File.join(@root, "tiny-demo-crm"),
           "remote set-url origin #{File.join(@remotes, 'RepoWright', 'tiny-demo-dashboard.git')}"
    capture = File.join(@root, "launched.txt")

    result = run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"ok"}), capture: capture),
                        payload: review_payload.merge("repositories" => entries))

    refute File.exist?(capture), "the reviewer must not be launched while a pin does not verify"
    refute result.success?
    assert_includes result.message, "'RepoWright/tiny-demo-crm' points at a different remote"
    assert_empty @platform.review_results
  end

  # Nothing is checked out. The refusal names the directory that was actually looked for —
  # `tiny-demo-crm`, not the nested `RepoWright/tiny-demo-crm` the old rule asked for.
  def test_a_missing_owner_qualified_checkout_names_the_repository_directory_it_looked_for
    result = run_review(payload: review_payload.merge(
      "repositories" => [ repository_entry("RepoWright/tiny-demo-crm",
                                           "https://github.com/RepoWright/tiny-demo-crm.git", HEAD) ]
    ))

    refute result.success?
    assert_includes result.message, "no local checkout for 'RepoWright/tiny-demo-crm'"
    assert_includes result.message, "its 'tiny-demo-crm' directory"
    refute_includes result.message, "its 'RepoWright/tiny-demo-crm' directory"
    assert_empty @platform.review_results
  end

  # Both allowed locations are the reviewed repository, and there is no precedence to apply.
  def test_refuses_when_the_root_and_the_repository_name_child_are_both_the_reviewed_repository
    remote = "https://github.com/RepoWright/tiny-demo-crm.git"
    head = build_repo_at(@root, remote: remote)
    build_repo_at(File.join(@root, "tiny-demo-crm"), remote: remote)

    result = verify_repositories([ repository_entry("RepoWright/tiny-demo-crm", remote, head) ])

    refute result.ok?
    refute result.stale?
    assert_includes result.reason, "ambiguous"
    assert_includes result.reason, "its 'tiny-demo-crm' directory"
  end

  # Not merely the right answer: for EVERY repository the only paths git is asked about are the
  # workspace root and the one direct child named by the repository segment, and only when that
  # child physically is one. The nested owner-qualified path is never among them, and set equality
  # excludes parents, siblings and grandchildren. The workspace repository IS the root here, so
  # `<root>/tiny-demo-workspace` does not exist and there is no second location to ask about.
  def test_only_the_root_and_the_repository_name_child_are_inspected_for_each_repository
    inspected_for = { "RepoWright/tiny-demo-workspace" => [ @root ],
                      "RepoWright/tiny-demo-dashboard" => [ @root, File.join(@root, "tiny-demo-dashboard") ],
                      "RepoWright/tiny-demo-crm" => [ @root, File.join(@root, "tiny-demo-crm") ] }

    three_repository_assignment.each do |entry|
      recorder = RecordingGit.new

      SpecrelayRunner::Review::Checkout.verify(
        assignment: SpecrelayRunner::Review::Assignment.new(
          review_payload.merge("repositories" => [ entry ])
        ), workspace_root: @root, git: recorder
      )

      assert_equal inspected_for.fetch(entry["repository_key"]).sort, recorder.roots.uniq.sort
      refute_includes recorder.roots, File.join(@root, entry["repository_key"])
    end
  end

  # Malformed key material is a REFUSAL at worst, never a wider search. Empty, dot, dot-dot and
  # absolute segments can only ever produce the workspace root itself or one contained child.
  MALFORMED_KEYS = [ "", ".", "..", "../..", "/etc", "RepoWright/", "RepoWright/..",
                     "RepoWright/../../etc" ].freeze

  def test_malformed_repository_keys_never_reach_a_path_outside_the_workspace_root
    MALFORMED_KEYS.each do |key|
      recorder = RecordingGit.new

      result = SpecrelayRunner::Review::Checkout.verify(
        assignment: SpecrelayRunner::Review::Assignment.new(review_payload.merge(
          "repositories" => [ repository_entry(key, "https://github.com/RepoWright/tiny-demo-crm.git", HEAD) ]
        )), workspace_root: @root, git: recorder
      )

      refute result.ok?, "#{key.inspect} must not resolve"
      inspected = recorder.roots.uniq
      assert_operator inspected.size, :<=, 2, "#{key.inspect} inspected #{inspected.inspect}"
      inspected.each { |path| assert contained_location?(path), "#{key.inspect} inspected #{path}" }
    end
  end

  # --- physical containment of the direct child (CR-001 F1) -----------------
  #
  # `same_directory?` compares a candidate and git's answer through `File.realpath`, which is what
  # lets the CONFIGURED ROOT be reached through a symlink. A symlinked CHILD exploited the same
  # tolerance: git resolved the outside repository, both sides then agreed, and a repository
  # physically outside the connected workspace verified as the reviewed one. Lexical containment
  # could not see it.

  # The escaped target is never handed to the git seam at all: the only location asked about is the
  # workspace root, so nothing that resolves outside the workspace is ever inspected.
  def test_a_repository_name_child_symlinked_outside_the_workspace_never_reaches_git
    outside = File.join(@remotes, "outside-workspace", "tiny-demo-crm")
    crm = pin_repository("tiny-demo-crm", at: outside)
    link = File.join(@root, "tiny-demo-crm")
    File.symlink(outside, link)
    refute File.realpath(link).start_with?(File.realpath(@root) + File::SEPARATOR),
           "the fixture must really point outside the connected workspace"
    recorder = RecordingGit.new

    result = SpecrelayRunner::Review::Checkout.verify(
      assignment: SpecrelayRunner::Review::Assignment.new(
        review_payload.merge("repositories" => [ crm ])
      ), workspace_root: @root, git: recorder
    )

    refute result.ok?
    assert_equal [ @root ], recorder.roots.uniq
    refute_includes recorder.roots, link
    refute_includes recorder.roots, File.realpath(outside)
  end

  # ... and with the real git seam the whole review ends before a reviewer is launched and before
  # anything could be submitted.
  def test_a_repository_name_child_symlinked_outside_the_workspace_refuses_before_the_reviewer_starts
    outside = File.join(@remotes, "outside-workspace", "tiny-demo-crm")
    crm = pin_repository("tiny-demo-crm", at: outside)
    File.symlink(outside, File.join(@root, "tiny-demo-crm"))
    capture = File.join(@root, "launched.txt")

    result = run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"ok"}), capture: capture),
                        payload: review_payload.merge("repositories" => [ crm ]))

    refute File.exist?(capture), "a checkout outside the workspace must not reach a reviewer"
    refute result.success?
    assert_includes result.message, "no local checkout for 'RepoWright/tiny-demo-crm'"
    assert_empty @platform.review_results
  end

  # An unresolvable child is an ORDINARY safe refusal — not a crash, and not a new classification.
  def test_a_broken_repository_name_symlink_refuses_without_reaching_git
    File.symlink(File.join(@remotes, "absent-crm"), File.join(@root, "tiny-demo-crm"))
    recorder = RecordingGit.new

    result = SpecrelayRunner::Review::Checkout.verify(
      assignment: SpecrelayRunner::Review::Assignment.new(review_payload.merge(
        "repositories" => [ repository_entry("RepoWright/tiny-demo-crm",
                                             "https://github.com/RepoWright/tiny-demo-crm.git", HEAD) ]
      )), workspace_root: @root, git: recorder
    )

    refute result.ok?
    assert_includes result.reason, "no local checkout for 'RepoWright/tiny-demo-crm'"
    assert_equal [ @root ], recorder.roots.uniq
  end

  # The correction applies to the DERIVED CHILD, never to the established root behavior: a
  # configured workspace root reached through a symlink is still the reviewed repository, and its
  # direct child still resolves beneath it.
  def test_a_workspace_root_reached_through_a_symlink_still_resolves_itself_and_its_child
    workspace = pin_repository("tiny-demo-workspace", at: @root)
    crm = pin_repository("tiny-demo-crm", at: File.join(@root, "tiny-demo-crm"))
    linked_root = File.join(@remotes, "linked-workspace")
    File.symlink(@root, linked_root)

    verified = SpecrelayRunner::Review::Checkout.verify(
      assignment: SpecrelayRunner::Review::Assignment.new(
        review_payload.merge("repositories" => [ workspace, crm ])
      ), workspace_root: linked_root
    )

    assert verified.ok?, verified.reason
    assert_equal linked_root, verified.roots["RepoWright/tiny-demo-workspace"]
    assert_equal File.join(linked_root, "tiny-demo-crm"), verified.roots["RepoWright/tiny-demo-crm"]
  end

  # The whole review boundary over the three-repository assignment: the reviewer starts only once
  # every pin verifies, and its verdict is submitted.
  def test_a_three_repository_review_launches_the_reviewer_and_submits_its_verdict
    entries = three_repository_assignment
    capture = File.join(@root, "launched.txt")

    result = run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"Read the diff."}),
                                                 capture: capture),
                        payload: review_payload.merge("repositories" => entries))

    assert result.success?, result.message
    assert File.exist?(capture), "the reviewer must run once every pin verifies"
    assert_equal "ACCEPT", @platform.last_review["outcome"]
  end

  # Pre-submission re-verification resolves the SAME anchored locations again: a push to one
  # repository's branch while the reviewer works stops the verdict instead of recording it.
  def test_a_head_that_moves_during_a_three_repository_review_stops_the_verdict
    entries = three_repository_assignment
    capture = File.join(@root, "launched.txt")
    script = reviewer_script(%({"outcome":"ACCEPT","summary":"Looked fine."}),
                             capture: capture, advance: File.join(@root, "tiny-demo-crm"))

    result = run_review(command: script, payload: review_payload.merge("repositories" => entries))

    assert File.exist?(capture), "the reviewer did run"
    assert_equal :stale, result.outcome
    assert_empty @platform.review_results
    assert_equal 1, @platform.stale_reports.size
  end

  # --- the fresh reviewer process ------------------------------------------

  def test_submits_the_parsed_verdict_from_a_fresh_process
    build_repo
    script = reviewer_script(<<~JSON)
      {"outcome":"ACCEPT","summary":"Read the diff and ran the suite.",
       "evidence":{"structural_review":true,"verification_run":true,"browser_review":true}}
    JSON

    result = run_review(command: script)

    assert result.success?, result.message
    assert_equal "ACCEPT", @platform.last_review["outcome"]
    assert_equal true, @platform.last_review.dig("evidence", "structural_review")
  end

  # A reviewer's input-required decision is a WRITTEN one: a long prompt and three mutually
  # exclusive options. This machine holds no prompt limit of its own, so the whole document must
  # reach Platform exactly as the reviewer wrote it — a runner that quietly shortened it would
  # hide the very field Platform is about to judge.
  def test_a_long_three_option_decision_reaches_platform_whole
    build_repo
    prompt = review_prompt_of(2_000)
    script = reviewer_script(JSON.generate(
                               "outcome" => "NEEDS_INPUT", "summary" => "A product decision is required.",
                               "evidence" => { "structural_review" => true, "verification_run" => true },
                               "question" => {
                                 "prompt" => prompt, "reason" => "It changes what the operator approves.",
                                 "options" => [
                                   { "key" => "stop_polling", "label" => "Stop polling",
                                     "trade_off" => "Quieter, but a stale tab.", "recommended" => true },
                                   { "key" => "keep_polling", "label" => "Keep polling",
                                     "trade_off" => "Always fresh, more requests." },
                                   { "key" => "poll_while_open", "label" => "Poll while a question is open",
                                     "trade_off" => "Fresh where it matters." }
                                 ]
                               }
                             ))

    result = run_review(command: script)

    assert result.success?, result.message
    question = @platform.last_review["question"]
    assert_equal "NEEDS_INPUT", @platform.last_review["outcome"]
    assert_equal prompt, question["prompt"]
    assert_equal 2_000, question["prompt"].length
    assert_equal %w[stop_polling keep_polling poll_while_open], question["options"].map { |o| o["key"] }
  end

  # The prompt is the reviewer's ENTIRE input. It must name the pinned commits and must carry
  # no session id, resume flag or executor context.
  def test_the_prompt_pins_the_commits_and_carries_no_executor_context
    build_repo
    capture = File.join(@root, "prompt.txt")
    run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"ok"}), capture: capture))

    prompt = File.read(capture)
    assert_includes prompt, "#{BASE}..#{pinned_head}"
    assert_includes prompt, "You are a FRESH process"
    refute_includes prompt, "--resume"
    refute_includes prompt, "session"
  end

  # The specification arrives as a DOCUMENT MANIFEST. MVP-0033 preserves the single approved
  # specification the product durably provides today; the manifest shape is what lets a later
  # MVP add a resolved Spec PR package without changing this runner.
  def test_the_prompt_renders_every_specification_document_in_the_manifest
    build_repo
    capture = File.join(@root, "prompt.txt")
    packet = review_payload
    packet["specification"]["documents"] << {
      "role" => "technical_analysis", "digest" => "cafebabe0000", "byte_size" => 5, "content" => "EXTRA-DOC"
    }

    run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"ok"}), capture: capture), payload: packet)

    prompt = File.read(capture)
    assert_includes prompt, "approved_specification_source"
    assert_includes prompt, "technical_analysis"
    assert_includes prompt, "EXTRA-DOC"
  end

  def test_a_continuation_carries_the_answer_and_prior_findings
    build_repo
    capture = File.join(@root, "prompt.txt")
    packet = review_payload.merge(
      "continuation" => {
        "previous_attempt_ordinal" => 1, "previous_outcome" => "NEEDS_INPUT",
        "previous_findings" => [ { "severity" => "major", "location" => "a.rb:1", "summary" => "Unbounded scan" } ],
        "question" => { "prompt" => "Which bound?" }, "answer" => { "option" => "other", "text" => "Cap at 50" }
      }
    )

    run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"ok"}), capture: capture), payload: packet)

    prompt = File.read(capture)
    assert_includes prompt, "Cap at 50"
    assert_includes prompt, "Unbounded scan"
    assert_includes prompt, "Which bound?"
  end

  # MAPIAI-71. A carried `human_browser_pass` note is the Product Owner's own browser pass,
  # performed because no reviewer could run one. Attempt 2 must assess it, must keep its own
  # `browser_review` false, and must not report the pass as work it did — so the attribution
  # travels in the fixed instructions and in the continuation label, never in a new packet
  # field. Removing either one fails here.
  def test_a_carried_human_browser_pass_is_attributed_to_the_human
    build_repo
    capture = File.join(@root, "prompt.txt")
    packet = review_payload.merge(
      "continuation" => {
        "previous_attempt_ordinal" => 1, "previous_outcome" => "NEEDS_INPUT", "previous_findings" => [],
        "question" => { "prompt" => "Who runs the browser pass?" },
        "answer" => { "option" => "human_browser_pass",
                      "text" => "1440x900 and 390x844 at /runs/abc: pass. Screenshots 01.png, 02.png." }
      }
    )

    run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"ok"}), capture: capture), payload: packet)

    prompt = File.read(capture)
    assert_includes prompt, "human_browser_pass"
    assert_includes prompt, "Screenshots 01.png, 02.png."
    assert_includes prompt, "the Product Owner's own words"
    assert_includes prompt, "not as work you did"
    assert_includes prompt, "Platform validates the human evidence"
  end

  # --- untrusted provider output -------------------------------------------

  def test_malformed_json_fails_without_a_verdict
    build_repo

    result = run_review(command: reviewer_script("I reviewed it and it seemed fine to me."))

    refute result.success?
    assert_includes result.message, "did not return one JSON object"
    assert_empty @platform.review_results
  end

  def test_an_unknown_outcome_is_refused
    build_repo

    result = run_review(command: reviewer_script(%({"outcome":"LOOKS_GOOD","summary":"ok"})))

    refute result.success?
    assert_includes result.message, "outcome must be one of"
  end

  def test_a_non_zero_exit_is_a_failure_rather_than_a_result
    build_repo

    result = run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"ok"}), exit_code: 3))

    refute result.success?
    assert_includes result.message, "exited 3"
    assert_empty @platform.review_results
  end

  def test_oversized_output_is_refused_before_it_is_parsed
    build_repo
    huge = "x" * (SpecrelayRunner::Review::Result::MAX_OUTPUT_BYTES + 10)

    result = run_review(command: reviewer_script(huge))

    refute result.success?
    assert_includes result.message, "more than"
  end

  # JSON wrapped in a fence or a sentence is the normal shape of model output, so the outermost
  # balanced object is taken — while anything that does not parse is still refused.
  def test_json_inside_a_fence_is_accepted
    build_repo
    fenced = "Here is my review:\n```json\n{\"outcome\":\"ACCEPT\",\"summary\":\"Fine.\"}\n```\n"

    assert run_review(command: reviewer_script(fenced)).success?
    assert_equal "ACCEPT", @platform.last_review["outcome"]
  end

  def test_a_credential_in_the_provider_output_is_redacted_before_it_leaves_the_machine
    build_repo
    body = %({"outcome":"ACCEPT","summary":"Fine. Token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 seen."})

    run_review(command: reviewer_script(body))

    assert_includes @platform.last_review["summary"], "[REDACTED]"
    refute_includes @platform.last_review["summary"], "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
  end

  # Platform is the trust boundary, so a submission it REFUSES must fail the attempt here too.
  # The first real-provider execution of this MVP reported "Submitted CHANGES_REQUESTED" and
  # exited 0 while Platform had recorded the attempt FAILED, because the client returned the
  # 422 instead of raising on it.
  def test_a_refused_submission_is_a_failure_rather_than_a_success
    build_repo
    @platform.review_response = [ 422, { accepted: false, errors: [ "ACCEPT requires zero blocking findings" ] } ]

    result = run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"Fine."})))

    refute result.success?
    assert_includes result.message, "Platform refused the review result"
  end

  # --- configuration -------------------------------------------------------

  def test_a_machine_with_no_reviewer_provider_refuses_rather_than_guessing
    build_repo
    settings = SpecrelayRunner::Review::Settings.new({}, env: {})

    result = SpecrelayRunner::Review::Execution.call(
      config: config, client: client, payload: review_payload, settings: settings,
      env: workspace_env, io: @io
    )

    refute result.success?
    assert_includes result.message, "no reviewer provider is configured"
    refute_includes result.message, "connect"
  end

  # MAPIAI-91 — a connection stored before the reviewer selection existed carries no provider.
  # Nothing may guess one from the executor, PATH, Platform profile or a default: review fails
  # with ONE actionable remedy, reported as a retryable failure rather than a verdict.
  def test_a_connected_machine_with_no_stored_reviewer_provider_is_told_to_reconnect
    build_repo
    config = SpecrelayRunner::Config.from_connection(connection_without_a_reviewer,
                                                    credential: FakePlatform::ISSUED_CREDENTIAL)

    result = SpecrelayRunner::Review::Execution.call(
      config: config, client: client, payload: review_payload,
      settings: SpecrelayRunner::Review::Settings.from(config, env: {}), env: workspace_env, io: @io
    )

    refute result.success?
    assert_includes result.message, "no reviewer provider is configured"
    assert_includes result.message, "specrelay-runner connect"
    assert_equal "provider_execution_failure", @platform.last_review_failure["kind"]
    assert_empty @platform.review_results
  end

  def test_the_public_identity_carries_no_command_or_path
    settings = SpecrelayRunner::Review::Settings.new(
      { "provider" => "fake", "command" => "/Users/someone/bin/review", "args" => [ "--secret" ] }, env: {}
    )

    identity = settings.public_identity(version: "1.2.3")

    assert_equal %w[role name provider version config_digest], identity.keys
    refute_includes identity.values.join(" "), "/Users/someone"
    refute_includes identity.values.join(" "), "--secret"
    assert_match(/\A[0-9a-f]{32}\z/, identity["config_digest"])
  end

  private

  def refusal?(request) = request.dig(:body, "review", "outcome").nil?

  def run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"ok"})), payload: review_payload)
    settings = SpecrelayRunner::Review::Settings.new({ "provider" => "fake", "command" => command }, env: {})
    SpecrelayRunner::Review::Execution.call(
      config: config, client: client, payload: payload, settings: settings,
      env: workspace_env, io: @io
    )
  end

  def workspace_env = { "PATH" => ENV["PATH"], "HOME" => @root }

  def config
    SpecrelayRunner::Config.new(
      { "platform" => { "base_url" => @platform.base_url },
        "runner" => { "id" => "review-runner", "display_name" => "Review Machine" },
        "workspace_roots" => { "tiny-demo-workspace" => @root } }
    )
  end

  def client = SpecrelayRunner::PlatformClient.new(base_url: @platform.base_url, token: FakePlatform::EXPECTED_TOKEN)

  # A real git repository with a real commit, so Checkout's `git cat-file` runs for real.
  def build_repo(remote: "https://github.com/SpecRelay/tiny-demo-workspace.git", head: nil)
    real = build_repo_at(@repo, remote: remote)
    @actual_head = head || real
  end

  # The same real repository, at any path — the reviewed repository may be the workspace root
  # itself, its direct child, or (for a refusal) somewhere neither of those covers.
  def build_repo_at(path, remote:)
    FileUtils.mkdir_p(path)
    git_in path, "init --quiet --initial-branch=main"
    git_in path, "config user.email review@example.com"
    git_in path, "config user.name Reviewer"
    git_in path, "remote add origin #{remote}"
    File.write(File.join(path, "README.md"), "demo\n")
    git_in path, "add README.md"
    git_in path, "-c commit.gpgsign=false commit --quiet -m first"
    `git -C #{path} rev-parse HEAD`.strip
  end

  def git_in(path, args) = system("git -C #{path} #{args}", out: File::NULL, err: File::NULL)

  # A real bare origin at `remotes/<owner>/<name>.git` plus a real checkout at `at`, pushed to it.
  # The pinned clone URL therefore carries the owner-qualified identity while the checkout is
  # anchored by the repository segment alone — which is exactly the distinction under test — and
  # `ls-remote` and `cat-file` both run for real, offline.
  def pin_repository(name, at:, owner: "RepoWright")
    remote = File.join(@remotes, owner, "#{name}.git")
    FileUtils.mkdir_p(File.dirname(remote))
    system("git init --quiet --bare --initial-branch=#{BRANCH} #{remote}", out: File::NULL, err: File::NULL)
    head = build_repo_at(at, remote: remote)
    git_in at, "push --quiet origin HEAD:refs/heads/#{BRANCH}"
    { "repository_key" => "#{owner}/#{name}", "slug" => "#{owner}/#{name}", "clone_url" => remote,
      "base_commit" => BASE, "branch" => BRANCH, "head_commit" => head,
      "pull_request_url" => "https://github.com/#{owner}/#{name}/pull/1" }
  end

  # The MAPIAI-95 layout: the workspace root itself, then two direct children, every key
  # owner-qualified.
  def three_repository_assignment
    [ pin_repository("tiny-demo-workspace", at: @root),
      pin_repository("tiny-demo-dashboard", at: File.join(@root, "tiny-demo-dashboard")),
      pin_repository("tiny-demo-crm", at: File.join(@root, "tiny-demo-crm")) ]
  end

  def verify_repositories(entries)
    SpecrelayRunner::Review::Checkout.verify(
      assignment: SpecrelayRunner::Review::Assignment.new(
        review_payload.merge("repositories" => entries)
      ), workspace_root: @root
    )
  end

  # The workspace root itself, or one of its direct children — the only two anchored locations.
  def contained_location?(path) = path == @root || File.dirname(path) == @root

  def verify(workspace_root)
    SpecrelayRunner::Review::Checkout.verify(
      assignment: SpecrelayRunner::Review::Assignment.new(review_payload), workspace_root: workspace_root
    )
  end

  def repository_entry(key, clone_url, head)
    { "repository_key" => key, "slug" => "SpecRelay/#{key}", "clone_url" => clone_url,
      "base_commit" => BASE, "head_commit" => head,
      "pull_request_url" => "https://github.com/SpecRelay/#{key}/pull/1" }
  end

  # A guided connection made before the reviewer selection was stored: complete in every other
  # respect, and pointing at this test's workspace root.
  def connection_without_a_reviewer
    SpecrelayRunner::ConnectionStore::Connection.new(
      base_url: @platform.base_url, runner_id: "review-runner", runner_public_id: "rnr_fake",
      runner_display_name: "Review Machine", project_slug: "tiny-demo",
      workspace_key: "tiny-demo-workspace", project_key: "tiny-demo",
      workspace_display_name: "Tiny Demo Workspace",
      repository_url: "https://github.com/SpecRelay/tiny-demo-workspace", default_branch: "main",
      local_path: @root, connected_at: "2026-08-01T00:00:00Z"
    )
  end

  def review_payload
    {
      "contract_version" => "mvp-0033", "assignment_type" => "review",
      "claim" => { "runner_execution_id" => "rex_fake" },
      "review" => { "attempt_id" => "rvt_fake", "attempt_ordinal" => 1,
                    "input_manifest_digest" => "digest" },
      "ticket" => { "external_id" => "DEMO-1", "task_id" => "DEMO-1" },
      "workspace" => { "key" => "tiny-demo-workspace" },
      "specification" => { "digest" => "specdigest", "documents" => [
        { "role" => "approved_specification_source", "digest" => "abc123", "byte_size" => 9,
          "content" => "# Approved" }
      ] },
      "implementation" => { "run_url" => "#{@platform.base_url}/runs/run_fake" },
      "repositories" => [ { "repository_key" => "specrelay-platform",
                            "slug" => "SpecRelay/tiny-demo-workspace",
                            "clone_url" => "https://github.com/SpecRelay/tiny-demo-workspace.git",
                            "base_commit" => BASE, "head_commit" => pinned_head,
                            "pull_request_url" => "https://github.com/SpecRelay/tiny-demo-workspace/pull/1" } ],
      "execution_evidence" => { "executor_summary" => "Did the work.", "files_changed_summary" => "a.rb",
                                "validation_commands" => [ "rspec" ], "files" => [] },
      "execution_policy" => { "attempt_timeout_seconds" => 30, "lease_renewal_seconds" => 0 },
      "result_contract" => { "outcomes" => %w[ACCEPT CHANGES_REQUESTED NEEDS_INPUT] }
    }
  end

  # The real commit when the repository was built with one, otherwise the deliberately absent
  # sha a refusal test wants.
  def pinned_head = @actual_head || HEAD

  # Real spaced prose of an exact length, not one repeated token: redaction and JSON transport
  # treat text with word boundaries differently from an entropy-like blob.
  def review_prompt_of(length)
    sentence = "The reviewer needs one product decision before this assignment can continue, " \
               "because the pinned specification leaves the retention boundary open. "
    text = (sentence * (length.fdiv(sentence.length).ceil + 1))[0, length]
    text.end_with?(" ") ? "#{text.chomp(' ')}." : text
  end

  # A reviewer stand-in that prints `body` and exits. It is a real executable launched as a
  # real child process, so the runner's argv, timeout and capture behaviour are all exercised.
  # `advance` pushes a commit from that checkout WHILE the reviewer works, which is how a head
  # that moves during a review is reproduced.
  def reviewer_script(body, exit_code: 0, capture: nil, advance: nil)
    path = File.join(@root, "reviewer-#{rand(1_000_000)}.rb")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      File.write(#{capture.inspect}, ARGV.last) if #{capture.inspect}
      if (moving = #{advance.inspect})
        File.write(File.join(moving, "LATER.md"), "added during the review\\n")
        system("git -C \#{moving} add LATER.md", out: File::NULL, err: File::NULL)
        system("git -C \#{moving} -c commit.gpgsign=false commit --quiet -m during",
               out: File::NULL, err: File::NULL)
        system("git -C \#{moving} push --quiet origin HEAD:refs/heads/#{BRANCH}",
               out: File::NULL, err: File::NULL)
      end
      print #{body.inspect}
      exit #{exit_code}
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end
end
