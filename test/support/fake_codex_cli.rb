# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# A deterministic stand-in for the real Codex CLI, written to disk as an executable literally
# named `codex` inside its own bin directory. A test prepends that directory to the child PATH,
# so the runner exercises its REAL code path — profile validation, PATH resolution,
# `codex --version`, `codex login status`, and an argv-only launch with the prompt on stdin —
# without a network call, a provider account, or any inference.
#
# Behaviour is BAKED INTO the generated script rather than read from the environment, because
# the deterministic seams have to work without mutating ENV or relying on global process state.
#
# The login-status double deliberately prints account-bearing text, which is what lets a test
# assert the runner records only a classification and never leaks the raw output.
module FakeCodexCli
  # Values a test can assert never appear in console output, events, or the report.
  ACCOUNT_EMAIL = "operator-account@fake-codex.test"
  ACCOUNT_ORG = "org-fake-codex-do-not-leak"
  VERSION = "9.9.9"
  VERSION_LINE = "codex-cli #{VERSION}"

  # A secret-shaped token the executor transcript must have redacted before upload.
  LEAKED_TOKEN = "sk-live-CODEX-DO-NOT-LEAK-0123456789"

  # The private reasoning the decoder must never publish.
  PRIVATE_REASONING = "private-codex-reasoning-do-not-publish"

  module_function

  # Returns [bin_dir, argv_log_path]. When `install:` is false the executable is deliberately NOT
  # created, so `codex` is genuinely absent from the PATH.
  #
  #   version: :ok | :error | :unexpected | :hang
  #   login:   :logged_in | :logged_out | :error | :hang
  #   run:     :edit | :fail | :auth_failure | :turn_failed | :no_terminal | :hang
  def build(install: true, version: :ok, login: :logged_in, run: :edit,
            from_heading: "Hello Demo", to_heading: "Hello SpecRelay Demo")
    bin_dir = Dir.mktmpdir("fake-codex-bin-")
    argv_log = File.join(bin_dir, "argv.json")
    return [ bin_dir, argv_log ] unless install

    path = File.join(bin_dir, "codex")
    File.write(path, script(argv_log, version, login, run, from_heading, to_heading))
    FileUtils.chmod(0o755, path)
    [ bin_dir, argv_log ]
  end

  # Sleeps well past every bounded probe timeout the runner uses, so the runner's own
  # Timeout/process-group kill is what ends it — a real timeout, not a stub.
  HANG_SECONDS = 600

  def script(argv_log, version, login, run, from_heading, to_heading)
    <<~RUBY
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      require "json"

      File.write(#{argv_log.inspect}, JSON.generate(ARGV))

      if ARGV.first == "--version"
        #{version_branch(version)}
      end

      if ARGV.first == "login"
        #{login_branch(login)}
      end

      #{run_branch(run, from_heading, to_heading)}
    RUBY
  end

  def version_branch(version)
    case version
    when :error then %(warn "codex: command failed"; exit 1)
    when :unexpected then %(puts "#{ACCOUNT_EMAIL} something else entirely"; exit 0)
    when :hang then %(sleep #{HANG_SECONDS}; exit 0)
    else %(puts #{VERSION_LINE.inspect}; exit 0)
    end
  end

  def login_branch(login)
    case login
    when :error then %(warn "codex: login status unavailable"; exit 1)
    when :hang then %(sleep #{HANG_SECONDS}; exit 0)
    when :logged_out then %(puts "Not logged in. Run `codex login`."; exit 1)
    else %(puts "Logged in as #{ACCOUNT_EMAIL} (#{ACCOUNT_ORG})"; exit 0)
    end
  end

  def run_branch(run, from_heading, to_heading)
    case run
    when :fail then %(warn "the model produced no usable change"; exit 4)
    when :auth_failure then %(warn "You are not logged in. Run `codex login`."; exit 1)
    when :hang then %(sleep #{HANG_SECONDS}; exit 0)
    when :turn_failed then failing_turn_branch
    when :no_terminal then unterminated_branch
    else edit_branch(from_heading, to_heading)
    end
  end

  # The prompt arrives on STDIN, which is this profile's whole reason for `prompt_delivery:
  # stdin`: the assignment text never becomes a process argument.
  #
  # Items carry the PUBLIC `item.type` discriminator, as the official Codex SDK emits it
  # (https://github.com/openai/codex, sdk/typescript/src/thread.ts). This double must describe the
  # provider, never the runner's reading of it.
  PROMPT = <<~RUBY.strip
    prompt = $stdin.read.to_s
    abort "refusing to run without a prompt on stdin" if prompt.strip.empty?
    $stdout.sync = true
    def say(event) = puts(JSON.generate(event))
    def item(type, fields) = { "id" => "item_0", "type" => type }.merge(fields)
  RUBY

  # The observed success shape: a started thread and turn, a command execution reported as it
  # starts and again as it completes, private reasoning, one public message, one terminal event.
  def edit_branch(from_heading, to_heading)
    <<~RUBY.strip
      #{PROMPT}
      #{selection_reporter}

      file = "demo-app/index.html"
      say("type" => "thread.started", "thread_id" => "th_fake")
      say("type" => "turn.started")
      say("type" => "item.completed",
          "item" => item("reasoning", "text" => #{PRIVATE_REASONING.inspect}))
      say("type" => "item.started",
          "item" => item("command_execution", "command" => "cat \#{File.expand_path(file)}",
                                              "status" => "in_progress"))
      content = File.read(file)
      applied = content.include?(#{from_heading.inspect})
      File.write(file, content.gsub(#{from_heading.inspect}, #{to_heading.inspect})) if applied
      say("type" => "item.completed",
          "item" => item("command_execution", "command" => "cat \#{File.expand_path(file)}",
                                              "aggregated_output" => "read \#{File.expand_path(file)}",
                                              "exit_code" => 0, "status" => "completed"))
      say("type" => "item.completed",
          "item" => item("agent_message", "text" => "working on the heading; #{LEAKED_TOKEN}"))
      sleep 0.4
      report(prompt)
      say("type" => "item.completed",
          "item" => item("agent_message",
                         "text" => (applied ? "applied the heading change" : "the heading change is already applied; nothing to do") +
                                   " (transcript echoed #{LEAKED_TOKEN})"))
      say("type" => "turn.completed", "usage" => { "input_tokens" => 12 })
      exit 0
    RUBY
  end

  def failing_turn_branch
    <<~RUBY.strip
      #{PROMPT}
      #{selection_reporter}
      say("type" => "thread.started", "thread_id" => "th_fake")
      report(prompt)
      say("type" => "item.completed", "item" => item("agent_message", "text" => "a partial answer"))
      say("type" => "turn.failed", "error" => { "message" => "quota exhausted for #{ACCOUNT_EMAIL}" })
      exit 0
    RUBY
  end

  def unterminated_branch
    <<~RUBY.strip
      #{PROMPT}
      #{selection_reporter}
      say("type" => "thread.started", "thread_id" => "th_fake")
      report(prompt)
      say("type" => "item.completed", "item" => item("agent_message", "text" => "looks finished but is not"))
      exit 0
    RUBY
  end

  # The runner's bounded repository-selection document, read out of the STDIN prompt rather than
  # out of argv — the shared lifecycle step this profile has to satisfy like every other.
  def selection_reporter
    <<~RUBY.strip
      def report(prompt)
        path = prompt[%r{`([^`]*/changed-repositories\\.json)`}, 1]
        abort "the prompt named no repository selection document" if path.nil?
        document = JSON.generate({ "repositories" => [ { "path" => ".", "commands" => [ [ "bin/test" ] ] } ] })
        File.write(path + ".partial", document)
        File.rename(path + ".partial", path)
      end
    RUBY
  end
end
