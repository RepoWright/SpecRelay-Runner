# frozen_string_literal: true

require_relative "test_helper"

# MAPIAI-97 — the claim that holds a preview open, and the heartbeat that carries Stop back.
#
# The point of these examples is that the claim does NOT end when the application starts. It ends
# when the environment is gone, and the only thing that can end it is the machine holding it. So
# what is proved here is the whole arc: report, hold, obey Stop, release — and, when the lease is
# lost instead, decline to invent a cleanup nobody recorded.
class PreviewSessionTest < Minitest::Test
  TASK = "MAPIAI-97-session"
  URL_A = "https://github.com/SpecRelay/component-a/pull/21"

  ACTIVE = { "state" => "active", "cancel_requested" => false }.freeze
  CANCELLED = { "state" => "cancelled", "cancel_requested" => true }.freeze
  EXPIRED = { "state" => "expired", "cancel_requested" => false }.freeze

  # Answers heartbeats and records every result posted.
  #
  # The lease changes AFTER a named result arrives, never after a duration: an operator presses
  # Stop because they saw the preview become available, and ordering the test on that fact rather
  # than on a clock is what keeps it from racing a slow `git worktree add`.
  class FakeClient
    attr_reader :results, :events, :beats

    def initialize(after: nil, then_lease: CANCELLED, on_result: nil, stop_at_once: false)
      @after = after
      @then_lease = then_lease
      @on_result = on_result
      @results = []
      @events = []
      # Every heartbeat is announced, so a test can BLOCK until one has happened rather than
      # sleep until one probably has.
      @beats = Queue.new
      @triggered = stop_at_once
    end

    def submit_protocol_event(claim:, event:)
      @events << event
      { "recorded" => true, "lease" => { "state" => "active", "cancel_requested" => false } }
    end

    def heartbeat(claim:)
      @beats << true
      { "lease" => @triggered ? @then_lease : ACTIVE }
    end

    def submit_preview_result(claim:, result:)
      @results << result
      @triggered = true if @after && result[:kind] == @after
      @on_result&.call(result)
      { "accepted" => true }
    end

    # Withdraws the Stop this client has been repeating. A claim that could not finish its cleanup
    # waits for the NEXT Stop, so a test that wants to observe that wait has to stop asking for
    # one — otherwise the same refused release repeats for as long as the example runs.
    def stop_signalling! = @triggered = false
  end

  # A stand-in for the subordinate tunnel. The child process itself is proved in
  # `secure_preview_tunnel_test.rb`; what these examples are about is the ORDER the claim imposes
  # on it — ready only after the application is available, stopped before the project-owned
  # release, and one honest report either way.
  class FakeTunnel
    attr_reader :preview_id, :namespace, :services, :verbs_at_stop

    def initialize(factory, preview_id, namespace, services)
      @factory = factory
      @preview_id = preview_id
      @namespace = namespace
      @services = services
      @running = true
    end

    def start
      @factory.started = true
      return SpecrelayRunner::SecurePreviewTunnel::Result.new(ok: true) if @factory.starts

      SpecrelayRunner::SecurePreviewTunnel::Result.new(ok: false, reason: @factory.reason)
    end

    def running? = @running && !@factory.exits
    def stop
      # Only the FIRST stop is recorded: the claim asks once on the release path and once more as
      # it ends, and it is the first that has to have happened before the release ran.
      @verbs_at_stop ||= @factory.observer&.call
      @running = false
      @factory.stops
    end
  end

  # Answers `new` exactly as the product's tunnel class does, so the session is wired the way it is
  # in production and the example keeps hold of the child it created.
  class TunnelFactory
    attr_reader :starts, :stops, :exits, :reason, :observer, :made
    attr_accessor :started

    def initialize(starts: true, stops: true, exits: false, observer: nil,
                   reason: "the secure preview tunnel would not start")
      @starts = starts
      @stops = stops
      @exits = exits
      @observer = observer
      @reason = reason
    end

    def new(preview_id:, namespace:, services:, env:)
      @env = env
      @made = FakeTunnel.new(self, preview_id, namespace, services)
    end
  end

  class FakeGitHubReader
    def initialize(answers) = (@answers = answers)
    def pull_request(root:, slug:, url:, env:) = @answers[url]
  end

  # Short real sleeps rather than none: the heartbeat runs in its own thread, and a sleeper that
  # returned instantly would spin against it instead of waiting for it.
  class Ticker
    def sleep(_seconds) = Kernel.sleep(0.02)
  end

  # Holds the pull-request read OPEN until the test says otherwise. This is the barrier the F1
  # examples are built on: while it is held, the claim is doing slow remote work and nothing else,
  # which is exactly the window in which the lease used to lapse unobserved.
  class BlockingGitHubReader
    attr_reader :entered

    def initialize(answer)
      @answer = answer
      @entered = Queue.new
      @released = Queue.new
    end

    def pull_request(root:, slug:, url:, env:)
      @entered << true
      @released.pop
      @answer
    end

    def unblock = @released << true
  end

  # A terminal that is also a barrier. Every line is queued as it is written, so a test can wait
  # for a specific line instead of polling the buffer — and because the heartbeater records its
  # stop reason BEFORE it logs one, seeing that line proves the stop was recorded.
  class WatchingIo < StringIO
    attr_reader :lines

    def initialize(*args)
      super
      @lines = Queue.new
    end

    def puts(*args)
      super
      args.flatten.each { |line| @lines << line.to_s }
    end
  end

  # Waits for one line, or gives up. Returning nil rather than hanging is what makes the red
  # version of these examples a readable failure instead of a stuck suite.
  def await_line(io, fragment, timeout: 15)
    loop do
      line = io.lines.pop(timeout: timeout)
      return nil if line.nil?
      return line if line.include?(fragment)
    end
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

  def payload(**overrides)
    { "contract_version" => "3", "assignment_kind" => "task_preview",
      "claim" => { "execution_id" => "rex_abc", "claimed_at" => nil, "lease_expires_at" => nil },
      "preview" => { "id" => "prv_abc", "ticket_key" => "MAPIAI-97", "project_slug" => "tiny-demo",
                     "task_id" => TASK, "canonical_branch" => TASK, "mode" => "start" },
      "workspace" => { "key" => "multi-demo-workspace", "repository_url" => nil, "default_branch" => "main" },
      "secure_preview" => { "route_namespace" => "7c1d4a90e3b25f6108ad4c3b2e59f071" },
      "sources" => [ { "repository" => "SpecRelay/component-a", "pull_request_url" => URL_A } ] }
      .merge(overrides)
  end

  def open_pull_request = { "state" => "OPEN", "headRefName" => "pr", "headRefOid" => @head,
                            "isCrossRepository" => false }

  def session(client, document = payload, github: FakeGitHubReader.new(URL_A => open_pull_request),
              io: @io, tunnel: tunnels, env: {})
    SpecrelayRunner::PreviewSession.call(
      payload: document, client: client, root: @workspace.root, io: io, env: env,
      heartbeat_seconds: 1, sleeper: Ticker.new, github: github, tunnel: tunnel
    )
  end

  def tunnels(**options) = @tunnels ||= TunnelFactory.new(**options)

  def kinds(client) = client.results.map { |result| result[:kind] }

  def chunks(client)
    client.events.select { |event| event["event_type"] == "log.chunk" }
          .flat_map { |event| event["sanitized_log_chunk"].to_s.lines.map(&:chomp) }
  end

  def test_the_claim_is_held_open_after_the_application_starts_and_released_on_stop
    client = FakeClient.new(after: "started")

    assert session(client), @io.string

    assert_equal %w[sources started secure_preview_ready released], kinds(client)
    assert_equal %w[contract_version task_id state primary_url services],
                 client.results[1][:status].keys
    assert_equal %w[create up status release], @workspace.verbs
  end

  # The startup output travels the ordered protocol-event stream every other lane uses, with no
  # run id: a preview claim has none, and the contract requires the field to be absent rather
  # than invented.
  def test_startup_output_reaches_the_ordered_event_stream_with_no_run_id
    client = FakeClient.new(after: "started")

    assert session(client), @io.string

    log = client.events.select { |event| event["event_type"] == "log.chunk" }
    chunks = log.map { |event| event["sanitized_log_chunk"].to_s }.join("\n")

    refute_empty log, "no startup output reached the event stream"
    # The project's own output, and the argv this runner observed. The RUNNER'S OWN narration is
    # what must carry no local path: where the project's checkout lives is a Runner concern, and
    # the argv line is the only line this runner writes. What the project itself prints is the
    # project's own output and travels raw, which is the whole of MAPIAI-97 section 4.
    assert_includes chunks, "starting #{TASK}"
    assert_includes chunks, "bin/worktree up #{TASK}"
    narration = chunks.lines.map(&:chomp).grep(/\Abin\/worktree /)

    refute_empty narration
    narration.each { |line| refute_includes line, @workspace.root }
    assert_equal [ nil ], client.events.map { |event| event["run_id"] }.uniq
    assert_equal [ "rex_abc" ], client.events.map { |event| event["attempt_id"] }.uniq
    sequences = client.events.map { |event| event["sequence"] }

    assert_equal sequences.sort, sequences
  end

  # The release the project refused is reported as failed, the claim keeps the machine, and the
  # operator's Retry is a second Stop on the SAME claim rather than a new one.
  def test_a_refused_release_is_reported_and_retried_on_the_same_claim
    @workspace.fail!("release")
    client = FakeClient.new(after: "started",
                            on_result: ->(result) { @workspace.succeed! if result[:kind] == "release_failed" })

    assert session(client), @io.string

    assert_equal %w[sources started secure_preview_ready release_failed released], kinds(client)
    assert_equal %w[create up status release release], @workspace.verbs
  end

  # A lease this runner no longer holds is not a Stop. Releasing on it would be a cleanup nobody
  # recorded — so it stops, and says what Platform will do about it instead.
  def test_a_lost_lease_never_fabricates_a_release
    client = FakeClient.new(after: "started", then_lease: EXPIRED)

    refute session(client)

    assert_equal %w[sources started secure_preview_ready], kinds(client)
    assert_equal %w[create up status], @workspace.verbs
    assert_includes @io.string, "handed back for release"
    refute_includes @io.string, "bin/worktree release #{TASK}"
  end


  # ---- The release Platform hands back on reconnect -------------------------------------

  # `call` runs `execution.start` unconditionally, so a release assignment that did not branch
  # would resolve the pull requests and rebuild the very environment it was sent to delete.
  # Nothing is held afterwards: the lease is already gone and there is no signal to wait on.
  def test_a_release_assignment_runs_only_the_project_owned_release
    client = FakeClient.new

    assert session(client, release_payload), @io.string

    assert_equal [ "released" ], client.results.map { |result| result[:kind] }
    assert_equal %w[release], @workspace.verbs
    assert client.beats.empty?, "a release assignment started a heartbeater"
  end

  # An honest report is a successful claim. The obligation persists on Platform and the identical
  # assignment returns on the next poll, so there is nothing for this process to retry.
  def test_a_refused_release_is_reported_and_still_exits_zero
    @workspace.fail!("release")
    client = FakeClient.new

    assert session(client, release_payload), @io.string

    assert_equal [ "release_failed" ], client.results.map { |result| result[:kind] }
    assert_equal %w[release], @workspace.verbs
  end

  def release_payload = payload("preview" => payload["preview"].merge("mode" => "release"))


  # ---- F1: the lease is this claim's responsibility from the moment it is bound ----------

  # The claim's FIRST slow work is a remote read, and it happens before a single local command.
  # Until CR-005 the beater was created lazily by the execution's own stop check, which is
  # reached only AFTER that read returns — so a GitHub call that hung outlived the lease on a
  # machine that was perfectly healthy. The barrier holds the read open and the queue proves the
  # lease was renewed while it was held.
  def test_the_lease_is_renewed_while_the_pull_request_read_is_blocked
    client = FakeClient.new(after: "started")
    reader = BlockingGitHubReader.new(open_pull_request)
    claim = Thread.new { session(client, github: reader) }

    reader.entered.pop
    first = client.beats.pop(timeout: 15)
    second = client.beats.pop(timeout: 15)
    reader.unblock

    assert claim.value, @io.string
    assert first, "the lease was never renewed while the pull-request read was blocked"
    assert second, "the lease was renewed once and then stopped while the read was still blocked"
    assert_equal %w[create up status release], @workspace.verbs
  end

  # Stop delivered through that same heartbeat, while the read is still open. The barrier is
  # released only after the beater has RECORDED the stop — it logs that line from inside the same
  # method that sets the reason — so this orders on a fact rather than on a duration.
  #
  # Afterwards: not one project-owned command ran, and the claim answered the only honest terminal
  # result for an environment that was never created.
  def test_a_stop_during_the_pull_request_read_runs_no_command_and_releases_once
    client = FakeClient.new(stop_at_once: true)
    reader = BlockingGitHubReader.new(open_pull_request)
    io = WatchingIo.new
    claim = Thread.new { session(client, github: reader, io: io) }

    reader.entered.pop
    signalled = await_line(io, "no longer live")
    reader.unblock
    held = claim.value

    assert signalled, "Stop was never observed while the pull-request read was blocked"
    assert held, io.string
    assert_equal [], @workspace.verbs, "a stopped preview ran a project-owned command"
    assert_equal %w[sources released], client.results.map { |result| result[:kind] }
    assert_equal 1, client.results.count { |result| result[:kind] == "released" }
  end

  # ---- the subordinate tunnel, and the order the claim imposes on it ---------

  # It is started only AFTER the application is available, from the snapshot the project's own
  # status command reported, inside the namespace the assignment carried. Nothing else reaches it:
  # no hostname, no port, no zone and no credential travel in the assignment at all.
  def test_the_tunnel_is_started_after_the_application_is_available_and_only_from_the_validated_snapshot
    client = FakeClient.new(after: "started")

    assert session(client), @io.string

    assert_equal %w[sources started secure_preview_ready released], kinds(client)
    child = tunnels.made

    assert_equal "prv_abc", child.preview_id
    assert_equal "7c1d4a90e3b25f6108ad4c3b2e59f071", child.namespace
    # The OPENABLE services only, exactly as Platform stored them: the internal database the
    # project also reports has no browser url and is not published.
    assert_equal [ "dashboard" ], child.services.map { |service| service["service"] }
    assert_equal [ "http://127.0.0.1:5173" ], child.services.map { |service| service["url"] }
    assert_equal({ kind: "secure_preview_ready" }, client.results[2])
  end

  # A tunnel that will not start is ONE bounded report and nothing else. The preview stays
  # available, the machine stays reserved, the Stop control still works, and no retry happens.
  def test_a_tunnel_that_will_not_start_is_one_bounded_failure_that_leaves_the_preview_running
    @tunnels = TunnelFactory.new(starts: false)
    client = FakeClient.new(after: "secure_preview_failed")

    assert session(client), @io.string

    assert_equal %w[sources started secure_preview_failed released], kinds(client)
    assert_equal 1, kinds(client).count("secure_preview_failed")
    assert_equal "the secure preview tunnel would not start", client.results[2][:reason]
    assert_equal %w[create up status release], @workspace.verbs
  end

  # A child that exits while a person is testing is reported once, on the same claim. The wait
  # carries on: the environment is still there and this machine still owes its release.
  def test_a_tunnel_that_exits_while_a_person_is_testing_is_reported_exactly_once
    @tunnels = TunnelFactory.new(exits: true)
    client = FakeClient.new(after: "secure_preview_failed")

    assert session(client), @io.string

    assert_equal %w[sources started secure_preview_ready secure_preview_failed released], kinds(client)
    assert_equal "the secure preview tunnel exited", client.results[3][:reason]
  end

  # THE ordering rule. The tunnel is accounted for BEFORE the project-owned release runs, because
  # releasing a worktree out from under a process still publishing it is the one state nobody can
  # reason about afterwards.
  def test_the_tunnel_is_stopped_before_the_project_owned_release_runs
    @tunnels = TunnelFactory.new(observer: -> { @workspace.verbs.dup })
    client = FakeClient.new(after: "started")

    assert session(client), @io.string

    assert_equal %w[create up status], tunnels.made.verbs_at_stop
    assert_equal %w[create up status release], @workspace.verbs
  end

  # A shutdown that cannot be accounted for leaves the EXISTING release obligation exactly where
  # it was: the project-owned release does not run, and the same claim re-offers it on the next
  # Stop rather than inventing a second cleanup path.
  def test_a_tunnel_that_cannot_be_stopped_keeps_the_release_obligation_and_runs_no_release
    @tunnels = TunnelFactory.new(stops: false)
    client = nil
    client = FakeClient.new(after: "started",
                            on_result: ->(r) { client.stop_signalling! if r[:kind] == "release_failed" })
    io = WatchingIo.new
    claim = Thread.new { session(client, io: io) }

    assert await_line(io, "could not be stopped"), io.string
    assert_equal %w[create up status], @workspace.verbs, "the project-owned release ran anyway"
    assert_includes kinds(client), "release_failed"
    refute_includes kinds(client), "released"
    claim.kill
  end

  # The release Platform hands back on reconnect performs the SAME ordering, and it is the case
  # that needs it most: this process spawned nothing, so any child still publishing the
  # environment was left by a runner process that has since died. The tunnel is asked to account
  # for that child BEFORE the project-owned release runs.
  def test_a_release_assignment_accounts_for_a_remaining_tunnel_before_the_release_only_path
    @tunnels = TunnelFactory.new(observer: -> { @workspace.verbs.dup })
    client = FakeClient.new

    assert session(client, release_payload), @io.string

    child = tunnels.made

    refute_nil child, "the reconnect release never asked about a remaining tunnel"
    assert_equal "prv_abc", child.preview_id, "the question was not bound to this attempt"
    assert_equal [], child.verbs_at_stop, "the project-owned release ran first"
    assert_equal [ "released" ], kinds(client)
    assert_equal %w[release], @workspace.verbs
  end

  # And a child it cannot account for keeps the EXISTING obligation on the reconnect path exactly
  # as on the start path: no project-owned release, and the same assignment returns on the next
  # poll rather than a second cleanup path being invented for it.
  def test_a_release_assignment_that_cannot_account_for_a_remaining_tunnel_runs_no_project_release
    @tunnels = TunnelFactory.new(stops: false)
    client = FakeClient.new

    assert session(client, release_payload), @io.string

    assert_equal [ "release_failed" ], kinds(client)
    assert_equal "the secure preview tunnel could not be stopped", client.results.first[:reason]
    assert_equal [], @workspace.verbs, "the project-owned release ran anyway"
  end

  # The two owners composed, with the REAL tunnel rather than a stand-in: state left by a previous
  # runner process that this machine cannot make sense of. The session does not interpret it — it
  # fences the project-owned release on the answer, reports the obligation, and the evidence stays
  # on disk for the retry.
  def test_a_reconnect_release_fences_the_project_command_on_state_it_cannot_account_for
    home = Dir.mktmpdir("preview-session-tunnel-state")
    attempt = SpecrelayRunner::SecurePreviewTunnel.new(
      preview_id: payload["preview"]["id"], namespace: "n", services: [], env: { "HOME" => home }
    ).state_directory
    FileUtils.mkdir_p(attempt)
    File.write(File.join(attempt, SpecrelayRunner::SecurePreviewTunnel::CONFIGURATION_FILE), "ingress: []\n")
    File.write(File.join(attempt, SpecrelayRunner::SecurePreviewTunnel::PID_FILE), "not-a-pid\n")
    client = FakeClient.new

    assert session(client, release_payload, tunnel: SpecrelayRunner::SecurePreviewTunnel,
                                            env: { "HOME" => home }), @io.string

    assert_equal [ "release_failed" ], kinds(client)
    assert_equal [], @workspace.verbs, "the project-owned release ran on state nobody could read"
    assert_path_exists File.join(attempt, SpecrelayRunner::SecurePreviewTunnel::PID_FILE),
                       "the evidence was discarded"
  ensure
    FileUtils.remove_entry(home) if home
  end

  # ---- F5: every project-owned command's raw output, not just `up` ----------------------

  # create, up, status and release each print, and all four belong to the operator watching the
  # page. Until CR-005 only `up` was wired to the stream, so the page went silent for exactly the
  # steps that take the longest and fail the most often.
  def test_every_project_owned_command_streams_its_raw_output
    client = FakeClient.new(after: "started")

    assert session(client), @io.string

    text = chunks(client).join("\n")

    assert_includes text, "created ", "the create command's own output never reached the stream"
    assert_includes text, "starting #{TASK}"
    assert_includes text, "\"compose_project\"", "the status document's own output never reached the stream"
    assert_includes text, "released #{TASK}", "the release output never reached the stream"
  end

  # Release happens after the operator pressed Stop, on the far side of the hold — a second live
  # window on the same claim and the same ordered stream, not a second transcript.
  def test_a_refused_release_streams_the_projects_own_stderr_while_stopping
    @workspace.fail!("release")
    client = FakeClient.new(after: "started",
                            on_result: ->(result) { @workspace.succeed! if result[:kind] == "release_failed" })

    assert session(client), @io.string

    text = chunks(client).join("\n")

    assert_includes text, "the project refused to release #{TASK}"
    assert_includes text, "released #{TASK}", "the retried release's output never reached the stream"
    sequences = client.events.map { |event| event["sequence"] }

    assert_equal sequences.sort, sequences, "the release window restarted the sequence"
  end


  # The raw stream is RAW, not unguarded. Whatever a project command prints travels verbatim
  # except for the one thing that must never leave this machine, and the redaction happens before
  # the line is printed locally as well as before it is queued for Platform.
  def test_a_secret_printed_by_a_project_command_never_reaches_the_stream
    @workspace.leak!("up", "exporting GITHUB_TOKEN=ghp_notarealtokenbutlooksexactlylikeone01\n")
    client = FakeClient.new(after: "started")

    assert session(client), @io.string

    text = chunks(client).join("\n")

    assert_includes text, "exporting [REDACTED]"
    refute_includes text, "ghp_notarealtokenbutlooksexactlylikeone01"
    refute_includes @io.string, "ghp_notarealtokenbutlooksexactlylikeone01"
  end

  def test_a_refused_assignment_is_reported_and_runs_no_command
    client = FakeClient.new

    refute session(client, payload("assignment_kind" => "run"))

    assert_equal [ "failed" ], client.results.map { |result| result[:kind] }
    assert_equal "invalid_assignment", client.results.first[:failure_kind]
    assert_equal false, client.results.first[:cleanup_required]
    assert_equal [], @workspace.verbs
  end

  # A failure before anything could be allocated frees the machine at once: there is no hold and
  # no release, because there is nothing to release.
  def test_a_clean_failure_ends_the_claim_without_holding_the_machine
    client = FakeClient.new
    closed = FakeGitHubReader.new(URL_A => { "state" => "CLOSED", "headRefName" => "pr",
                                             "headRefOid" => @head, "isCrossRepository" => false })

    held = SpecrelayRunner::PreviewSession.call(
      payload: payload, client: client, root: @workspace.root, io: @io, env: {},
      heartbeat_seconds: 1, sleeper: Ticker.new, github: closed
    )

    assert held
    assert_equal [ "failed" ], client.results.map { |result| result[:kind] }
    assert_equal "source_unavailable", client.results.first[:failure_kind]
    assert_equal [], @workspace.verbs
  end
end
