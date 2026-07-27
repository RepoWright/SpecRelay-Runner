# frozen_string_literal: true

module SpecrelayRunner
  # MVP-0018 — the live executor output pipeline. It sits between the executor
  # process and the two places live progress is shown: the operator's terminal and
  # Platform's ordered event stream.
  #
  # The problem it solves: a real Claude run printed `[core.started] Running claude
  # executor ...` and then nothing for minutes. The run was healthy, but silence is
  # indistinguishable from a hang.
  #
  # The invariants, in the order they are applied to every line:
  #
  #   1. REDACT. `Redaction.redact` runs before the line is printed and before it is
  #      queued for upload, so no code path exists that can put an unredacted line
  #      on a terminal, in a log file, or on the wire.
  #   2. CLIP. One line is capped at MAX_LINE_BYTES so a provider that emits a
  #      megabyte on one line cannot flood a terminal or a browser row.
  #   3. BUDGET. The whole run's live stream is capped at MAX_TOTAL_BYTES. Reaching
  #      it emits ONE `log.truncated` event and stops accepting — visibly, never
  #      silently. The full capture is still in the report's stdout/stderr evidence.
  #   4. BATCH. Lines are coalesced per stream and flushed on a byte threshold or a
  #      short interval, so a chatty provider produces a bounded number of events
  #      rather than one HTTP request per line.
  #
  # And two things it must never do, both learned from the legacy runner:
  #
  #   - it must never fail the execution it reports on. Every upload error is
  #     swallowed and counted; the authoritative result is the buffered capture and
  #     the terminal-result envelope.
  #   - a heartbeat is a fallback, not a substitute. `core.progress` is emitted only
  #     when the provider has said nothing for HEARTBEAT_INTERVAL_SECONDS, so an
  #     operator can always tell "working, quiet" from "working, talking".
  #
  # Thread model: `accept` is called from CommandRunner's two reader threads and a
  # timer thread emits heartbeats, so all mutable state is behind one mutex. The
  # HTTP POST happens outside the mutex (the emitter is itself thread-safe), so a
  # slow Platform never blocks the reader threads and therefore never applies
  # back-pressure to the executor's stdout pipe.
  class ExecutorLogStream
    MAX_LINE_BYTES = 2_000
    MAX_TOTAL_BYTES = 131_072
    FLUSH_BYTES = 8_192
    FLUSH_INTERVAL_SECONDS = 2
    HEARTBEAT_INTERVAL_SECONDS = 15
    TICK_SECONDS = 0.25

    LINE_CLIP_MARKER = " [line clipped at #{MAX_LINE_BYTES} bytes]"
    TRUNCATION_NOTICE = "live executor output reached its #{MAX_TOTAL_BYTES}-byte budget; " \
                        "later output is in the report's stdout/stderr evidence"

    # Event vocabulary (documented in docs/runner-api.md and the v1 contract).
    CHUNK_EVENT = "log.chunk"
    HEARTBEAT_EVENT = "core.progress"
    TRUNCATED_EVENT = "log.truncated"

    def self.start(**kwargs) = new(**kwargs).start

    # `provider` only names the executor in operator-facing text. `io` is the CLI's
    # own writer, shared with Heartbeater, so terminal output stays on one stream.
    def initialize(emitter:, io:, provider:, task_id:, clock: Process,
                   heartbeat_interval: HEARTBEAT_INTERVAL_SECONDS,
                   flush_interval: FLUSH_INTERVAL_SECONDS)
      @emitter = emitter
      @io = io
      @provider = provider.to_s
      @task_id = task_id.to_s
      @clock = clock
      @heartbeat_interval = heartbeat_interval
      @flush_interval = flush_interval
      @mutex = Mutex.new
      @buffers = {}
      @evidence = []
      @total_bytes = 0
      @emitted_lines = 0
      @upload_failures = 0
      @truncated = false
      @finished = false
      @running = false
      @stop_reason = nil
      @started_at = now
      @last_output_at = @started_at
      @last_flush_at = @started_at
      @last_heartbeat_at = @started_at
    end

    def start
      @running = true
      @timer = Thread.new { tick_loop }
      self
    end

    # The callback handed to Executor#run. Returning a lambda (rather than exposing
    # `accept` directly) keeps the CommandRunner contract a plain proc.
    def sink = ->(source, line) { accept(source, line) }

    # One complete output line from the executor. Called from a reader thread.
    def accept(source, line)
      text = Redaction.redact(line.to_s)
      pending = @mutex.synchronize { record(source, text) }
      flush(pending) if pending
    end

    # Stops the timer, flushes what is buffered, and emits the truncation notice if
    # the budget was reached.
    #
    # IDEMPOTENT by design: Execution stops the stream when the executor returns
    # (so the live log closes with the core phase) and again in its outer `ensure`
    # (so an exception on any path still stops the thread). A second call must not
    # re-print or re-emit the truncation notice.
    def finish
      return self if claim_finish_turn == :already_finished

      @running = false
      @timer&.join
      @timer = nil
      flush_all
      announce_truncation
      report_upload_failures
      self
    end

    # A stop signal Platform returned on one of OUR event responses (cancelled,
    # expired, or superseded attempt). Execution consults this at its checkpoints,
    # exactly as it consults Heartbeater#stop_reason.
    def stop_reason = @mutex.synchronize { @stop_reason }

    def emitted_lines = @mutex.synchronize { @emitted_lines }
    def truncated? = @mutex.synchronize { @truncated }

    # The exact bounded, redacted live stream, for the report's live-log evidence
    # file. It is deliberately a SEPARATE artifact from the full stdout/stderr
    # capture, so a reviewer can tell what the operator actually saw during the run
    # from what was collected for review afterwards.
    def evidence_text
      lines = @mutex.synchronize { @evidence.dup }
      header + (lines.empty? ? [ "(the executor emitted no live output)" ] : lines).join("\n") + "\n"
    end

    private

    attr_reader :emitter, :io, :provider, :task_id, :clock, :heartbeat_interval, :flush_interval

    def claim_finish_turn
      @mutex.synchronize do
        next :already_finished if @finished

        @finished = true
        :first
      end
    end

    # ---- accounting (always under the mutex) --------------------------------

    # Applies the per-line clip and the whole-run budget, appends to the per-stream
    # buffer, and returns a flushable batch when one is due (so the HTTP POST can
    # happen outside the lock).
    def record(source, text)
      return nil if @truncated

      clipped = clip(text)
      # The line's own bytes PLUS the newline that will separate it from the next
      # one when lines are joined into a chunk. Counting only the line bytes let the
      # uploaded total drift past the budget by one byte per line.
      cost = clipped.bytesize + 1
      return budget_exhausted if @total_bytes + cost > MAX_TOTAL_BYTES

      @total_bytes += cost
      @emitted_lines += 1
      @last_output_at = now
      @evidence << "[#{source}] #{clipped}"
      print_line(source, clipped)
      (@buffers[source] ||= []) << clipped
      due_batch(source)
    end

    def budget_exhausted
      @truncated = true
      nil
    end

    def clip(text)
      return text if text.bytesize <= MAX_LINE_BYTES

      kept = MAX_LINE_BYTES - LINE_CLIP_MARKER.bytesize
      "#{text.byteslice(0, kept).force_encoding(Encoding::UTF_8).scrub('')}#{LINE_CLIP_MARKER}"
    end

    def due_batch(source)
      buffered = @buffers[source]
      return nil unless buffered && buffered.sum { |line| line.bytesize + 1 } >= FLUSH_BYTES

      take(source)
    end

    # Removes and returns one stream's buffer as a [source, text] batch.
    def take(source)
      lines = @buffers.delete(source)
      return nil if lines.nil? || lines.empty?

      @last_flush_at = now
      [ source, lines.join("\n") ]
    end

    # ---- emission (always outside the mutex) --------------------------------

    def flush(batch)
      source, text = batch
      submit(CHUNK_EVENT, chunk_summary(source, text), log_source: source, phase: "core", log_chunk: text)
    end

    def flush_all
      batches = @mutex.synchronize { @buffers.keys.filter_map { |source| take(source) } }
      batches.each { |batch| flush(batch) }
    end

    def announce_truncation
      return unless truncated?

      print_line("status", TRUNCATION_NOTICE)
      @mutex.synchronize { @evidence << "[status] #{TRUNCATION_NOTICE}" }
      submit(TRUNCATED_EVENT, TRUNCATION_NOTICE, log_source: "status", phase: "core", note: "budget_exhausted")
    end

    # Every upload failure is counted rather than raised, then reported once so a
    # silent gap in the Platform-side log is never invisible to the operator.
    def report_upload_failures
      failures = @mutex.synchronize { @upload_failures }
      return if failures.zero?

      write "[core.progress] #{failures} live log update(s) could not be delivered to Platform; " \
            "the terminal output above and the report evidence are unaffected"
    end

    # The one place a live log event is sent. A transport failure is counted, never
    # raised: the live view is progress evidence, and losing a chunk of it must not
    # change the outcome of the run.
    def submit(event_type, summary, log_chunk: nil, **attributes)
      response = emitter.emit(event_type, summary, log_chunk: log_chunk, **attributes)
      observe(response)
    rescue PlatformClient::Error
      @mutex.synchronize { @upload_failures += 1 }
      nil
    end

    # Live log responses carry the same MVP-0012 lease signal every other event
    # response does, so the stream observes stop conditions for free.
    def observe(response)
      lease = response.is_a?(Hash) ? response["lease"] : nil
      return response unless lease.is_a?(Hash)

      state = lease["state"].to_s
      cancelled = lease["cancel_requested"] ? true : false
      @mutex.synchronize { @stop_reason ||= state } unless state == "active" && !cancelled
      @mutex.synchronize { @stop_reason ||= "cancelled" } if cancelled
      response
    end

    # ---- terminal output ----------------------------------------------------

    # The stream name is printed as PLAIN TEXT, not conveyed by colour: the terminal
    # may be a pipe, a CI log, or a screenshot, and the operator must still be able
    # to tell stdout from stderr.
    def print_line(source, text)
      write "  [#{provider}:#{source}] #{text}"
    end

    # Ruby BLOCK-buffers stdout when it is not a terminal, so a redirected or piped
    # run showed nothing until the process exited — which is precisely the silence
    # this feature exists to remove, just moved from "no output" to "no output yet".
    # Live output has to be flushed to be live.
    def write(line)
      io.puts line
      io.flush if io.respond_to?(:flush)
    end

    def chunk_summary(source, text)
      count = text.count("\n") + 1
      "#{provider} #{source}: #{count} line#{'s' unless count == 1} of executor output"
    end

    # ---- timer thread ------------------------------------------------------

    # One low-frequency thread drives both the time-based flush (so a trickle of
    # output still reaches Platform promptly) and the quiet-period heartbeat.
    def tick_loop
      while @running
        sleep TICK_SECONDS
        flush_if_due
        heartbeat_if_quiet
      end
    rescue StandardError
      # A progress thread must never take the run down with it.
      nil
    end

    def flush_if_due
      batches = @mutex.synchronize do
        next [] unless now - @last_flush_at >= flush_interval

        @buffers.keys.filter_map { |source| take(source) }
      end
      batches.each { |batch| flush(batch) }
    end

    # A heartbeat is emitted only while the provider is QUIET. Once real output
    # resumes, `@last_output_at` moves and the heartbeat goes away on its own.
    def heartbeat_if_quiet
      elapsed = @mutex.synchronize do
        next nil unless quiet? && heartbeat_due?

        @last_heartbeat_at = now
        (now - @started_at).round
      end
      return if elapsed.nil?

      message = "#{provider} executor running for #{elapsed}s on #{task_id} (no new output yet)"
      print_line("status", message)
      # Recorded in the evidence file too: the quiet periods are part of what the
      # operator saw, and a report that showed only the talkative moments would not
      # explain why a run took as long as it did.
      @mutex.synchronize { @evidence << "[status] #{message}" }
      submit(HEARTBEAT_EVENT, message, log_source: "status", phase: "core", duration_seconds: elapsed)
    end

    def quiet? = now - @last_output_at >= heartbeat_interval
    def heartbeat_due? = now - @last_heartbeat_at >= heartbeat_interval

    def header
      [ "# Live executor output (MVP-0018)",
        "#",
        "# What this is: the bounded, redacted stream the operator saw in the terminal",
        "# and in Platform WHILE the executor ran. Each line is prefixed with its",
        "# source stream.",
        "#",
        "# What this is NOT: the full capture. evidence/stdout.log and",
        "# evidence/stderr.log hold the complete executor output collected for review.",
        "# Lines here are clipped at #{MAX_LINE_BYTES} bytes and the whole stream at",
        "# #{MAX_TOTAL_BYTES} bytes; a [status] line records it when that happened.",
        "#",
        "# Redacted before display, before upload, and before this file was written.",
        "",
        "" ].join("\n")
    end

    def now = clock.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
