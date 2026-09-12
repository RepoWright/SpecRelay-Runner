# frozen_string_literal: true

require_relative "test_helper"

# The reader is the machine's ONLY window onto the local Claude installation, and the whole
# safety argument for it is what it REFUSES to carry. It runs two documented commands through
# argv arrays, keeps a closed set of fields out of each, and drops the raw text on the floor.
#
# So the tests here are mostly negative. A parser that recognised a little more than the
# documented shape would be the thing that puts an account identifier, a server URL or a
# provider's prose on an operator's screen — and every one of those arrives in the output
# these two commands produce.
class ClaudeStatusReaderTest < Minitest::Test
  # The documented two-window shape, as the operator-facing command prints it.
  USAGE_OUTPUT = <<~TEXT
    Current session
    ███░░░░░░░░░░░░  14% used
    Resets 4:50pm

    Current week (all models)
    ███████░░░░░░░░  50% used
    Resets Sun 10pm

    Current week (Opus)
    ██░░░░░░░░░░░░░  8% used
    Resets Sun 10pm
  TEXT

  # `claude mcp list` names each server and, after a health check, says how it answered. The
  # middle of every line is the thing that must never travel: a command line with arguments, or
  # a server URL.
  MCP_OUTPUT = <<~TEXT
    Checking MCP server health...

    playwright: npx @playwright/mcp@latest - ✓ Connected
    contextplus: /Users/someone/.local/bin/contextplus-mcp --root /Users/someone/dev - ✗ Failed to connect
    graphify: https://graphify.internal.invalid/mcp?token=synthetic-not-a-credential - Needs authentication
    legacy: /opt/legacy/bin/mcp - Disabled
  TEXT

  # 2026-09-11 is a Friday, so "Sun 10pm" resolves forward two days and "4:50pm" resolves
  # later the same afternoon. Fixed here so every reset assertion is an exact instant rather
  # than a relative phrase.
  NOW = Time.utc(2026, 9, 11, 9, 0, 0)

  # Answers each argv from a table and records what it was asked to run, so a test can assert
  # the exact argv AND that nothing else was ever launched.
  class ScriptedCommand
    attr_reader :invocations

    def initialize(results)
      @results = results
      @invocations = []
    end

    def call(argv)
      @invocations << argv
      result = @results[argv]
      raise "no scripted result for #{argv.inspect}" if result.nil?

      result == :launch_failure ? nil : result
    end
  end

  Result = Struct.new(:exit_code, :stdout, :stderr, :timed_out, keyword_init: true) do
    def success? = !timed_out && exit_code.zero?
    def timed_out? = timed_out ? true : false
  end

  def ok(stdout) = Result.new(exit_code: 0, stdout: stdout, stderr: "", timed_out: false)
  def failed(code: 1) = Result.new(exit_code: code, stdout: "", stderr: "boom", timed_out: false)
  def timed_out = Result.new(exit_code: nil, stdout: "", stderr: "", timed_out: true)

  def reader_for(usage: ok(USAGE_OUTPUT), mcp: ok(MCP_OUTPUT), version: ok("2.1.268 (Claude Code)"))
    command = ScriptedCommand.new(
      SpecrelayRunner::ClaudeStatusReader::USAGE_ARGV => usage,
      SpecrelayRunner::ClaudeStatusReader::MCP_ARGV => mcp,
      SpecrelayRunner::ClaudeStatusReader::VERSION_ARGV => version
    )
    [ SpecrelayRunner::ClaudeStatusReader.new(command: command), command ]
  end

  # --- capacity: the documented shape ---------------------------------------

  def test_the_two_documented_windows_are_read_with_exact_percentages_and_reset_instants
    reader, = reader_for
    capacity = reader.capacity(now: NOW)

    assert_equal 14, capacity.dig("windows", "five_hour", "used_percent")
    assert_equal 50, capacity.dig("windows", "weekly_all_models", "used_percent")
    # The provider prints the OPERATOR's wall clock, so the expected instants are built from
    # this machine's own zone rather than written as UTC literals — an assertion that assumed
    # UTC would pass only where the developer happens to sit.
    assert_equal utc("4:50pm today", Time.new(2026, 9, 11, 16, 50, 0)),
                 capacity.dig("windows", "five_hour", "resets_at")
    assert_equal utc("10pm on the coming Sunday", Time.new(2026, 9, 13, 22, 0, 0)),
                 capacity.dig("windows", "weekly_all_models", "resets_at")
  end

  def utc(_description, local) = local.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

  # The model-specific block is explicitly out of scope. It carries the same two field shapes
  # as the ones that are in scope, so a parser that scanned for percentages rather than for
  # the two documented HEADINGS would silently report an Opus window as the weekly one.
  def test_the_model_specific_block_is_not_read_as_a_window
    reader, = reader_for
    capacity = reader.capacity(now: NOW)

    assert_equal %w[five_hour weekly_all_models], capacity["windows"].keys.sort
  end

  def test_the_documented_command_is_launched_through_argv_with_no_shell
    reader, command = reader_for
    reader.capacity(now: NOW)

    assert_equal [ [ "claude", "-p", "/usage" ] ], command.invocations
    assert(command.invocations.flatten.none? { |arg| arg.include?("|") || arg.include?(";") })
  end

  # --- capacity: every refusal shape ----------------------------------------

  # Each of these is a DIFFERENT way the documented contract can fail to hold, and every one of
  # them has to produce the same answer: no capacity at all. A parser that repaired any of them
  # would be reporting a number the provider never gave.
  def test_every_unrecognised_usage_shape_reports_no_capacity_and_never_a_guess
    {
      "a missing weekly block" => "Current session\n12% used\nResets 4:50pm\n",
      "a missing session block" => "Current week (all models)\n12% used\nResets 4:50pm\n",
      "a duplicated heading" => USAGE_OUTPUT + "\nCurrent session\n99% used\nResets 5pm\n",
      "two percentages in one block" => "Current session\n12% used\n13% used\nResets 4:50pm\n" \
                                        "Current week (all models)\n50% used\nResets Sun 10pm\n",
      "two reset lines in one block" => "Current session\n12% used\nResets 4:50pm\nResets 5:50pm\n" \
                                        "Current week (all models)\n50% used\nResets Sun 10pm\n",
      "a localised heading" => "Aktuelle Sitzung\n12% benutzt\nZurücksetzen 16:50\n",
      "an out-of-range percentage" => "Current session\n120% used\nResets 4:50pm\n" \
                                      "Current week (all models)\n50% used\nResets Sun 10pm\n",
      "an unparseable reset" => "Current session\n12% used\nResets whenever\n" \
                                "Current week (all models)\n50% used\nResets Sun 10pm\n",
      "a missing reset line" => "Current session\n12% used\n" \
                                "Current week (all models)\n50% used\nResets Sun 10pm\n",
      "empty output" => ""
    }.each do |shape, text|
      reader, = reader_for(usage: ok(text))

      assert_nil reader.capacity(now: NOW), "#{shape} must report no capacity"
    end
  end

  def test_a_timeout_or_nonzero_exit_reports_no_capacity
    [ timed_out, failed, :launch_failure ].each do |result|
      reader, = reader_for(usage: result)

      assert_nil reader.capacity(now: NOW)
    end
  end

  # Order is part of the documented contract, not an incidental property of the output. Reading a
  # reordered result by matching each heading would recover the right numbers, but it would also
  # mean this reader deciding that output the provider never documents is close enough — and the
  # whole safety argument here is that it never does. Both blocks present, in this order, or no
  # capacity at all.
  def test_a_reordered_result_is_not_the_documented_output_and_reports_no_capacity
    reordered = "Current week (all models)\n50% used\nResets Sun 10pm\n\n" \
                "Current session\n14% used\nResets 4:50pm\n"
    reader, = reader_for(usage: ok(reordered))

    assert_nil reader.capacity(now: NOW)
  end

  # The same two blocks the other way round ARE read, so the example above is failing on the order
  # itself rather than on some other property of the fixture.
  def test_the_documented_order_of_the_same_two_blocks_is_read
    ordered = "Current session\n14% used\nResets 4:50pm\n\n" \
              "Current week (all models)\n50% used\nResets Sun 10pm\n"
    reader, = reader_for(usage: ok(ordered))
    capacity = reader.capacity(now: NOW)

    assert_equal 14, capacity.dig("windows", "five_hour", "used_percent")
    assert_equal 50, capacity.dig("windows", "weekly_all_models", "used_percent")
  end

  # --- capacity: privacy ----------------------------------------------------

  # The command's output carries an account email, an organisation and a cost panel in the real
  # product. NOTHING but the four parsed numbers may survive the call, so the result is checked
  # for the raw text rather than for a list of fields somebody has to remember to extend.
  def test_no_raw_usage_output_survives_the_read
    noisy = USAGE_OUTPUT + "\nAccount: operator@example.invalid\nOrganisation: Example GmbH\n" \
                           "Cost this month: $412.19\n"
    reader, = reader_for(usage: ok(noisy))
    capacity = reader.capacity(now: NOW)

    serialized = capacity.to_json
    %w[operator@example.invalid Example\ GmbH 412.19 Opus ███].each do |leak|
      refute_includes serialized, leak
    end
  end

  # --- MCP inventory --------------------------------------------------------

  def test_mcp_inventory_keeps_only_the_name_and_a_normalised_health_state
    reader, command = reader_for
    servers = reader.mcp_servers(now: NOW)

    assert_equal [ [ "claude", "mcp", "list" ] ], command.invocations
    assert_equal([ { "name" => "contextplus", "health" => "failed" },
                   { "name" => "graphify", "health" => "pending_approval" },
                   { "name" => "legacy", "health" => "disabled" },
                   { "name" => "playwright", "health" => "healthy" } ],
                 servers.sort_by { |server| server["name"] })
  end

  # Every line of that command's output has a command line or a URL in the middle of it, and
  # one of them here carries a query-string credential. The inventory keeps two keys, so none
  # of it can travel — asserted against the raw text, not against a field list.
  def test_no_mcp_command_url_or_credential_survives_the_read
    reader, = reader_for
    serialized = reader.mcp_servers(now: NOW).to_json

    %w[npx @playwright/mcp /Users/someone /opt/legacy graphify.internal.invalid
       synthetic-not-a-credential --root].each do |leak|
      refute_includes serialized, leak
    end
  end

  def test_each_server_carries_only_a_name_and_a_health_state
    reader, = reader_for

    reader.mcp_servers(now: NOW).each { |server| assert_equal %w[health name], server.keys.sort }
  end

  def test_an_unrecognised_or_failed_mcp_command_reports_no_inventory
    [ timed_out, failed, :launch_failure, ok("something else entirely\n") ].each do |result|
      reader, = reader_for(mcp: result)

      assert_nil reader.mcp_servers(now: NOW)
    end
  end

  # A health word this reader has no vocabulary for is recorded as `unknown` rather than being
  # dropped: the server IS configured, and hiding it would understate the inventory. The word
  # itself is never carried through.
  def test_an_unknown_health_word_is_normalised_rather_than_carried
    reader, = reader_for(mcp: ok("thing: /bin/thing - Reticulating splines\n"))

    assert_equal [ { "name" => "thing", "health" => "unknown" } ], reader.mcp_servers(now: NOW)
  end

  # --- readiness ------------------------------------------------------------

  def test_readiness_reports_the_local_cli_version_and_nothing_else
    reader, = reader_for
    readiness = reader.readiness(now: NOW)

    assert_equal "ready", readiness["state"]
    assert_equal "2.1.268", readiness["cli_version"]
    assert_equal %w[cli_version state], readiness.keys.sort
  end

  def test_an_absent_cli_is_reported_as_unavailable_without_a_version
    reader, = reader_for(version: :launch_failure)

    assert_equal({ "state" => "unavailable" }, reader.readiness(now: NOW))
  end
end
