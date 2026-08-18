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
  #   run:     :edit | :fail | :auth_failure | :hang | :no_change
  def build(install: true, version: :ok, auth: :logged_in, run: :edit,
            from_heading: "Hello Demo", to_heading: "Hello SpecRelay Demo")
    bin_dir = Dir.mktmpdir("fake-claude-bin-")
    argv_log = File.join(bin_dir, "argv.json")
    return [ bin_dir, argv_log ] unless install

    path = File.join(bin_dir, "claude")
    File.write(path, script(argv_log, version, auth, run, from_heading, to_heading))
    FileUtils.chmod(0o755, path)
    [ bin_dir, argv_log ]
  end

  # `hang` sleeps well past every bounded timeout the runner uses, so the runner's
  # own Timeout/process-group kill is what ends it — a real timeout, not a stub.
  HANG_SECONDS = 600

  def script(argv_log, version, auth, run, from_heading, to_heading)
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

      #{run_branch(run, from_heading, to_heading)}
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

  def run_branch(run, from_heading, to_heading)
    case run
    when :fail then %(warn "the model produced no usable change"; exit 4)
    when :auth_failure then %(warn "Not logged in. Please run `claude auth login`."; exit 1)
    when :hang then %(sleep #{HANG_SECONDS}; exit 0)
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
end
