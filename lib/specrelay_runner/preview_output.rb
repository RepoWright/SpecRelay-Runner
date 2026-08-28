# frozen_string_literal: true

module SpecrelayRunner
  # MAPIAI-97 CR-006 — the preview lane's output boundary, in front of the one log stream.
  #
  # A preview streams the PROJECT'S OWN command output, and the project's commands name the
  # machine they run on: `create` prints the directory it made, `status --json` reports a
  # `worktree_path` per repository, `release` says what it is removing. The closed wire-status
  # document drops those fields on purpose; streaming the raw line walked past that projection and
  # onto an authenticated page. {PrivatePaths} is the rule; this is where the preview applies it.
  #
  # It is deliberately opt-in and preview-only. Ordinary executor, specification and review output
  # is unchanged: those lanes have their own approved policies, and needing this here is not a
  # reason to start filtering theirs.
  #
  # It removes ONLY private host paths. Ports, Compose project names, slots, task ids,
  # repository-relative paths and ordinary prose are operational content the Product Owner asked
  # to see raw, and they pass through untouched — including when the reader cuts them in half.
  # A long token is not a private token (CR-008 F9); the previous rule replaced the tail of every
  # fragment and the head of every continuation, which destroyed exactly the raw output this
  # feature exists to show.
  class PreviewOutput
    # `CommandRunner` hands over complete lines, except for one bounded fallback: a single token
    # that outgrows its pending-line cap is delivered in pieces. A private root can straddle that
    # cut, and neither piece then matches on its own.
    #
    # A root is at most {PrivatePaths::LONGEST_ROOT_BYTES} characters and contains no whitespace,
    # so at most one character less than that can sit on the near side of a cut — always inside
    # the fragment's trailing non-whitespace run. Holding exactly that much back, and emitting it
    # unchanged in front of the next callback, is enough to recognise a split root while deciding
    # nothing about bytes that are not one. It is a look-behind, not a buffer: it cannot grow with
    # the length of the token, and a newline or the end of the stream flushes it.
    CARRY_CHARS = PrivatePaths::LONGEST_ROOT_BYTES - 1
    UNDECIDED = /\S{1,#{CARRY_CHARS}}\z/

    # One stream's state: the undecided characters held back from its last fragment, and — when a
    # private path was itself cut in half — the pattern matching what is left of it.
    Stream = Struct.new(:carry, :suppress)

    # `sink` receives `(source, text)` — in practice {ExecutorLogStream}'s `accept`, which prints
    # locally and queues the same bytes for Platform. Sanitizing in front of it is what makes the
    # two surfaces identical rather than two chances to get it wrong.
    def initialize(sink)
      @sink = sink
      # Pre-seeded so the two reader threads only ever assign into an entry that already exists.
      # Each source is read by exactly one thread, so neither ever waits for the other.
      @streams = { CommandRunner::STDOUT => Stream.new(+"", nil),
                   CommandRunner::STDERR => Stream.new(+"", nil) }
    end

    # What this sanitizer is holding, across both streams. Bounded by CARRY_CHARS per source —
    # asserted rather than assumed, because "bounded" is the whole claim.
    def carried_bytes = @streams.values.sum { |stream| stream.carry.bytesize }

    # `piece` is the reader's own account of the callback. It defaults to a complete line for the
    # runner's synthesised narration, which is read from no process and can never be cut.
    def call(source, text, piece = CommandRunner::COMPLETE_LINE)
      body = decide(@streams[source] || Stream.new(+"", nil), text, piece)
      @sink.call(source, body) unless body.empty?
    end

    private

    def decide(stream, text, piece)
      buffer = "#{stream.carry}#{text}"
      stream.carry = +""
      rest = resume(stream, buffer)
      return hold(stream, rest) if piece.cut?

      # A newline, or the end of the stream, ends every token it could have been holding.
      stream.suppress = nil
      PrivatePaths.sanitize(rest)
    end

    # A path an earlier fragment already reported keeps being suppressed until the terminator it
    # was cut before. Everything after that terminator is ordinary output again, so only the
    # remainder of the one path is dropped — never the prose beside it.
    def resume(stream, buffer)
      return buffer if stream.suppress.nil?

      consumed = buffer[stream.suppress].to_s
      return +"" if !buffer.empty? && consumed.length == buffer.length

      stream.suppress = nil
      buffer[consumed.length..].to_s
    end

    # The reader cut this fragment short. Either it ends inside a private path — report that once,
    # and suppress its remainder — or it ends in characters that are still undecided, which are
    # held for the next callback rather than judged now.
    def hold(stream, buffer)
      path, remainder = PrivatePaths.open_path(buffer)
      if path
        stream.suppress = remainder
        return "#{PrivatePaths.sanitize(buffer[0, buffer.length - path.length])}#{PrivatePaths::REDACTION}"
      end

      stream.carry = buffer[UNDECIDED].to_s
      PrivatePaths.sanitize(buffer[0, buffer.length - stream.carry.length])
    end
  end
end
