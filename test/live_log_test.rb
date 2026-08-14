# frozen_string_literal: true

require_relative "test_helper"

# MVP-0018 proof for live executor output on the standalone runner.
#
# The three claims that matter, each asserted against real behaviour rather than
# against a mock of it:
#
#   1. output is INCREMENTAL. A real child process is spawned that prints, sleeps,
#      then prints again; the test measures the arrival gap. Under the previous
#      `IO#read(n)` reader both lines arrived at process exit, so the gap assertion
#      fails against pre-fix source — which is what makes it a regression test.
#   2. output is SAFE. Redaction happens before the terminal write and before the
#      upload, per-line clipping and a whole-run byte budget are enforced, and
#      reaching the budget is announced instead of silently dropping output.
#   3. output cannot break the run. A consumer that raises, and a Platform that
#      refuses the upload, both leave the execution's captured result untouched.
class LiveLogTest < Minitest::Test
  Sink = Struct.new(:lines, :times) do
    def to_proc = ->(source, line) { lines << [ source, line ] and times << Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  end

  def setup
    @tmp = Dir.mktmpdir("live-log")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
  end

  # ---- CommandRunner: incremental delivery -------------------------------

  def test_output_lines_arrive_while_the_process_is_still_running
    script = write_script(<<~RUBY)
      $stdout.sync = true
      puts "first line"
      sleep 0.5
      puts "second line"
    RUBY
    seen = []
    result = SpecrelayRunner::CommandRunner.run(
      [ RbConfig.ruby, script ], chdir: @tmp, env: { "PATH" => ENV["PATH"] }, timeout_seconds: 20,
      on_output: ->(source, line) { seen << [ monotonic, source, line ] }
    )

    assert_equal 0, result.exit_code
    assert_equal 2, seen.size, "both lines must be delivered, got #{seen.inspect}"
    gap = seen[1][0] - seen[0][0]
    assert_operator gap, :>=, 0.3,
                    "the first line must arrive BEFORE the process exits; a #{gap.round(3)}s gap means " \
                    "both lines were delivered at exit (buffered, not streamed)"
    assert_equal [ "stdout", "first line" ], seen[0][1..2]
    assert_equal [ "stdout", "second line" ], seen[1][1..2]
  end

  # ---- CommandRunner: the provider-start boundary (MVP-0036 CR-005 F2) ----
  #
  # `on_start` means "this child has what we gave it". A caller records an irreversible fact on
  # the strength of it, so it must fire once for a real handoff and never for a failed one.

  def test_the_start_callback_fires_once_when_the_prompt_travels_as_an_argument
    started = 0

    result = SpecrelayRunner::CommandRunner.run(
      [ RbConfig.ruby, write_script("exit 0\n") ], chdir: @tmp, env: { "PATH" => ENV["PATH"] },
      timeout_seconds: 20, on_start: -> { started += 1 }
    )

    assert_equal 0, result.exit_code
    assert_equal 1, started
  end

  def test_the_start_callback_fires_once_when_the_prompt_is_delivered_on_stdin
    script = write_script(<<~RUBY)
      read = $stdin.read
      $stdout.write(read.bytesize.to_s)
    RUBY
    started = 0
    prompt = "x" * 200_000

    result = SpecrelayRunner::CommandRunner.run(
      [ RbConfig.ruby, script ], chdir: @tmp, env: { "PATH" => ENV["PATH"] }, timeout_seconds: 20,
      stdin_data: prompt, on_start: -> { started += 1 }
    )

    assert_equal 0, result.exit_code
    assert_equal prompt.bytesize.to_s, result.stdout, "the child received the whole prompt"
    assert_equal 1, started
  end

  # The child is gone before it reads a byte, and the prompt is larger than the pipe buffer so
  # the write cannot quietly complete into it. Nothing was handed off, so nothing may be told it
  # was — and the caller has to learn the launch failed rather than see an ordinary exit code.
  def test_the_start_callback_never_fires_when_the_child_closed_its_input_first
    started = 0

    assert_raises(Errno::EPIPE) do
      SpecrelayRunner::CommandRunner.run(
        [ RbConfig.ruby, write_script("exit 0\n") ], chdir: @tmp, env: { "PATH" => ENV["PATH"] },
        timeout_seconds: 20, stdin_data: "x" * 1_000_000, on_start: -> { started += 1 }
      )
    end

    assert_equal 0, started
  end

  # F2.4 — with no lifecycle callback the ordinary behaviour is untouched: a child that exits
  # before reading its input has always been an ordinary early exit, and its result still decides.
  def test_a_child_that_never_reads_its_input_is_unchanged_without_a_start_callback
    result = SpecrelayRunner::CommandRunner.run(
      [ RbConfig.ruby, write_script("exit 7\n") ], chdir: @tmp, env: { "PATH" => ENV["PATH"] },
      timeout_seconds: 20, stdin_data: "x" * 1_000_000
    )

    assert_equal 7, result.exit_code
  end

  def test_stdout_and_stderr_are_delivered_with_distinct_stream_names
    script = write_script(<<~RUBY)
      $stdout.sync = true
      $stderr.sync = true
      puts "to stdout"
      warn "to stderr"
    RUBY
    seen = []
    SpecrelayRunner::CommandRunner.run([ RbConfig.ruby, script ], chdir: @tmp, env: { "PATH" => ENV["PATH"] },
                                                                 timeout_seconds: 20,
                                                                 on_output: ->(s, l) { seen << [ s, l ] })

    assert_includes seen, [ "stdout", "to stdout" ]
    assert_includes seen, [ "stderr", "to stderr" ]
  end

  def test_a_final_line_without_a_trailing_newline_is_still_delivered
    script = write_script('$stdout.write("no trailing newline")')
    seen = []
    SpecrelayRunner::CommandRunner.run([ RbConfig.ruby, script ], chdir: @tmp, env: { "PATH" => ENV["PATH"] },
                                                                 timeout_seconds: 20,
                                                                 on_output: ->(s, l) { seen << [ s, l ] })

    assert_equal [ [ "stdout", "no trailing newline" ] ], seen
  end

  def test_a_consumer_that_raises_cannot_fail_the_execution
    script = write_script('puts "still captured"')
    result = SpecrelayRunner::CommandRunner.run([ RbConfig.ruby, script ], chdir: @tmp,
                                                                          env: { "PATH" => ENV["PATH"] }, timeout_seconds: 20,
                                                                          on_output: ->(_s, _l) { raise "consumer exploded" })

    assert_equal 0, result.exit_code
    assert_includes result.stdout, "still captured", "the buffered capture stays authoritative"
  end

  def test_multibyte_output_split_across_reads_always_decodes_as_valid_utf8
    # 120_000 bytes of two-byte characters with a single trailing newline, so a
    # character necessarily straddles the boundary between two 64KiB reads AND the
    # pending-line cap forces a partial flush. Both paths must still yield text a
    # terminal, a JSON body, and a browser can render.
    script = write_script('$stdout.write(("é" * 60_000) + "\n")')
    seen = []
    SpecrelayRunner::CommandRunner.run([ RbConfig.ruby, script ], chdir: @tmp, env: { "PATH" => ENV["PATH"] },
                                                                 timeout_seconds: 30,
                                                                 on_output: ->(s, l) { seen << [ s, l ] })

    refute_empty seen
    seen.each do |_source, line|
      assert_equal Encoding::UTF_8, line.encoding
      assert_predicate line, :valid_encoding?, "no delivered line may carry a split multi-byte character"
    end
  end

  def test_a_line_that_never_terminates_is_delivered_rather_than_buffered_forever
    # No newline at all, and more than the pending-line cap: the consumer must see
    # it while the process is still alive instead of at exit.
    script = write_script(<<~RUBY)
      $stdout.sync = true
      $stdout.write("a" * (#{SpecrelayRunner::CommandRunner::MAX_PENDING_LINE_BYTES} + 1))
      sleep 0.5
      $stdout.write("\\n")
    RUBY
    seen = []
    SpecrelayRunner::CommandRunner.run([ RbConfig.ruby, script ], chdir: @tmp, env: { "PATH" => ENV["PATH"] },
                                                                 timeout_seconds: 20,
                                                                 on_output: ->(_s, l) { seen << [ monotonic, l ] })

    refute_empty seen
    assert_operator seen.first[0], :<, monotonic - 0.4,
                    "an unterminated long line must be flushed before the process exits"
  end

  # ---- ExecutorLogStream: redaction, bounds, heartbeats -------------------

  def test_a_secret_is_redacted_before_the_terminal_write_and_before_the_upload
    stream, io, emitter = build_stream
    stream.accept("stdout", "using token sk-live-DO-NOT-LEAK-0123456789 now")
    stream.finish

    refute_includes io.string, "sk-live-DO-NOT-LEAK-0123456789", "the terminal must never show the secret"
    chunks = emitter.chunks
    assert_equal 1, chunks.size
    refute_includes chunks.first[:log_chunk], "sk-live-DO-NOT-LEAK-0123456789", "the upload must never carry the secret"
    assert_includes chunks.first[:log_chunk], "[REDACTED]"
    refute_includes stream.evidence_text, "sk-live-DO-NOT-LEAK-0123456789", "the report evidence must not carry it either"
  end

  def test_one_overlong_line_is_clipped_with_a_visible_marker
    stream, io, emitter = build_stream
    stream.accept("stdout", "x" * (SpecrelayRunner::ExecutorLogStream::MAX_LINE_BYTES + 5_000))
    stream.finish

    chunk = emitter.chunks.first[:log_chunk]
    assert_operator chunk.bytesize, :<=, SpecrelayRunner::ExecutorLogStream::MAX_LINE_BYTES
    assert_includes chunk, "[line clipped at"
    assert_includes io.string, "[line clipped at"
  end

  def test_the_whole_run_budget_is_capped_and_the_truncation_is_announced_once
    stream, io, emitter = build_stream
    line = "y" * 1_000
    200.times { stream.accept("stdout", line) } # far beyond MAX_TOTAL_BYTES
    stream.finish
    stream.finish # idempotent: a second stop must not re-announce

    assert_predicate stream, :truncated?
    truncations = emitter.events_of("log.truncated")
    assert_equal 1, truncations.size, "the truncation notice is emitted exactly once"
    assert_equal 1, io.string.scan("reached its").size, "and printed exactly once"
    total = emitter.chunks.sum { |c| c[:log_chunk].bytesize }
    assert_operator total, :<=, SpecrelayRunner::ExecutorLogStream::MAX_TOTAL_BYTES
  end

  def test_every_uploaded_chunk_stays_within_the_platform_per_event_cap
    stream, _io, emitter = build_stream
    500.times { |i| stream.accept("stdout", "line #{i} #{'z' * 200}") }
    stream.finish

    emitter.chunks.each do |chunk|
      assert_operator chunk[:log_chunk].bytesize, :<=, 65_536,
                      "a single log.chunk must stay inside the documented 65536-byte contract cap"
    end
  end

  def test_a_chunk_event_names_its_stream_and_phase
    stream, _io, emitter = build_stream
    stream.accept("stderr", "a diagnostic line")
    stream.finish

    attributes = emitter.chunks.first[:attributes]
    assert_equal "stderr", attributes[:log_source]
    assert_equal "core", attributes[:phase]
  end

  def test_a_heartbeat_is_emitted_only_while_the_provider_is_quiet
    clock = FakeClock.new
    stream, io, emitter = build_stream(clock: clock, heartbeat_interval: 10)
    clock.advance(11)
    stream.send(:heartbeat_if_quiet)

    beats = emitter.events_of("core.progress")
    assert_equal 1, beats.size, "a quiet provider gets a heartbeat"
    assert_includes beats.first[:summary], "no new output yet"
    assert_includes io.string, "no new output yet"

    # Output resumes: the provider is no longer quiet, so no further heartbeat.
    stream.accept("stdout", "talking again")
    stream.send(:heartbeat_if_quiet)
    assert_equal 1, emitter.events_of("core.progress").size,
                 "a heartbeat must never stand in for output that was actually available"
    stream.finish

    # The quiet period is part of what the operator saw, so it belongs in the report
    # evidence too — otherwise the file cannot explain why the run took as long as it did.
    assert_includes stream.evidence_text, "[status] fake executor running for",
                    "the evidence file must record the heartbeats, not only the chatty moments"
  end

  # ---- RUNNER-0001 scope 5: the quiet executor in a terminal ---------------

  # Scenario 13. Elapsed liveness is true only NOW, so in a terminal it replaces one row
  # instead of appending a line every interval — while Platform still receives the same
  # bounded `core.progress` event, and the report evidence still records it. Only the
  # TERMINAL representation became transient.
  def test_a_quiet_executor_uses_the_transient_row_and_still_emits_its_platform_progress_event
    clock = FakeClock.new
    terminal = RecordingTerminal.new
    presenter = SpecrelayRunner::TerminalPresenter.new(out: terminal, transient: true, columns: 100)
    stream, _io, emitter = build_stream(clock: clock, heartbeat_interval: 10, io: presenter)
    clock.advance(11)
    stream.send(:heartbeat_if_quiet)
    clock.advance(11)
    stream.send(:heartbeat_if_quiet)

    assert_equal 2, emitter.events_of("core.progress").size, "Platform still gets every heartbeat"
    assert_empty terminal.durable_lines, "two heartbeats must not add two lines of history"
    assert_equal 2, terminal.transient_rows.length
    assert_includes terminal.transient_rows.last, "no new output yet"
    assert_includes stream.evidence_text, "[status] fake executor running for",
                    "the report evidence is unchanged — it is the durable record of the same fact"
  end

  def test_real_executor_output_clears_the_quiet_status_before_it_is_printed
    clock = FakeClock.new
    terminal = RecordingTerminal.new
    presenter = SpecrelayRunner::TerminalPresenter.new(out: terminal, transient: true, columns: 100)
    stream, _io, _emitter = build_stream(clock: clock, heartbeat_interval: 10, io: presenter)
    clock.advance(11)
    stream.send(:heartbeat_if_quiet)
    stream.accept("stdout", "Reading the approved specification")
    stream.finish

    assert_equal [ "  [fake:stdout] Reading the approved specification" ], terminal.durable_lines
    erase = terminal.writes[terminal.writes.index { |w| w.include?("Reading the approved") } - 1]
    assert_match(/\A\r +\r\z/, erase, "the status row was still on screen under the real line")
  end

  def test_finishing_the_stream_leaves_no_quiet_status_row_on_screen
    clock = FakeClock.new
    terminal = RecordingTerminal.new
    presenter = SpecrelayRunner::TerminalPresenter.new(out: terminal, transient: true, columns: 100)
    stream, _io, _emitter = build_stream(clock: clock, heartbeat_interval: 10, io: presenter)
    clock.advance(11)
    stream.send(:heartbeat_if_quiet)
    stream.finish

    assert_match(/\A\r +\r\z/, terminal.writes.last, "a quiet-executor row is only true while it runs")
  end

  # With no row to redraw, the same fact stays a plain bounded line: a CI log has nowhere else
  # to show that a silent executor is still alive.
  def test_without_a_terminal_the_quiet_heartbeat_remains_line_oriented
    clock = FakeClock.new
    stream, io, emitter = build_stream(clock: clock, heartbeat_interval: 10)
    clock.advance(11)
    stream.send(:heartbeat_if_quiet)

    assert_includes io.string, "no new output yet"
    refute_includes io.string, "\r"
    assert_equal 1, emitter.events_of("core.progress").size
  end

  # Criterion 16 / scenario 24: a heartbeat timer and provider output arriving at the same
  # moment must produce complete, ordered lines. This drives the real stream from several
  # threads at once, which is exactly how CommandRunner's readers call it.
  def test_concurrent_provider_output_and_a_heartbeat_never_split_a_line
    clock = FakeClock.new
    terminal = RecordingTerminal.new
    presenter = SpecrelayRunner::TerminalPresenter.new(out: terminal, transient: true, columns: 200)
    stream, _io, _emitter = build_stream(clock: clock, heartbeat_interval: 1, io: presenter)
    readers = %w[stdout stderr].map do |source|
      Thread.new { 40.times { |i| stream.accept(source, "#{source} line #{i} #{'-' * 30}") } }
    end
    beater = Thread.new { 40.times { clock.advance(2) and stream.send(:heartbeat_if_quiet) } }
    (readers + [ beater ]).each(&:join)
    stream.finish

    lines = terminal.durable_lines
    assert_equal 80, lines.count { |line| line.include?(" line ") }
    lines.each do |line|
      next unless line.include?(" line ")

      assert_match(/\A  \[fake:(stdout|stderr)\] (stdout|stderr) line \d+ -{30}\z/, line,
                   "a durable executor line was split or interleaved: #{line.inspect}")
    end
  end

  def test_an_upload_failure_is_counted_and_reported_but_never_raised
    stream, io, emitter = build_stream
    emitter.fail_next!
    stream.accept("stdout", "a line that cannot be delivered")
    stream.finish

    assert_includes io.string, "could not be delivered to Platform"
    assert_includes io.string, "a line that cannot be delivered", "the terminal still showed it"
    assert_includes stream.evidence_text, "a line that cannot be delivered", "and the report still records it"
  end

  # ---- MAPIAI-60 S10/S11: delivery gaps close without changing identity ----
  #
  # A live view must never apply back-pressure to a provider, so an undelivered envelope waits
  # in the attempt's existing in-memory state instead of blocking or failing the work. When
  # delivery becomes possible again the ORIGINAL bytes go out — same sequence, same payload —
  # because a retry that renumbered or rebuilt an event would make Platform's idempotency rules
  # meaningless and could render the same progress twice.

  # ---- CR-001 F3: Platform I/O never happens on the child output reader ----
  #
  # `accept` is called FROM CommandRunner's reader thread. A Platform request made there stops
  # the reader, fills the child's pipe and freezes the very provider whose progress is being
  # reported — review 001 measured one `accept` blocked for 0.503 seconds. Delivery therefore
  # belongs to the stream's own existing timer, and to `finish`; never to the reader.

  # How long a deliberately slow Platform holds each request. Long enough that a reader-path
  # request cannot hide inside scheduling noise.
  SLOW_CALL_SECONDS = 0.5

  def test_the_output_callback_never_waits_for_a_platform_request
    client = RecordingClient.new(delay: SLOW_CALL_SECONDS)
    stream, _io = live_stream(client)

    started = monotonic
    flush_batch(stream, "Provider started")
    elapsed = monotonic - started

    assert_operator elapsed, :<, SLOW_CALL_SECONDS / 2,
                    "the reader path waited #{elapsed.round(3)}s for Platform; it must only " \
                    "normalize, bound, print and buffer"
    stream.finish
    assert_equal [ 1 ], client.accepted_sequences, "and the delivery still happened, off that path"
  end

  # The same boundary through the REAL seam it exists for: a live child writing JSONL, decoded
  # and streamed while a Platform client holds every request. The provider must run at its own
  # speed and its terminal result must still be captured.
  def test_a_blocked_platform_client_never_delays_the_child_or_its_terminal_result
    client = RecordingClient.new(delay: SLOW_CALL_SECONDS)
    emitter = SpecrelayRunner::EventEmitter.new(client: client, run_id: "run_60", attempt_id: "rex_60")
    stream = SpecrelayRunner::ExecutorLogStream.start(emitter: emitter, io: StringIO.new,
                                                      provider: "claude", task_id: "DEMO-0060")
    decoder = SpecrelayRunner::ClaudeStream.new(sink: stream.sink, repository_path: @tmp)

    started = monotonic
    result = SpecrelayRunner::CommandRunner.run([ RbConfig.ruby, chatty_provider ], chdir: @tmp,
                                                env: { "PATH" => ENV["PATH"] }, timeout_seconds: 20,
                                                on_output: decoder.sink)
    elapsed = monotonic - started
    stream.finish

    assert_equal 0, result.exit_code
    assert_operator elapsed, :<, SLOW_CALL_SECONDS,
                    "the child waited #{elapsed.round(3)}s on a slow Platform"
    assert_nil decoder.close.failure
    assert_equal "the provider's own answer", decoder.final_text
  end

  def test_an_envelope_lost_to_a_transport_outage_is_retried_verbatim_when_delivery_returns
    client = RecordingClient.new
    stream, io = live_stream(client)

    client.offline = true
    flush_batch(stream, "Provider started")
    stream.deliver_pending
    client.offline = false
    flush_batch(stream, "Editing app/index.html")
    stream.deliver_pending
    stream.finish

    assert_equal [ 1, 2 ], client.accepted_sequences,
                 "the lost sequence must be delivered once, before the newer one"
    assert_equal client.first_attempt_for(1), client.accepted_for(1),
                 "the retry must be the ORIGINAL envelope, byte for byte"
    assert_includes io.string, "Provider started", "local display never waited for Platform"
    refute_includes io.string, "could not be delivered to Platform",
                    "the gap closed during the attempt, so there is nothing to warn about"
  end

  def test_a_permanent_refusal_is_not_retried_as_a_transport_outage
    client = RecordingClient.new
    stream, _io = live_stream(client)

    client.refuse = true
    flush_batch(stream, "Provider started")
    stream.deliver_pending
    client.refuse = false
    flush_batch(stream, "Editing app/index.html")
    stream.deliver_pending
    stream.finish

    assert_equal [ 2 ], client.accepted_sequences
    assert_equal 1, client.attempts_for(1).size, "Platform read and refused it; the same bytes cannot become acceptable"
  end

  def test_a_gap_that_never_closes_is_named_locally_and_never_claimed_as_delivered
    client = RecordingClient.new
    stream, io = live_stream(client)

    client.offline = true
    flush_batch(stream, "Provider started")
    stream.finish

    assert_empty client.accepted_sequences
    assert_includes io.string, "could not be delivered to Platform"
    assert_includes stream.evidence_text, "Provider started", "the local record is unaffected"
  end

  def test_a_stop_signal_on_a_log_event_response_is_observed
    stream, _io, emitter = build_stream
    emitter.lease = { "state" => "cancelled", "cancel_requested" => true }
    stream.accept("stdout", "a line")
    stream.finish

    assert_equal "cancelled", stream.stop_reason
  end

  def test_the_evidence_file_distinguishes_live_output_from_the_full_capture
    stream, _io, _emitter = build_stream
    stream.accept("stdout", "hello")
    stream.finish
    text = stream.evidence_text

    assert_includes text, "evidence/stdout.log", "it points at where the full capture lives"
    assert_includes text, "[stdout] hello"
    assert_includes text, "Redacted before display, before upload"
  end

  def test_a_run_with_no_executor_output_says_so_rather_than_producing_an_empty_file
    stream, _io, emitter = build_stream
    stream.finish

    assert_includes stream.evidence_text, "(the executor emitted no live output)"
    assert_empty emitter.chunks
  end

  # ---- end to end over real HTTP -----------------------------------------

  def test_live_log_events_land_between_core_started_and_verification_started
    with_execution do |platform, output|
      types = platform.protocol_events.map { |e| e["event_type"] }
      core = types.index("core.started")
      verification = types.index("verification.started")
      chunk = types.index("log.chunk")

      refute_nil chunk, "a live log event must be submitted; got #{types.inspect}"
      assert_operator core, :<, chunk
      assert_operator chunk, :<, verification
      assert_includes output, "[fake:stdout]", "and the same output is shown in the terminal"
    end
  end

  def test_the_event_sequence_stays_dense_and_monotonic_with_log_events_interleaved
    with_execution do |platform, _output|
      sequences = platform.protocol_events.map { |e| e["sequence"] }
      assert_equal (1..sequences.size).to_a, sequences,
                   "adding a concurrently-emitted log stream must not skip or reuse a sequence"
    end
  end

  def test_the_uploaded_report_carries_the_bounded_live_log_as_its_own_evidence_file
    with_execution do |platform, _output|
      files = platform.last_report.dig(:body, "report", "files").to_h { |f| [ f["relative_path"], f ] }
      path = SpecrelayRunner::ReportBundle::LIVE_LOG_PATH
      assert_includes files.keys, path
      assert_includes files.keys, "evidence/stdout.log", "the full capture is still a separate file"

      body = Base64.decode64(files.fetch(path)["content_base64"])
      refute_includes body, "sk-live-DO-NOT-LEAK", "the demo executor's planted secret must be redacted"
      assert_includes body, "[stdout]"
      assert_includes platform.last_terminal_result.fetch("artifacts"), path
    end
  end

  private

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def write_script(body)
    path = File.join(@tmp, "script-#{rand(1 << 32)}.rb")
    File.write(path, body)
    path
  end

  # A stream wired to a recording emitter, with the timer thread never started so
  # the heartbeat/flush schedule is driven explicitly by the test.
  def build_stream(clock: FakeClock.new, heartbeat_interval: 15, io: StringIO.new)
    emitter = RecordingEmitter.new
    stream = SpecrelayRunner::ExecutorLogStream.new(
      emitter: emitter, io: io, provider: "fake", task_id: "DEMO-0018",
      clock: clock, heartbeat_interval: heartbeat_interval
    )
    [ stream, io, emitter ]
  end

  # A real provider that reports enough long-path activity to cross the flush threshold several
  # times, then answers. Every status line is long, so a reader that delivered its own batches
  # would stop for the slow client more than once.
  def chatty_provider
    deep = File.join(@tmp, "app", "a" * 600, "b" * 600, "index.html.erb")
    write_script(<<~RUBY)
      require "json"
      $stdout.sync = true
      puts JSON.generate({ "type" => "system", "subtype" => "init" })
      20.times do
        puts JSON.generate({ "type" => "assistant", "message" => { "content" => [
          { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => #{deep.inspect} } } ] } })
      end
      puts JSON.generate({ "type" => "result", "subtype" => "success", "is_error" => false,
                           "result" => "the provider's own answer" })
    RUBY
  end

  # One marker line plus enough clipped-length lines to cross FLUSH_BYTES, so the following
  # `deliver_pending` is exactly ONE delivery attempt: the outage and the recovery become
  # deterministic events rather than a race with the flush timer.
  def flush_batch(stream, marker)
    stream.accept("status", marker)
    5.times { stream.accept("status", "x" * (SpecrelayRunner::ExecutorLogStream::MAX_LINE_BYTES - 100)) }
  end

  # A stream wired to the REAL EventEmitter, because exact-envelope retry is a claim about the
  # sequence and payload an emitter builds — a double could only restate the assertion.
  def live_stream(client, io: StringIO.new)
    emitter = SpecrelayRunner::EventEmitter.new(client: client, run_id: "run_60", attempt_id: "rex_60")
    stream = SpecrelayRunner::ExecutorLogStream.new(emitter: emitter, io: io, provider: "claude",
                                                    task_id: "DEMO-0060", clock: FakeClock.new)
    [ stream, io ]
  end

  def with_execution
    root, executor = DemoWorkspace.build
    platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: "DEMO-0018", executor_command: executor)).start
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: live-log-runner
        display_name: Live Log Runner
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{root}
    YAML
    io = StringIO.new
    code = SpecrelayRunner::CLI.run(%W[claim-once --config #{path}], out: io, err: io,
                                                                    env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] })
    assert_equal SpecrelayRunner::CLI::SUCCESS, code, io.string
    yield platform, io.string
  ensure
    platform&.stop
    FileUtils.remove_entry(root) if root && File.directory?(root)
  end

  # A monotonic clock the test advances by hand, so heartbeat timing is exact
  # rather than slept for.
  class FakeClock
    def initialize = @now = 1_000.0
    def advance(seconds) = @now += seconds
    def clock_gettime(_id) = @now
  end

  # Records what the stream tried to send, and can be told to fail or to return a
  # stop-signalling lease.
  class RecordingEmitter
    attr_accessor :lease
    attr_reader :sent

    def initialize
      @sent = []
      @fail_next = false
      @failures = 0
      @lease = { "state" => "active", "cancel_requested" => false }
    end

    def fail_next! = @fail_next = true

    def emit(event_type, summary, log_chunk: nil, **attributes)
      @sent << { type: event_type, summary: summary, log_chunk: log_chunk, attributes: attributes }
      if @fail_next
        @fail_next = false
        @failures += 1
        raise SpecrelayRunner::PlatformClient::Error, "simulated transport failure"
      end
      { "lease" => lease }
    end

    def chunks = @sent.select { |e| e[:type] == "log.chunk" }
    def events_of(type) = @sent.select { |e| e[:type] == type }

    # EventEmitter's delivery-gap interface, which the stream drives on every submit.
    def retry_undelivered = undelivered_count
    def undelivered_count = @failures
  end

  # A PlatformClient stand-in that can be taken OFFLINE (a transport fault, whose outcome is
  # unknown and may succeed later) or made to REFUSE (Platform read the payload and rejected
  # it). Every attempted body is kept, so a retry can be compared with the original.
  class RecordingClient
    attr_accessor :offline, :refuse

    # `delay` holds every request open, the way a slow or hanging Platform does. It is what makes
    # "the reader never waits for delivery" a measurement rather than a reading of the source.
    def initialize(delay: 0)
      @attempts = []
      @accepted = []
      @offline = false
      @refuse = false
      @delay = delay
    end

    def submit_protocol_event(claim:, event:, **)
      _ = claim
      sleep @delay if @delay.positive?
      @attempts << event
      raise SpecrelayRunner::PlatformClient::RequestFailed.new("refused", status: 422) if refuse
      raise SpecrelayRunner::PlatformClient::Error, "unreachable" if offline

      @accepted << event
      { "lease" => { "state" => "active", "cancel_requested" => false } }
    end

    def accepted_sequences = @accepted.map { |e| e["sequence"] }
    def accepted_for(sequence) = @accepted.find { |e| e["sequence"] == sequence }
    def attempts_for(sequence) = @attempts.select { |e| e["sequence"] == sequence }
    def first_attempt_for(sequence) = attempts_for(sequence).first
  end
end
