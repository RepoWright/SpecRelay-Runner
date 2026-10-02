# frozen_string_literal: true

require_relative "test_helper"

# Which run the terminal output in front of an operator belongs to, proved at the one place
# that knows: the dispatcher that holds a claimed assignment.
#
# The claims:
#   - every assignment shape STATES its ticket, and the runner reads it from the assignment
#     rather than deriving it from a task id or from provider output;
#   - the key is on the presenter for exactly as long as the lane runs; and
#   - it is gone when the lane returns AND when the lane raises, so the next claim in a
#     `loop` session can never inherit it.
class ActiveTicketKeyTest < Minitest::Test
  CLI = SpecrelayRunner::CLI

  # ---- every lane states its own key -------------------------------------

  def test_the_implementation_assignment_states_the_ticket_key
    payload = claim_payload_for(task_id: "DEMO-9-add-an-export-button", issue_key: "DEMO-9")

    assert_equal "DEMO-9", resolve(payload)
  end

  # The point of the field. A task id opens with the key but is not one, and reconstructing a
  # key by cutting one up is exactly what the assignment exists to make unnecessary.
  def test_the_key_is_read_from_the_assignment_and_never_cut_out_of_the_task_id
    payload = claim_payload_for(task_id: "DEMO-9-add-an-export-button", issue_key: "DEMO-9")
    payload["work_item"] = { "issue_key" => nil }

    assert_nil resolve(payload), "no stated key means no prefix, not a key invented from task_id"
  end

  def test_the_specification_assignment_states_the_ticket_key
    assert_equal "DEMO-700", resolve(spec_creation_payload_for(issue_key: "DEMO-700"))
  end

  def test_the_package_preflight_assignment_states_the_ticket_key
    payload = {
      "assignment_kind" => SpecrelayRunner::PackagePreflight::Assignment::KIND,
      "claim" => { "runner_execution_id" => "rex_1" },
      "run" => { "id" => "run_1", "task_id" => "DEMO-42-add-an-export-button" },
      "specification_package_preflight" => { "ticket_key" => "DEMO-42" }
    }

    assert_equal "DEMO-42", resolve(payload)
  end

  def test_the_preview_assignment_states_the_ticket_key
    payload = {
      "contract_version" => "3", "assignment_kind" => "task_preview",
      "claim" => { "execution_id" => "rex_abc" },
      "preview" => { "id" => "prv_abc", "ticket_key" => "DEMO-97", "task_id" => "DEMO-97-preview" }
    }

    assert_equal "DEMO-97", resolve(payload)
  end

  def test_the_review_assignment_states_the_ticket_key
    payload = {
      "assignment_type" => "review",
      "claim" => { "runner_execution_id" => "rex_fake" },
      "ticket" => { "external_id" => "DEMO-1", "task_id" => "DEMO-1" }
    }

    assert_equal "DEMO-1", resolve(payload)
  end

  def test_an_assignment_that_states_no_key_resolves_to_none
    assert_nil resolve({ "run" => { "task_id" => "DEMO-9-add-an-export-button" } })
    assert_nil resolve({ "work_item" => { "issue_key" => "  " } })
    assert_nil resolve("not a document")
  end

  # ---- the window: set for the lane, cleared on every exit path ----------

  def test_the_lane_writes_under_the_key_and_the_lines_around_it_do_not
    cli, terminal = dispatching_cli { |presenter| presenter.line("[loop] executing") }
    cli.send(:presenter).line("[loop] claimed")

    assert_equal 0, cli.send(:execute, nil, nil, claim_payload_for(task_id: "DEMO-9", issue_key: "DEMO-9"))
    cli.send(:presenter).line("[loop] no eligible work")

    assert_equal [ "[loop] claimed", "[DEMO-9] [loop] executing", "[loop] no eligible work" ],
                 terminal.string.lines.map(&:chomp)
  end

  def test_a_second_assignment_in_one_session_states_its_own_key
    cli, terminal = dispatching_cli { |presenter| presenter.line("[loop] executing") }

    cli.send(:execute, nil, nil, claim_payload_for(task_id: "DEMO-9", issue_key: "DEMO-9"))
    cli.send(:execute, nil, nil, claim_payload_for(task_id: "DEMO-10", issue_key: "DEMO-10"))

    assert_equal [ "[DEMO-9] [loop] executing", "[DEMO-10] [loop] executing" ],
                 terminal.string.lines.map(&:chomp)
  end

  def test_a_lane_that_raises_still_leaves_no_key_behind
    cli, terminal = dispatching_cli { raise SpecrelayRunner::PlatformClient::Error, "the lease lapsed" }

    assert_raises(SpecrelayRunner::PlatformClient::Error) do
      cli.send(:execute, nil, nil, claim_payload_for(task_id: "DEMO-9", issue_key: "DEMO-9"))
    end
    cli.send(:presenter).line("[loop] stopping")

    assert_equal [ "[loop] stopping" ], terminal.string.lines.map(&:chomp)
  end

  private

  def resolve(payload) = CLI.new(out: StringIO.new, err: StringIO.new).send(:ticket_key_for, payload)

  # A CLI whose lane is the given block, so the window around dispatch is observed through the
  # real presenter rather than through a stub of it. The block is handed the presenter because
  # `self` inside a singleton definition is the CLI, not this test.
  def dispatching_cli(&lane)
    terminal = StringIO.new
    cli = CLI.new(out: terminal, err: StringIO.new)
    cli.define_singleton_method(:dispatch) do |_config, _client, _payload|
      lane.call(send(:presenter))
      0
    end
    [ cli, terminal ]
  end
end
