# frozen_string_literal: true

require_relative "test_helper"

# The Status Reporter is the one thing in this runner that exists purely to TELL Platform
# something, and it is deliberately the least important thing running. Two properties carry
# that, and both are asserted here:
#
#   - its CADENCE is fixed and bounded, so a fleet of connected machines cannot turn status
#     into a load pattern, and a section is never collected more often than its own interval;
#   - it FAILS QUIETLY. A slow provider command, an unparseable result and an unreachable
#     Platform are all ordinary weather, and none of them may raise out of a cycle.
#
# Time is injected as an explicit instant rather than slept, so every cadence assertion is an
# exact one and the whole file runs without a thread or a clock.
class StatusReporterTest < Minitest::Test
  START = Time.utc(2026, 9, 11, 9, 0, 0)

  CAPACITY = {
    "state" => "available",
    "windows" => {
      "five_hour" => { "used_percent" => 14, "resets_at" => "2026-09-11T16:50:00Z" },
      "weekly_all_models" => { "used_percent" => 50, "resets_at" => "2026-09-13T22:00:00Z" }
    }
  }.freeze

  MCP = [ { "name" => "playwright", "health" => "healthy" } ].freeze
  READINESS = { "state" => "ready", "cli_version" => "2.1.268" }.freeze

  # Counts what was collected and when, so a test can assert an interval was RESPECTED rather
  # than merely that a value arrived. `fails` turns one section into a collection failure
  # without changing the others, which is the isolation the section contract promises.
  class CountingReader
    attr_reader :calls

    def initialize(fails: [])
      @fails = fails.dup
      @calls = Hash.new(0)
    end

    # Turns a section that has already answered once into one that no longer can, which is the
    # only way to observe a CARRIED value rather than an absent one.
    def fail_from_now_on(section) = @fails << section

    def capacity(now:) = record(:capacity, now) { CAPACITY }
    def mcp_servers(now:) = record(:mcp, now) { MCP }
    def readiness(now:) = record(:readiness, now) { READINESS }

    private

    def record(section, _now)
      @calls[section] += 1
      @fails.include?(section) ? nil : yield
    end
  end

  # Records every delivered snapshot. `error` makes Platform unreachable, which must cost the
  # cycle and nothing else.
  class RecordingClient
    attr_reader :snapshots

    def initialize(error: nil)
      @error = error
      @snapshots = []
    end

    def report_status(snapshot:)
      raise @error if @error

      @snapshots << snapshot
      {}
    end
  end

  def reporter_for(client: RecordingClient.new, reader: CountingReader.new)
    SpecrelayRunner::StatusReporter.new(client: client, reader: reader)
  end

  def at(seconds) = START + seconds

  # --- cadence --------------------------------------------------------------

  def test_the_first_cycle_reports_immediately_at_start
    client = RecordingClient.new
    reporter = reporter_for(client: client)

    assert reporter.report_if_due(START)
    assert_equal 1, client.snapshots.length
  end

  def test_nothing_is_reported_before_the_fixed_sixty_second_cadence_is_due
    client = RecordingClient.new
    reporter = reporter_for(client: client)
    reporter.report_if_due(START)

    refute reporter.report_if_due(at(30))
    refute reporter.report_if_due(at(59))
    assert reporter.report_if_due(at(60))
    assert_equal 2, client.snapshots.length
  end

  # Each section has its OWN ceiling, and the report cadence is not it. Capacity moves with the
  # report; the MCP inventory is a five-minute fact and must not be collected once a minute
  # just because a report is going out anyway.
  def test_each_section_is_collected_no_more_often_than_its_own_interval
    reader = CountingReader.new
    reporter = reporter_for(reader: reader)

    0.step(240, 60) { |offset| reporter.report_if_due(at(offset)) }

    assert_equal 5, reader.calls[:capacity]
    assert_equal 1, reader.calls[:mcp]
    assert_equal 1, reader.calls[:readiness]
  end

  def test_the_mcp_inventory_is_collected_again_once_five_minutes_have_passed
    reader = CountingReader.new
    reporter = reporter_for(reader: reader)

    0.step(300, 60) { |offset| reporter.report_if_due(at(offset)) }

    assert_equal 2, reader.calls[:mcp]
  end

  # --- observation time and freshness --------------------------------------

  # The point of a per-section observation time is that it describes when the VALUE was
  # measured, not when it was last posted. A section carried forward keeps the instant it was
  # actually collected at, or a stale measurement would look permanently current.
  def test_resending_a_carried_section_never_renews_its_observation_time
    client = RecordingClient.new
    reporter = reporter_for(client: client)
    reporter.report_if_due(START)
    reporter.report_if_due(at(60))

    first, second = client.snapshots
    assert_equal first.dig("mcp", "observed_at"), second.dig("mcp", "observed_at")
    refute_equal first.dig("capacity", "observed_at"), second.dig("capacity", "observed_at")
  end

  # A value the machine still holds but could no longer refresh is neither current nor absent,
  # and `stale` is the only truthful word for it. It is what lets the operator surface show the
  # last real measurement AS old rather than presenting it as the provider's present state.
  def test_a_value_that_stops_refreshing_is_carried_as_stale_rather_than_as_current
    reader = CountingReader.new
    client = RecordingClient.new
    reporter = reporter_for(client: client, reader: reader)
    reporter.report_if_due(START)
    reader.fail_from_now_on(:capacity)
    reporter.report_if_due(at(60))

    fresh, stale = client.snapshots
    assert_equal "fresh", fresh.dig("capacity", "freshness")
    assert_equal "stale", stale.dig("capacity", "freshness")
    # Stale means OLD, never invented: the measurement and its instant are the real ones.
    assert_equal 14, stale.dig("capacity", "windows", "five_hour", "used_percent")
    assert_equal fresh.dig("capacity", "observed_at"), stale.dig("capacity", "observed_at")
  end

  # --- section-level failure is never a cycle failure ----------------------

  def test_a_failed_section_is_reported_unavailable_while_every_other_section_is_delivered
    client = RecordingClient.new
    reporter = reporter_for(client: client, reader: CountingReader.new(fails: [ :capacity ]))

    assert reporter.report_if_due(START)
    snapshot = client.snapshots.first

    assert_equal "unavailable", snapshot.dig("capacity", "freshness")
    assert_nil snapshot.dig("capacity", "windows")
    assert_equal "fresh", snapshot.dig("mcp", "freshness")
    assert_equal "ready", snapshot.dig("readiness", "state")
  end

  # A collector that raises is the case a section contract has to survive without the caller
  # knowing anything about it: the cycle still reports, and the section says it has nothing.
  def test_a_collector_that_raises_costs_its_section_and_not_the_cycle
    raising = Class.new do
      def capacity(now:) = raise(Errno::ENOENT, "claude")
      def mcp_servers(now:) = [ { "name" => "playwright", "health" => "healthy" } ]
      def readiness(now:) = { "state" => "ready", "cli_version" => "2.1.268" }
    end.new
    client = RecordingClient.new
    reporter = reporter_for(client: client, reader: raising)

    assert reporter.report_if_due(START)
    assert_equal "unavailable", client.snapshots.first.dig("capacity", "freshness")
  end

  # An unreachable Platform is ordinary weather for a signal nobody waits on. It must not
  # raise, and it must not poison the next cycle.
  def test_an_unreachable_platform_costs_one_cycle_and_never_raises
    client = RecordingClient.new(error: SpecrelayRunner::PlatformClient::Error.new("unreachable"))
    reporter = reporter_for(client: client)

    refute reporter.report_if_due(START)
    refute reporter.report_if_due(at(30))
    refute reporter.report_if_due(at(60))
  end

  # --- what the snapshot may say -------------------------------------------

  def test_the_snapshot_is_the_closed_versioned_v1_object
    client = RecordingClient.new
    reporter_for(client: client).report_if_due(START)
    snapshot = client.snapshots.first

    assert_equal 1, snapshot["version"]
    assert_equal "claude", snapshot["provider"]
    assert_equal %w[capacity execution mcp observed_at provider readiness version], snapshot.keys.sort
  end

  # Platform owns the assigned provider and profile. This machine reports what it OBSERVED,
  # and it observed no model and no effort — there is no documented local source that gives
  # either exactly, so neither field may appear at all.
  def test_no_model_or_effort_is_ever_reported_and_the_observed_execution_is_truthful
    client = RecordingClient.new
    reporter_for(client: client).report_if_due(START, executing: true)
    snapshot = client.snapshots.first

    assert_equal true, snapshot.dig("execution", "active")
    # Asserted over the KEYS rather than the serialized text: `weekly_all_models` is a window
    # name, and a substring search would call that a reported model.
    assert_equal %w[active freshness observed_at], snapshot["execution"].keys.sort
    refute(deep_keys(snapshot).any? { |key| %w[model effort].include?(key) })
  end

  def deep_keys(value)
    case value
    when Hash then value.keys + value.values.flat_map { |nested| deep_keys(nested) }
    when Array then value.flat_map { |nested| deep_keys(nested) }
    else []
    end
  end

  # The disabled reporter is how a loop with no workspace connection carries no status at all,
  # rather than four nil checks at its call sites.
  def test_a_disabled_reporter_reports_nothing_and_starts_nothing
    refute SpecrelayRunner::StatusReporter::NONE.enabled?
    refute SpecrelayRunner::StatusReporter::NONE.report_if_due(START)
    assert_nil SpecrelayRunner::StatusReporter::NONE.start(executing: -> { true })
    assert_nil SpecrelayRunner::StatusReporter::NONE.stop
  end
end
