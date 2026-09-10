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
# Driven through the real `claim-once` CLI with a stub provider first on PATH, because the claim is
# that the selection survives the WHOLE trip: Platform's workspace config → the assignment →
# {Assignment#selected_implementation_profile} → the exact-profile comparison → the process
# actually launched. A unit test on any single link would have passed before the fix.
#
# Both approved real providers make that trip here, because a second provider that resolved but
# never launched would satisfy every unit test in the lane.
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

  CODEX_PROFILE = {
    "provider" => "codex", "command" => "codex", "mode" => "exec",
    "args" => [ "exec", "--json", "--ephemeral", "--dangerously-bypass-approvals-and-sandbox" ],
    "prompt_delivery" => "stdin", "timeout_seconds" => 1800, "env" => {}
  }.freeze

  # The fixture's exact configuration, including the environment that IS its script — read from
  # the one authority rather than restated, because a restated copy that drifts would test a
  # profile Platform does not serve.
  FIXTURE_PROFILE = SpecrelayRunner::ImplementationProfile::FIXTURE_CANONICAL

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

    # MAPIAI-77: the specification lane has no approved root — its provider works in a private
    # temporary directory — so containment can never be proven and every absolute local path
    # renders as the placeholder. The lane still shares one renderer and one fan-out.
    expected = [ "Provider started", "> Read [LOCAL_PATH]", "Provider completed" ]
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

  # ------------------------------------------------------------------ the second real provider

  # The whole trip for Codex: Platform's exact profile, the stdin prompt, the Codex turn contract,
  # the same package validation and the same recorded provenance. A Codex adapter that resolved but
  # never launched, or launched with the prompt in argv, would pass every unit test in this lane.
  def test_the_codex_profile_selected_in_project_setup_generates_through_the_same_lane
    stub_codex
    start_platform(profile: "codex", executor: CODEX_PROFILE)

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    assert_equal "generated", @platform.last_specification_generation["outcome"], @io.string
    assert_includes File.read(@prompt), "Return ONLY a JSON object",
                    "the prompt must reach Codex on stdin"
    manifest = JSON.parse(File.read(File.join(SpecificationWorkspace.isolated_worktree(@temp),
                                              "specs/SR-700-add-an-export-button",
                                              "generation-manifest.json")))
    assert_equal "codex", manifest.dig("provider", "kind"), @io.string
    assert_includes manifest.dig("provider", "description"), "codex"
  end

  # The live panel names the provider that actually ran, and shows only normalized public progress:
  # no reasoning, no raw JSONL wrapper, no account identity.
  def test_codex_progress_reaches_both_surfaces_under_its_own_provider_name_and_nothing_private_does
    stub_codex
    start_platform(profile: "codex", executor: CODEX_PROFILE)

    assert_equal SpecrelayRunner::CLI::SUCCESS, run_cli, @io.string

    [ "Provider started", "Provider completed" ].each do |status|
      assert_includes @io.string, "[codex:status] #{status}"
    end
    chunks = @platform.protocol_events.select { |event| event["event_type"] == "log.chunk" }
    refute_empty chunks, "the Codex lane must reach the run page's existing panel"
    delivered = chunks.map { |event| event["sanitized_log_chunk"].to_s }.join("\n")
    [ delivered, @io.string ].each do |surface|
      refute_includes surface, SpecificationWorkspace::CODEX_PRIVATE_REASONING
      refute_includes surface, %("type":"turn.completed"), "a raw JSONL wrapper reached a surface"
      refute_includes surface, %("type":"thread.started")
    end
    # And the package still came only from the terminal message, through the same validation.
    assert_equal "generated", @platform.last_specification_generation["outcome"]
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
    assert_includes generation["message"], "`claude`"
    assert_includes generation["message"], "`codex`"
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

  # An operator who SELECTED a provider locally has decided which provider this machine uses, and
  # Platform's selection does not silently replace that — the same reason an explicit
  # `provider.kind` wins over everything else. What a local block may no longer do is DESCRIBE the
  # profile: the approved command, argv, timeout and environment belong to the profile itself.
  def test_a_local_provider_selection_still_wins_over_the_platform_selection
    stub_claude
    start_platform(profile: "claude", executor: CLAUDE_PROFILE)

    assert_equal SpecrelayRunner::CLI::SUCCESS,
                 run_cli(config: build_config(local_executor: { "provider" => "claude" })), @io.string

    assert_equal "generated", @platform.last_specification_generation["outcome"], @io.string
  end

  # The replacement for the old "a hand-written profile wins" case. A local block carrying its own
  # timeout is a composed profile, and it is refused before any Platform request rather than
  # quietly launching something nobody audited.
  def test_a_local_block_that_composes_a_profile_is_refused
    stub_claude
    start_platform(profile: "claude", executor: CLAUDE_PROFILE)
    local = { "provider" => "claude", "timeout_seconds" => 111 }

    assert_equal SpecrelayRunner::CLI::USAGE_ERROR,
                 run_cli(config: build_config(local_executor: local)), @io.string
    assert_match(/only a provider/, @io.string)
  end

  # One altered field is enough, on either real profile: the claim is compared as it arrived, and a
  # profile that differs anywhere is refused before the process exists.
  def test_a_codex_profile_with_one_altered_argument_is_refused_not_launched
    stub_codex
    start_platform(profile: "codex",
                   executor: CODEX_PROFILE.merge("args" => CODEX_PROFILE.fetch("args") + [ "--output-schema" ]))

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, run_cli, @io.string

    assert_equal "generation_provider_unavailable",
                 @platform.last_specification_generation["failure_class"], @io.string
    refute File.exist?(@prompt), "a refused profile must never be launched"
    assert_no_package
  end

  # An operator who selected the deterministic fixture LOCALLY has decided this machine does not
  # generate specifications. That decision must not fall through to whatever Platform selected —
  # which is what "nil profile" would mean if absence and an explicit fixture were the same thing.
  def test_an_explicit_local_fixture_refuses_instead_of_falling_through_to_the_platform_profile
    stub_claude
    start_platform(profile: "claude", executor: CLAUDE_PROFILE)

    assert_equal SpecrelayRunner::CLI::RUN_FAILED,
                 run_cli(config: build_config(local_executor: { "provider" => "fake" })), @io.string

    assert_equal "generation_provider_unavailable",
                 @platform.last_specification_generation["failure_class"], @io.string
    refute File.exist?(@prompt), "a local fixture selection must never launch Platform's provider"
    assert_no_package
  end

  # The removed configuration surface selects nothing. A runner YAML that still names a provider
  # kind and an arbitrary command is inert: with no real profile anywhere, the lane refuses, and
  # the executable it names is never launched.
  def test_a_configured_provider_kind_and_command_no_longer_select_anything
    marker = File.join(@temp, "arbitrary-ran")
    arbitrary = File.join(@temp, "arbitrary-writer")
    File.write(arbitrary, "#!/bin/sh\ntouch #{marker}\n")
    File.chmod(0o755, arbitrary)
    payload = spec_creation_payload_for(issue_key: ISSUE,
                                        specification_provider: { "profile" => nil, "executor" => nil })
    @platform = FakePlatform.new(claim_payload: payload).start

    assert_equal SpecrelayRunner::CLI::RUN_FAILED,
                 run_cli(config: build_config(provider_kind: "command", provider_command: arbitrary)), @io.string

    assert_equal "generation_provider_unavailable",
                 @platform.last_specification_generation["failure_class"], @io.string
    refute File.exist?(marker), "a configured command must not be launched by the specification lane"
    assert_empty SpecificationWorkspace.isolated_workspaces(@temp)
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

  # Each double is the approved profile's own BARE name on its own bin directory, placed first on
  # PATH so `Executor.resolve_command` resolves to it exactly as it would to a real CLI.

  def stub_claude
    @stub_dir = SpecificationWorkspace.claude_stub(@temp, files: valid_generated_files,
                                                          capture_prompt_to: @prompt)
  end

  # The Codex double: named `codex`, reading its prompt from STDIN as the approved profile
  # delivers it, and answering with the same JSON file map every provider answers with.
  def stub_codex
    @stub_dir = SpecificationWorkspace.codex_stub(@temp, files: valid_generated_files,
                                                         capture_prompt_to: @prompt)
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
  # A refusal writes no package at all: the isolated worktree the run would have used is never
  # created, and the operator's checkout never had one.
  def assert_no_package
    assert_empty SpecificationWorkspace.isolated_workspaces(@temp)
    refute File.exist?(File.join(@specs, "specs", "SR-700-add-an-export-button"))
  end

  def build_config(local_executor: nil, provider_kind: nil, provider_command: nil)
    path = File.join(Dir.mktmpdir("cfg", @temp), "runner.yml")
    executor_line = local_executor ? "  executor: #{JSON.generate(local_executor)}\n" : ""
    # A flow mapping on one line, so the removed configuration keys can be written into the file
    # without the surrounding heredoc's indentation deciding whether the test is valid YAML.
    provider_block = provider_kind ? "provider: {kind: #{provider_kind}, command: #{provider_command}}" : ""
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
          #{provider_block}
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
