# frozen_string_literal: true

require "test_helper"

# MAPIAI-78 — the runner half of recovering an automated review that produced no verdict.
#
# The live MAPIAI-73 review was stranded here: the provider exited successfully, the runner
# refused what it printed, and the refusal then travelled to Platform as an outcome-less review
# body — where Platform's own outcome validation replaced the runner's specific reason with a
# generic one and no attempt was left to retry.
#
# Four boundaries are under test, and each of them is a different failure:
#
#   - the provider's output SHAPE is deterministic, so a native envelope can never be mistaken
#     for a review document;
#   - the allowed outcomes come from Platform's own result contract, not from a runner copy;
#   - a failure is reported AS a failure, carrying the local reason that explains it;
#   - a delivery whose response was lost is retried with the identical body and never reruns
#     the provider.
class ReviewRecoveryTest < Minitest::Test
  BASE = "1111111111111111111111111111111111111111"

  # Claude Code's `--output-format json` envelope, as the CLI emits it. It IS one JSON object,
  # it parses, and its top level carries no `outcome` — the review document is a STRING inside
  # `result`. This is the shape the live defect's persisted error describes: a result that
  # parsed successfully while exposing no supported outcome.
  PROVIDER_ENVELOPE = <<~JSON
    {"type":"result","subtype":"success","is_error":false,"duration_ms":184213,"num_turns":37,
     "result":"{\\"outcome\\":\\"ACCEPT\\",\\"summary\\":\\"Read the diff and ran the suite.\\"}",
     "session_id":"1f9c0c6e","total_cost_usd":1.42}
  JSON

  def setup
    @root = Dir.mktmpdir("review-recovery")
    @repo = File.join(@root, "specrelay-platform")
    @io = StringIO.new
    @platform = FakePlatform.new(claim_payload: { "claimed" => false })
    @platform.start
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@root, true)
  end

  # --- the deterministic provider output boundary ---------------------------

  # The live defect, reproduced. The envelope must be refused as an INVALID REVIEWER RESULT —
  # never mined for the outcome buried in its `result` string, which would be Platform trusting
  # a verdict nobody validated.
  def test_a_provider_native_envelope_is_refused_as_an_invalid_reviewer_result
    build_repo

    result = run_review(command: reviewer_script(PROVIDER_ENVELOPE))

    refute result.success?
    assert_empty @platform.review_results, "an envelope must never be submitted as a verdict"
    failure = @platform.last_review_failure
    assert_equal "invalid_reviewer_result", failure["kind"]
    assert_includes failure["reason"], "outcome must be one of"
  end

  # The configuration that can produce that envelope is refused before a provider is launched,
  # rather than decoded afterwards: a second accepted output shape would mean a second result
  # parser, and no way to prove which one produced a verdict.
  def test_a_reviewer_configured_for_wrapped_output_is_refused_before_launch
    settings = SpecrelayRunner::Review::Settings.new(
      { "provider" => "claude", "args" => %w[--print --output-format json] }, env: {}
    )

    error = assert_raises(SpecrelayRunner::Review::Settings::Error) { settings.argv("prompt") }
    assert_includes error.message, "--output-format"
  end

  def test_the_supported_text_output_mode_is_accepted
    settings = SpecrelayRunner::Review::Settings.new(
      { "provider" => "claude", "args" => %w[--print --output-format=text] }, env: {}
    )

    assert_includes settings.argv("prompt"), "--output-format=text"
  end

  def test_no_output_format_flag_at_all_is_the_ordinary_supported_configuration
    settings = SpecrelayRunner::Review::Settings.new(
      { "provider" => "claude", "args" => %w[--print --dangerously-skip-permissions] }, env: {}
    )

    assert_includes settings.argv("prompt"), "--print"
  end

  # review-001 F6: only the FIRST occurrence used to be inspected, so a direct-text flag in
  # front of a wrapped one passed the check and left the provider wrapped. Every occurrence is
  # read, in both spellings, and anything but one unambiguous text selection is refused.
  #
  # A repeated flag is refused even when both values agree: which one the provider honours is
  # its business, and a configuration whose effective output mode has to be reasoned about is
  # not the deterministic one this boundary exists to guarantee.
  UNSUPPORTED_ARG_SETS = {
    "a text flag in front of a wrapped one" => %w[--print --output-format text --output-format json],
    "a wrapped flag in front of a text one" => %w[--print --output-format json --output-format text],
    "the equals spelling, repeated and conflicting" => %w[--print --output-format=text --output-format=stream-json],
    "the two spellings mixed" => %w[--print --output-format text --output-format=json],
    "a repeated flag that agrees with itself" => %w[--print --output-format text --output-format text],
    "stream-json" => %w[--print --output-format stream-json],
    "the equals spelling with no value" => %w[--print --output-format=],
    "the split spelling with no value" => %w[--print --output-format]
  }.freeze

  UNSUPPORTED_ARG_SETS.each do |description, args|
    define_method(:"test_#{description.tr(' -', '__')}_is_refused_before_launch") do
      settings = SpecrelayRunner::Review::Settings.new({ "provider" => "claude", "args" => args }, env: {})

      error = assert_raises(SpecrelayRunner::Review::Settings::Error) { settings.argv("prompt") }
      assert_includes error.message, "--output-format"
    end
  end

  # A misconfigured reviewer never ran, so it is a PROVIDER EXECUTION failure rather than an
  # invalid result — the two carry different recoveries.
  def test_wrapped_output_configuration_reaches_platform_as_a_provider_execution_failure
    build_repo
    settings = SpecrelayRunner::Review::Settings.new(
      { "provider" => "claude", "command" => reviewer_script("{}"), "args" => %w[--output-format json] }, env: {}
    )

    result = execute(settings: settings)

    refute result.success?
    assert_equal "provider_execution_failure", @platform.last_review_failure["kind"]
    assert_includes @platform.last_review_failure["reason"], "--output-format"
  end

  # --- exactly one scalar outcome ------------------------------------------

  # Two `outcome` members are a reviewer stating two verdicts. Selecting either one would be
  # this runner deciding a review, so the whole document is refused.
  #
  # This must hold on every supported runtime, and it is exactly where review-001 F1 found the
  # hole: the standard library's own duplicate handling differs across the supported range
  # (json 2.9 on Ruby 3.4 silently keeps the LAST member; json 2.21 on Ruby 4 keeps the last
  # unless told otherwise), so a rule expressed in only one of the two ways is deterministic on
  # only one of them. The assertions below name both candidates deliberately: "refused" is not
  # enough — neither verdict may survive anywhere in the result.
  def test_duplicate_outcome_members_are_refused_rather_than_resolved
    parsed = parse(%({"outcome":"ACCEPT","outcome":"CHANGES_REQUESTED","summary":"two verdicts"}))

    refute parsed.ok?, "duplicate outcomes were resolved on #{RUBY_VERSION} / json #{JSON::VERSION}"
    assert_nil parsed.review
    refute_includes parsed.error.to_s, "ACCEPT"
    refute_includes parsed.error.to_s, "CHANGES_REQUESTED"
  end

  # The same document over the whole execution path: no verdict reaches Platform, and the
  # explicit failure that does reach it names neither candidate.
  def test_duplicate_outcome_members_reach_platform_as_an_invalid_result_naming_no_verdict
    build_repo

    result = run_review(command: reviewer_script(%({"outcome":"ACCEPT","outcome":"CHANGES_REQUESTED","summary":"two"})))

    refute result.success?
    assert_empty @platform.review_results
    failure = @platform.last_review_failure
    assert_equal "invalid_reviewer_result", failure["kind"]
    refute_includes failure["reason"], "ACCEPT"
    refute_includes failure["reason"], "CHANGES_REQUESTED"
  end

  # A duplicate anywhere in the document is the same ambiguity, and is refused for the same
  # reason: the parser would otherwise choose which of two values Platform is told about.
  def test_a_duplicate_member_inside_the_result_is_refused_too
    parsed = parse(%({"outcome":"ACCEPT","summary":"one","summary":"another"}))

    refute parsed.ok?
    assert_nil parsed.review
  end

  def test_two_contradictory_result_documents_are_refused
    parsed = parse(%({"outcome":"ACCEPT","summary":"ok"}\n{"outcome":"CHANGES_REQUESTED","summary":"no"}))

    refute parsed.ok?
    assert_nil parsed.review
  end

  def test_an_outcome_that_is_not_a_scalar_is_refused
    parsed = parse(%({"outcome":["ACCEPT","NEEDS_INPUT"],"summary":"ok"}))

    refute parsed.ok?
    assert_includes parsed.error, "outcome must be one of"
  end

  # --- one outcome contract, owned by Platform ------------------------------

  # The set is Platform's, so an outcome outside the contract it sent is refused even though it
  # is a name this runner's own source once carried.
  def test_the_allowed_outcomes_come_from_platforms_result_contract
    parsed = parse(%({"outcome":"NEEDS_INPUT","summary":"ok"}), outcomes: %w[ACCEPT])

    refute parsed.ok?
    assert_includes parsed.error, "ACCEPT"
    refute_includes parsed.error, "NEEDS_INPUT"
  end

  def test_the_prompt_states_the_outcomes_platform_sent
    packet = review_payload
    packet["result_contract"]["outcomes"] = %w[ACCEPT NEEDS_INPUT]

    prompt = SpecrelayRunner::Review::Packet.new(SpecrelayRunner::Review::Assignment.new(packet)).prompt

    assert_includes prompt, %("ACCEPT" | "NEEDS_INPUT")
    refute_includes prompt, %("ACCEPT" | "CHANGES_REQUESTED" | "NEEDS_INPUT")
  end

  # --- a failure is reported as a failure -----------------------------------

  def test_a_provider_that_exits_non_zero_reports_a_provider_execution_failure
    build_repo

    result = run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"ok"}), exit_code: 3))

    refute result.success?
    assert_empty @platform.review_results
    assert_equal "provider_execution_failure", @platform.last_review_failure["kind"]
    assert_includes @platform.last_review_failure["reason"], "exited 3"
  end

  # The whole point of the explicit body: the reason the RUNNER observed survives to Platform
  # instead of being replaced by Platform's generic outcome-validation message.
  def test_the_local_reason_survives_to_platform_instead_of_a_generic_refusal
    build_repo

    run_review(command: reviewer_script("I reviewed it and it seemed fine to me."))

    assert_includes @platform.last_review_failure["reason"], "did not return one JSON object"
  end

  def test_a_failure_report_carries_no_provider_output
    build_repo
    secret = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"

    run_review(command: reviewer_script("not json at all; token #{secret}"))

    body = @platform.review_failures.to_s
    refute_includes body, secret
    refute_includes body, "not json at all"
  end

  # --- replay-safe delivery -------------------------------------------------

  # A lost response is a transport fact, not a verdict. The same body is delivered again and
  # the provider is NOT rerun — rerunning it could produce a different verdict for an attempt
  # Platform may already have ended.
  def test_a_lost_response_is_retried_with_the_identical_body_without_rerunning_the_provider
    build_repo
    launches = File.join(@root, "launches")
    script = reviewer_script(%({"outcome":"ACCEPT","summary":"Fine."}), counter: launches)

    result = run_review(command: script, client: flaky_client(failures: 1))

    assert result.success?, result.message
    assert_equal 1, File.read(launches).length, "the provider must run exactly once"
    assert_equal 1, @platform.review_results.size
    assert_equal "ACCEPT", @platform.last_review["outcome"]
  end

  # Platform received nothing this machine can prove. The runner says so and exits non-zero;
  # it never reports a success it cannot substantiate, and never invents a second ending.
  def test_an_unconfirmed_delivery_fails_locally_without_fabricating_an_ending
    build_repo

    result = run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"Fine."})),
                        client: flaky_client(failures: 99))

    refute result.success?
    assert_includes result.message, "did not confirm"
    assert_empty @platform.review_submissions
  end

  # review-001 F4: the real shape of a lost response. Platform COMMITTED the first body and the
  # answer vanished on the way back — which surfaces as EOFError or a connection reset from the
  # exchange itself, not as the connect-time failures the client used to map. Both deliveries
  # must carry the identical body, and the provider must not run again to produce the second.
  RESPONSE_LOSS_ERRORS = [ EOFError, Errno::ECONNRESET, Errno::EPIPE ].freeze

  RESPONSE_LOSS_ERRORS.each do |error_class|
    define_method(:"test_a_response_lost_as_#{error_class.name.split('::').last.downcase}_is_retried_with_the_identical_body") do
      build_repo
      launches = File.join(@root, "launches-#{error_class.name.split('::').last}")
      script = reviewer_script(%({"outcome":"ACCEPT","summary":"Fine."}), counter: launches)

      result = run_review(command: script, client: lossy_client(error_class))

      assert result.success?, result.message
      assert_equal 1, File.read(launches).length, "the provider must run exactly once"
      bodies = @platform.review_submissions.map { |request| request[:body] }
      assert_equal 2, bodies.size, "Platform must have received the committed body and its replay"
      assert_equal bodies.first, bodies.last, "the replayed body must be identical"
    end
  end

  # --- the acknowledgement is read, not assumed -----------------------------

  # review-001 F5: a 201 from something that is not Platform — a proxy, a captive portal, a
  # truncated body — used to be reported as a submitted verdict. A delivery is confirmed only by
  # an acknowledgement that names the attempt this runner holds and the ending it sent.
  UNCONFIRMED_ACKNOWLEDGEMENTS = {
    "a non-JSON body" => { raw: "<html>proxy</html>" },
    "an empty body" => { raw: "" },
    "a body with no review block" => { contract_version: "mvp-0033" },
    "an acknowledgement for another attempt" => { review: { attempt_id: "rvt_someone_else", state: "COMPLETED",
                                                            outcome: "ACCEPT" } },
    "an acknowledgement of a different outcome" => { review: { attempt_id: "rvt_fake", state: "COMPLETED",
                                                               outcome: "CHANGES_REQUESTED" } },
    "an acknowledgement that records no state" => { review: { attempt_id: "rvt_fake", outcome: "ACCEPT" } }
  }.freeze

  UNCONFIRMED_ACKNOWLEDGEMENTS.each do |description, body|
    define_method(:"test_#{description.tr(' -', '__')}_is_unconfirmed_delivery_rather_than_success") do
      build_repo
      @platform.review_response = [ 201, body ]

      result = run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"Fine."})))

      refute result.success?, "an unconfirmed acknowledgement must not be reported as a verdict"
      assert_includes result.message, "did not confirm"
    end
  end

  # An unconfirmed acknowledgement leaves the delivery uncertain, so the IDENTICAL body is
  # delivered again — the same rule a lost response follows, because they are the same fact.
  def test_an_unconfirmed_acknowledgement_retries_the_identical_body
    build_repo
    @platform.review_response = [ 201, { raw: "<html>proxy</html>" } ]

    run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"Fine."})))

    bodies = @platform.review_submissions.map { |request| request[:body] }
    assert_equal 3, bodies.size
    assert_equal [ bodies.first ], bodies.uniq
  end

  def test_a_failure_report_is_confirmed_by_an_acknowledgement_that_records_no_verdict
    build_repo

    result = run_review(command: reviewer_script("not json"))

    refute result.success?
    assert_includes result.message, "Review failed"
    refute_includes result.message, "did not confirm"
  end

  # --- the acknowledgement names the ending THIS delivery produced ----------

  # review-002 F1. Requiring merely a non-blank state accepted `"state":"WAITING"` as a
  # confirmed failure delivery — an attempt waiting for a runner is not an attempt that ended,
  # so the runner would have exited believing Platform held an ending it does not hold. Each
  # delivery kind produces exactly one durable ending, and only that ending confirms it.
  UNCONFIRMED_ENDINGS = {
    "a failure answered with WAITING" =>
      [ :failure, { attempt_id: "rvt_fake", state: "WAITING", outcome: nil } ],
    "a failure answered with CLAIMED" =>
      [ :failure, { attempt_id: "rvt_fake", state: "CLAIMED", outcome: nil } ],
    "a failure answered with RUNNING" =>
      [ :failure, { attempt_id: "rvt_fake", state: "RUNNING", outcome: nil } ],
    "a failure answered with another kind's terminal state" =>
      [ :failure, { attempt_id: "rvt_fake", state: "STALE", outcome: nil } ],
    "a stale report answered with another kind's terminal state" =>
      [ :stale, { attempt_id: "rvt_fake", state: "FAILED", outcome: nil } ],
    "an ACCEPT answered with AWAITING_ANSWER" =>
      [ :accept, { attempt_id: "rvt_fake", state: "AWAITING_ANSWER", outcome: "ACCEPT" } ],
    "a NEEDS_INPUT answered with COMPLETED" =>
      [ :needs_input, { attempt_id: "rvt_fake", state: "COMPLETED", outcome: "NEEDS_INPUT" } ],
    "an ACCEPT answered with arbitrary state text" =>
      [ :accept, { attempt_id: "rvt_fake", state: "RECORDED", outcome: "ACCEPT" } ],
    "an ACCEPT answered with a state that does not match its outcome" =>
      [ :accept, { attempt_id: "rvt_fake", state: "COMPLETED", outcome: nil } ]
  }.freeze

  UNCONFIRMED_ENDINGS.each do |description, (kind, acknowledgement)|
    define_method(:"test_#{description.tr(' -', '__')}_is_unconfirmed_delivery") do
      @platform.review_response = [ 201, { review: acknowledgement } ]

      assert_raises(SpecrelayRunner::PlatformClient::Error) { deliver(kind) }
    end
  end

  # An unconfirmed 201 is the same fact as a lost response, so it takes the same road: the
  # identical body again, and a local non-zero result once the attempts are spent.
  def test_a_wrong_ending_retries_the_identical_body_and_then_fails_locally
    build_repo
    @platform.review_response = [ 201, { review: { attempt_id: "rvt_fake", state: "WAITING", outcome: nil } } ]

    result = run_review(command: reviewer_script("not json"))

    refute result.success?
    assert_includes result.message, "did not confirm"
    bodies = @platform.review_submissions.map { |request| request[:body] }
    assert_equal 3, bodies.size
    assert_equal [ bodies.first ], bodies.uniq
  end

  CONFIRMED_ENDINGS = {
    "a failure ends the attempt FAILED with no verdict" =>
      [ :failure, { attempt_id: "rvt_fake", state: "FAILED", outcome: nil } ],
    "a stale report ends the attempt STALE with no verdict" =>
      [ :stale, { attempt_id: "rvt_fake", state: "STALE", outcome: nil } ],
    "an ACCEPT completes the attempt" =>
      [ :accept, { attempt_id: "rvt_fake", state: "COMPLETED", outcome: "ACCEPT" } ],
    "a CHANGES_REQUESTED completes the attempt" =>
      [ :changes_requested, { attempt_id: "rvt_fake", state: "COMPLETED", outcome: "CHANGES_REQUESTED" } ],
    "a NEEDS_INPUT leaves the attempt awaiting an answer" =>
      [ :needs_input, { attempt_id: "rvt_fake", state: "AWAITING_ANSWER", outcome: "NEEDS_INPUT" } ]
  }.freeze

  CONFIRMED_ENDINGS.each do |description, (kind, acknowledgement)|
    define_method(:"test_#{description.tr(' -', '__')}_confirms_the_delivery") do
      @platform.review_response = [ 201, { review: acknowledgement } ]

      deliver(kind)

      assert_equal 1, @platform.review_submissions.size, "a confirmed delivery is sent once"
    end
  end

  # A 422 is Platform having READ the result and refused it, so the attempt already carries
  # Platform's own reason. A failure report on top of it would be a second, conflicting ending.
  def test_a_refused_result_is_not_followed_by_a_failure_report
    build_repo
    @platform.review_response = [ 422, { accepted: false, errors: [ "ACCEPT requires zero blocking findings" ] } ]

    result = run_review(command: reviewer_script(%({"outcome":"ACCEPT","summary":"Fine."})))

    refute result.success?
    assert_includes result.message, "Platform refused the review result"
    assert_empty @platform.review_failures
  end

  private

  def parse(output, outcomes: %w[ACCEPT CHANGES_REQUESTED NEEDS_INPUT])
    SpecrelayRunner::Review::Result.parse(output, outcomes: outcomes)
  end

  # One delivery of each kind, straight at the client boundary that reads the acknowledgement.
  # Driven here rather than through Execution because what is under test is the answer Platform
  # gives, not the local condition that produced the body.
  def deliver(kind)
    claim = { claim: "rex_fake", attempt_id: "rvt_fake" }
    case kind
    when :failure
      client.report_review_failure(**claim, kind: "invalid_reviewer_result", reason: "no usable result")
    when :stale
      client.report_stale_target(**claim, reason: "the head moved")
    else
      client.submit_review_result(**claim, review: { "outcome" => kind.to_s.upcase, "summary" => "Reviewed." })
    end
  end

  def run_review(command:, payload: review_payload, client: client())
    settings = SpecrelayRunner::Review::Settings.new({ "provider" => "fake", "command" => command }, env: {})
    execute(settings: settings, payload: payload, client: client)
  end

  def execute(settings:, payload: review_payload, client: client())
    SpecrelayRunner::Review::Execution.call(config: config, client: client, payload: payload,
                                            settings: settings, env: workspace_env, io: @io)
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

  # A client whose first `failures` connection attempts never reach Platform at all.
  def flaky_client(failures:)
    SpecrelayRunner::PlatformClient.new(base_url: @platform.base_url, token: FakePlatform::EXPECTED_TOKEN,
                                        http: FlakyHttp.new(failures))
  end

  class FlakyHttp
    def initialize(failures)
      @remaining = failures
    end

    def start(*args, **kwargs, &block)
      if @remaining.positive?
        @remaining -= 1
        raise Errno::ECONNREFUSED, "the response was lost"
      end
      Net::HTTP.start(*args, **kwargs, &block)
    end
  end

  # A client whose FIRST exchange reaches Platform, is committed there, and then loses the
  # response on the way back. The distinction from FlakyHttp is the whole point: Platform has
  # the body, and this machine cannot tell.
  def lossy_client(error_class)
    SpecrelayRunner::PlatformClient.new(base_url: @platform.base_url, token: FakePlatform::EXPECTED_TOKEN,
                                        http: LossyHttp.new(error_class))
  end

  class LossyHttp
    def initialize(error_class)
      @error_class = error_class
      @lost = false
    end

    def start(*args, **kwargs, &block)
      response = Net::HTTP.start(*args, **kwargs, &block)
      return response if @lost

      @lost = true
      raise @error_class, "the committed response was lost"
    end
  end

  def build_repo(remote: "https://github.com/SpecRelay/tiny-demo-workspace.git")
    FileUtils.mkdir_p(@repo)
    git "init --quiet --initial-branch=main"
    git "config user.email review@example.com"
    git "config user.name Reviewer"
    git "remote add origin #{remote}"
    File.write(File.join(@repo, "README.md"), "demo\n")
    git "add README.md"
    git "-c commit.gpgsign=false commit --quiet -m first"
    @actual_head = `git -C #{@repo} rev-parse HEAD`.strip
  end

  def git(args) = system("git -C #{@repo} #{args}", out: File::NULL, err: File::NULL)

  def review_payload
    {
      "contract_version" => "mvp-0033", "assignment_type" => "review",
      "claim" => { "runner_execution_id" => "rex_fake" },
      "review" => { "attempt_id" => "rvt_fake", "attempt_ordinal" => 1, "input_manifest_digest" => "digest" },
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
                            "base_commit" => BASE, "head_commit" => @actual_head.to_s,
                            "pull_request_url" => "https://github.com/SpecRelay/tiny-demo-workspace/pull/1" } ],
      "execution_evidence" => { "executor_summary" => "Did the work.", "files_changed_summary" => "a.rb",
                                "validation_commands" => [ "rspec" ], "files" => [] },
      "execution_policy" => { "attempt_timeout_seconds" => 30, "lease_renewal_seconds" => 0 },
      "result_contract" => { "outcomes" => %w[ACCEPT CHANGES_REQUESTED NEEDS_INPUT] }
    }
  end

  # A reviewer stand-in launched as a real child process. `counter` appends one byte per launch,
  # which is how "the provider ran exactly once" is measured across a delivery retry.
  def reviewer_script(body, exit_code: 0, counter: nil)
    path = File.join(@root, "reviewer-#{rand(1_000_000)}.rb")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      File.write(#{counter.inspect}, "x", mode: "a") if #{counter.inspect}
      print #{body.inspect}
      exit #{exit_code}
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end
end
