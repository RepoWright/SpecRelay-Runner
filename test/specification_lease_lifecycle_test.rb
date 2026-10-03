# frozen_string_literal: true

require_relative "test_helper"

# The lease a claimed specification-creation assignment holds, for as long as it holds it.
#
# Preparing a specification workspace is the slow part of this lane: it builds or reuses the
# ticket's whole task environment through the project's own command, may place a previously
# accepted implementation into it, and prepares the analysis tooling against the final tree. None
# of that renews the claim unless renewal is owned by the CLAIM rather than by the phase that
# happens to be running, and a claim that lapses mid-preparation spends a whole provider run on a
# result Platform will not record.
#
# Driven through the real `claim-once` and `loop` CLIs against the fake Platform HTTP server, for
# the same reason the rest of this lane's coverage is: "a renewal reached Platform while the
# workspace was still being prepared" is a fact about the wire and about ORDER, and only the
# end-to-end path carries both.
class SpecificationLeaseLifecycleTest < Minitest::Test
  ISSUE = "SR-700"

  # The advertised cadence, short enough that several renewals fall inside a preparation a test
  # is willing to wait for. The worker clamps anything below one second, so this is the floor.
  RENEWAL_SECONDS = 1

  # How long the project's own task-environment command is held open. Longer than the cadence
  # above, short enough that the suite does not notice.
  PREPARATION_SECONDS = 3

  def setup
    @provider_exit_code = 0
    @source, @specs, @temp = SpecificationWorkspace.build
    @platform = FakePlatform.new(claim_payload: claim_payload).start
    @config = build_config
    @io = StringIO.new
  end

  def teardown
    @platform.stop
    FileUtils.remove_entry(@temp) if @temp && File.directory?(@temp)
  end

  # ---------------------------------------------------- renewal covers preparation

  # The defect, stated as the wire sees it: at a moment when preparation was still running,
  # Platform had already received a renewal for this claim. Nothing in the lane beats before the
  # provider except the renewal worker, so a renewal counted here can only have come from it —
  # and the run still produces the package it was claimed for.
  def test_renewal_reaches_platform_while_the_workspace_is_still_being_prepared
    delay_task_environment_command

    assert_equal SpecrelayRunner::CLI::SUCCESS, counting_renewals { run_cli }, @io.string

    assert_operator renewals_during_preparation, :>=, 1,
                    "the claim was not renewed while its workspace was being prepared"
    generation = @platform.last_specification_generation
    assert_equal "generated", generation["outcome"], @io.string
    refute_empty generation.dig("package", "files")
  end

  # Criterion 3: the session is not left needing a restart. One long run, then the next claim,
  # from the same admitted terminal, with the failure policy unchanged.
  def test_a_session_that_finishes_a_long_run_claims_again_without_a_restart
    delay_task_environment_command
    restart_platform(claim_limit: 2) { |platform| platform.queue_claims([ claim_payload, claim_payload ]) }

    Timeout.timeout(180) { run_cli(command: %w[loop --poll-interval 5 --on-failure continue]) }

    assert_equal 3, @platform.requests_to("/api/runner/claim").length, @io.string
    assert_equal %w[generated generated], recorded_outcomes, @io.string
  end

  # ---------------------------------------------------- the claim Platform ended

  # A claim Platform no longer considers live is discovered BEFORE the provider is launched, so
  # a model run is not spent on a result that cannot be submitted. Retention matches what this
  # ending has always done: an explicit cancellation is Platform's own terminal record, and this
  # run's snapshot and environment go with it.
  def test_a_cancelled_claim_is_noticed_before_the_provider_is_launched
    @platform.signal_cancelled!

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    refute provider_generated?, "the provider was launched for a claim Platform had ended"
    assert_empty @platform.requests_to("/api/runner/events"), "the provider's live log was opened"
    assert_empty @platform.specification_generations
    assert_empty SpecificationWorkspace.isolated_workspaces(@temp)
    assert_nil SpecificationWorkspace.task_worktree(@source, ISSUE)
  end

  # The expired ending keeps what the cancelled one discards, exactly as it did before the
  # liveness check moved in front of the provider.
  def test_an_expired_claim_noticed_before_the_provider_keeps_its_workspace
    @platform.signal_expired!

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    refute provider_generated?
    assert_empty @platform.specification_generations
    refute_empty SpecificationWorkspace.isolated_workspaces(@temp)
    refute_nil SpecificationWorkspace.task_worktree(@source, ISSUE)
  end

  # The pre-provider check is not the only one. A claim that dies AFTER the provider produced its
  # documents still submits nothing, which is the boundary that stops a superseded attempt from
  # overwriting a newer one's result.
  def test_a_claim_that_dies_after_the_provider_still_submits_no_result
    cancel_once_the_provider_has_run

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert provider_generated?, "the provider never ran, so this proves nothing"
    assert_empty @platform.specification_generations
    assert_includes @io.string, "No generation result was submitted"
  end

  # A transport failure reaching Platform is a reporting problem, not a lost claim: the run goes
  # on and still records its result.
  def test_an_unreachable_heartbeat_does_not_stop_the_run
    with_failing_heartbeats { assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string }

    assert_equal "generated", @platform.last_specification_generation["outcome"]
  end

  # ---------------------------------------------------- one worker, one ensured stop

  # Criterion 4, over every ending the lane has: the refusal preparation makes, the provider that
  # failed, the result Platform would not take, and the ordinary success.
  def test_every_ending_creates_exactly_one_renewal_worker_and_stops_it
    { "a preparation refusal" => -> { @broken_redaction = true },
      "a provider failure" => -> { @provider_exit_code = 1 },
      "a result Platform refused" => -> { @platform.generation_response = [ 500, { error: "unavailable" } ] },
      "a generated package" => -> { } }.each do |ending, arrange|
      reset_lane
      arrange.call
      workers = recording_workers { @broken_redaction ? with_broken_redaction { run_cli } : run_cli }

      assert_equal 1, workers.length, "#{ending}: one claim must build exactly one renewal worker"
      refute_nil workers.first.instance_variable_get(:@started_at), "#{ending}: the worker never started"
      assert_nil workers.first.instance_variable_get(:@thread), "#{ending}: a renewal worker outlived its claim"
    end
  end

  # An assignment that never parsed has no claim identity to renew, so nothing is started and
  # nothing is left running.
  def test_an_unparseable_assignment_starts_no_renewal_worker
    @platform.claim_payload = claim_payload(complete: false)

    workers = recording_workers { run_cli }

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, @exit_code, @io.string
    assert_empty workers
  end

  # ------------------------------------------------------------------ helpers

  def claim_payload(complete: true)
    spec_creation_payload_for(issue_key: ISSUE, complete: complete,
                              lease_renewal_seconds: RENEWAL_SECONDS)
  end

  def recorded_outcomes
    @platform.specification_generations.map { |request| request.dig(:body, "generation", "outcome") }
  end

  # The project's own task-environment command, held open past the renewal cadence, with the
  # renewal count copied aside while preparation is still running. A deliberate delay is how
  # "longer than one renewal window" is made deterministic without a clock the test owns.
  def delay_task_environment_command
    command = File.join(@source, "bin", "worktree")
    FileUtils.mv(command, "#{command}.project")
    SpecificationWorkspace.write_executable(command, <<~SH)
      #!/usr/bin/env sh
      if [ "$1" = create ]; then
        sleep #{PREPARATION_SECONDS}
        cp "#{renewal_log}" "#{renewals_at_preparation}" 2>/dev/null || :
      fi
      exec "#{command}.project" "$@"
    SH
  end

  def renewal_log = File.join(@temp, "renewals.log")
  def renewals_at_preparation = File.join(@temp, "renewals-during-preparation.log")

  def renewals_during_preparation
    File.exist?(renewals_at_preparation) ? File.readlines(renewals_at_preparation).length : 0
  end

  # Every lease renewal this runner sends, recorded as a FILE because the thing that has to read
  # it mid-run is the project's own command, which runs in a child process while the session is
  # still preparing.
  def counting_renewals
    log = renewal_log
    original = SpecrelayRunner::PlatformClient.instance_method(:heartbeat)
    SpecrelayRunner::PlatformClient.define_method(:heartbeat) do |claim:|
      File.write(log, "beat\n", mode: "a")
      original.bind(self).call(claim: claim)
    end
    yield
  ensure
    SpecrelayRunner::PlatformClient.define_method(:heartbeat, original)
  end

  # Platform unreachable for renewal only, so the claim and the result still travel.
  def with_failing_heartbeats
    original = SpecrelayRunner::PlatformClient.instance_method(:heartbeat)
    SpecrelayRunner::PlatformClient.define_method(:heartbeat) do |claim:|
      raise SpecrelayRunner::PlatformClient::Error, "Platform is unreachable (#{claim})"
    end
    yield
  ensure
    SpecrelayRunner::PlatformClient.define_method(:heartbeat, original)
  end

  # Flip Platform's liveness answer the moment the provider has produced its documents, so the
  # claim dies between the provider and the report rather than before either.
  def cancel_once_the_provider_has_run
    platform = @platform
    original = @platform.method(:lease_signal)
    marker = -> { provider_generated? }
    @platform.define_singleton_method(:lease_signal) do
      platform.signal_cancelled! if marker.call
      original.call
    end
  end

  # Every renewal worker one claim built. Instances rather than threads: "exactly one worker" and
  # "it was stopped" are both properties of the object, and a live-thread count would also see
  # the live-log timer and the fake server.
  def recording_workers
    built = []
    original = SpecrelayRunner::Heartbeater.method(:new)
    SpecrelayRunner::Heartbeater.define_singleton_method(:new) do |**kwargs|
      original.call(**kwargs).tap { |worker| built << worker }
    end
    @exit_code = yield
    built
  ensure
    singleton = SpecrelayRunner::Heartbeater.singleton_class
    singleton.send(:remove_method, :new) if singleton.instance_methods(false).include?(:new)
  end

  # The runner's redaction guard failing its own probe: the refusal preparation makes after the
  # task environment exists, which is the refusal that happens while a worker is running.
  def with_broken_redaction
    original = SpecrelayRunner::Redaction.method(:redact)
    SpecrelayRunner::Redaction.define_singleton_method(:redact) { |text| text }
    yield
  ensure
    SpecrelayRunner::Redaction.define_singleton_method(:redact, original)
  end

  # Whether the generation provider was launched. Asserted against the prompt it was handed
  # rather than against the file existing, because the same approved profile also answers the
  # optional reference analysis, and only one of the two is the model run under test here.
  def provider_marker = File.join(@temp, "provider-prompt")

  def provider_generated?
    File.exist?(provider_marker) &&
      File.read(provider_marker).include?(SpecificationWorkspace::GENERATION_MARKER)
  end

  # A clean lane for the next ending in a table-driven case: the previous run's claim, workspace,
  # task environment and provider marker are all spent.
  def reset_lane
    @platform.stop
    FileUtils.remove_entry(@temp) if @temp && File.directory?(@temp)
    @provider_stub = nil
    @provider_exit_code = 0
    @broken_redaction = false
    @source, @specs, @temp = SpecificationWorkspace.build
    @platform = FakePlatform.new(claim_payload: claim_payload).start
    @config = build_config
    @io = StringIO.new
  end

  def restart_platform(claim_limit: nil)
    @platform.stop
    @platform = FakePlatform.new(claim_payload: claim_payload, claim_limit: claim_limit)
    yield @platform if block_given?
    @platform.start
    @config = build_config
    @io = StringIO.new
  end

  def build_config
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{@platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: test-runner
        display_name: Test Runner
        claim_policy:
          mode: all_eligible
        specification:
          repository_roots:
            "SpecRelay/SpecRelay-Specs": #{@specs}
          context_plus:
            available: true
      workspace_roots: #{{ 'tiny-demo-workspace' => @source }.to_json}
    YAML
    SpecrelayRunner::Config.load(path)
  end

  # The approved provider's bare name on the child PATH, writing the prompt it was handed so
  # "the provider was never launched" is an observation rather than an inference.
  def provider_stub
    @provider_stub ||= SpecificationWorkspace.claude_stub(
      @temp, compose: true, exit_code: @provider_exit_code.to_i, capture_prompt_to: provider_marker
    )
  end

  def run_cli(command: %w[claim-once])
    env = { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
            "PATH" => SpecificationWorkspace.provider_path(provider_stub) }
          .merge(SpecificationWorkspace.lane_env(@temp))
    SpecrelayRunner::CLI.run([ *command, "--config", @config.source_path ], out: @io, err: @io, env: env)
  end
end
