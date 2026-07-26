# frozen_string_literal: true

module SpecrelayRunner
  # The runner's local durable-credential store (MVP-0017).
  #
  # The guided connection must never print a durable credential, write it to YAML, a
  # shell profile, Git, or a log. So the credential goes straight into the operating
  # system's own secret store, and this class is the ONE narrow seam where that happens.
  #
  # macOS is the supported guided-storage platform for this MVP. On any other system
  # `connect` fails BEFORE registration with a clear message rather than silently saving
  # a plaintext credential — an unsupported platform is a refusal, never a downgrade.
  # There is deliberately no file-based fallback in this class at all: adding one later
  # would be a visible, reviewable change rather than an accident.
  #
  # The macOS backend is the `security` command-line tool, not a native extension,
  # because the runner is standard-library-only and Rails-free by contract.
  # `add-generic-password -U` is an upsert, which is what makes a retried `connect`
  # idempotent instead of raising a duplicate-item error.
  #
  # The credential is delivered on the child's STDIN, never as an argv element (round 002,
  # review-001 F8). `security` itself documents `-w` as insecure — "Use of the -p or -w
  # options is insecure. Specify -w as the last option to be prompted." — because an argv
  # element is visible in the process table to any process running as the same user for the
  # duration of the call. Passing `-w` last with no value makes the tool prompt, and the value
  # is written to the pipe instead. The tool asks twice (password, then confirmation), so the
  # value is written twice; that is the documented interactive contract, not a workaround.
  #
  # The process is spawned directly, never through a shell, so the value cannot be
  # word-split, glob-expanded, or captured by a shell history file either. It is not logged,
  # echoed, or included in any error message: a failure reports the exit status and the tool's
  # own stderr, which never contains the value.
  class SecretStore
    Error = Class.new(StandardError)
    UnsupportedPlatform = Class.new(Error)

    # A stable, non-secret Keychain service name. It contains no project, workspace, or
    # account identity, so the Keychain listing itself leaks nothing about the operator's
    # work; the per-workspace distinction is the account field below.
    SERVICE = "com.specrelay.runner"

    # Bounded so a Keychain prompt that is never answered cannot hang the connection.
    TIMEOUT_SECONDS = 60

    def self.for(platform: RUBY_PLATFORM, runner: CommandRunner)
      raise UnsupportedPlatform, unsupported_message(platform) unless macos?(platform)

      new(runner: runner)
    end

    def self.macos?(platform) = platform.to_s.include?("darwin")

    def self.unsupported_message(platform)
      "guided local secret storage is only supported on macOS in this release (detected #{platform}). " \
        "The runner will not save a plaintext credential on this system."
    end

    def initialize(runner: CommandRunner)
      @runner = runner
    end

    # Store (or replace) the credential for one workspace. `-U` upserts, so reconnecting
    # the same workspace overwrites rather than failing. `-w` is LAST and carries no value, so
    # the tool prompts and reads the credential from stdin — keeping it out of argv.
    def write(account:, credential:)
      result = run([ "security", "add-generic-password", "-a", account, "-s", SERVICE, "-U", "-w" ],
                   stdin_data: prompt_response(credential))
      return true if result&.success?

      raise Error, "could not save the runner credential to the macOS Keychain#{failure_suffix(result)}. " \
                   "If you denied the Keychain prompt, run the connect command again and choose Allow."
    end

    # The stored credential for one workspace, or nil when none is stored. A missing item
    # is a normal state (a runner that has not connected yet), not an error.
    def read(account:)
      result = run([ "security", "find-generic-password", "-a", account, "-s", SERVICE, "-w" ])
      return nil if result.nil? || !result.success?

      value = result.stdout.to_s.chomp
      value.empty? ? nil : value
    end

    # The non-secret Keychain account name for one RUNNER identity.
    #
    # Keyed by the runner's Platform-issued public id, because that is the credential's actual
    # scope: `registered_runners.credential_digest` is per runner, not per workspace. Round 002
    # keyed it per workspace, so a first-time connection to a second workspace rotated the shared
    # credential and left the first workspace's stored copy stale — `claim-once --workspace A`
    # then failed to authenticate (review-002, F3 residual).
    #
    # The public id is non-secret and carries no local path, provider account, or operator email,
    # so the Keychain listing still leaks nothing about the operator's work.
    def self.account_for_runner(runner_public_id) = "runner:#{runner_public_id}"

    # The pre-round-003 per-workspace account name. Retained for READS only, so a machine that
    # connected under the old scheme keeps authenticating without reconnecting; nothing writes
    # here any more.
    def self.legacy_account_for(workspace_key) = "workspace:#{workspace_key}"

    private

    attr_reader :runner

    # `security add-generic-password -w` prompts for the password and then for a confirmation,
    # so both lines are the credential. Kept in one place so the doubling is obvious and cannot
    # be mistaken for an accidental duplicate.
    def prompt_response(credential) = "#{credential}\n#{credential}\n"

    def run(argv, stdin_data: nil)
      runner.run(argv, chdir: Dir.pwd, env: { "PATH" => ENV["PATH"].to_s },
                 timeout_seconds: TIMEOUT_SECONDS, stdin_data: stdin_data)
    rescue SystemCallError
      # `security` could not be launched at all. Treated as a failure rather than an
      # exception so the caller reports one clear remedy.
      nil
    end

    # The tool's exit status and first stderr line. `security` never echoes the password
    # value it was handed, so this is safe to surface; it is still passed through
    # Redaction as defence in depth.
    def failure_suffix(result)
      return " (the `security` command could not be run)" if result.nil?

      detail = Redaction.redact(result.stderr.to_s.strip.lines.first.to_s.strip)
      detail.empty? ? " (exit #{result.exit_code})" : " (exit #{result.exit_code}: #{detail})"
    end
  end
end
