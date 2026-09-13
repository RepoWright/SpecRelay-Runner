# frozen_string_literal: true

require "test_helper"
require "open3"

# The canonical full-suite command.
#
# Every case builds a throwaway checkout holding a copy of the real executable plus the few
# generated test files that case needs. The command locates its own checkout from its own path,
# so a copy governs a directory containing nothing but the files under test — which is how
# scheduling, accounting, attribution and refusal can be proven here without this repository's
# own suite launching itself from inside one of its own files.
class FullSuiteCommandTest < Minitest::Test
  COMMAND = File.expand_path("../bin/test", __dir__)
  NAMES = %w[alpha_test.rb beta_test.rb gamma_test.rb].freeze

  # The flood case writes far more than the command may retain, so an implementation that keeps
  # the whole stream — in memory or in a file — is separated from one that keeps only the tail.
  LOUD_MEGABYTES = 64
  RETAINED_BYTES_BOUND = 256 * 1024
  RESIDENT_KILOBYTES_BOUND = 64 * 1024

  def setup
    @checkouts = []
  end

  def teardown
    @checkouts.each { |dir| FileUtils.remove_entry(dir) }
  end

  def test_one_worker_runs_every_discovered_file_exactly_once_in_its_own_process
    dir = three_file_checkout

    output, status = run_suite(dir, "--workers", "1")

    assert_equal 0, status, output
    assert_equal NAMES, ledger(dir).map(&:first).sort
    assert_equal 3, ledger(dir).map(&:last).uniq.size
    assert_includes output, "discovered=3 completed=3 passed=3 failed=0 workers=1"
  end

  def test_bounded_worker_modes_run_the_same_closed_set_with_attributable_output
    %w[2 4].each do |workers|
      dir = three_file_checkout

      output, status = run_suite(dir, "--workers", workers)

      assert_equal 0, status, output
      assert_equal NAMES, ledger(dir).map(&:first).sort
      assert_equal 3, ledger(dir).map(&:last).uniq.size
      assert_includes output, "discovered=3 completed=3 passed=3 failed=0 workers=#{workers}"
      assert_attributable_blocks(output)
    end
  end

  def test_a_failing_file_fails_the_run_and_is_named_while_every_file_is_accounted
    dir = checkout
    install_test(dir, "alpha_test.rb")
    install_test(dir, "beta_test.rb", exit_status: 3, body: 'warn "the beta diagnostic detail"')
    install_test(dir, "gamma_test.rb")

    output, status = run_suite(dir, "--workers", "2")

    refute_equal 0, status
    assert_includes output, "discovered=3 completed=3 passed=2 failed=1 workers=2"
    assert_includes output, "test/beta_test.rb (exit=3)"
    assert_includes block_for(output, "test/beta_test.rb"), "the beta diagnostic detail"
    assert_equal NAMES, ledger(dir).map(&:first).sort
  end

  def test_an_overlapping_invocation_in_the_same_checkout_refuses_before_launching_a_test
    dir = checkout
    gate = File.join(dir, "release")
    install_test(dir, "alpha_test.rb", body: <<~RUBY)
      deadline = Time.now + 30
      sleep 0.02 until File.exist?(#{gate.inspect}) || Time.now > deadline
    RUBY
    holder = Process.spawn(File.join(dir, "bin", "test"),
                           out: File.join(dir, "holder.log"), err: %i[child out])
    wait_until { ledger(dir).size == 1 }

    output, status = run_suite(dir)

    refute_equal 0, status
    assert_match(/already running/i, output)
    assert_equal 1, ledger(dir).size
  ensure
    FileUtils.touch(gate) if gate
    Process.wait(holder) if holder
  end

  def test_an_unbounded_or_malformed_worker_selection_is_rejected_before_any_test_runs
    [ %w[--workers 3], %w[--workers 0], %w[--workers -1], %w[--workers abc],
      %w[--jobs 2], %w[--workers], %w[--workers 2 extra] ].each do |args|
      dir = three_file_checkout

      output, status = run_suite(dir, *args)

      refute_equal 0, status, "#{args.inspect} was accepted"
      assert_empty ledger(dir), "#{args.inspect} launched a test file"
      refute_includes output, "passed="
    end
  end

  def test_a_checkout_with_no_test_files_fails_closed_instead_of_reporting_a_green_run
    dir = checkout

    output, status = run_suite(dir)

    refute_equal 0, status
    refute_includes output, "passed="
    assert_match(/no test file/i, output)
  end

  def test_out_of_order_completion_keeps_durations_counts_and_concurrency_coherent
    dir = checkout
    install_test(dir, "alpha_test.rb", body: "sleep 1.0")
    install_test(dir, "beta_test.rb", body: "sleep 1.0")
    install_test(dir, "gamma_test.rb")

    output, status = run_suite(dir, "--workers", "4")

    assert_equal 0, status, output
    assert_includes output, "discovered=3 completed=3 passed=3 failed=0 workers=4"
    assert_operator duration_of(output, "test/alpha_test.rb"), :>=, 1.0
    assert_operator duration_of(output, "test/gamma_test.rb"), :<, 1.0
    # The fast file is reported first although it is discovered last, and the two one-second
    # files overlap: a serial run of this set could not finish inside the wall-clock bound.
    assert_operator result_index(output, "test/gamma_test.rb"), :<,
                    result_index(output, "test/alpha_test.rb")
    assert_operator wall_of(output), :<, 1.9
  end

  # The bound has to hold *while the run is in flight*, not only in what is finally printed: a
  # command that parks the whole stream somewhere and trims it at reporting time has not bounded
  # anything. The command is given its own temporary directory, so every byte it puts on disk is
  # attributable, and it is probed while the loud child is still alive and has already emitted
  # far more than it may keep.
  def test_a_flooding_child_cannot_grow_the_retained_capture_while_the_run_is_in_flight
    dir = checkout
    gate = File.join(dir, "release")
    emitted = File.join(dir, "emitted")
    temporary = File.join(dir, "tmp")
    FileUtils.mkdir_p(temporary)
    install_test(dir, "loud_test.rb", body: <<~RUBY)
      $stdout.write("LOUD-HEAD-MARKER\\n")
      chunk = "x" * (1024 * 1024)
      #{LOUD_MEGABYTES}.times { $stdout.write(chunk) }
      $stdout.write("\\nLOUD-TAIL-MARKER\\n")
      $stdout.flush
      File.write(#{emitted.inspect}, "1")
      deadline = Time.now + 30
      sleep 0.02 until File.exist?(#{gate.inspect}) || Time.now > deadline
    RUBY
    log = File.join(dir, "run.log")
    pid = Process.spawn({ "TMPDIR" => temporary }, File.join(dir, "bin", "test"),
                        out: log, err: %i[child out])
    wait_until { File.exist?(emitted) }

    retained = retained_bytes(temporary)
    resident = resident_kilobytes(pid)

    assert_operator retained, :<=, RETAINED_BYTES_BOUND,
                    "the command retained #{retained} bytes on disk after a child emitted " \
                    "#{LOUD_MEGABYTES} MiB"
    assert_operator resident, :<=, RESIDENT_KILOBYTES_BOUND,
                    "the command held #{resident} KiB resident after a child emitted " \
                    "#{LOUD_MEGABYTES} MiB"

    FileUtils.touch(gate)
    _, status = Process.wait2(pid)
    pid = nil
    output = File.read(log)

    assert_equal 0, status.exitstatus, output[0, 2000]
    assert_includes output, "discovered=1 completed=1 passed=1 failed=0 workers=2"
    # The tail is what diagnoses a failure, so the tail is what survives.
    block = block_for(output, "test/loud_test.rb")

    assert_includes block, "LOUD-TAIL-MARKER"
    refute_includes block, "LOUD-HEAD-MARKER"
    assert_operator block.bytesize, :<=, RETAINED_BYTES_BOUND
  ensure
    FileUtils.touch(gate) if gate
    Process.wait(pid) if pid
  end

  # An interrupted run takes its children down with it and reports no total for work it never
  # finished. The disposition is forced to DEFAULT for the duration and restored afterwards: a
  # suite launched as a background job inherits SIGINT as ignored and would pass that on to the
  # command, which would then never receive the signal this case is about.
  def test_an_interrupted_run_terminates_its_children_and_reports_no_green_summary
    dir = checkout
    4.times { |index| install_test(dir, "slow#{index}_test.rb", body: "sleep 30") }
    previous = Signal.trap("INT", "DEFAULT")
    log = File.join(dir, "run.log")
    pid = Process.spawn(File.join(dir, "bin", "test"), "--workers", "4",
                        out: log, err: %i[child out])
    wait_until { ledger(dir).size == 4 }
    children = `pgrep -P #{pid}`.split.map(&:to_i)

    assert_equal 4, children.length

    interrupted_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Process.kill("INT", pid)
    _, status = Process.wait2(pid)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - interrupted_at
    pid = nil

    # The children sleep far longer than this bound, so an interrupted run has to end them
    # rather than wait them out.
    assert_operator elapsed, :<, 10
    refute_predicate status, :success?
    refute_includes File.read(log), "passed="
    wait_until { children.none? { |child| process_alive?(child) } }
  ensure
    Signal.trap("INT", previous) if previous
    terminate(pid) if pid
  end

  private

  # A throwaway checkout holding the real executable at its real relative location.
  def checkout
    dir = Dir.mktmpdir("full-suite-")
    @checkouts << dir
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "test"))
    FileUtils.cp(COMMAND, File.join(dir, "bin", "test"))
    FileUtils.chmod(0o755, File.join(dir, "bin", "test"))
    dir
  end

  def three_file_checkout
    dir = checkout
    NAMES.each { |name| install_test(dir, name) }
    dir
  end

  # A generated test file: it appends its own name and process id to the checkout's ledger under
  # an exclusive lock, prints a marker only it can print, then runs `body` and exits.
  def install_test(dir, name, exit_status: 0, body: "")
    source = <<~RUBY
      File.open(#{File.join(dir, 'ledger.tsv').inspect}, File::CREAT | File::WRONLY | File::APPEND) do |f|
        f.flock(File::LOCK_EX)
        f.puts("#{name}\\t" + Process.pid.to_s)
      end
      puts "marker-#{name}"
      #{body}
      exit #{exit_status}
    RUBY
    File.write(File.join(dir, "test", name), source)
  end

  def run_suite(dir, *args)
    output, status = Open3.capture2e(File.join(dir, "bin", "test"), *args)
    [ output, status.exitstatus ]
  end

  def ledger(dir)
    path = File.join(dir, "ledger.tsv")
    return [] unless File.exist?(path)

    File.readlines(path, chomp: true).map { |line| line.split("\t") }
  end

  # The captured output between one file's BEGIN delimiter and its result delimiter — what
  # "attributable" has to mean when several children are writing at the same time.
  def block_for(output, file)
    pattern = /^=+ #{Regexp.escape(file)}: BEGIN =+$\n(.*?)^=+ #{Regexp.escape(file)}: /m
    block = output[pattern, 1]
    assert block, "no delimited block for #{file} in:\n#{output}"
    block
  end

  def assert_attributable_blocks(output)
    NAMES.each do |name|
      block = block_for(output, "test/#{name}")

      assert_includes block, "marker-#{name}"
      (NAMES - [ name ]).each { |other| refute_includes block, "marker-#{other}" }
    end
  end

  def result_line(output, file)
    line = output[/^=+ #{Regexp.escape(file)}: (?:PASS|FAIL).*$/]
    assert line, "no result line for #{file} in:\n#{output}"
    line
  end

  def duration_of(output, file)
    result_line(output, file)[/duration=([0-9.]+)s/, 1].to_f
  end

  def result_index(output, file)
    output.index(result_line(output, file))
  end

  def wall_of(output)
    output[/wall=([0-9.]+)s/, 1].to_f
  end

  # Every byte the command is holding in the temporary directory it was handed.
  def retained_bytes(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
       .select { |path| File.file?(path) }
       .sum { |path| File.size(path) }
  end

  def resident_kilobytes(pid)
    value = Integer(`ps -o rss= -p #{pid}`.to_s.strip, exception: false)
    assert value, "could not read the resident set size of process #{pid}"
    value
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def terminate(pid)
    Process.kill("TERM", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def wait_until(timeout: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.02 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    assert yield, "the condition was not reached within #{timeout}s"
  end
end
