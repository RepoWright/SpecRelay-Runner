# frozen_string_literal: true

# MAPIAI-60 CR-005 — the SUPPORTED Claude stream-json shapes, captured verbatim from
# `claude --print --output-format stream-json --verbose` (Claude Code 2.1.222) during the
# CR-005 contract capture and reduced to the fields the transcript reads.
#
# This is a recording, not an invention: every key here appeared in that capture. Where a
# shape is not in the capture it is marked, so a test can never claim contract support the
# CLI has not demonstrated.
module ClaudeStreamJson
  module_function

  def init(cwd: "/work")
    { "type" => "system", "subtype" => "init", "cwd" => cwd, "session_id" => "sess-1",
      "model" => "claude-opus-5", "apiKeySource" => "keychain", "tools" => %w[Read Bash Edit],
      "mcp_servers" => [], "claude_code_version" => "2.1.222", "uuid" => "u-init" }
  end

  # `system/thinking_tokens` is the only thinking-related PUBLIC signal the capture contains:
  # an estimated token count. There is no duration, so no "Thought for 1s" is reproducible.
  def thinking_tokens(estimated, delta = estimated)
    { "type" => "system", "subtype" => "thinking_tokens", "estimated_tokens" => estimated,
      "estimated_tokens_delta" => delta, "uuid" => "u-tt", "session_id" => "sess-1" }
  end

  def narration(text, parent: nil)
    assistant([ { "type" => "text", "text" => text } ], parent: parent)
  end

  # A `thinking` block carries the model's PRIVATE reasoning plus a signature. It is public in
  # the transport, never public to an operator.
  def thinking(text)
    assistant([ { "type" => "thinking", "thinking" => text, "signature" => "sig-abc" } ])
  end

  def read_call(path, id: "toolu_read")
    assistant([ tool_use(id, "Read", "file_path" => path) ])
  end

  def bash_call(command, description: nil, id: "toolu_bash")
    input = { "command" => command }
    input["description"] = description if description
    assistant([ tool_use(id, "Bash", input) ])
  end

  def edit_call(path, old_string, new_string, id: "toolu_edit")
    assistant([ tool_use(id, "Edit", "replace_all" => false, "file_path" => path,
                         "old_string" => old_string, "new_string" => new_string) ])
  end

  def task_call(description, prompt, subagent_type: "general-purpose", id: "toolu_task")
    assistant([ tool_use(id, "Task", "description" => description, "prompt" => prompt,
                         "subagent_type" => subagent_type) ])
  end

  # Any tool the specialized renderers do not know. Captured live: TaskOutput arrives exactly
  # like this — `{"task_id":"b8sk74npe","block":true,"timeout":15000}`.
  def tool_call(name, input, id = "toolu_generic")
    assistant([ tool_use(id, name, input) ])
  end

  # The genuine background/TaskOutput result recorded from the supported CLI.
  def task_output_result(id, task_id, output, status: "completed", exit_code: 0)
    result(id, "<retrieval_status>success</retrieval_status>",
           detail: { "retrieval_status" => "success",
                     "task" => { "task_id" => task_id, "task_type" => "local_bash",
                                 "status" => status, "description" => "Sleep then echo",
                                 "output" => output, "exitCode" => exit_code } })
  end

  def tool_use(id, name, input)
    { "type" => "tool_use", "id" => id, "name" => name, "input" => input,
      "caller" => { "type" => "direct" } }
  end

  def assistant(content, parent: nil)
    { "type" => "assistant", "message" => { "content" => content }, "parent_tool_use_id" => parent,
      "session_id" => "sess-1", "uuid" => "u-a", "timestamp" => "2026-08-14T20:00:00Z" }
  end

  # A Bash result: `tool_use_result` separates stdout from stderr; the `tool_result` block
  # carries the same text already joined.
  def bash_result(id, stdout: "", stderr: "", is_error: false)
    result(id, "#{stdout}#{stderr}", is_error: is_error,
           detail: { "stdout" => stdout, "stderr" => stderr, "interrupted" => false,
                     "isImage" => false, "noOutputExpected" => false })
  end

  def read_result(id, path, content)
    lines = content.lines.length
    result(id, content,
           detail: { "type" => "text",
                     "file" => { "filePath" => path, "content" => content, "numLines" => lines,
                                 "startLine" => 1, "totalLines" => lines } })
  end

  def edit_result(id, path, old_string, new_string, original_file: "")
    result(id, "The file #{path} has been updated.",
           detail: { "filePath" => path, "oldString" => old_string, "newString" => new_string,
                     "originalFile" => original_file, "userModified" => false,
                     "replaceAll" => false })
  end

  # A failing tool answers with a plain String `tool_use_result` and an `is_error` block.
  def failed_result(id, text)
    result(id, text, is_error: true, detail: text)
  end

  def result(id, content, is_error: false, detail: nil)
    block = { "tool_use_id" => id, "type" => "tool_result", "content" => content }
    block["is_error"] = true if is_error
    message = { "type" => "user", "message" => { "content" => [ block ] },
                "parent_tool_use_id" => nil, "session_id" => "sess-1", "uuid" => "u-u",
                "timestamp" => "2026-08-14T20:00:01Z" }
    message["tool_use_result"] = detail unless detail.nil?
    message
  end

  def rate_limit(status: "allowed", type: "five_hour")
    { "type" => "rate_limit_event",
      "rate_limit_info" => { "status" => status, "rateLimitType" => type, "resetsAt" => 1_786_747_800,
                             "overageStatus" => "rejected", "isUsingOverage" => false },
      "uuid" => "u-rl", "session_id" => "sess-1" }
  end

  def terminal(text = "final result text", is_error: false, subtype: "success",
               duration_ms: 43_673, num_turns: 8, stop_reason: "end_turn")
    { "type" => "result", "subtype" => subtype, "is_error" => is_error, "result" => text,
      "duration_ms" => duration_ms, "duration_api_ms" => 44_995, "num_turns" => num_turns,
      "stop_reason" => stop_reason, "terminal_reason" => "completed", "total_cost_usd" => 0.29,
      "session_id" => "sess-1", "uuid" => "u-r" }
  end
end
