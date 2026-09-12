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
  # The documented two-window shape, exactly as the AUTHENTICATED CLI prints it — captured from
  # a real `claude -p /usage` run, middle dot and all. The account prose above the measurements
  # and the model-specific line below them are part of that output, so they stay: walking past
  # both without reading either is the behaviour under test, not noise the fixture may tidy up.
  USAGE_OUTPUT = <<~TEXT
    You are currently using your subscription to power your Claude Code usage

    Current session: 14% used · resets Sep 12 at 1:10pm (Europe/Berlin)
    Current week (all models): 77% used · resets Sep 14 at 10pm (Europe/Berlin)
    Current week (Fable): 0% used · resets Sep 14 at 10pm (Europe/Berlin)
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

  # Before both printed resets, so each resolves within the observation year. Fixed here, and
  # in UTC, so every reset assertion is an exact instant rather than a relative phrase.
  NOW = Time.utc(2026, 9, 12, 8, 0, 0)

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
    assert_equal 77, capacity.dig("windows", "weekly_all_models", "used_percent")
    # 1:10pm and 10pm in Europe/Berlin, which was +02:00 on both printed dates. Written as UTC
    # literals rather than built from this machine's zone, because the provider PRINTS the zone
    # it means: the instant is the same wherever the developer running this happens to sit.
    assert_equal "2026-09-12T11:10:00Z", capacity.dig("windows", "five_hour", "resets_at")
    assert_equal "2026-09-14T20:00:00Z", capacity.dig("windows", "weekly_all_models", "resets_at")
  end

  # The zone in the output is the OPERATOR's, and this machine's is a different fact that merely
  # tends to agree with it. Reading the same output under two unrelated host zones is what tells
  # those two apart: a reader that quietly used the host's would answer differently here.
  def test_the_printed_zone_is_read_rather_than_this_machines_own
    instants = %w[UTC America/Los_Angeles Asia/Kolkata].map do |zone|
      in_host_zone(zone) do
        reader, = reader_for
        reader.capacity(now: NOW)["windows"]["five_hour"]["resets_at"]
      end
    end

    assert_equal [ "2026-09-12T11:10:00Z" ] * 3, instants
  end

  # The reset is resolved by setting TZ, which is process-wide. The variable this program was
  # started with therefore has to survive the read — including the case where it was never set,
  # which must be left unset rather than turned into an empty string.
  def test_the_host_timezone_setting_survives_a_read
    [ "America/Los_Angeles", nil ].each do |setting|
      in_host_zone(setting) do
        reader, = reader_for
        reader.capacity(now: NOW)

        setting.nil? ? assert_nil(ENV["TZ"]) : assert_equal(setting, ENV["TZ"])
      end
    end
  end

  def in_host_zone(zone)
    previous = ENV["TZ"]
    zone.nil? ? ENV.delete("TZ") : ENV["TZ"] = zone
    yield
  ensure
    previous.nil? ? ENV.delete("TZ") : (ENV["TZ"] = previous)
  end

  # Nothing used is a measurement, not a missing one. A reader that treated 0 as absent would
  # report a fresh week as `Unavailable` — the one moment the number is least in doubt.
  def test_a_zero_percentage_is_a_measurement_rather_than_an_absence
    output = "Current session: 0% used · resets Sep 12 at 1:10pm (Europe/Berlin)\n" \
             "Current week (all models): 0% used · resets Sep 14 at 10pm (Europe/Berlin)\n"
    reader, = reader_for(usage: ok(output))
    capacity = reader.capacity(now: NOW)

    assert_equal 0, capacity.dig("windows", "five_hour", "used_percent")
    assert_equal "available", capacity["state"]
  end

  # The model-specific line is explicitly out of scope. It carries the SAME two field shapes as
  # the lines that are in scope, so a parser that scanned for percentages rather than for the
  # two documented HEADINGS would silently report the Fable window as the weekly one — and in
  # this fixture that would read as 0% used on a week that is 77% gone.
  def test_the_model_specific_line_is_not_read_as_a_window
    reader, = reader_for
    capacity = reader.capacity(now: NOW)

    assert_equal %w[five_hour weekly_all_models], capacity["windows"].keys.sort
    assert_equal 77, capacity.dig("windows", "weekly_all_models", "used_percent")
  end

  # The provider prints no year, so one is resolved — forward, never backward. Observed in
  # December, a January reset belongs to the year after the observation.
  def test_a_reset_past_the_year_end_resolves_into_the_following_year
    output = "Current session: 14% used · resets Jan 2 at 10pm (Europe/Berlin)\n" \
             "Current week (all models): 77% used · resets Jan 4 at 10pm (Europe/Berlin)\n"
    reader, = reader_for(usage: ok(output))

    capacity = reader.capacity(now: Time.utc(2026, 12, 28, 9, 0, 0))

    assert_equal "2027-01-02T21:00:00Z", capacity.dig("windows", "five_hour", "resets_at")
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
      "a missing weekly line" => session,
      "a missing session line" => weekly,
      "a duplicated measurement" => USAGE_OUTPUT + session,
      "a localised measurement" => "Aktuelle Sitzung: 12% benutzt · Zurücksetzen 16:50\n" + weekly,
      "an out-of-range percentage" => session(percent: 120) + weekly,
      "a missing percentage" => "Current session: used · resets Sep 12 at 1:10pm (Europe/Berlin)\n" +
                                weekly,
      "two percentages on one line" => session(percent: "12% used · 13") + weekly,
      "a missing reset" => "Current session: 12% used\n" + weekly,
      "an unparseable reset" => session(reset: "whenever") + weekly,
      "a reset with no printed zone" => session(reset: "Sep 12 at 1:10pm") + weekly,
      "a bare weekday reset" => session(reset: "Sun 10pm") + weekly,
      # Each of these would be RESOLVED rather than refused by a parser that handed the printed
      # fields to Time.local: an impossible day and a common-year Feb 29 silently roll into the
      # next month, and an unknown zone name silently resolves to UTC. Every one of them would
      # then render as a confident instant that the provider never named.
      "an impossible day" => session(reset: "Sep 31 at 1:10pm (Europe/Berlin)") + weekly,
      "Feb 29 in a common year" => session(reset: "Feb 29 at 1:10pm (Europe/Berlin)") + weekly,
      "a zero day" => session(reset: "Sep 0 at 1:10pm (Europe/Berlin)") + weekly,
      "an unknown month" => session(reset: "Foo 12 at 1:10pm (Europe/Berlin)") + weekly,
      "an unknown zone" => session(reset: "Sep 12 at 1:10pm (Europe/Berlinn)") + weekly,
      "an out-of-range hour" => session(reset: "Sep 12 at 13pm (Europe/Berlin)") + weekly,
      "an out-of-range minute" => session(reset: "Sep 12 at 1:70pm (Europe/Berlin)") + weekly,
      "a 24-hour clock with no half named" => session(reset: "Sep 12 at 13:10 (Europe/Berlin)") +
                                              weekly,
      "trailing material after the zone" => session(reset: "Sep 12 at 1:10pm (Europe/Berlin) or so") +
                                            weekly,
      "empty output" => ""
    }.each do |shape, text|
      reader, = reader_for(usage: ok(text))

      assert_nil reader.capacity(now: NOW), "#{shape} must report no capacity"
    end
  end

  # The two in-scope measurements, each overridable in one field, so a refusal fixture differs
  # from the documented shape in exactly the way its name claims and in nothing else.
  def session(percent: 14, reset: "Sep 12 at 1:10pm (Europe/Berlin)")
    "Current session: #{percent}% used · resets #{reset}\n"
  end

  def weekly(percent: 77, reset: "Sep 14 at 10pm (Europe/Berlin)")
    "Current week (all models): #{percent}% used · resets #{reset}\n"
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
    reader, = reader_for(usage: ok(weekly + session))

    assert_nil reader.capacity(now: NOW)
  end

  # The same two measurements the other way round ARE read, so the example above is failing on
  # the order itself rather than on some other property of the fixture.
  def test_the_documented_order_of_the_same_two_measurements_is_read
    reader, = reader_for(usage: ok(session + weekly))
    capacity = reader.capacity(now: NOW)

    assert_equal 14, capacity.dig("windows", "five_hour", "used_percent")
    assert_equal 77, capacity.dig("windows", "weekly_all_models", "used_percent")
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
    # The provider's own prose and the model-specific line are in the fixture too: neither is an
    # account detail, and both must be just as absent from a result that carries four numbers.
    [ "operator@example.invalid", "Example GmbH", "412.19", "Fable", "subscription" ].each do |leak|
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
