# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# A deterministic stand-in for the real Claude Code CLI (MVP-0016), written to
# disk as an executable literally named `claude` inside its own bin directory. A
# test prepends that directory to the child PATH, so the runner exercises its REAL
# code path — profile validation, PATH resolution, `claude --version`,
# `claude auth status`, and an argv-only launch — without a network call, a
# provider account, or any inference.
#
# Behaviour is BAKED INTO the generated script rather than read from the
# environment: the spec requires the real-profile seam to be testable without
# mutating ENV or relying on global process state.
#
# The auth-status double deliberately prints the same account-bearing JSON shape
# the real CLI prints (email, org id, org name). That is what lets a test assert
# the runner records only a classification and never leaks the raw output.
module FakeClaudeCli
  # Values a test can assert never appear in console output, events, or the report.
  ACCOUNT_EMAIL = "operator-account@fake-claude.test"
  ACCOUNT_ORG_ID = "org-2dccf0e0-fake-do-not-leak"
  ACCOUNT_ORG_NAME = "FakeClaudeOrg"
  VERSION_LINE = "9.9.9 (Fake Claude Code)"

  # A secret-shaped token the executor transcript must have redacted before upload.
  LEAKED_TOKEN = "sk-live-CLAUDE-DO-NOT-LEAK-0123456789"

  module_function

  # Returns [bin_dir, argv_log_path]. When `install:` is false the executable is
  # deliberately NOT created, so `claude` is genuinely absent from the PATH — the
  # honest way to prove the unavailable classification.
  #
  #   version: :ok | :error | :hang
  #   auth:    :logged_in | :logged_out | :error | :hang
  #   run:     :edit | :fail | :auth_failure | :hang | :no_change | :refused_question
  #   refused_turn: what a :refused_question provider does once its first question is refused —
  #            :correct re-asks and finishes on the answer; :exit leaves without asking again;
  #            :repeat ends the refused turn with a second result frame before correcting.
  def build(install: true, version: :ok, auth: :logged_in, run: :edit, refused_turn: :correct,
            from_heading: "Hello Demo", to_heading: "Hello SpecRelay Demo")
    bin_dir = Dir.mktmpdir("fake-claude-bin-")
    argv_log = File.join(bin_dir, "argv.json")
    return [ bin_dir, argv_log ] unless install

    path = File.join(bin_dir, "claude")
    File.write(path, script(argv_log, version, auth, run, refused_turn, from_heading, to_heading))
    FileUtils.chmod(0o755, path)
    [ bin_dir, argv_log ]
  end

  # `hang` sleeps well past every bounded timeout the runner uses, so the runner's
  # own Timeout/process-group kill is what ends it — a real timeout, not a stub.
  HANG_SECONDS = 600

  def script(argv_log, version, auth, run, refused_turn, from_heading, to_heading)
    <<~RUBY
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      require "json"

      # Record the exact argv this process was launched with, so a test can prove
      # the prompt arrived as ONE distinct element and no shell was involved.
      File.write(#{argv_log.inspect}, JSON.generate(ARGV))

      if ARGV.first == "--version"
        #{version_branch(version)}
      end

      if ARGV.first == "auth"
        #{auth_branch(auth)}
      end

      #{run_branch(run, refused_turn, from_heading, to_heading)}
    RUBY
  end

  def version_branch(version)
    case version
    when :error then %(warn "claude: command failed"; exit 1)
    when :hang then %(sleep #{HANG_SECONDS}; exit 0)
    else %(puts #{VERSION_LINE.inspect}; exit 0)
    end
  end

  def auth_branch(auth)
    case auth
    when :error then %(warn "claude: auth status unavailable"; exit 1)
    when :hang then %(sleep #{HANG_SECONDS}; exit 0)
    when :logged_out then %(puts JSON.pretty_generate(#{account_payload(false)}); exit 0)
    else %(puts JSON.pretty_generate(#{account_payload(true)}); exit 0)
    end
  end

  def account_payload(logged_in)
    {
      "loggedIn" => logged_in, "authMethod" => "claude.ai", "apiProvider" => "firstParty",
      "email" => ACCOUNT_EMAIL, "orgId" => ACCOUNT_ORG_ID, "orgName" => ACCOUNT_ORG_NAME,
      "subscriptionType" => "team"
    }.inspect
  end

  def run_branch(run, refused_turn, from_heading, to_heading)
    case run
    when :fail then %(warn "the model produced no usable change"; exit 4)
    when :auth_failure then %(warn "Not logged in. Please run `claude auth login`."; exit 1)
    when :hang then %(sleep #{HANG_SECONDS}; exit 0)
    when :refused_question then refused_question_branch(refused_turn, from_heading, to_heading)
    when :no_change
      # MAPIAI-84 — a provider that changed nothing still reports an EMPTY selection. Writing
      # no document at all is a different fact (the executor did not answer), and the runner
      # refuses that rather than guessing it meant "nothing".
      %(puts "considered the task and changed nothing"\n#{DemoWorkspace.selection_snippet(changed: 'false')}\nexit 0)
    else edit_branch(from_heading, to_heading)
    end
  end

  # The success path: behave like the supported profile — take the prompt as the final argv
  # element, edit the assigned worktree idempotently, and report progress the way
  # `--output-format stream-json --verbose` does (MAPIAI-60): a `system/init` message, typed
  # assistant/user messages as work happens, then ONE terminal `result` carrying the answer.
  #
  # It emits INCREMENTALLY, with a real pause before the result, so a test can prove progress
  # reached a surface while the process was still running rather than at exit.
  #
  # The planted token travels in an assistant TEXT block — private prose that must never be
  # displayed — so a test can assert both that it is not shown and that nothing else leaked.
  def edit_branch(from_heading, to_heading)
    <<~RUBY.strip
      prompt = ARGV.last.to_s
      abort "refusing to run without a prompt" if prompt.strip.empty?
      $stdout.sync = true
      def say(message) = puts(JSON.generate(message))
      def tool(name, input) = say("type" => "assistant", "message" => { "content" => [
        { "type" => "tool_use", "name" => name, "input" => input } ] })
      def tool_done = say("type" => "user", "message" => { "content" => [
        { "type" => "tool_result", "is_error" => false, "content" => "raw tool output" } ] })

      file = "demo-app/index.html"
      say("type" => "system", "subtype" => "init", "cwd" => Dir.pwd, "model" => "fake-claude")
      say("type" => "assistant", "message" => { "content" => [
        { "type" => "text", "text" => "considering the task; #{LEAKED_TOKEN}" } ] })
      tool("Read", "file_path" => File.expand_path(file))
      tool_done
      content = File.read(file)
      applied = content.include?(#{from_heading.inspect})
      if applied
        tool("Edit", "file_path" => File.expand_path(file))
        File.write(file, content.gsub(#{from_heading.inspect}, #{to_heading.inspect}))
        tool_done
      end
      tool("Bash", "command" => "npm test")
      tool_done
      sleep 0.4
      # The token also travels in the TERMINAL RESULT, which does reach the report's stdout
      # evidence — so the existing redaction of that evidence stays under test even though the
      # assistant prose above never reaches a surface at all.
      say("type" => "result", "subtype" => "success", "is_error" => false,
          "result" => (applied ? "applied the heading change" : "the heading change is already applied; nothing to do") +
                      " (transcript echoed #{LEAKED_TOKEN})")
      #{DemoWorkspace.selection_snippet(changed: 'applied')}
      exit 0
    RUBY
  end

# The refused question turn's own result frame and the final one, told apart by content so a test
# can prove which of them became evidence.
INTERMEDIATE_RESULT = "stopped on the refused question"
FINAL_RESULT = "applied the heading change after the answer"
QUESTION = {
  "questions" => [ { "prompt" => "Keep the heading change?",
                     "options" => [ { "key" => "keep", "label" => "Keep it", "recommended" => true } ] } ],
  "continuation_context" => {
    "progress" => "the heading is changed", "changed_areas" => "demo-app/index.html",
    "why_it_matters" => "the choice decides the visible copy", "next_step" => "finish",
    "remaining_work" => "verification", "do_not_repeat" => "the heading edit"
  }
}.freeze

# The observed rejected-question chain, as the supported profile emits it: the provider edits the
# worktree, reports its selection and asks; the first request is REFUSED, and the refused turn
# ends in a `result` frame of its own before the session continues. What follows is
# `refused_turn`'s choice. The blocked wait is bounded by the profile's own timeout, not here.
def refused_question_branch(refused_turn, from_heading, to_heading)
  <<~RUBY.strip
    prompt = ARGV.last.to_s
    abort "refusing to run without a prompt" if prompt.strip.empty?
    $stdout.sync = true
    def say(message) = puts(JSON.generate(message))
    def narrate(text) = say("type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => text } ] })
    def result(text) = say("type" => "result", "subtype" => "success", "is_error" => false, "result" => text)

    request = prompt[%r{`([^`]*/question-request\.json)`}, 1]
    abort "the prompt named no bridge" if request.nil?
    answer = File.join(File.dirname(request), "question-answer.json")
    error = File.join(File.dirname(request), "question-error.json")
    # A verdict is CONSUMED when read: the parent clears the previous verdict only when it
    # picks up the next request, so a provider that re-asks and polls at once would otherwise
    # read its own earlier refusal again.
    def verdict(answer, error)
      loop do
        return [ :answered, consume(answer)["answers"] ] if File.file?(answer)
        return [ :refused, consume(error)["error"] ] if File.file?(error)

        sleep 0.05
      end
    end
    def consume(path)
      JSON.parse(File.read(path)).tap { File.delete(path) }
    end
    def ask(request)
      File.write("\#{request}.partial", JSON.generate(#{QUESTION.inspect}))
      File.rename("\#{request}.partial", request)
    end

    say("type" => "system", "subtype" => "init", "cwd" => Dir.pwd, "model" => "fake-claude")
    file = "demo-app/index.html"
    File.write(file, File.read(file).gsub(#{from_heading.inspect}, #{to_heading.inspect}))
    #{DemoWorkspace.selection_reporter}
    SELECTION.call
    ask(request)
    kind, detail = verdict(answer, error)
    abort "expected the first question to be refused" unless kind == :refused
    narrate("question refused: \#{detail}")
    result(#{INTERMEDIATE_RESULT.inspect})
    #{after_refusal(refused_turn)}
  RUBY
end

def after_refusal(refused_turn)
  case refused_turn
  when :exit then "exit 1"
  when :repeat then "result(#{"#{INTERMEDIATE_RESULT} again".inspect})\n#{corrected_turn}"
  else corrected_turn
  end
end

def corrected_turn
  <<~RUBY.strip
    ask(request)
    kind, detail = verdict(answer, error)
    abort "expected the corrected question to be answered" unless kind == :answered
    narrate("answered: \#{JSON.generate(detail)}")
    result(#{FINAL_RESULT.inspect})
    SELECTION.call
    exit 0
  RUBY
end
end
