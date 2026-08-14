# frozen_string_literal: true

require_relative "test_helper"
require "digest"

# MVP-0028 remediation, defect 4 — the provider an operator selects in Platform's Project Setup
# must actually reach the specification lane.
#
# It did not. The lane resolved a provider from this runner's own `runner.executor:` YAML alone
# (`Config#selected_claude_profile`), and a runner set up the supported way — `specrelay-runner
# connect` — writes no YAML at all. So a project whose operator had correctly selected "Claude Code
# (real provider)" refused EVERY generation with `generation_provider_unavailable`. The live
# MAPIAI-53 run is what exposed it; defect 1 had removed the silent composer fallback that was
# previously hiding the same missing channel behind plausible output.
#
# Driven through the real `claim-once` CLI with a stub `claude` first on PATH, because the claim is
# that the selection survives the WHOLE trip: Platform's workspace config → the assignment →
# {Assignment#selected_claude_profile} → {ClaudeProfile} validation → the process actually
# launched. A unit test on any single link would have passed before the fix.
#
# The unit-level semantics of {Provider.resolve} stay in specification_provider_selection_test.rb.
class SpecificationProviderPropagationTest < Minitest::Test
  ISSUE = "SR-700"

  # The exact configuration ProjectSetup::ExecutorProfiles stores for each selectable profile.
  CLAUDE_PROFILE = {
    "provider" => "claude", "command" => "claude", "mode" => "print",
    "args" => [ "--print", "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions" ],
    "prompt_delivery" => "argument",
    "timeout_seconds" => 1800, "env" => {}
  }.freeze

  FIXTURE_PROFILE = {
    "provider" => "fake", "command" => "specrelay-fake-executor", "mode" => "print",
    "args" => [], "prompt_delivery" => "file_argument", "timeout_seconds" => 120, "env" => {}
  }.freeze

  def setup
    @source, @specs, @temp = SpecificationWorkspace.build
    @io = StringIO.new
    @prompt = File.join(@temp, "prompt.txt")
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@temp) if @temp && File.directory?(@temp)
  end

  # ------------------------------------------------------------------ the defect itself

  # FAILING-FIRST. Before the fix this refused with `generation_provider_unavailable` — exactly
  # what the live run did on a correctly configured project.
  def test_the_profile_selected_in_project_setup_generates_when_this_runner_has_no_local_yaml
    stub_claude
    start_platform(profile: "claude", executor: CLAUDE_PROFILE)

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    assert_equal "generated", @platform.last_specification_generation["outcome"], @io.string
    assert File.exist?(@prompt), "the profile Platform selected must be the process that actually ran"
  end

  # Not merely accepted — RECORDED, in the generation manifest the package carries, so an operator
  # can answer "what wrote this?" from the artifact rather than by recognising the prose style.
  # Before the fix the only reachable answer here was a refusal.
  def test_the_recorded_provider_is_the_one_platform_selected
    stub_claude
    start_platform(profile: "claude", executor: CLAUDE_PROFILE)

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    manifest = JSON.parse(File.read(File.join(SpecificationWorkspace.isolated_worktree(@temp),
                                              "specs/SR-700-add-an-export-button",
                                              "generation-manifest.json")))
    assert_equal "claude", manifest.dig("provider", "kind"), @io.string
    assert_includes manifest.dig("provider", "description"), "claude"
  end

  # ------------------------------------------------------------------ MAPIAI-60: live progress

  # The second workflow, on the SAME path as the first: this lane used to attach no live stream
  # at all, so an operator watching a specification run saw one "Generating" line and then
  # silence until the package appeared.
  def test_specification_generation_shows_live_provider_progress_on_both_surfaces
    stub_claude
    start_platform(profile: "claude", executor: CLAUDE_PROFILE)

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    # CR-005: the specification lane has no repository and still renders the same transcript,
    # path included — an ordinary path is not a secret, and both lanes share one renderer.
    expected = [ "Provider started", "> Read /elsewhere/notes.md", "Provider completed" ]
    expected.each { |status| assert_includes @io.string, "[claude:status] #{status}" }

    chunks = @platform.protocol_events.select { |event| event["event_type"] == "log.chunk" }
    refute_empty chunks, "the specification lane must reach the run page's existing panel"
    assert_equal [ "status" ], chunks.map { |event| event.dig("attributes", "log_source") }.uniq
    delivered = chunks.map { |event| event["sanitized_log_chunk"].to_s }.join("\n")
    assert_equal expected, delivered.split("\n").select { |line| expected.include?(line) }

    # And the package still came only from the terminal result.
    assert_equal "generated", @platform.last_specification_generation["outcome"]
    refute_includes @io.string, %("type":"result"), "a raw frame reached the terminal"
  end

  # CR-002 F1 — the same finalization boundary on this lane's own orchestrator. `Generation`
  # finishes the stream in an `ensure` around the provider call, so a live-log channel that stops
  # answering used to hold the generated DOCUMENTS behind it. Held far longer than any legitimate
  # shutdown, so "waited for Platform" cannot be mistaken for "settled its own thread".
  LOG_EVENT_DELAY = 15

  def test_a_platform_that_stops_answering_the_log_channel_never_holds_the_generated_package
    stub_claude
    start_platform(profile: "claude", executor: CLAUDE_PROFILE)
    @platform.log_event_delay = LOG_EVENT_DELAY

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, LOG_EVENT_DELAY,
                    "generation took #{elapsed.round(3)}s: it waited for the live-log channel"
    assert_equal "generated", @platform.last_specification_generation["outcome"], @io.string
    # CR-003 F1: Platform accepted the event and only its acknowledgement was withheld, so the
    # unconfirmed progress must be named without being called a failed delivery.
    assert_includes @io.string, "were not acknowledged by Platform before this attempt ended"
    assert_includes @io.string, "delivery may still have succeeded"
  end

  # ------------------------------------------------------------------ what must still refuse

  # The fixture is a real selection with no specification provider behind it. It must refuse —
  # silently composing was defect 1 — and the refusal must name the profile the operator actually
  # picked, so they return to the screen they picked it on instead of re-reading their YAML.
  def test_the_deterministic_fixture_selection_refuses_and_names_the_profile
    start_platform(profile: "fake", executor: FIXTURE_PROFILE)
    before = snapshot(@specs)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    generation = @platform.last_specification_generation
    assert_equal "refused", generation["outcome"]
    assert_equal "generation_provider_unavailable", generation["failure_class"]
    assert generation["zero_output_files_written"]
    assert_includes generation["message"], "`fake` executor profile"
    assert_includes generation["message"], "Claude Code (real provider)"
    assert_equal before, snapshot(@specs), "a refusal must not write into the specification checkout"
  end

  # A payload is not a licence to run anything. Platform's selection is a closed set, but the
  # runner refuses INDEPENDENTLY — so a profile carrying a flag this runner will not launch is a
  # refusal before the process exists, not a launched command.
  def test_a_platform_profile_carrying_a_forbidden_flag_is_refused_not_launched
    stub_claude
    start_platform(profile: "claude",
                   executor: CLAUDE_PROFILE.merge("args" => CLAUDE_PROFILE.fetch("args") + [ "--mcp-config", "/tmp/x.json" ]))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_equal "generation_provider_unavailable",
                 @platform.last_specification_generation["failure_class"], @io.string
    refute File.exist?(@prompt), "a refused profile must never be launched"
  end

  # An operator who hand-wrote a profile has decided. Platform's selection must not silently
  # replace it, for the same reason an explicit `provider.kind` wins over everything else.
  def test_a_local_executor_override_still_wins_over_the_platform_selection
    stub_claude
    start_platform(profile: "claude", executor: CLAUDE_PROFILE)
    local = CLAUDE_PROFILE.merge("timeout_seconds" => 111)

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli(config: build_config(local_executor: local)), @io.string

    assert_equal "generated", @platform.last_specification_generation["outcome"], @io.string
  end

  # A Platform old enough to send no block at all must not crash a current runner: it refuses with
  # the ordinary unconfigured message, exactly as it did before this block existed.
  def test_an_assignment_with_no_provider_block_refuses_with_the_ordinary_message
    payload = spec_creation_payload_for(issue_key: ISSUE)
    payload.delete("specification_provider")
    @platform = FakePlatform.new(claim_payload: payload).start

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    generation = @platform.last_specification_generation
    assert_equal "generation_provider_unavailable", generation["failure_class"]
    assert_includes generation["message"], "no specification generation provider is configured"
    refute_includes generation["message"], "executor profile in"
  end

  private

  # A `claude` that satisfies the profile: named `claude`, taking the prompt as its LAST argv
  # element (`prompt_delivery: argument`), answering in the supported structured format
  # (MAPIAI-60) — activity while it works, then ONE terminal result carrying the JSON file map
  # every provider answers with. Placed first on PATH so `Executor.resolve_command` resolves to
  # this one.
  #
  # The tool it reports names a path OUTSIDE any repository, because this lane is assigned none:
  # containment can never be proven here, so no path may ever be shown.
  STUB_MESSAGES = lambda do |files|
    [ { "type" => "system", "subtype" => "init" },
      { "type" => "assistant", "message" => { "content" => [
        { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/elsewhere/notes.md" } } ] } },
      { "type" => "result", "subtype" => "success", "is_error" => false, "result" => JSON.generate(files) } ]
      .map { |message| JSON.generate(message) }.join("\n")
  end

  def stub_claude
    @stub_dir = Dir.mktmpdir("claude-stub", @temp)
    path = File.join(@stub_dir, "claude")
    File.write(path, <<~SH)
      #!/bin/sh
      eval "prompt=\\${$#}"
      printf '%s' "$prompt" > "#{@prompt}"
      cat <<'SPECRELAY_PROVIDER_EOF'
      #{STUB_MESSAGES.call(valid_generated_files)}
      SPECRELAY_PROVIDER_EOF
    SH
    File.chmod(0o755, path)
  end

  def start_platform(profile:, executor:)
    payload = spec_creation_payload_for(
      issue_key: ISSUE, specification_provider: { "profile" => profile, "executor" => executor }
    )
    @platform = FakePlatform.new(claim_payload: payload).start
  end

  def snapshot(root)
    Dir.glob("#{root}/**/*", File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort.to_h do |path|
      [ path.delete_prefix("#{root}/"), Digest::SHA256.hexdigest(File.binread(path)) ]
    end
  end

  def valid_generated_files
    sections = SpecrelayRunner::Specification::DocumentSet::REQUIRED_SECTIONS
    body = "Filler content for this section, long enough to pass the minimum length check.\n\n"
    {
      "spec.md" => "# #{ISSUE} — a specification\n\n" +
        sections.fetch("spec.md").map { |h| "## #{h}\n\n#{body}" }.join,
      "analysis/business.md" => "# Business analysis — #{ISSUE}\n\n" +
        sections.fetch("analysis/business.md").map { |h| "## #{h}\n\n#{body}" }.join,
      "analysis/technical.md" => "# Technical analysis — #{ISSUE}\n\n" +
        sections.fetch("analysis/technical.md").map { |h| "## #{h}\n\n#{body}" }.join,
      "analysis/input-evidence.md" => "# Input evidence\n\nNo supporting input beyond the ticket.\n"
    }
  end

  # Deliberately the GUIDED-CONNECTION shape: no `runner.executor:` block and no
  # `specification.provider.kind`. That is what `specrelay-runner connect` leaves on disk, and the
  # configuration under which the live failure happened.
  def build_config(local_executor: nil)
    path = File.join(Dir.mktmpdir("cfg", @temp), "runner.yml")
    executor_line = local_executor ? "  executor: #{JSON.generate(local_executor)}\n" : ""
    File.write(path, <<~YAML)
      platform:
        base_url: #{@platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: test-runner
        display_name: Test Runner
        claim_policy:
          mode: all_eligible
      #{executor_line.chomp}
        specification:
          repository_roots:
            "SpecRelay/SpecRelay-Specs": #{@specs}
          context_plus:
            available: true
      workspace_roots:
        tiny-demo-workspace: #{@source}
    YAML
    SpecrelayRunner::Config.load(path)
  end

  def run_cli(config: nil)
    config ||= build_config
    path = [ @stub_dir, ENV["PATH"] ].compact.join(File::PATH_SEPARATOR)
    SpecrelayRunner::CLI.run(%W[claim-once --config #{config.source_path}], out: @io, err: @io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => path,
                                    "HOME" => @temp }.merge(SpecificationWorkspace.lane_env(@temp)))
  end
end
