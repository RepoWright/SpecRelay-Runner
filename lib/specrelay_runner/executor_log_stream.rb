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
  # Thread model: `accept` is called from CommandRunner's two reader threads, so all mutable
  # state is behind one mutex. Every Platform request for this stream is made by the ONE timer
  # thread, or by `finish` once the provider has already exited — never by a reader thread, and
  # never inside the mutex. That is what makes "a slow Platform cannot apply back-pressure to
  # the executor's stdout pipe" a property of the structure rather than a hope about latency
  # (MAPIAI-60 CR-001 F3; review 001 measured one reader `accept` blocked for 0.503s).
  #
  # There is one delivery owner and it needs no queue of its own: the per-stream buffers are the
  # pending work, bounded by MAX_TOTAL_BYTES, and EventEmitter holds the exact envelopes an
  # outage left undelivered. Because deliveries are serialized on that single thread, a retry of
  # an older sequence always precedes a newer one.
  class ExecutorLogStream
    MAX_LINE_BYTES = 2_000
    MAX_TOTAL_BYTES = 131_072
    FLUSH_BYTES = 8_192
    # The per-event cap in contracts/runner/v1/run-event.schema.json, which Platform also
    # enforces on ingest. Applied when a batch is CUT rather than when a line is appended:
    # since CR-001 F3 the reader no longer decides when to send, so a burst can buffer past
    # FLUSH_BYTES between ticks and the cap has to belong to whoever builds the chunk.
    MAX_CHUNK_BYTES = 65_536
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
    #
    # RUNNER-0001: it is wrapped in a TerminalPresenter (a no-op when the caller
    # already passed one) so this stream's writes and the loop's transient status
    # share ONE write boundary. Without it, a heartbeat timer and a reader thread
    # could each land half a line while the loop was redrawing its status row.
    def initialize(emitter:, io:, provider:, task_id:, clock: Process,
                   heartbeat_interval: HEARTBEAT_INTERVAL_SECONDS,
                   flush_interval: FLUSH_INTERVAL_SECONDS)
      @emitter = emitter
      @io = TerminalPresenter.wrap(io)
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

    # One complete output line from the executor, called from a reader thread — so it does only
    # what a reader thread may do: redact, clip, budget, print locally, and buffer.
    #
    # MAPIAI-60 CR-001 F3: it performs NO Platform I/O. It used to send the batch itself once one
    # was due, which put an HTTP request in front of the child's stdout: a slow or hanging
    # Platform stopped the reader, filled the pipe, and froze the very provider whose progress
    # was being reported. Delivery belongs to the timer thread and to {#finish}.
    def accept(source, line)
      text = Redaction.redact(line.to_s)
      @mutex.synchronize { record(source, text) }
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
      # MAPIAI-60 — the last delivery opportunity of the attempt. A gap that closed here still
      # closed during the attempt, which is why the report below runs after it, not before.
      emitter.retry_undelivered
      report_delivery_gap
      # A quiet-provider status row is only true while the provider is running.
      io.clear_status
      self
    end

    # The timer thread's unit of work, and the ONE place this stream talks to Platform while the
    # provider is still running: settle whatever an earlier outage left owed, then send any batch
    # that is now due.
    #
    # Public because it names the delivery boundary CR-001 F3 moved off the reader. The timer
    # drives it; a test steps it directly instead of racing a wall clock.
    def deliver_pending
      batches = @mutex.synchronize do
        next [] unless now - @last_flush_at >= flush_interval || buffered_bytes >= FLUSH_BYTES

        @buffers.keys.filter_map { |source| take(source) }
      end
      batches.each { |batch| flush(batch) }
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

    # Applies the per-line clip and the whole-run budget, then appends to the per-stream buffer.
    # Deciding that a batch is due — and sending it — is the timer thread's job.
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
      nil
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

    def buffered_bytes = @buffers.values.sum { |lines| lines.sum { |line| line.bytesize + 1 } }

    # Removes and returns ONE event's worth of a stream's buffer as a [source, text] batch,
    # leaving anything over the per-event cap for the next flush.
    def take(source)
      lines = @buffers[source]
      return nil if lines.nil? || lines.empty?

      batch = cut(lines)
      @buffers.delete(source) if lines.empty?
      @last_flush_at = now
      [ source, batch.join("\n") ]
    end

    # As many whole lines as fit in one event. A line is already clipped to MAX_LINE_BYTES, so
    # the first one always fits and this can never return an empty batch for a non-empty buffer.
    def cut(lines)
      bytes = 0
      batch = []
      while (line = lines.first) && bytes + line.bytesize + 1 <= MAX_CHUNK_BYTES
        bytes += line.bytesize + 1
        batch << lines.shift
      end
      batch
    end

    # ---- emission (always outside the mutex) --------------------------------

    def flush(batch)
      source, text = batch
      submit(CHUNK_EVENT, chunk_summary(source, text), log_source: source, phase: "core", log_chunk: text)
    end

    # Drains every buffer, however many events that takes: `take` now yields at most one
    # capped event per call, so a single pass could leave output behind.
    def flush_all
      loop do
        batches = @mutex.synchronize { @buffers.keys.filter_map { |source| take(source) } }
        break if batches.empty?

        batches.each { |batch| flush(batch) }
      end
    end

    def announce_truncation
      return unless truncated?

      print_line("status", TRUNCATION_NOTICE)
      @mutex.synchronize { @evidence << "[status] #{TRUNCATION_NOTICE}" }
      submit(TRUNCATED_EVENT, TRUNCATION_NOTICE, log_source: "status", phase: "core", note: "budget_exhausted")
    end

    # What Platform never accepted, reported once at the end so a silent gap in the Platform-side
    # log is never invisible to the operator. It is the emitter's count, not a local one: after
    # MAPIAI-60 a failed delivery may still be retried, so "how many attempts failed" would
    # overstate the gap and claim missing output that in fact arrived.
    def report_delivery_gap
      owed = emitter.undelivered_count
      return if owed.zero?

      write "[core.progress] #{owed} live log update(s) could not be delivered to Platform; " \
            "the terminal output above and the report evidence are unaffected"
    end

    # The one place a live log event is sent. A transport failure is swallowed, never raised: the
    # live view is progress evidence, and losing a chunk of it must not change the outcome of the
    # run.
    #
    # MAPIAI-60 — every submission is also a delivery opportunity for whatever an earlier outage
    # left undelivered, which is what makes reconnection a property of the ordinary path instead
    # of a reconnect daemon, a disk queue, or a second retention policy. Retrying here is what
    # puts the oldest pending sequence ahead of newer delivery; it is safe to do synchronously
    # because every caller of this method is the timer thread or `finish`, never a reader.
    def submit(event_type, summary, log_chunk: nil, **attributes)
      emitter.retry_undelivered
      observe(emitter.emit(event_type, summary, log_chunk: log_chunk, **attributes))
    rescue PlatformClient::Error
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
    # Live output has to be flushed to be live; the presenter flushes every line,
    # and clears any transient status row before writing it.
    def write(line) = io.line(line)

    def chunk_summary(source, text)
      count = text.count("\n") + 1
      "#{provider} #{source}: #{count} line#{'s' unless count == 1} of executor output"
    end

    # ---- timer thread ------------------------------------------------------

    # One low-frequency thread drives both delivery (so a trickle of output still reaches
    # Platform promptly, and a burst is sent without the reader ever waiting) and the
    # quiet-period heartbeat.
    def tick_loop
      while @running
        sleep TICK_SECONDS
        deliver_pending
        heartbeat_if_quiet
      end
    rescue StandardError
      # A progress thread must never take the run down with it.
      nil
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
      # RUNNER-0001 scope 5: elapsed liveness is true only NOW, so in a terminal it
      # replaces the status row instead of appending a line every interval — and the
      # next real provider line clears it before printing. With no row to redraw it
      # stays a plain bounded line, because a CI log has nowhere else to show it.
      #
      # The Platform `core.progress` event and the report evidence below are
      # unchanged: they are the durable protocol/evidence record of the same fact,
      # and only its TERMINAL representation became transient.
      io.status("[#{provider}:status] #{message}", fallback: :line)
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
