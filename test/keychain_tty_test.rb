# frozen_string_literal: true

require_relative "test_helper"
require "pty"

# MVP-0017 — credential delivery under a REAL controlling terminal.
#
# This file exists because of a defect that shipped through three review rounds while the
# suite was green. Round 002 delivered the credential by passing `security ... -w` with no
# value so the tool would prompt, and writing the value to the child's stdin. `security` reads
# that prompt with `readpassphrase(3)`, which opens **/dev/tty** and falls back to stdin only
# when no controlling terminal can be opened. Every place the delivery was tested — the unit
# test's fake runner, CI, a captured shell — has no controlling terminal, so the fallback
# engaged and the write worked. On an operator's actual terminal the tool prompted on the
# terminal, never read the pipe, and `connect` hung until the timeout killed it:
#
#   could not save the runner credential to the macOS Keychain (exit )
#
# The empty exit status was the timeout: `Process::Status#exitstatus` is nil for a killed child.
#
# The lesson is not "mock less". It is that the ONE environmental fact the delivery depended on
# — the presence of a controlling terminal — was the one fact no test reproduced. So these
# examples run the real `SecretStore` inside a real pty, against a stub `security` that
# reproduces the prompt-on-/dev/tty behaviour that made the difference. They assert both that
# today's delivery works there AND that the round-002 delivery does not, so the stub is proven
# to reproduce the bug rather than merely to pass.
#
# The real Keychain is deliberately not touched: the stub makes the failure deterministic and
# keeps the suite from prompting or writing on a developer's machine.
class KeychainTtyTest < Minitest::Test
  # Bounded well below SecretStore::TIMEOUT_SECONDS so the round-002 control fails fast
  # instead of hanging the suite for a minute.
  CONTROL_TIMEOUT_SECONDS = 3
  CREDENTIAL = "src_tty-delivery-probe-0123456789"

  def setup
    @dir = Dir.mktmpdir("keychain-tty")
    @stub_dir = File.join(@dir, "bin")
    Dir.mkdir(@stub_dir)
    write_stub_security
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # --- the fix -------------------------------------------------------------

  def test_the_real_secret_store_stores_the_credential_under_a_controlling_terminal
    output = run_under_pty(<<~RUBY)
      store = SpecrelayRunner::SecretStore.new
      store.write(account: "runner:rnr_tty", credential: CREDENTIAL)
      report("WRITE", "ok")
      report("STORED_FAITHFULLY", store.read(account: "runner:rnr_tty") == CREDENTIAL)
    RUBY

    assert_equal "true", value_of(output, "CHILD_HAS_CONTROLLING_TTY"),
                 "the harness must give the child a controlling terminal, or this proves nothing"
    assert_equal "ok", value_of(output, "WRITE"), "write failed under a tty:\n#{output}"
    assert_equal "true", value_of(output, "STORED_FAITHFULLY")
    # The credential must not be echoed by the delivery, even onto a terminal.
    refute_includes output, CREDENTIAL
  end

  # The credential is on stdin, so it is in no process's argv — the round-002 requirement
  # (review-001 F8) still holds under the new delivery.
  def test_the_credential_is_not_an_argv_element_of_the_security_process
    output = run_under_pty(<<~RUBY)
      SpecrelayRunner::SecretStore.new.write(account: "runner:rnr_tty", credential: CREDENTIAL)
      invocations = File.readlines(ENV.fetch("STUB_ARGV_LOG")).map(&:strip).reject(&:empty?)
      report("WRITE_ARGV", invocations.first)
      report("ALL_ARGV", invocations.join(" | "))
    RUBY

    assert_equal "-i", value_of(output, "WRITE_ARGV"),
                 "the write must be invoked as `security -i`, with no value in argv"
    # Not one invocation of the tool — write or verifying read-back — carries the credential in
    # argv, which is where the process table reads from (review-001 F8).
    refute_includes value_of(output, "ALL_ARGV").to_s, CREDENTIAL
    refute_includes output, CREDENTIAL
  end

  # --- the control: the delivery that shipped, against the same stub --------

  def test_the_round_002_delivery_never_reaches_the_tool_under_a_controlling_terminal
    output = run_under_pty(<<~RUBY)
      # Exactly what round 002 ran: `-w` last with no value, credential on stdin.
      result = SpecrelayRunner::CommandRunner.run(
        [ "security", "add-generic-password", "-a", "runner:legacy", "-s",
          SpecrelayRunner::SecretStore::SERVICE, "-U", "-w" ],
        chdir: Dir.pwd, env: { "PATH" => ENV.fetch("PATH"), "STUB_STORE" => ENV.fetch("STUB_STORE"),
                               "STUB_ARGV_LOG" => ENV.fetch("STUB_ARGV_LOG") },
        timeout_seconds: #{CONTROL_TIMEOUT_SECONDS}, stdin_data: "\#{CREDENTIAL}\\n\#{CREDENTIAL}\\n"
      )
      report("TIMED_OUT", result.timed_out?)
      report("EXIT_CODE", result.exit_code.inspect)
      report("STORED", SpecrelayRunner::SecretStore.new.read(account: "runner:legacy").inspect)
    RUBY

    # The tool waited on the terminal for a value that was written to a pipe it never read.
    assert_equal "true", value_of(output, "TIMED_OUT"),
                 "expected the round-002 delivery to hang under a tty; got:\n#{output}"
    # This nil is what printed as the operator's "(exit )".
    assert_equal "nil", value_of(output, "EXIT_CODE")
    assert_equal "nil", value_of(output, "STORED"), "nothing may be stored when the value never arrived"
  end

  # A timeout must now say it timed out, instead of rendering as "(exit )".
  def test_a_timeout_is_reported_as_a_timeout_not_as_an_empty_exit_status
    timed_out = SpecrelayRunner::CommandRunner::Result.new(
      exit_code: nil, stdout: "", stderr: "", timed_out: true
    )
    store = SpecrelayRunner::SecretStore.new(runner: Object.new.tap do |runner|
      runner.define_singleton_method(:run) { |*, **| timed_out }
    end)

    error = assert_raises(SpecrelayRunner::SecretStore::Error) do
      store.write(account: "runner:rnr_x", credential: CREDENTIAL)
    end

    assert_match(/did not finish within/, error.message)
    refute_match(/exit \)/, error.message)
    refute_includes error.message, CREDENTIAL
  end

  private

  # The stub writes its prompt to the terminal, which lands mid-line in the captured pty
  # stream, so a reported value is matched anywhere on its line rather than at line start.
  def value_of(output, key)
    output.lines.each do |line|
      # `strip` first: a pty delivers CRLF, so the value would otherwise keep a stray \r.
      match = line.strip.match(/#{Regexp.escape(key)}=(.*)\z/)
      return match[1].strip if match
    end
    nil
  end

  # Run `body` in a child Ruby that has a controlling terminal, with the stub `security`
  # first on PATH. PTY.spawn is what makes the child a session leader with the pty as its
  # controlling terminal — the condition the shipped bug depended on.
  def run_under_pty(body)
    script = File.join(@dir, "child.rb")
    File.write(script, child_program(body))
    collect_pty_output(script)
  end

  def collect_pty_output(script)
    output = +""
    begin
      PTY.spawn(child_env, RbConfig.ruby, script) do |reader, _writer, pid|
        begin
          loop { output << reader.readpartial(4096) }
        rescue Errno::EIO, EOFError
          # the child exited and closed the pty; normal termination
        end
        begin
          Process.wait(pid)
        rescue Errno::ECHILD
          nil
        end
      end
    rescue PTY::ChildExited
      nil
    end
    output
  end

  def child_env
    { "PATH" => "#{@stub_dir}:#{ENV.fetch('PATH', '')}",
      "STUB_STORE" => File.join(@dir, "store.json"),
      "STUB_ARGV_LOG" => File.join(@dir, "argv.log"),
      "RUNNER_LIB" => File.expand_path("../lib", __dir__) }
  end

  def child_program(body)
    <<~RUBY
      $LOAD_PATH.unshift ENV.fetch("RUNNER_LIB")
      require "specrelay_runner"

      CREDENTIAL = #{CREDENTIAL.inspect}

      def report(key, value) = puts("#{'#'}{key}=#{'#'}{value}")

      has_tty = begin
        File.open("/dev/tty", "r") { true }
      rescue StandardError
        false
      end
      report("CHILD_HAS_CONTROLLING_TTY", has_tty)

      begin
        #{body.strip.gsub(/\n/, "\n  ")}
      rescue StandardError => e
        report("ERROR", "#{'#'}{e.class}: #{'#'}{e.message}")
      end
    RUBY
  end

  # A stand-in for macOS `security` reproducing the one behaviour that decided this bug: a
  # valueless `-w` is answered from the CONTROLLING TERMINAL (as readpassphrase(3) does), not
  # from stdin, while `-i` reads its command line from stdin. Storage is a JSON file.
  def write_stub_security
    path = File.join(@stub_dir, "security")
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"

      STORE = ENV.fetch("STUB_STORE")
      # Appended, so a later read-back cannot overwrite the record of how the WRITE was invoked.
      File.open(ENV.fetch("STUB_ARGV_LOG"), "a") { |log| log.puts(ARGV.join(" ")) } if ENV["STUB_ARGV_LOG"]

      def load_store = File.exist?(STORE) ? JSON.parse(File.read(STORE)) : {}
      def save_store(entries) = File.write(STORE, JSON.generate(entries))
      def flag(argv, name)
        index = argv.index(name)
        index && argv[index + 1] && !argv[index + 1].start_with?("-") ? argv[index + 1] : nil
      end
      def key_for(argv) = "#{flag(argv, '-s')} #{flag(argv, '-a')}"

      # readpassphrase(3): the prompt is read from /dev/tty, and stdin is IGNORED.
      def prompt_from_tty
        tty = File.open("/dev/tty", "r+")
        tty.write("password data for new item: ")
        value = tty.gets.to_s.chomp
        tty.write("\nretype password for new item: ")
        tty.gets
        tty.close
        value
      end

      def add(argv)
        value = argv.include?("-w") ? flag(argv, "-w") : nil
        value = prompt_from_tty if value.nil?
        entries = load_store
        entries[key_for(argv)] = value
        save_store(entries)
        0
      end

      def find(argv)
        entries = load_store
        key = key_for(argv)
        return (warn "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain."; 44) unless entries.key?(key)

        print "#{entries[key]}\n"
        0
      end

      def remove(argv)
        entries = load_store
        existed = entries.delete(key_for(argv))
        save_store(entries)
        existed ? 0 : 44
      end

      def dispatch(argv)
        case argv.first
        when "add-generic-password" then add(argv)
        when "find-generic-password" then find(argv)
        when "delete-generic-password" then remove(argv)
        else (warn "security: unknown command \"#{argv.first}\""; 1)
        end
      end

      if ARGV.first == "-i"
        status = 0
        while (line = $stdin.gets)
          argv = line.split
          next if argv.empty?

          status = dispatch(argv)
        end
        exit status
      else
        exit dispatch(ARGV)
      end
    RUBY
    File.chmod(0o755, path)
  end
end
