# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"

# MAPIAI-97 — what the preview sanitizer may and may not do with output the reader cut in half.
#
# CR-007 moved the cut fact to its owner: `CommandRunner` says whether a callback ended at a
# newline, at EOF, or at its bounded unterminated fallback, and whether it began inside a token an
# earlier fallback cut. CR-008 fixes what the preview lane then DID with that fact — it replaced
# the tail of every fragment and the head of every continuation, whether or not a private path was
# anywhere near them. Long output is not private output.
#
# The rule now is conditional: hold back the few bytes that could still become a private root,
# decide when the next callback arrives, and emit everything else exactly as it was read. Every
# example drives the REAL reader against a real child process.
class PreviewOutputFragmentsTest < Minitest::Test
  BOUND = SpecrelayRunner::CommandRunner::MAX_PENDING_LINE_BYTES
  REDACTED = SpecrelayRunner::PrivatePaths::REDACTION
  NEXT_LINE = "the next line is independent"
  PROSE = " safe prose"

  # Long enough to cross the bound several times over, so "a complete line is complete" is
  # asserted at the boundary and well past it.
  LENGTHS = [ BOUND - 1, BOUND, BOUND + 1, BOUND * 2, BOUND * 3, BOUND * 4 ].freeze

  # The private tail every split case carries, and the parts of it that must never be shown.
  PRIVATE_TAIL = "jane/secret-notes.txt"
  SECRETS = %w[jane secret-notes.txt].freeze

  # Every root the one rule supports. The matrix below cuts each of them at EVERY byte.
  ROOTS = [ "/Users/", "/home/", "/tmp/", "/private/tmp/", "/private/var/folders/",
            "file://", 'C:\\Users\\' ].freeze

  # Records the reader's own Piece for every callback and then hands it to the real sanitizer. It
  # declares three arguments, so `CommandRunner` gives it exactly what it gives `PreviewOutput` —
  # this observes the boundary, it does not stand in for it.
  class Recorder
    attr_reader :pieces, :seen, :output

    def initialize
      @pieces = []
      @seen = []
      @output = SpecrelayRunner::PreviewOutput.new(->(source, text) { @seen << [ source, text ] })
    end

    def call(source, text, piece)
      @pieces << [ source, piece.terminator ]
      @output.call(source, text, piece)
    end

    def fragments = pieces.count { |(_source, terminator)| terminator == :bound }
    # Everything the sink was handed, in order and with nothing between: what the operator's
    # terminal and Platform would show, reassembled.
    def joined = seen.map(&:last).join
    def text_of(source) = seen.select { |(from, _)| from == source }.map(&:last).join
  end

  # ExecutorLogStream's Platform side, reduced to what it actually drives.
  class Emitter
    def initialize = (@sent = [])

    def emit(event_type, _summary, log_chunk: nil, **_attributes)
      @sent << [ event_type, log_chunk.to_s ]
      { "lease" => { "state" => "active", "cancel_requested" => false } }
    end

    def retry_undelivered = 0
    def undelivered_count = 0
    def chunks = @sent.select { |(type, _)| type == "log.chunk" }.map(&:last).join("\n")
  end

  def setup = (@tmp = Dir.mktmpdir("preview-fragments"))

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
  end

  # ---- a complete line is complete at every length (CR-007 F7) ---------------------------

  # The ordinary lane — the same stream with no sanitizer in front of it — is the baseline. If
  # the preview lane's terminal text and uploaded chunks are byte for byte the same, then being a
  # preview added, removed and reordered nothing; the only difference left is the per-line clip
  # that both lanes already had.
  def test_a_complete_line_of_any_length_survives_the_preview_boundary_byte_for_byte
    corrupted = LENGTHS.reject do |size|
      body = long_line_script(size)
      plain = rendered(body, preview: false)
      through_preview = rendered(body, preview: true)
      plain == through_preview && through_preview.last.include?(NEXT_LINE)
    end

    assert_equal [], corrupted, "the preview boundary changed complete lines of these lengths"
  end

  def test_the_line_after_a_long_complete_line_is_never_treated_as_its_continuation
    swallowed = LENGTHS.reject { |size| preview(long_line_script(size)).first.joined.include?(NEXT_LINE) }

    assert_equal [], swallowed, "these lengths made the following independent line a continuation"
  end

  def test_a_final_line_without_a_newline_is_intact_even_after_a_bound_length_line
    recorder, = preview(<<~RUBY)
      $stdout.sync = true
      $stdout.write("x" * #{BOUND} + "\\n")
      $stdout.write("done, no trailing newline")
    RUBY

    assert_equal [ "x" * BOUND, "done, no trailing newline" ], recorder.seen.map(&:last)
  end

  # ---- CR-008 F9.1/F9.2: a bounded token that is not a path keeps every byte ---------------

  # The defect this replaces: a long unterminated token gained a placeholder and lost bytes for no
  # reason other than its length. Byte equality with the source is the whole assertion — it proves
  # at once that nothing was redacted, nothing was dropped, and nothing was emitted twice.
  def test_a_path_free_token_crossing_the_bound_keeps_every_byte_and_gains_no_placeholder
    damaged = [ 1, 2, 8 ].flat_map { |pieces| ENDINGS.map { |tail| carry_case(pieces, tail) } }.compact

    assert_equal [], damaged
  end

  # ---- CR-008 F9.3: every byte at which the reader can cut a root -------------------------

  def test_a_root_cut_at_any_byte_leaks_neither_side_nor_its_continuation
    recorder, = preview(split_matrix_script)
    text = recorder.joined

    assert_equal split_cases.length, recorder.fragments,
                 "a case did not reach the reader's bounded fallback, so it proved nothing"
    assert_equal split_cases.length, text.scan(REDACTED).length
    assert_equal split_cases.length, text.scan("-ok").length, "an ordinary marker was eaten"
    SECRETS.each { |secret| refute_includes text, secret }
    # Every root byte is one of these three characters, and nothing else in this fixture is. So a
    # surviving root — either side of any cut — shows up here whatever it was cut down to.
    [ "/", "\\", ":" ].each { |char| refute_includes text, char, "part of a root survived" }
  end

  # ---- CR-008 F9.4: a private path longer than one fragment -------------------------------

  def test_a_private_path_spanning_several_fragments_is_suppressed_to_its_own_terminator
    recorder, = preview(<<~RUBY)
      $stdout.sync = true
      $stdout.write("A" * #{BOUND} + "/Users/jane/")
      sleep 0.15
      3.times do
        $stdout.write("x" * #{BOUND + 1})
        sleep 0.15
      end
      $stdout.write("/secret-notes.txt and then prose\\n")
    RUBY
    text = recorder.joined

    assert_operator recorder.fragments, :>=, 4, "the path never crossed the bounded fallback"
    SECRETS.each { |secret| refute_includes text, secret }
    refute_includes text, "x" * 40, "the body of the path reached the sink"
    assert_includes text, REDACTED
    assert_includes text, " and then prose", "prose after the path's terminator was eaten"
  end

  # ---- CR-008 F9.5: two streams, two states ------------------------------------------------

  def test_stdout_and_stderr_cannot_borrow_carry_or_private_path_state
    recorder, = preview(<<~RUBY)
      $stdout.sync = true
      $stderr.sync = true
      $stdout.write("A" * #{BOUND} + "/Users/jane/sec")
      sleep 0.25
      $stderr.write("B" * #{BOUND} + "/Use")
      sleep 0.25
      $stderr.puts "rs/other/private-file.txt done-stderr"
      sleep 0.25
      $stdout.puts "ret-notes.txt done-stdout"
    RUBY
    out = recorder.text_of("stdout")
    err = recorder.text_of("stderr")

    assert_includes out, "done-stdout"
    assert_includes err, "done-stderr"
    assert_equal "A" * BOUND, out.sub(REDACTED, "").sub(" done-stdout", "")
    assert_equal "B" * BOUND, err.sub(REDACTED, "").sub(" done-stderr", "")
    (SECRETS + %w[other private-file.txt]).each { |secret| refute_includes recorder.joined, secret }
  end

  # ---- CR-008 F9.6: bounded, and delivered while the child is alive -------------------------

  def test_delivery_is_prompt_and_the_sanitizer_holds_no_more_than_the_published_bound
    held = []
    times = []
    sanitizer = nil
    sanitizer = SpecrelayRunner::PreviewOutput.new(lambda { |_source, _text|
      held << sanitizer.carried_bytes
      times << monotonic
    })
    run_script(token_script(2, PROSE), sanitizer)

    refute_empty times
    assert_operator times.first, :<, monotonic - 0.2, "the fragment was held until the process exited"
    # One character of a root can be four bytes of UTF-8, which is the only reason this is not
    # simply CARRY_CHARS. Nothing here can grow with the length of the token.
    assert_operator held.max, :<=, SpecrelayRunner::PreviewOutput::CARRY_CHARS * 4
    assert_equal 0, sanitizer.carried_bytes, "the last flush left bytes behind"
  end

  # ---- CR-008 F9.7: the captured result is the unsanitized original -------------------------

  def test_the_captured_result_and_the_exit_status_are_untouched_by_sanitization
    recorder, result = preview(<<~RUBY)
      $stdout.sync = true
      puts "worktree_path /Users/jane/secret-notes.txt"
      $stderr.puts "and /home/jane/other"
      exit 4
    RUBY

    assert_includes result.stdout, "/Users/jane/secret-notes.txt",
                    "local status parsing reads the captured result, not the log"
    assert_includes result.stderr, "/home/jane/other"
    assert_equal 4, result.exit_code
    refute_predicate result, :success?
    refute_predicate result, :timed_out?
    SECRETS.each { |secret| refute_includes recorder.joined, secret }
  end

  private

  ENDINGS = [ "#{PROSE}\n", PROSE, "" ].freeze

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Nil when this many bounded fragments came through untouched; otherwise a one-line account of
  # what went wrong, so a matrix failure names every case at once without printing 64 KiB of it.
  def carry_case(pieces, tail)
    recorder, = preview(token_script(pieces, tail))
    expected = ("A" * (pieces * (BOUND + 1))) + tail.chomp
    return nil if recorder.joined == expected && recorder.fragments == pieces

    "#{pieces} fragment(s) ending #{tail.inspect}: #{recorder.joined.length} of #{expected.length} " \
      "chars, #{recorder.joined.scan(REDACTED).length} placeholder(s), #{recorder.fragments} cut(s)"
  end

  # One unterminated token written in `pieces` writes, each over the reader's bound and far enough
  # apart that the reader really returns them separately — the only way its bounded fallback fires
  # more than once.
  def token_script(pieces, tail)
    <<~RUBY
      $stdout.sync = true
      #{pieces}.times do
        $stdout.write("A" * #{BOUND + 1})
        sleep 0.15
      end
      $stdout.write(#{tail.inspect})
    RUBY
  end

  # Each root, cut at each of its bytes, as [what precedes the cut, what follows it].
  def split_cases
    @split_cases ||= ROOTS.flat_map do |root|
      (0..root.length).map { |offset| [ root[0, offset], "#{root[offset..]}#{PRIVATE_TAIL}" ] }
    end
  end

  # One child for the whole matrix. The sleep BEFORE each token matters as much as the one after
  # it: without it the previous line's newline can still be in the same read, and the reader then
  # completes the token instead of cutting it — which is how a split test quietly stops testing.
  def split_matrix_script
    <<~RUBY
      $stdout.sync = true
      #{split_cases.inspect}.each_with_index do |(head, tail), index|
        sleep 0.12
        $stdout.write("A" * #{BOUND} + head)
        sleep 0.12
        $stdout.write(tail + " case-\#{index}-ok\\n")
      end
    RUBY
  end

  def long_line_script(size)
    <<~RUBY
      $stdout.sync = true
      $stdout.write("x" * #{size} + "\\n")
      $stdout.write(#{NEXT_LINE.inspect} + "\\n")
    RUBY
  end

  def run_script(body, sink)
    path = File.join(@tmp, "script-#{rand(1 << 32)}.rb")
    File.write(path, body)
    SpecrelayRunner::CommandRunner.run([ RbConfig.ruby, path ], chdir: @tmp,
                                       env: { "PATH" => ENV["PATH"] }, timeout_seconds: 60,
                                       on_output: sink)
  end

  def preview(body)
    recorder = Recorder.new
    [ recorder, run_script(body, recorder) ]
  end

  # One script through the WHOLE presentation boundary: sanitizer, stream, operator terminal and
  # the queued Platform chunks.
  def rendered(body, preview:)
    io = StringIO.new
    emitter = Emitter.new
    stream = SpecrelayRunner::ExecutorLogStream.new(emitter: emitter, io: io,
                                                    provider: "the task environment",
                                                    task_id: "MAPIAI-97").start
    run_script(body, preview ? SpecrelayRunner::PreviewOutput.new(stream.sink) : stream.sink)
    stream.finish
    [ io.string, emitter.chunks ]
  end
end
