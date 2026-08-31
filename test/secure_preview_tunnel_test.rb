# frozen_string_literal: true

require_relative "test_helper"

# The subordinate tunnel that makes an already-available preview reachable remotely.
#
# Three things are proved here, and the third is the one that matters operationally. First, the
# document handed to the child is derived ONLY from the validated service snapshot: exact hosts,
# one per service, and a final 404 — never a wildcard, never a rule this machine invented. Second,
# the child is really a child: it is started, its own local readiness is what "ready" means, and
# stopping it answers honestly enough for the release ordering to depend on the answer. Third, that
# answer is PROVED rather than assumed — a runner that cannot tell what its own state names says
# so, and a process that is not this attempt's tunnel is never touched.
#
# The child is a real process. `cloudflared` is not installed on a test machine, so the executable
# is a stub handed in through the same constructor argument the product uses — the spawn, the
# process group, the readiness probe and the shutdown are all the real ones.
class SecurePreviewTunnelTest < Minitest::Test
  PREVIEW_ID = "prv_0123456789abcdef0123456789abcdef"
  # The production tunnel executable's file name. Every stand-in below really carries it.
  PROGRAM = SpecrelayRunner::SecurePreviewTunnel::EXECUTABLE
  NAMESPACE = "7c1d4a90e3b25f6108ad4c3b2e59f071"
  ZONE = "edge.internal.example"
  SERVICES = [ { "service" => "dashboard", "url" => "http://127.0.0.1:5173" },
               { "service" => "api", "url" => "http://127.0.0.1:5174/" } ].freeze

  def setup
    @root = Dir.mktmpdir("secure-preview-tunnel-test")
    @credentials = File.join(@root, "tunnel.json")
    File.write(@credentials, "{}")
    @strays = []
  end

  def teardown
    @tunnel&.stop
    @strays.each { |pid| stray_gone!(pid) }
    FileUtils.remove_entry(@root)
  rescue SystemCallError
    nil
  end

  # HOME is where the runner's existing local state lives, and this attempt's own directory lives
  # under it. Pointing it at this test's own directory is what keeps these examples off the
  # machine's real state.
  def env(**overrides)
    { "HOME" => @root,
      SpecrelayRunner::SecurePreviewTunnel::TUNNEL_ENV => "preview-tunnel",
      SpecrelayRunner::SecurePreviewTunnel::CREDENTIALS_ENV => @credentials,
      SpecrelayRunner::SecurePreviewTunnel::HIDDEN_ZONE_ENV => ZONE }.merge(overrides)
  end

  def tunnel(**options) = @tunnel = build(**options)

  # A separate object for the same attempt, which is what a runner process that reconnected after
  # a restart really has: nothing in memory, and a record on disk.
  def build(executable: nil, services: SERVICES, ready_timeout_seconds: 10,
            process_probe: SpecrelayRunner::SecurePreviewTunnel::PROCESS_PROBE, **env_overrides)
    SpecrelayRunner::SecurePreviewTunnel.new(
      preview_id: PREVIEW_ID, namespace: NAMESPACE, services: services, env: env(**env_overrides),
      executable: executable || stub_child(:ready), ready_timeout_seconds: ready_timeout_seconds,
      process_probe: process_probe
    )
  end

  def digest(name) = Digest::SHA256.hexdigest(name)[0, 16]
  def attempt = PREVIEW_ID.delete_prefix("prv_")

  # The expected label, packed here rather than read from the product: 64 bits of service digest,
  # 128 of attempt token, 128 of namespace, as one zero-padded base36 number.
  def label(name, namespace = NAMESPACE)
    "v#{"#{digest(name)}#{attempt}#{namespace}".to_i(16).to_s(36).rjust(62, '0')}"
  end

  # ---- the document handed to the child -------------------------------------------------

  def test_every_rule_names_one_exact_validated_host_and_the_last_one_answers_404
    document = tunnel.configuration(45_000)

    assert_equal [ "#{label('dashboard')}.#{ZONE}", "#{label('api')}.#{ZONE}", nil ],
                 document["ingress"].map { |rule| rule["hostname"] }
    assert_equal [ "http://127.0.0.1:5173", "http://127.0.0.1:5174", "http_status:404" ],
                 document["ingress"].map { |rule| rule["service"] }
  end

  # The literal cross-repository vector. Platform derives the same hidden host from the same three
  # inputs in its own suite, and both must produce this exact 63-character label — a disagreement
  # here is a name that resolves for one side and not the other.
  VECTOR_SERVICE = "app"
  VECTOR_NAMESPACE = "fedcba9876543210fedcba9876543210"
  VECTOR_LABEL = "vfnyag6wi21byitimfrk0bsbuyj59a4o6doacbem2x2si6xbdl3t14x1gdy3500"

  def test_the_shared_vector_builds_the_label_platform_builds
    tunnel = SpecrelayRunner::SecurePreviewTunnel.new(
      preview_id: PREVIEW_ID, namespace: VECTOR_NAMESPACE,
      services: [ { "service" => VECTOR_SERVICE, "url" => "http://127.0.0.1:5173" } ],
      env: env, executable: stub_child(:ready)
    )

    assert_equal 63, VECTOR_LABEL.length
    assert_equal "#{VECTOR_LABEL}.#{ZONE}",
                 tunnel.configuration(45_000)["ingress"].first["hostname"]
  end

  # One label below the zone is what makes ordinary first-level wildcard certificate coverage
  # possible; a second dot would put the name outside it.
  def test_every_published_host_is_one_label_below_the_zone
    tunnel.configuration(45_000)["ingress"].filter_map { |rule| rule["hostname"] }.each do |host|
      assert_match(/\Av[0-9a-z]{62}\.#{Regexp.escape(ZONE)}\z/, host)
      refute_includes host.delete_suffix(".#{ZONE}"), "."
    end
  end

  # A wildcard, a path rule or a catch-all origin would each let a request for a service this
  # preview does not publish reach an application anyway.
  def test_the_document_carries_no_wildcard_path_rule_or_catch_all_origin
    document = tunnel.configuration(45_000)

    refute_includes document.to_s, "*"
    assert_nil document["ingress"].find { |rule| rule.key?("path") }
    assert_equal 1, document["ingress"].count { |rule| rule["hostname"].nil? }
    assert_equal "http_status:404", document["ingress"].last["service"]
  end

  def test_the_document_names_only_the_locally_configured_tunnel_and_credential
    document = tunnel.configuration(45_000)

    assert_equal "preview-tunnel", document["tunnel"]
    assert_equal @credentials, document["credentials-file"]
    assert_equal "127.0.0.1:45000", document["metrics"]
  end

  # ---- refusing to start ----------------------------------------------------------------

  # A machine that was never provisioned fails closed and says so once. It is not an error and not
  # a retry: the local preview is running and stays running.
  def test_an_unprovisioned_machine_refuses_before_it_spawns_anything
    [ SpecrelayRunner::SecurePreviewTunnel::TUNNEL_ENV,
      SpecrelayRunner::SecurePreviewTunnel::CREDENTIALS_ENV,
      SpecrelayRunner::SecurePreviewTunnel::HIDDEN_ZONE_ENV ].each do |key|
      result = tunnel(**{ key => "" }).start

      refute result.ok?, key
      assert_includes result.reason, "not provisioned for secure preview access"
      refute @tunnel.running?
    end
  end

  def test_a_missing_credential_file_and_an_empty_snapshot_both_refuse
    missing = tunnel(SpecrelayRunner::SecurePreviewTunnel::CREDENTIALS_ENV => File.join(@root, "gone.json")).start

    refute missing.ok?
    assert_includes missing.reason, "credential file is missing"

    empty = tunnel(services: []).start

    refute empty.ok?
    assert_includes empty.reason, "no service to publish"
  end

  def test_a_missing_executable_is_a_bounded_failure_rather_than_a_crash
    result = tunnel(executable: File.join(@root, "no-such-cloudflared")).start

    refute result.ok?
    assert_includes result.reason, "could not be started"
    assert_operator result.reason.length, :<=, 1_000
  end

  # ---- the real child --------------------------------------------------------------------

  def test_a_child_that_registers_a_connection_is_ready_and_stops_on_request
    result = tunnel.start

    assert result.ok?, result.reason
    assert @tunnel.running?

    pid = child_pid

    assert @tunnel.stop, "the tunnel was not accounted for"
    refute @tunnel.running?
    refute alive?(pid), "the child survived the stop"
  end

  # There is no retry. A child that exits before it ever registers is one bounded failure, and the
  # process it left behind is accounted for rather than leaked.
  def test_a_child_that_exits_at_once_is_one_bounded_failure
    result = tunnel(executable: stub_child(:exit)).start

    refute result.ok?
    assert_includes result.reason, "did not become ready"
    refute @tunnel.running?
  end

  # A child that runs but never answers its own readiness endpoint is not ready, and it is
  # terminated rather than left publishing something nobody verified.
  def test_a_child_that_never_registers_is_terminated_within_the_bound
    result = tunnel(executable: stub_child(:silent), ready_timeout_seconds: 1).start

    refute result.ok?
    assert_includes result.reason, "did not become ready"
    refute @tunnel.running?
  end

  # The answer the release ordering depends on. A tunnel that was never started, and one whose
  # child has already gone, are both accounted for.
  def test_a_tunnel_that_was_never_started_is_accounted_for
    assert tunnel.stop
    refute tunnel.running?
  end

  # ---- accounting for a child after the runner process that spawned it has gone ----------

  # The state exists only while a child does. A claim that ended cleanly leaves the next one
  # nothing to chase, and the configuration that named the hidden hostnames goes with it.
  def test_a_running_child_is_recorded_and_a_confirmed_shutdown_removes_the_whole_attempt_directory
    assert tunnel.start.ok?
    assert_path_exists configuration_of(@tunnel)
    assert_equal child_pid, Integer(File.read(pid_of(@tunnel)).strip, 10)
    assert_equal "40700", File.stat(@tunnel.state_directory).mode.to_s(8)
    assert_equal "100600", File.stat(pid_of(@tunnel)).mode.to_s(8)

    assert @tunnel.stop
    refute File.exist?(@tunnel.state_directory), "the attempt directory outlived the child it named"
  end

  # THE reconnect case. The runner process that spawned this child is gone — the child is in its
  # own process group and survived it — and the release Platform hands back is the first thing in
  # a position to account for it. A separate object with nothing in memory finds that exact child,
  # stops it, and only then removes the evidence.
  def test_a_child_left_by_a_dead_runner_process_is_found_stopped_and_its_state_removed
    pid = start_in_another_process

    assert alive?(pid), "the previous process took its child with it; this example proves nothing"

    reconnected = build(services: [])

    assert reconnected.stop, "the remaining child was not accounted for"
    refute alive?(pid), "the child survived the reconnect release"
    refute File.exist?(reconnected.state_directory), "the previous configuration was left behind"
  end

  # ---- uncertainty is never success ------------------------------------------------------

  # A pid file that will not parse says nothing about whether a child is running. Guessing is the
  # one thing this class may not do: it refuses, keeps the evidence for the retry and for a person
  # to read, and the caller keeps its release obligation.
  def test_a_malformed_or_partial_pid_blocks_release_and_keeps_the_evidence
    # An empty file and a bare newline are what an interrupted write leaves; `12 34` is a second
    # value arriving where one was expected; `0` and `-1` are worse than useless, because `kill`
    # reads a non-positive number as "this process group" — the runner itself.
    [ "not-a-pid\n", "", "\n", "12 34\n", "0\n", "-1\n" ].each do |content|
      subject = build(services: [])
      establish(subject)
      File.write(pid_of(subject), content)

      refute subject.stop, content.inspect
      assert_path_exists pid_of(subject), content.inspect
      assert_path_exists configuration_of(subject), content.inspect
    end
  end

  # A probe that will not answer, and one that answers with more than one candidate, are both
  # ignorance. Neither is an accounted child and neither signals anything.
  def test_a_failed_or_ambiguous_identity_probe_blocks_release_and_keeps_the_evidence
    unanswered = build(services: [], process_probe: probe_stub("exit 2"))
    establish(unanswered)
    File.write(pid_of(unanswered), "#{stray('while :; do sleep 1; done')}\n")

    refute unanswered.stop, "a probe that would not answer was treated as an absent child"
    assert_path_exists pid_of(unanswered)

    # No pid was ever persisted, so the search runs — and finds two processes that BOTH pass the
    # complete proof: the right program, the right arguments. Two tunnels for one attempt is not a
    # thing this runner can resolve, so it resolves nothing.
    established = build(services: [])
    establish(established)
    ambiguous = build(services: [], process_probe: probe_stub(two_proven_candidates(established)))

    refute ambiguous.stop, "two fully proven candidates were treated as one child"
    assert_path_exists configuration_of(ambiguous)
  end

  # A crash window with an IMPOSTOR in it. The search narrows by the attempt's configuration path,
  # so the impostor is a candidate — and then fails the executable proof, leaving zero proven
  # matches. Nothing is signalled, and the attempt is accounted for because no child of this
  # attempt is running.
  def test_no_pid_recovery_applies_the_same_executable_proof_to_every_candidate
    subject = build(services: [])
    establish(subject)
    impostor = stray("while :; do sleep 1; done", PROGRAM, "tunnel", "--config",
                     configuration_of(subject), "run")

    accounted = subject.stop

    assert alive?(impostor), "the crash-window search signalled an unrelated executable"
    assert accounted
  end

  # A pid outlives the process that owned it and the number is handed out again. Identity is the
  # WHOLE argument tail this class spawns, so a process that merely carries the configuration path
  # as another argument is positively something else: it is never signalled, and the attempt is
  # accounted for because its own child has in fact gone.
  def test_a_process_whose_argv_merely_carries_the_configuration_path_is_never_signalled
    subject = build(services: [])
    establish(subject)
    stranger = stray("while :; do sleep 1; done", "unrelated", "--config", configuration_of(subject))
    File.write(pid_of(subject), "#{stranger}\n")

    assert_includes `ps -ww -o command= -p #{stranger}`, configuration_of(subject),
                    "the unrelated process does not carry the path; this example proves nothing"

    assert subject.stop, "a pid proven to belong to another process is not an unaccounted child"
    assert alive?(stranger), "an unrelated process was signalled"
    refute File.exist?(subject.state_directory)
  end

  # THE false positive. A process's arguments can END with anything at all, including this class's
  # own argument shape and the name of its executable — those are just strings another program was
  # handed. What a process IS has to come from somewhere an argument cannot reach.
  def test_an_unrelated_executable_whose_arguments_end_with_the_expected_shape_is_never_signalled
    subject = build(services: [])
    establish(subject)
    impostor = stray("while :; do sleep 1; done", File.basename(stub_child(:ready)),
                     "tunnel", "--config", configuration_of(subject), "run")
    File.write(pid_of(subject), "#{impostor}\n")

    assert_equal "/bin/sh", `ps -ww -o comm= -p #{impostor}`.strip,
                 "the impostor is not another executable; this example proves nothing"
    assert `ps -ww -o args= -p #{impostor}`.strip.end_with?(
      " tunnel --config #{configuration_of(subject)} run"
    ), "the impostor does not present the expected argument shape; this example proves nothing"

    # Positively a different executable, so the child that pid named has exited and the number was
    # reused: accounted, and the process now holding it is left completely alone. The signal is
    # asserted FIRST because it is the safety boundary — a wrong answer afterwards would not undo it.
    accounted = subject.stop

    assert alive?(impostor), "an unrelated executable was signalled"
    assert accounted, "a pid proven to belong to another executable is not an unaccounted child"
  end

  # The same proof, the other way round: the right executable running a DIFFERENT attempt's
  # configuration is somebody else's tunnel and is never touched by this attempt.
  def test_the_expected_executable_serving_another_configuration_is_never_signalled
    subject = build(services: [])
    establish(subject)
    elsewhere = stray_program(stub_child(:silent), "tunnel", "--config",
                              runnable_configuration(File.join(@root, "other.yml")), "run")
    File.write(pid_of(subject), "#{elsewhere}\n")

    assert subject.stop
    assert alive?(elsewhere), "another attempt's tunnel was signalled"
  end

  # A probe that will not answer, and one that answers with nothing at all, are both ignorance.
  # Neither signals, both keep the evidence, and both leave the release obligation standing.
  def test_a_failed_or_empty_executable_probe_signals_nothing_and_fences_the_release
    [ "exit 2", "exit 0" ].each do |behaviour|
      subject = build(services: [], process_probe: probe_stub(behaviour))
      establish(subject)
      live = stray_program(stub_child(:silent), "tunnel", "--config", configuration_of(subject), "run")
      File.write(pid_of(subject), "#{live}\n")

      refute subject.stop, behaviour
      assert alive?(live), "a candidate this runner could not identify was signalled (#{behaviour})"
      assert_path_exists pid_of(subject), behaviour
    end
  end

  # The executable field is a fixed width on one supported system. A name that could not survive it
  # cannot be compared, so no candidate is ever proved and nothing is signalled.
  def test_an_executable_name_too_long_to_compare_is_never_proved
    long = File.join(@root, "a-tunnel-executable-with-a-very-long-name")
    subject = build(services: [], executable: long)
    establish(subject)
    live = stray_program(stub_child(:silent), "tunnel", "--config", configuration_of(subject), "run")
    File.write(pid_of(subject), "#{live}\n")

    refute subject.stop
    assert alive?(live)
    assert_path_exists pid_of(subject)
  end

  # A runner killed between the spawn and the pid being persisted leaves a configuration and no
  # pid. That is not "no child": the configuration is the exact identity, and the process table is
  # searched for it — never for a program by name — before anything is signalled.
  def test_a_child_spawned_before_its_pid_was_persisted_is_recovered_and_stopped
    pid = start_in_another_process
    # The on-disk state a crash in that window leaves behind.
    File.delete(pid_of(build(services: [])))

    reconnected = build(services: [])

    assert reconnected.stop, "the child spawned before its pid was persisted was not recovered"
    refute alive?(pid), "the recovered child survived"
    refute File.exist?(reconnected.state_directory)
  end

  # The preview id arrives as free text on the wire, and the attempt directory is the one place it
  # would otherwise choose a path on this machine. A separator in it must not be able to name a
  # directory outside the runner's own state root, which this class writes into and removes.
  def test_a_preview_id_carrying_a_path_separator_cannot_name_a_directory_outside_the_state_root
    escaping = SpecrelayRunner::SecurePreviewTunnel.new(
      preview_id: "../../../../etc/passwd", namespace: NAMESPACE, services: [], env: env
    )

    assert_equal File.join(@root, SpecrelayRunner::SecurePreviewTunnel::STATE_RELATIVE_PATH),
                 File.dirname(escaping.state_directory)
    assert_match(/\A[0-9a-f]{32}\z/, File.basename(escaping.state_directory))
  end

  private

  def pid_of(subject) = File.join(subject.state_directory, SpecrelayRunner::SecurePreviewTunnel::PID_FILE)

  def configuration_of(subject)
    File.join(subject.state_directory, SpecrelayRunner::SecurePreviewTunnel::CONFIGURATION_FILE)
  end

  # A process table answering with two candidates that each pass the WHOLE proof: `comm` names the
  # production executable and the arguments end with this attempt's own shape. Two operating-system
  # processes cannot be conjured into that state on demand, so only the table's answers are
  # substituted — the proof reading them is the product's own.
  def two_proven_candidates(subject)
    tail = "#{PROGRAM} tunnel --config #{configuration_of(subject)} run"
    <<~SH
      case "$*" in
        *comm=*) echo "/opt/#{PROGRAM}" ;;
        *-A*)    echo " 424242 #{tail}" ; echo " 434343 #{tail}" ;;
        *)       echo "#{tail}" ;;
      esac
    SH
  end

  # The on-disk state a previous runner process leaves: the attempt directory and the configuration
  # its child was started with, written before the spawn. It is a document the stand-in can really
  # run from, so a process started against it stays alive and its survival means something.
  def establish(subject)
    FileUtils.mkdir_p(subject.state_directory, mode: 0o700)
    runnable_configuration(configuration_of(subject))
  end

  def runnable_configuration(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "metrics: 127.0.0.1:0\ningress: []\n")
    path
  end

  # A stand-in for `ps`. The operating system cannot be asked to fail its own process table on
  # demand, and it cannot be asked to report two identical tunnels, so those two answers are the
  # only thing substituted — the identity rule reading them is the product's own.
  def probe_stub(body)
    path = File.join(@root, "ps-#{Digest::SHA256.hexdigest(body)[0, 8]}")
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  # A runner process that starts a tunnel and then dies. Its child is re-parented, exactly as it
  # is on a machine whose runner was killed while a preview was open.
  def start_in_another_process
    script = File.join(@root, "previous-runner.rb")
    File.write(script, PREVIOUS_RUNNER)
    arguments = [ File.expand_path("../lib", __dir__), stub_child(:ready), @credentials, @root ]

    assert system(RbConfig.ruby, script, *arguments), "the previous runner process failed to start a tunnel"

    pid = Integer(File.read(pid_of(build(services: []))).strip, 10)
    @strays << pid
    pid
  end

  def stray(command, *arguments)
    pid = Process.spawn("/bin/sh", "-c", command, *arguments, pgroup: true,
                        out: File::NULL, err: File::NULL)
    @strays << pid
    pid
  end

  # A real process running a real program, spawned exactly as the product spawns its child.
  def stray_program(*argv)
    pid = Process.spawn({}, *argv, pgroup: true, out: File::NULL, err: File::NULL)
    @strays << pid
    sleep 0.2
    pid
  end

  def stray_gone!(pid)
    Process.kill("KILL", -Process.getpgid(pid))
    Process.waitpid(pid)
  rescue SystemCallError
    nil
  end

  # Starts the same tunnel this test starts, from a process that then exits without stopping it.
  PREVIOUS_RUNNER = <<~RUBY
    $LOAD_PATH.unshift(ARGV[0])
    require "specrelay_runner"
    tunnel = SpecrelayRunner::SecurePreviewTunnel.new(
      preview_id: "#{PREVIEW_ID}", namespace: "#{NAMESPACE}",
      services: #{SERVICES.inspect},
      env: { "HOME" => ARGV[3],
             SpecrelayRunner::SecurePreviewTunnel::TUNNEL_ENV => "preview-tunnel",
             SpecrelayRunner::SecurePreviewTunnel::CREDENTIALS_ENV => ARGV[2],
             SpecrelayRunner::SecurePreviewTunnel::HIDDEN_ZONE_ENV => "#{ZONE}" },
      executable: ARGV[1], ready_timeout_seconds: 10
    )
    exit(tunnel.start.ok? ? 0 : 1)
  RUBY


  def child_pid = @tunnel.instance_variable_get(:@pid)

  # A process that was signalled but not yet reaped still answers `kill(0)`, so a test asking "did
  # this survive?" has to ask the process table instead: a zombie is a process that died.
  def alive?(pid)
    state = `ps -o state= -p #{pid}`.strip

    !state.empty? && !state.start_with?("Z")
  end

  # A stand-in for `cloudflared`, in three behaviours: one that serves its own readiness endpoint
  # exactly as the real client does, one that exits at once, and one that runs and never answers.
  # It reads the metrics port out of the config file the product wrote, so the test is exercising
  # the real document rather than a value it was handed.
  def stub_child(behaviour)
    directory = File.join(@root, behaviour.to_s)
    FileUtils.mkdir_p(directory)
    path = File.join(directory, PROGRAM)
    File.write(path, STUB.sub("INTERPRETER", interpreter).gsub("BEHAVIOUR", behaviour.to_s))
    File.chmod(0o755, path)
    path
  end

  # The stand-in has to be a REAL program with the production executable name, because the identity
  # proof reads the process table's own `comm` field — the file the kernel executed — and a script
  # would report its interpreter. A symlink to the Ruby binary, named `cloudflared`, is a real
  # executable that `comm` reports as `cloudflared` on both supported systems, and it is what the
  # stub's shebang names. Nothing here substitutes the identity rule itself.
  def interpreter
    @interpreter ||= begin
      directory = File.join(@root, "bin")
      FileUtils.mkdir_p(directory)
      link = File.join(directory, PROGRAM)
      File.symlink(RbConfig.ruby, link)
      link
    end
  end

  # The second line is what lets a Ruby binary invoked under another name recognise this file as a
  # script: Ruby skips shebang lines until one names it.
  STUB = <<~RUBY
    #!INTERPRETER
    #!ruby
    require "socket"
    require "yaml"
    exit 1 if "BEHAVIOUR" == "exit"
    config = YAML.safe_load_file(ARGV[ARGV.index("--config") + 1])
    port = config["metrics"].split(":").last.to_i
    server = TCPServer.new("127.0.0.1", port)
    loop do
      client = server.accept
      request = client.gets.to_s
      body = ("BEHAVIOUR" == "ready" && request.include?("/ready")) ? "200 OK" : "503 Service Unavailable"
      client.print("HTTP/1.1 \#{body}\\r\\nContent-Length: 0\\r\\nConnection: close\\r\\n\\r\\n")
      client.close
    end
  RUBY
end
