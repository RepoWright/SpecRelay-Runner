# frozen_string_literal: true

require_relative "test_helper"

# MAPIAI-87 S02 — the specification REVISION's read-only view of the accepted implementation.
#
# A revision already reads the previous specification off its own pull request
# ({Specification::PreviousSpecificationPackage}). What it could not see was the implementation
# that was actually shipped from that specification, so it revised requirements with no knowledge
# of what already exists. This adds that as CONTEXT — identity, the specification it implemented,
# and the current pull requests with their pinned heads — and nothing that would let the writer
# touch an implementation repository.
class SpecificationPreviousImplementationTest < Minitest::Test
  ISSUE = "SR-700"
  HEAD = "0123456789abcdef0123456789abcdef01234567"

  Source = Struct.new(:repository_name, :entry_point_paths, :fallbacks, :graphify, :context_plus)
  Tool = Struct.new(:name, :usable, :contributed, :summary, :detail) do
    def usable? = usable
    def contributed? = contributed
  end
  Inputs = Struct.new(:inputs, :warnings)
  PackagePath = Struct.new(:relative_package_path)

  def continuation(overrides = {})
    { "package_id" => "art_previous123", "checksum" => "c" * 64, "source_run_id" => "run_previous",
      "approved_specification" => { "reference" => "https://github.com/SpecRelay/SpecRelay-Specs/pull/6",
                                    "digest" => "d" * 64 },
      "implementation_pull_requests" => [ accepted_row ] }.merge(overrides)
  end

  def accepted_row
    { "repository" => "SpecRelay/Specrelay-Platform",
      "clone_url" => "https://github.com/SpecRelay/Specrelay-Platform",
      "branch" => "#{ISSUE}-add-an-export-button", "head_commit" => HEAD,
      "pull_request_url" => "https://github.com/SpecRelay/Specrelay-Platform/pull/45" }
  end

  def assignment_for(block)
    payload = spec_creation_payload_for(issue_key: ISSUE).merge("previous_accepted_package" => block)
    SpecrelayRunner::Specification::Assignment.parse(payload)
  end

  def packet_for(block)
    tool = Tool.new("graphify", true, true, "graph FRESH", "")
    SpecrelayRunner::Specification::Packet.build(
      assignment: assignment_for(block),
      source: Source.new("tiny-demo-workspace", [ "app/models/run.rb" ], [], tool, tool),
      inputs: Inputs.new([], []), package_path: PackagePath.new("specs/#{ISSUE}")
    )
  end

  def test_a_first_specification_carries_no_previous_implementation
    assert_nil assignment_for(nil).previous_accepted_package
    assert_nil packet_for(nil)["previous_accepted_package"]
  end

  def test_the_packet_carries_the_accepted_package_specification_and_pinned_heads
    block = packet_for(continuation)["previous_accepted_package"]

    assert_equal "art_previous123", block["package_id"]
    assert_equal "https://github.com/SpecRelay/SpecRelay-Specs/pull/6", block["approved_specification"]
    assert_equal [ { "repository" => "SpecRelay/Specrelay-Platform",
                     "branch" => "#{ISSUE}-add-an-export-button", "head_commit" => HEAD,
                     "pull_request_url" => "https://github.com/SpecRelay/Specrelay-Platform/pull/45" } ],
                 block["implementation_pull_requests"]
  end

  def test_the_packet_carries_no_clone_url_credential_or_local_path
    serialized = packet_for(continuation).to_json

    refute_includes serialized, "clone_url"
    refute_match(/@github\.com/, serialized)
    refute_match(%r{"/Users/}, serialized)
  end

  def test_an_accepted_package_that_changed_nothing_reaches_the_writer_as_an_empty_list
    block = packet_for(continuation("implementation_pull_requests" => []))["previous_accepted_package"]

    assert_equal [], block["implementation_pull_requests"]
  end

  def test_the_previous_specification_context_is_unaffected
    packet = packet_for(continuation)

    assert_nil packet["revision"]
    assert packet.key?("input_bundle")
  end

  # CR-001 F1 — the bound is a refusal, not a `.first(100)` trim. A silently shortened list would
  # reach the writer as the complete accepted implementation.
  def test_an_oversized_accepted_list_is_refused_rather_than_truncated
    error = assert_raises(SpecrelayRunner::Specification::Assignment::Malformed) do
      packet_for(continuation("implementation_pull_requests" => Array.new(101) { accepted_row }))
    end

    assert_match(/at most 100/, error.message)
  end

  def test_the_provider_prompt_states_the_section_is_read_only
    prompt = SpecrelayRunner::Specification::Provider::Claude.allocate
                                                             .send(:prompt_for, packet_for(continuation))

    section = prompt[/PREVIOUS ACCEPTED IMPLEMENTATION.*?\n\n/m].to_s

    assert_includes section, "previous_accepted_package"
    assert_match(/read-only/i, section)
    assert_match(/never check out, clone, modify, push\s+to, or open a pull request against an implementation repository/, section)
  end
end
