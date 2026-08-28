# frozen_string_literal: true

require_relative "test_helper"
require "json"

# MAPIAI-97 CR-006 — a private host path is private on the preview channel too.
#
# CR-005 made every project-owned lifecycle verb stream its raw output, which is what the Product
# Owner asked for. The project's own commands name the machine they run on: `create` prints the
# directory it made, and `status --json` reports a `worktree_path` for every repository. The closed
# wire-status document drops those fields deliberately — streaming the raw command output walked
# straight past that projection and onto an authenticated page.
#
# The roots below are FIXTURES, not this machine's directories: the rule decides on path TEXT, so
# nothing here needs to exist and the assertions hold identically on macOS and Linux.
class PreviewPathPrivacyTest < Minitest::Test
  TASK = "MAPIAI-97-privacy"
  URL_A = "https://github.com/SpecRelay/component-a/pull/21"
  # The existing placeholder, already used by the specification analyzer.
  PLACEHOLDER = "[PRIVATE_PATH_REDACTED]"

  HOST_ROOT = "/Users/person/project/.specrelay-runs/worktree/environments/#{TASK}/workspace"
  # The same machine, owned by somebody whose account name has a space in it. `status --json`
  # quotes the value either way, so the document is identical apart from where it ends (CR-007 F8).
  SPACED_ROOT = "/Users/Jane Doe/My Project/environments/#{TASK}/workspace"

  ACTIVE = { "state" => "active", "cancel_requested" => false }.freeze
  CANCELLED = { "state" => "cancelled", "cancel_requested" => true }.freeze

  class FakeClient
    attr_reader :results, :events

    def initialize(after: nil, on_result: nil)
      @after = after
      @on_result = on_result
      @results = []
      @events = []
      @triggered = false
    end

    def submit_protocol_event(claim:, event:)
      @events << event
      { "recorded" => true, "lease" => { "state" => "active", "cancel_requested" => false } }
    end

    def heartbeat(claim:) = { "lease" => @triggered ? CANCELLED : ACTIVE }

    def submit_preview_result(claim:, result:)
      @results << result
      @triggered = true if @after && result[:kind] == @after
      @on_result&.call(result)
      { "accepted" => true }
    end
  end

  class FakeGitHubReader
    def initialize(answers) = (@answers = answers)
    def pull_request(root:, slug:, url:, env:) = @answers[url]
  end

  class Ticker
    def sleep(_seconds) = Kernel.sleep(0.02)
  end

  def setup
    @workspace = PreviewWorkspace.build(components: %w[component-a])
    @head = PreviewWorkspace.pull_request_head(@workspace.root, "component-a", "alpha")
    @workspace.status!(PreviewWorkspace.status_document(TASK))
    @io = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@workspace.root)
  rescue SystemCallError
    nil
  end

  def payload
    { "contract_version" => "mapiai-97", "assignment_kind" => "task_preview",
      "claim" => { "execution_id" => "rex_abc", "claimed_at" => nil, "lease_expires_at" => nil },
      "preview" => { "id" => "prv_abc", "ticket_key" => "MAPIAI-97", "project_slug" => "tiny-demo",
                     "task_id" => TASK, "canonical_branch" => TASK },
      "workspace" => { "key" => "multi-demo-workspace", "repository_url" => nil, "default_branch" => "main" },
      "sources" => [ { "repository" => "SpecRelay/component-a", "pull_request_url" => URL_A } ] }
  end

  def session(client)
    SpecrelayRunner::PreviewSession.call(
      payload: payload, client: client, root: @workspace.root, io: @io, env: {},
      heartbeat_seconds: 1, sleeper: Ticker.new,
      github: FakeGitHubReader.new(URL_A => { "state" => "OPEN", "headRefName" => "pr",
                                              "headRefOid" => @head, "isCrossRepository" => false })
    )
  end

  # Everything the operator's own terminal saw, and everything Platform was sent. Proving BOTH is
  # the point: they are two presentations of one line, and a fix that cleaned only the uploaded
  # copy would still print the path on the machine's own screen.
  def wire(client)
    client.events.select { |event| event["event_type"] == "log.chunk" }
          .map { |event| event["sanitized_log_chunk"].to_s }.join("\n")
  end

  def local = @io.string

  def refute_private(client, path)
    refute_includes wire(client), path, "the path reached Platform"
    refute_includes local, path, "the path reached the operator's own terminal"
  end

  # ---- requirement 1: the create command names the directory it made ----------------------

  def test_a_host_path_printed_by_create_reaches_neither_surface
    @workspace.leak!("create", "created #{HOST_ROOT}\n")
    client = FakeClient.new(after: "started")

    assert session(client), local

    refute_private(client, HOST_ROOT)
    refute_private(client, "/Users/person")
    assert_includes wire(client), "created #{PLACEHOLDER}"
    assert_includes local, "created #{PLACEHOLDER}"
    # The two surfaces are one line rendered twice. Every byte Platform was sent is a byte the
    # operator's own terminal showed, so there is no sanitized copy and unsanitized original.
    wire(client).lines.map(&:chomp).reject(&:empty?).each do |line|
      assert_includes local, line, "Platform received a line the terminal never showed"
    end
  end

  # ---- requirement 2: the rich status document, and the projection that survives it -------

  def test_the_status_documents_worktree_path_is_sanitized_without_breaking_the_projection
    document = PreviewWorkspace.status_document(TASK)
    document["repositories"] = [ { "repository" => "component-a", "worktree_path" => "#{HOST_ROOT}/component-a",
                                   "dirty" => false },
                                 { "repository" => "component-b", "worktree_path" => "#{SPACED_ROOT}/component-b",
                                   "dirty" => false } ]
    @workspace.status!(document)
    client = FakeClient.new(after: "started")

    assert session(client), local

    refute_private(client, HOST_ROOT)
    # A spaced path is one path: no part of it may be left standing beside the placeholder.
    [ "Jane", "Doe", "My Project" ].each { |fragment| refute_private(client, fragment) }
    assert_includes wire(client), "\"worktree_path\":\"#{PLACEHOLDER}\"",
                    "the raw status line must still read as the document it is"
    # The CAPTURED json — untouched — still produces the same closed projection and links.
    started = client.results.find { |result| result[:kind] == "started" }

    assert_equal %w[contract_version task_id state primary_url services], started[:status].keys
    assert_equal [ "http://127.0.0.1:5173" ], started[:status]["services"].map { |s| s["url"] }
    assert_equal "http://127.0.0.1:5173", started[:status]["primary_url"]
  end

  # ---- requirement 3: release, on both streams, while stopping ---------------------------

  def test_release_output_on_both_streams_is_sanitized_including_a_failed_release
    @workspace.leak!("release", "removing #{HOST_ROOT}\n")
    @workspace.leak_stderr!("release", "could not remove #{HOST_ROOT}/component-a\n")
    @workspace.fail!("release")
    # The first release is refused, so the operator retries; the second succeeds.
    client = FakeClient.new(after: "started",
                            on_result: ->(result) { @workspace.succeed! if result[:kind] == "release_failed" })

    assert session(client), local
    refute_private(client, HOST_ROOT)
    assert_includes wire(client), "removing #{PLACEHOLDER}"
    assert_includes wire(client), "could not remove #{PLACEHOLDER}"
  end

  # The bounded reason a failed release reports is queued and rendered like any other line, so it
  # is the same boundary wearing a different name.
  def test_a_failure_reason_built_from_command_output_carries_no_host_path
    @workspace.leak_stderr!("up", "cannot start: #{HOST_ROOT}/compose.yaml is unreadable\n")
    @workspace.fail!("up")
    # The failure owns cleanup, so the claim holds until Stop; the lease flips once it is reported.
    client = FakeClient.new(after: "failed",
                            on_result: ->(result) { @workspace.succeed! if result[:kind] == "failed" })

    assert session(client), local

    failure = client.results.find { |result| result[:kind] == "failed" }

    refute_includes failure[:reason].to_s, "/Users/person"
    assert_includes failure[:reason].to_s, PLACEHOLDER
    refute_private(client, HOST_ROOT)
  end

  # ---- CR-008 F9: a fragment that is not a path, at the session boundary -------------------

  # `ExecutorLogStream` clips every callback at 2,000 bytes, which hides what the sanitizer did to
  # the middle of a long fragment. So this asserts the two things clipping cannot hide: a path-free
  # fragment gained no privacy placeholder, and the operational text that followed it survived.
  def test_a_path_free_fragment_gains_no_placeholder_and_keeps_the_text_that_follows_it
    bound = SpecrelayRunner::CommandRunner::MAX_PENDING_LINE_BYTES
    @workspace.split!("up", "A" * bound, "compose project srt-mapiai-97 is starting")
    client = FakeClient.new(after: "started")

    assert session(client), local

    [ phase(wire(client), "up"), phase(local, "up") ].each do |text|
      assert_includes text, "[line clipped", "the fragment never crossed the reader's bound"
      refute_includes text, PLACEHOLDER, "a path-free fragment was treated as private"
      assert_includes text, "compose project srt-mapiai-97 is starting"
    end
  end

  # One project command's own output, from its narration line to the next command's.
  def phase(text, verb)
    text[/bin\/worktree #{verb}\b.*?(?=bin\/worktree |\z)/m].to_s
  end

  # ---- requirement 6: the reader's bounded partial-line fallback --------------------------

  # `CommandRunner` delivers a single over-long line in bounded pieces. A path straddling that cut
  # is present in NEITHER piece as a whole token, so sanitizing each piece independently would let
  # the tail of a username through.
  def test_a_path_split_by_the_readers_bounded_fallback_leaks_neither_half
    bound = SpecrelayRunner::CommandRunner::MAX_PENDING_LINE_BYTES
    # The first piece is over the bound, so the reader delivers it alone — ending PART-WAY through
    # the username. The second piece carries the rest, and on its own matches no path pattern.
    @workspace.split!("up", "#{'x' * bound}/Users/per", "son/project/secret-place")
    client = FakeClient.new(after: "started")

    assert session(client), local

    assert_operator wire(client).scan("[line clipped").length, :>=, 1,
                    "the reader never took its bounded fallback, so this example proves nothing"
    refute_private(client, "son/project/secret-place")
    refute_private(client, "/Users/per")
  end
end
