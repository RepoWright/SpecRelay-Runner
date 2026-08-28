# frozen_string_literal: true

require_relative "test_helper"

# MAPIAI-97 — the closed preview assignment boundary.
#
# The refusals matter more than the acceptance: this is the gate that stops a browser-influenced
# field from reaching an argv array. Every block is closed, so the test does not enumerate
# forbidden names — it proves that anything not in the contract refuses the whole document.
class PreviewAssignmentTest < Minitest::Test
  TASK = "MAPIAI-97-provide-live-task-preview-urls-for-human-approval"

  def payload(**overrides)
    {
      "contract_version" => "mapiai-97",
      "assignment_kind" => "task_preview",
      "claim" => { "execution_id" => "rex_abc", "claimed_at" => "2026-08-27T00:00:00Z",
                   "lease_expires_at" => "2026-08-27T00:05:00Z" },
      "preview" => { "id" => "prv_abc", "ticket_key" => "MAPIAI-97", "project_slug" => "tiny-demo",
                     "task_id" => TASK, "canonical_branch" => TASK },
      "workspace" => { "key" => "tiny-demo-workspace",
                       "repository_url" => "https://github.com/SpecRelay/tiny-demo-workspace",
                       "default_branch" => "main" },
      "sources" => [ { "repository" => "SpecRelay/App",
                       "pull_request_url" => "https://github.com/SpecRelay/App/pull/7" } ]
    }.merge(overrides)
  end

  def read(document) = SpecrelayRunner::PreviewAssignment.read(document)

  def refuses(document, expected)
    result = read(document)
    refute result.ok?, "expected a refusal"
    assert_includes result.reason, expected
  end

  def test_a_complete_assignment_is_accepted_and_exposes_only_named_values
    result = read(payload)

    assert result.ok?, result.reason
    assert_equal "rex_abc", result.execution_id
    assert_equal "prv_abc", result.preview_id
    assert_equal TASK, result.task_id
    assert_equal TASK, result.canonical_branch
    assert_equal "tiny-demo-workspace", result.workspace_key
    assert_equal 1, result.sources.length
  end

  def test_a_preview_is_never_inferred_from_field_presence
    refuses(payload.merge("assignment_kind" => "run"), "not a task preview")
    refuses(payload.tap { |document| document.delete("assignment_kind") }, "not a task preview")
  end

  def test_an_unknown_contract_version_is_refused
    refuses(payload.merge("contract_version" => "mvp-0010"), "unsupported contract version")
    refuses(payload.tap { |document| document.delete("contract_version") }, "unsupported contract version")
  end

  def test_an_unexpected_top_level_block_is_refused
    refuses(payload.merge("executor" => { "command" => "sh" }), "unexpected block \"executor\"")
  end

  def test_a_missing_null_or_scalar_block_is_refused
    %w[claim preview workspace].each do |name|
      refuses(payload.merge(name => nil), "the #{name} block is missing")
      refuses(payload.merge(name => "x"), "the #{name} block is not an object")
    end
  end

  # The whole point of the closed shape: a command, an argv array, a local path, a credential, a
  # host or a port is refused because it is not in the contract, not because it is on a list.
  def test_every_smuggled_field_shape_is_refused
    { "command" => "rm -rf /", "argv" => %w[sh -c evil], "platform_root" => "/Users/someone/dev",
      "credential" => "src_secret", "host" => "10.0.0.5", "port" => 8080 }.each do |key, value|
      refuses(payload.merge("preview" => payload["preview"].merge(key => value)),
              "unexpected field #{key.inspect}")
    end
  end

  def test_a_missing_required_identifier_is_refused
    refuses(payload.merge("claim" => payload["claim"].merge("execution_id" => nil)),
            "claim block is missing \"execution_id\"")
    refuses(payload.merge("preview" => payload["preview"].merge("task_id" => "")),
            "preview block is missing \"task_id\"")
    refuses(payload.merge("workspace" => payload["workspace"].merge("key" => nil)),
            "workspace block is missing \"key\"")
  end

  def test_a_structured_value_where_a_plain_one_belongs_is_refused
    refuses(payload.merge("preview" => payload["preview"].merge("task_id" => { "x" => 1 })),
            "is not a plain value")
    refuses(payload.merge("preview" => payload["preview"].merge("canonical_branch" => %w[a b])),
            "is not a plain value")
  end

  def test_an_over_bound_value_is_refused
    long = "a" * (SpecrelayRunner::PreviewAssignment::MAX_VALUE_BYTES + 1)
    refuses(payload.merge("preview" => payload["preview"].merge("ticket_key" => long)), "longer than")
  end

  # A task id becomes a command argument, so it may not carry a path, an option or whitespace.
  def test_an_unsafe_task_id_or_branch_is_refused
    [ "../../etc", "--force", "a b", "task/../..", "-rf", "" ].each do |unsafe|
      refuses(payload.merge("preview" => payload["preview"].merge("task_id" => unsafe)),
              unsafe.empty? ? "is missing" : "is not a safe identifier")
    end
    refuses(payload.merge("preview" => payload["preview"].merge("canonical_branch" => "a;b")),
            "is not a safe identifier")
  end
end
