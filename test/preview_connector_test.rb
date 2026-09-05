# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# The loop session's own preview connector.
#
# A connected machine runs ONE outbound connector for as long as its loop is active, started from
# the connector token the guided connection already put in the operating system's secret store.
# The operator installs the program and supplies nothing else: no account credential, no
# credential file, no certificate, no tunnel name, no zone, no environment setting.
#
# Three properties are proved here, and the child is a REAL process in all of them.
#
# THE SECRET BOUNDARY. The token reaches the child through a private file and nothing else. The
# live process table is asked what the child was given, the child itself records what it found on
# disk, and neither the value nor the store it came from appears in argv, in the session's output,
# or in any file this class leaves behind.
#
# THE OWNERSHIP. One child per loop session: a second start reuses the one that is healthy, an
# unexpected exit is reported once and started again on the loop's own next poll, and every stop
# path — an ordinary end, a refusal, `SIGINT`, `SIGTERM` — leaves no child and no temporary state.
#
# THE REFUSAL. A machine with no stored connector, and a machine with no program to run, are told
# the one thing each has to do. Neither is told anything about the local secret store, and neither
# reaches a claim.
#
# `cloudflared` is not installed on a test machine, so the executable is a stand-in handed in
# through the same constructor argument the product uses — the spawn, the process group, the
# readiness probe, the shutdown and the file removal are all the real ones.
class PreviewConnectorTest < Minitest::Test
  Connector = SpecrelayRunner::PreviewConnector
  Loop = SpecrelayRunner::LoopRunner

  # The production program's file name. Every stand-in below really carries it.
  PROGRAM = Connector::EXECUTABLE

  RUNNER = "rnr_0f3a91c47b5e4d28"
  SECOND_RUNNER = "rnr_9b2c40de71a8f635"

  # A synthetic non-credential in the shape the guided connection stores. It authenticates
  # nothing, and it is the exact byte string the child is expected to find on disk.
  STORED_CONNECTOR = "cft_fake-loop-session-connector"

  # A readiness bound short enough that a stand-in which never answers costs a couple of seconds
  # rather than a minute, and long enough that a real spawn and a real HTTP round trip fit inside
  # it on a loaded machine.
  READY_SECONDS = 5

  def setup
    @root = Dir.mktmpdir("preview-connector-test")
    @connectors = []
    # Anything this test leaves under the machine's private temporary root is residue, so the
    # baseline is taken before the first start rather than assumed empty.
    @residue_before = residue
  end

  def teardown
    @connectors.each { |connector| connector.stopped }
    FileUtils.remove_entry(@root)
  rescue SystemCallError
    nil
  end

  # ---- one child, from the stored connector ---------------------------------------------

  def test_a_stored_connector_starts_exactly_one_child_that_becomes_ready
    connector = build

    assert_predicate connector.started, :ok?
    assert_equal 1, spawns(:ready).length
    assert alive?(child_pid(connector)), "the child must still be running once the start returns"
  end

  # The whole point of the slice: no account credential, no credential file, no certificate, no
  # tunnel name, no zone. The child is handed a metrics address to answer readiness on and a file
  # to read its token from, and nothing else.
  def test_the_launch_consults_no_account_authority_and_no_operator_authored_setting
    connector = build
    connector.started
    argv = record(:ready).fetch(:argv)

    assert_equal [ "tunnel", "--no-autoupdate", "--metrics" ], argv.first(3)
    assert_match(/\A127\.0\.0\.1:\d+\z/, argv[3])
    assert_equal [ "run", "--token-file", record(:ready).fetch(:path) ], argv.last(3)
    refute_includes argv, "--config"
    refute_includes argv, "--credentials-file"
    refute_includes argv, "--token"
  end

  # A runner-scoped lookup, proved by behaviour rather than by inspecting a call: the same value
  # stored under another machine's identity, or under this machine's DURABLE credential account,
  # starts nothing.
  def test_the_token_is_read_from_this_machines_own_connector_account_and_no_other
    refused = [ { "preview-connector:#{SECOND_RUNNER}" => STORED_CONNECTOR },
                { "runner:#{RUNNER}" => STORED_CONNECTOR } ]

    refused.each do |entries|
      outcome = build(entries: entries).started

      assert_predicate outcome, :stop?, "#{entries.keys.first} is not this machine's connector"
      assert_empty spawns(:ready), "nothing may be started for #{entries.keys.first}"
    end
  end

  # ---- the secret boundary ---------------------------------------------------------------

  # The live process table, which is what any other process running as this user can read.
  def test_the_running_childs_command_line_carries_the_file_path_and_never_the_token
    connector = build
    connector.started
    command_line = `ps -ww -o args= -p #{child_pid(connector)}`.to_s

    refute_includes command_line, STORED_CONNECTOR
    assert_includes command_line, "#{PROGRAM} tunnel "
    assert_includes command_line, "--token-file #{record(:ready).fetch(:path)}"
  end

  def test_the_token_file_is_private_and_carries_exactly_the_stored_value
    connector = build
    connector.started
    found = record(:ready)

    assert_equal "600", found.fetch(:mode)
    assert_equal "700", found.fetch(:directory_mode)
    assert_equal Digest::SHA256.hexdigest(STORED_CONNECTOR), found.fetch(:digest)
  end

  def test_the_token_file_lives_outside_every_repository_under_the_private_temporary_root
    connector = build
    connector.started

    assert record(:ready).fetch(:real_path).start_with?("#{File.realpath(Dir.tmpdir)}/")
    refute record(:ready).fetch(:real_path).start_with?("#{File.realpath(repository_root)}/")
  end

  # Readiness is the PROOF of acquisition: a connector that has registered a connection has
  # already read the token it registered with. So the file is gone the moment the start returns,
  # while the child it started keeps running.
  def test_the_token_file_is_removed_once_the_child_has_acquired_it
    connector = build

    assert_predicate connector.started, :ok?
    refute_path_exists record(:ready).fetch(:path)
    assert_empty new_residue, "no temporary directory may outlive the acquisition"
    assert alive?(child_pid(connector))
  end

  # ---- one child per session -------------------------------------------------------------

  def test_a_second_start_reuses_the_healthy_child_and_creates_no_second_process
    connector = build
    connector.started
    first = child_pid(connector)

    assert_predicate connector.started, :ok?
    assert_equal 1, spawns(:ready).length
    assert_equal first, child_pid(connector)
  end

  def test_nothing_is_restarted_while_the_child_is_healthy
    connector = build
    connector.started

    3.times { assert_predicate connector.restart_if_exited, :ok? }

    assert_equal 1, spawns(:ready).length
  end

  # ---- refusals --------------------------------------------------------------------------

  def test_a_machine_with_no_stored_connector_is_told_to_reconnect_and_starts_nothing
    outcome = build(entries: {}).started

    assert_predicate outcome, :stop?
    assert_includes outcome.remedy, "specrelay-runner connect"
    assert_empty spawns(:ready), "nothing may be spawned before the token is known"
    assert_empty new_residue
  end

  def test_a_machine_without_the_program_is_told_to_install_it
    outcome = build(executable: File.join(@root, "absent", PROGRAM)).started

    assert_predicate outcome, :stop?
    assert_match(/not installed/, outcome.message)
    assert_includes outcome.remedy, PROGRAM
    assert_empty new_residue, "a failed launch may leave no token file behind"
  end

  # A stand-in that runs and never answers is the shape of a rejected token: the process exists,
  # the connection never registers. It is ended, cleaned up, and reported in this class's own
  # words.
  def test_a_child_that_never_becomes_ready_is_ended_cleaned_and_reported_without_secret_text
    connector = build(behaviour: :silent, ready_seconds: 1)
    outcome = connector.started

    assert_predicate outcome, :stop?
    refute_includes outcome.message, STORED_CONNECTOR
    refute_match(/keychain|secret store|security/i, "#{outcome.message} #{outcome.remedy}")
    refute alive?(spawned_pid(:silent)), "the child that could not become ready must be gone"
    assert_empty new_residue
  end

  def test_a_child_that_exits_at_once_is_refused_and_leaves_nothing_behind
    outcome = build(behaviour: :exit).started

    assert_predicate outcome, :stop?
    assert_equal 1, spawns(:exit).length, "one attempt, not a retry loop"
    assert_empty new_residue
  end

  # ---- stopping ---------------------------------------------------------------------------

  def test_stopping_ends_the_child_and_removes_every_owned_temporary_directory
    connector = build
    connector.started
    pid = child_pid(connector)

    connector.stopped

    refute alive?(pid)
    assert_empty new_residue
  end

  def test_stopping_a_connector_that_never_started_is_a_harmless_no_op
    connector = build

    assert_nil connector.stopped
    assert_empty spawns(:ready)
  end

  # No pid file, no state document, no directory under the runner's own local state root: this
  # connector belongs to a running loop, so there is nothing for a later process to adopt and
  # nothing a reconnect has to account for.
  def test_the_connector_leaves_no_pid_file_or_local_state_for_a_later_process_to_adopt
    before = local_state
    connector = build
    connector.started
    connector.stopped

    assert_equal before, local_state
    assert_empty new_residue
  end

  # ---- the loop that owns it --------------------------------------------------------------

  def test_the_connector_starts_before_the_first_claim_poll
    connector = build
    order = []
    run_loop(connector: connector, claim: -> { order << :claim; not_claimed }, max_iterations: 1)

    assert_equal 1, spawns(:ready).length
    assert_equal [ :claim ], order
    assert_equal 1, File.readlines(record_path(:ready)).length
  end

  def test_a_refused_connector_ends_the_session_before_anything_is_claimed
    claims = 0
    status = run_loop(connector: build(entries: {}), claim: -> { claims += 1; not_claimed },
                      max_iterations: 3)

    assert_equal Loop::FAILED, status
    assert_equal 0, claims, "a machine that cannot run its connector must claim nothing"
    assert_includes output, "specrelay-runner connect"
  end

  # The loop's own poll interval is the cadence, so an exit is noticed once and answered once —
  # never in a spin, and never with a second child.
  def test_an_unexpected_exit_is_reported_once_and_started_again_on_the_next_poll
    connector = build
    polls = 0
    claim = lambda do
      polls += 1
      end_child!(connector) if polls == 2
      not_claimed
    end
    status = run_loop(connector: connector, claim: claim, max_iterations: 5)

    assert_equal Loop::OK, status
    assert_equal 2, spawns(:ready).length, "one restart, not one per poll"
    assert_equal 1, output.scan("preview connector stopped unexpectedly").size
  end

  def test_an_ordinary_loop_stop_ends_the_child_and_leaves_no_residue
    connector = build
    run_loop(connector: connector, max_iterations: 2)

    refute alive?(spawned_pid(:ready))
    assert_empty new_residue
  end

  # Real traps, a real signal, and a real child — the path a person actually takes to stop a
  # runner, and the one an in-theory-only test would miss.
  def test_a_real_interrupt_or_termination_ends_the_child_and_leaves_no_residue
    %w[INT TERM].each do |name|
      connector = build
      signal_on_first_sleep!(name)
      run_loop(connector: connector, max_iterations: 5, install_signals: true)

      refute alive?(spawned_pid(:ready)), "#{name} must leave no connector child"
      assert_empty new_residue, "#{name} must leave no temporary state"
      FileUtils.rm_f(record_path(:ready))
    end
  end

  def test_the_token_never_reaches_the_sessions_output
    run_loop(connector: build, max_iterations: 2)

    refute_includes output, STORED_CONNECTOR
    refute_match(/keychain|preview-connector:/i, output)
  end

  # The advanced/legacy `--config` invocation has no connection record, so it has no machine
  # identity to read a connector for and manages none.
  def test_a_loop_with_no_connection_record_manages_no_connector_at_all
    assert_predicate Connector::NONE.started, :ok?
    assert_predicate Connector::NONE.restart_if_exited, :ok?
    assert_nil Connector::NONE.stopped

    status = run_loop(connector: Connector::NONE, max_iterations: 2)

    assert_equal Loop::OK, status
    assert_empty residue
  end

  private

  attr_reader :output

  def build(behaviour: :ready, executable: nil, entries: nil, runner: RUNNER,
            ready_seconds: READY_SECONDS)
    connector = Connector.new(
      runner_public_id: runner,
      secret_store: FakeSecretStore.new(
        entries: entries || { "preview-connector:#{RUNNER}" => STORED_CONNECTOR }
      ),
      executable: executable || executable(behaviour),
      ready_timeout_seconds: ready_seconds,
      on_notice: ->(message) { @io&.puts("[loop] #{message}") }
    )
    @connectors << connector
    connector
  end

  def run_loop(connector:, claim: -> { not_claimed }, max_iterations: 1, install_signals: false)
    @io = StringIO.new
    @clock = FakeClock.new
    status = Loop.call(out: @io, err: @io, claim: claim, execute: ->(_payload) { true },
                       poll_seconds: 60, install_signals: install_signals,
                       max_iterations: max_iterations, sleeper: sleeper, clock: @clock,
                       connector: connector)
    @output = @io.string
    status
  end

  # Advances the injected monotonic clock rather than sleeping, so the loop's own wait is instant
  # while the connector's real readiness wait stays real.
  def sleeper
    lambda do |slice|
      @clock.advance(slice)
      pending = @pending_signal
      @pending_signal = nil
      pending&.call
      nil
    end
  end

  def signal_on_first_sleep!(name)
    @pending_signal = -> { Process.kill(name, Process.pid) }
  end

  class FakeClock
    def initialize = @now = 5_000.0
    def advance(seconds) = @now += seconds.to_f
    def clock_gettime(_id) = @now
  end

  def not_claimed
    SpecrelayRunner::PlatformClient::ClaimResult.new(claimed: false,
                                                     payload: { "reason" => "nothing eligible" })
  end

  def child_pid(connector) = connector.instance_variable_get(:@pid)

  # A process that was signalled but not yet reaped still answers `kill(0)`, so a test asking
  # "did this survive?" has to ask the process table: a zombie is a process that died.
  def alive?(pid)
    return false if pid.nil?

    state = `ps -o state= -p #{pid}`.to_s.strip
    !state.empty? && !state.start_with?("Z")
  end

  # Ends the child the way an unexpected exit ends it, and waits for the process table to agree
  # before returning — the connector's next poll must see a fact, not a race.
  def end_child!(connector)
    pid = child_pid(connector)
    Process.kill("KILL", -Process.getpgid(pid))
    deadline = monotonic + READY_SECONDS
    sleep(0.02) while alive?(pid) && monotonic < deadline
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def repository_root = File.expand_path("..", __dir__)

  # Every temporary directory this connector could still own, so "no residue" is asserted against
  # the machine's real private temporary root rather than against a path the test chose.
  def residue = Dir.glob(File.join(Dir.tmpdir, "#{Connector::TOKEN_DIRECTORY_PREFIX}*"))
  def new_residue = residue - @residue_before

  # The runner's own local state root, where the per-preview tunnel legitimately keeps a
  # configuration and a pid for a later process to adopt. This connector must add nothing here.
  def local_state = Dir.glob(File.join(Dir.home, ".specrelay", "runner", "**", "*")).sort

  # ---- the stand-in ------------------------------------------------------------------------

  # One directory per behaviour, holding a real program with the production file name and the
  # record it appends to on every launch.
  def stand_in_directory(behaviour) = File.join(@root, behaviour.to_s)
  def record_path(behaviour) = File.join(stand_in_directory(behaviour), "launches")

  def executable(behaviour)
    path = File.join(stand_in_directory(behaviour), PROGRAM)
    return path if File.exist?(path)

    FileUtils.mkdir_p(stand_in_directory(behaviour))
    File.write(path, STAND_IN.sub("INTERPRETER", RbConfig.ruby).gsub("BEHAVIOUR", behaviour.to_s))
    File.chmod(0o755, path)
    path
  end

  def spawns(behaviour)
    path = record_path(behaviour)
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  # What the child found when it started: what it was given, what it read, and how private the
  # file and its directory were at the moment it read them.
  def record(behaviour, index: 0)
    fields = spawns(behaviour).fetch(index).split("\t")
    { pid: fields[0].to_i, mode: fields[1], directory_mode: fields[2], digest: fields[3],
      path: fields[4], real_path: fields[5], argv: fields[6..] }
  end

  def spawned_pid(behaviour, index: 0)
    spawns(behaviour).empty? ? nil : record(behaviour, index: index).fetch(:pid)
  end

  # A stand-in for the connector program, in three behaviours: one that answers its own readiness
  # endpoint exactly as the real client does, one that runs and never answers, and one that exits
  # at once. It reads the metrics address out of the argv the product built, so the test exercises
  # the real command line rather than a value it was handed.
  #
  # Every launch APPENDS one line, which is what lets "exactly one child" and "one later restart"
  # be counted rather than assumed.
  STAND_IN = <<~RUBY
    #!INTERPRETER
    require "digest"
    require "socket"

    path = ARGV[ARGV.index("--token-file") + 1]
    File.open(File.join(__dir__, "launches"), "a") do |record|
      record.puts([ Process.pid, format("%o", File.stat(path).mode & 0o777),
                    format("%o", File.stat(File.dirname(path)).mode & 0o777),
                    Digest::SHA256.hexdigest(File.read(path)), path, File.realpath(path),
                    *ARGV ].join("\\t"))
    end
    exit 1 if "BEHAVIOUR" == "exit"

    server = TCPServer.new("127.0.0.1", ARGV[ARGV.index("--metrics") + 1].split(":").last.to_i)
    loop do
      client = server.accept
      ready = "BEHAVIOUR" == "ready" && client.gets.to_s.include?("/ready")
      client.print("HTTP/1.1 \#{ready ? '200 OK' : '503 Service Unavailable'}\\r\\n" \\
                   "Content-Length: 0\\r\\nConnection: close\\r\\n\\r\\n")
      client.close
    end
  RUBY
end
