# frozen_string_literal: true

require_relative "test_helper"

# MVP-0034 CR-001 — the runner half of the specification-package protocol.
#
# The runner is the only role that can reach GitHub, so it is the only role that can establish
# whether the pull request a ticket names is still open, still on the right base, and still at the
# commit the specification was published from. Every test here is about one promise: **no provider
# starts on a package this runner has not read at the exact recorded commit and Platform has not
# accepted.**
#
# `gh` is a real subprocess throughout — a generated script on PATH — so the runner exercises its
# actual command boundary, argv handling and failure translation rather than a stubbed method.
class PackagePreflightTest < Minitest::Test
  SLUG = "SpecRelay/specs"
  HEAD = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4"
  MOVED = "ffffffffffffffffffffffffffffffffffffffff"
  FOLDER = "specs/SR-42"
  PR_URL = "https://github.com/#{SLUG}/pull/7"

  DOCUMENTS = {
    "spec.md" => "# SR-42\n\nThe approved scope.\n",
    "analysis/input-evidence.md" => "# Input evidence\n",
    "analysis/business.md" => "# Business\n",
    "analysis/technical.md" => "# Technical\n",
    "generation-manifest.json" => %({"contract_version":"mvp-0026"}\n)
  }.freeze

  def setup
    @dir = Dir.mktmpdir("preflight")
    @log = File.join(@dir, "gh.log")
  end

  def teardown = FileUtils.remove_entry(@dir)

  # ---------------------------------------------------------------- the assignment

  def assignment_payload(documents: DOCUMENTS, head: HEAD)
    {
      "assignment_kind" => SpecrelayRunner::PackagePreflight::Assignment::KIND,
      "claim" => { "runner_execution_id" => "rex_1" },
      "run" => { "id" => "run_1", "state" => "AWAITING_SPECIFICATION_PACKAGE_PREFLIGHT" },
      "specification_package_preflight" => {
        "ticket_key" => "SR-42", "spec_pull_request_url" => PR_URL, "repository_slug" => SLUG,
        "pull_request_number" => 7, "base_branch" => "main", "head_sha" => head,
        "package_path" => FOLDER,
        "documents" => documents.map do |path, body|
          { "role" => "x", "path" => path, "digest" => Digest::SHA256.hexdigest(body) }
        end
      }
    }
  end

  # A `gh` that answers the three calls preflight makes. `pr_state`/`pr_base`/`pr_head` script the
  # PR view; `final_head` scripts the SECOND view only, which is how a head that moves mid-read is
  # modelled. `fail_api` makes every contents read fail.
  def fake_gh(pr_state: "OPEN", pr_base: "main", pr_head: HEAD, final_head: nil,
              contents: DOCUMENTS, fail_api: false, fail_view: false)
    tree = contents.keys.group_by { |path| path.include?("/") ? "analysis" : "root" }
    payloads = contents.to_h { |path, body| [ path, Base64.strict_encode64(body) ] }
    path = File.join(@dir, "gh")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      LOG = #{@log.inspect}
      File.open(LOG, "a") { |f| f.puts ARGV.join(" ") }
      views = File.read(LOG).lines.count { |l| l.start_with?("pr view") }

      if ARGV[0] == "pr" && ARGV[1] == "view"
        exit 1 if #{fail_view}
        head = (views > 1 && #{final_head.inspect}) ? #{final_head.inspect} : #{pr_head.inspect}
        puts({ "url" => #{PR_URL.inspect}, "state" => #{pr_state.inspect}, "headRefName" => "spec-branch",
               "headRefOid" => head, "baseRefName" => #{pr_base.inspect}, "isDraft" => true,
               "isCrossRepository" => false }.to_json)
        exit 0
      end

      if ARGV[0] == "api"
        exit 1 if #{fail_api}
        target = ARGV[1].to_s.sub("repos/#{SLUG}/contents/", "")
        root = #{(tree["root"] || []).inspect}
        nested = #{(tree["analysis"] || []).map { |p| p.split("/").last }.inspect}
        if target == #{FOLDER.inspect}
          entries = root.map { |n| { "name" => n, "type" => "file" } }
          entries << { "name" => "analysis", "type" => "dir" } unless nested.empty?
          puts entries.to_json
          exit 0
        end
        if target == #{"#{FOLDER}/analysis".inspect}
          puts nested.map { |n| { "name" => n, "type" => "file" } }.to_json
          exit 0
        end
        relative = target.sub("#{FOLDER}/", "")
        body = #{payloads.inspect}[relative]
        if body
          puts({ "encoding" => "base64", "content" => body }.to_json)
          exit 0
        end
        exit 1
      end
      exit 1
    RUBY
    File.chmod(0o755, path)
    @dir
  end

  def run_preflight(payload: assignment_payload, client:, **gh)
    bin = fake_gh(**gh)
    SpecrelayRunner::PackagePreflight::Execution.call(
      config: nil, client: client, payload: payload,
      env: { "PATH" => "#{bin}:#{ENV['PATH']}", "HOME" => @dir }, io: StringIO.new
    )
  end

  # A Platform that records what the runner sent and answers with a scripted verdict.
  class RecordingPlatform
    attr_reader :submissions

    def initialize(response) = (@response = response; @submissions = [])

    def submit_specification_package(claim:, package:)
      @submissions << package
      raise SpecrelayRunner::PlatformClient::Error, "refused" if @response == :error

      @response
    end
  end

  def gh_calls = File.exist?(@log) ? File.read(@log).lines.map(&:strip) : []

  # The runner carries no ActiveSupport, so `sole` is unavailable; the count is asserted
  # explicitly instead, which is what `sole` was standing in for.
  def only_submission(platform)
    assert_equal 1, platform.submissions.length, "expected exactly one submission"
    platform.submissions.first
  end

  # ---------------------------------------------------------------- S22

  def test_reads_every_package_file_at_the_exact_commit_and_submits_the_bytes
    platform = RecordingPlatform.new({ "authorized" => true, "manifest_digest" => "d" * 64,
                                       "assignment" => { "run" => { "id" => "run_1" } } })

    result = run_preflight(client: platform)

    assert result.authorized?, result.message
    submitted = only_submission(platform)
    assert_equal DOCUMENTS.keys.sort, submitted[:documents].map { |d| d[:path] }.sort
    DOCUMENTS.each do |path, body|
      entry = submitted[:documents].find { |d| d[:path] == path }
      assert_equal body, Base64.strict_decode64(entry[:content_base64]), path
    end
    # The bytes travel; a digest the RUNNER computed does not. Platform recomputes every one, so a
    # digest here could only be a value that looks authoritative and is not.
    refute submitted[:documents].any? { |d| d.key?(:digest) }
    assert_equal HEAD, submitted[:head_sha]
  end

  def test_reads_content_by_commit_sha_and_never_by_the_branch_name
    run_preflight(client: RecordingPlatform.new({ "authorized" => true }))

    content_calls = gh_calls.select { |line| line.start_with?("api") }
    refute_empty content_calls
    content_calls.each do |line|
      assert_includes line, "ref=#{HEAD}", "every content read must be pinned to the commit"
      refute_includes line, "spec-branch", "a package must never be read by a moving branch name"
    end
  end

  # ---------------------------------------------------------------- S09

  def test_refuses_when_the_remote_head_is_not_the_published_commit
    platform = RecordingPlatform.new({ "authorized" => false })

    result = run_preflight(client: platform, pr_head: MOVED)

    assert result.refused?
    refute result.authorized?
    assert_equal "package_stale", only_submission(platform)[:refusal]
    # Nothing was read: the head check comes before the first content call.
    assert_empty gh_calls.select { |line| line.start_with?("api") }
  end

  def test_refuses_a_closed_pull_request_and_a_wrong_base
    %w[CLOSED MERGED].each do |state|
      setup
      platform = RecordingPlatform.new({ "authorized" => false })
      assert run_preflight(client: platform, pr_state: state).refused?
      assert_equal "github_unreadable", only_submission(platform)[:refusal]
    end

    setup
    platform = RecordingPlatform.new({ "authorized" => false })
    assert run_preflight(client: platform, pr_base: "develop").refused?
    assert_equal "github_unreadable", only_submission(platform)[:refusal]
  end

  # ---------------------------------------------------------------- S18

  def test_refuses_when_the_head_moves_between_the_first_and_final_read
    platform = RecordingPlatform.new({ "authorized" => false })

    result = run_preflight(client: platform, final_head: MOVED)

    assert result.refused?
    submitted = only_submission(platform)
    assert_equal "github_unreadable", submitted[:refusal]
    # The package was read, but no documents are submitted: a package assembled either side of a
    # moving head is not a package.
    refute submitted.key?(:documents)
    assert_operator gh_calls.count { |l| l.start_with?("pr view") }, :>=, 2
  end

  # ---------------------------------------------------------------- S19

  def test_a_github_failure_is_a_retryable_refusal_that_launches_nothing
    platform = RecordingPlatform.new({ "authorized" => false })

    result = run_preflight(client: platform, fail_api: true)

    assert result.refused?
    refute result.authorized?
    assert_equal "github_unreadable", only_submission(platform)[:refusal]
  end

  def test_an_unreadable_pull_request_never_reads_the_package
    platform = RecordingPlatform.new({ "authorized" => false })

    assert run_preflight(client: platform, fail_view: true).refused?
    assert_empty gh_calls.select { |line| line.start_with?("api") }
  end

  def test_a_refusal_message_carries_no_credential
    platform = RecordingPlatform.new({ "authorized" => false })

    run_preflight(client: platform, fail_api: true)

    message = only_submission(platform)[:message].to_s
    refute_includes message, "ghp_"
    refute_includes message, "@github.com"
  end

  # ---------------------------------------------------------------- the file set

  def test_refuses_a_package_folder_that_does_not_hold_the_expected_file_set
    platform = RecordingPlatform.new({ "authorized" => false })

    result = run_preflight(client: platform, contents: DOCUMENTS.except("analysis/business.md"))

    assert result.refused?
    assert_equal "package_file_set_mismatch", only_submission(platform)[:refusal]
  end

  def test_refuses_an_extra_file_the_publication_never_recorded
    platform = RecordingPlatform.new({ "authorized" => false })

    result = run_preflight(client: platform, contents: DOCUMENTS.merge("notes.md" => "# extra\n"))

    assert result.refused?
    assert_equal "package_file_set_mismatch", only_submission(platform)[:refusal]
  end

  # ---------------------------------------------------------------- the assignment itself

  def test_refuses_an_assignment_whose_head_is_not_a_full_commit_sha
    result = run_preflight(client: RecordingPlatform.new({}), payload: assignment_payload(head: "main"))

    refute result.authorized?
    assert_empty gh_calls
  end

  def test_recognises_a_preflight_assignment_only_by_its_explicit_kind
    assert SpecrelayRunner::PackagePreflight::Assignment.preflight?(assignment_payload)
    refute SpecrelayRunner::PackagePreflight::Assignment.preflight?(assignment_payload.merge("assignment_kind" => "other"))
    refute SpecrelayRunner::PackagePreflight::Assignment.preflight?({ "run" => { "id" => "x" } })
  end

  # ---------------------------------------------------------------- the provider gate

  def test_only_an_authorized_response_permits_execution
    accepted = SpecrelayRunner::PackagePreflight::Execution::Result.new(outcome: :authorized)
    %i[refused failed].each do |outcome|
      refute SpecrelayRunner::PackagePreflight::Execution::Result.new(outcome: outcome).authorized?
    end

    assert accepted.authorized?
  end

  def test_platform_accepting_without_authorizing_launches_nothing
    platform = RecordingPlatform.new({ "authorized" => false, "outcome" => "accepted_pending_jira" })

    result = run_preflight(client: platform)

    refute result.authorized?, "a pin without a Jira transition must not launch a provider"
    assert_nil result.assignment_payload
  end

  def test_a_platform_error_leaves_the_run_unlaunched
    result = run_preflight(client: RecordingPlatform.new(:error))

    refute result.authorized?
    assert_match(/preflight_failed/, result.message)
  end
end
