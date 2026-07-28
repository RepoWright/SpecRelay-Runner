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
  # HOW THE CREDENTIAL IS DELIVERED, AND WHY IT IS NOT `-w <value>` IN ARGV
  # ----------------------------------------------------------------------
  # `security` documents `-w` as insecure when given a value — "Use of the -p or -w options
  # is insecure" — because an argv element is visible in the process table to any process
  # running as the same user for the duration of the call (round 002, review-001 F8).
  #
  # Round 002 therefore passed `-w` LAST with no value so the tool would prompt, and wrote the
  # credential to the child's stdin. That is wrong on a real operator's machine, and it shipped
  # because it was only ever verified where it happens to work. `security` reads that prompt
  # with `readpassphrase(3)`, which opens **`/dev/tty`** and only falls back to stdin when no
  # controlling terminal can be opened. In CI and in a captured non-interactive shell there is
  # no controlling terminal, so the stdin fallback engaged and the write succeeded. In a real
  # terminal — which is the only place a normal user ever runs `connect` — the tool prompted on
  # the terminal, never read the pipe, and the connection hung until the timeout killed it.
  #
  # So the command is delivered through `security -i` (interactive mode), which reads its
  # command line from **stdin**. The credential is part of that stdin line, so:
  #
  #   - it is not an argv element of any process (`ps` shows only `security -i`), which is what
  #     F8 required; and
  #   - no terminal is involved at all, so the behaviour is identical with and without a
  #     controlling terminal.
  #
  # Interactive mode splits its line on whitespace, so a credential containing whitespace, a
  # quote, or a backslash could be silently truncated — measured: `security -i` stores the
  # truncated value and still exits 0. Two defences, because a silently wrong stored credential
  # would surface much later as an unexplained authentication failure:
  #
  #   1. `UNDELIVERABLE` refuses such a value up front rather than storing part of it;
  #   2. every write is READ BACK and compared, and a mismatch deletes the item and raises.
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
    # work; the per-runner distinction is the account field below.
    SERVICE = "com.specrelay.runner"

    # Bounded so a Keychain interaction that never completes cannot hang the connection.
    TIMEOUT_SECONDS = 60

    # The writability pre-flight (see `#verify_writable!`). Both values are fixed, meaningless,
    # and non-secret: the point is to prove the Keychain accepts a write, not to store anything.
    PROBE_ACCOUNT = "probe:writability"
    PROBE_VALUE = "specrelay-writability-probe"

    # Characters `security -i` would treat as token structure rather than as part of the value.
    UNDELIVERABLE = /[\s"'\\]/

    # `security`'s exit status for "the item is not there", measured against the real tool on
    # macOS 15: `security delete-generic-password -a <absent> -s <service>` exits 44 with
    # `SecKeychainSearchCopyNext: The specified item could not be found in the keychain.`
    #
    # This is the ONLY non-zero status `delete_credential` treats as success. It exists as a
    # named constant because round 001 assumed every non-zero status meant this one, and a
    # refusal (exit 36, keychain locked or access denied) took the same path.
    ITEM_NOT_FOUND = 44
    ITEM_NOT_FOUND_HINT = /could not be found in the keychain/i

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

    # Store (or replace) the credential for one runner identity. `-U` upserts, so reconnecting
    # overwrites rather than failing.
    def write(account:, credential:)
      store!(account: account, value: credential, label: "runner credential")
    end

    # Prove the Keychain will accept a write, using a throwaway non-secret item.
    #
    # `connect` calls this BEFORE it spends the one-time enrollment code, so a machine whose
    # Keychain cannot be written to fails at no cost and the same code still works on the next
    # attempt. Without it, the credential arrives from Platform — the code already consumed —
    # and only then does storage fail, which is the state a real operator hit: every retry
    # needed a freshly issued code.
    #
    # The probe item is always removed, including when the write itself failed.
    def verify_writable!
      store!(account: PROBE_ACCOUNT, value: PROBE_VALUE, label: "Keychain writability check")
      true
    ensure
      delete(PROBE_ACCOUNT)
    end

    # The stored credential for one account, or nil when none is stored. A missing item
    # is a normal state (a runner that has not connected yet), not an error.
    def read(account:)
      result = run([ "security", "find-generic-password", "-a", account, "-s", SERVICE, "-w" ])
      return nil if result.nil? || !result.success?

      value = result.stdout.to_s.chomp
      value.empty? ? nil : value
    end

    # Remove one stored item (MVP-0021 scope 5).
    #
    # SUCCESS means exactly two things: the item was deleted (exit 0), or it was ALREADY GONE
    # (exit ITEM_NOT_FOUND). The second is a success because the operator asked for the item not
    # to be there and it is not there.
    #
    # EVERYTHING else is a refusal and raises. Round 001 shipped this as "any non-zero exit means
    # no such item", which was measured wrong and was the more dangerous direction to be wrong in
    # (review-001 F1): a locked or access-denied login keychain exits 36
    # (`SecKeychainItemDelete: User interaction is not allowed.`) with the credential still
    # stored, and that reported as "the credential was removed" — while the same operation had
    # just deleted the local entry that would have led the operator back to it. A deletion the OS
    # refused must reach the operator as a refusal.
    #
    # The account name is non-secret by construction (`runner:<public-id>` or `workspace:<key>`),
    # so a caller may name it in the confirmation it shows before calling this, and this method
    # may name it in a failure.
    #
    # The runner NEVER calls this as a side effect of another operation. Removing a credential is
    # its own explicit, separately confirmed decision, because the credential is scoped to the
    # runner identity and shared by every workspace that identity is connected to.
    def delete_credential(account:)
      result = delete(account)
      return true if removed?(result)

      raise Error, delete_failure_message(account, result)
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

    # One upsert, delivered on stdin, then verified by reading it back.
    def store!(account:, value:, label:)
      deliverable!(account, "Keychain account name")
      deliverable!(value, label)

      result = run([ "security", "-i" ], stdin_data: "#{add_command(account, value)}\n")
      raise Error, failure_message(label, result) unless result&.success?

      verify_stored!(account, value, label)
      true
    end

    # The interactive-mode command line. This string carries the credential, which is exactly
    # why it goes on stdin and never into argv.
    def add_command(account, value)
      "add-generic-password -a #{account} -s #{SERVICE} -U -w #{value}"
    end

    # A write that stored something other than what was asked for is worse than a write that
    # failed, because it fails later and somewhere else. The wrong item is removed so the next
    # attempt starts clean, and neither value appears in the message.
    def verify_stored!(account, value, label)
      return if read(account: account) == value

      delete(account)
      raise Error, "the macOS Keychain did not store the #{label} exactly as issued, so the " \
                   "item was removed again. Run the connect command again; if it repeats, " \
                   "report it — the credential was not saved."
    end

    def delete(account)
      run([ "security", "delete-generic-password", "-a", account, "-s", SERVICE ])
    end

    # Deleted, or already absent. Nothing else counts.
    #
    # `ITEM_NOT_FOUND` is matched by exit status AND by the tool's own not-found message, so a
    # future `security` that renumbered its statuses would still be understood rather than
    # silently reclassified as a refusal. The stderr match is the belt to the status's braces —
    # deliberately not the other way round, because an unrecognised failure must land on the
    # raising path, not the succeeding one.
    def removed?(result)
      return false if result.nil? || result.timed_out?
      return false if result.exit_code.nil?
      return true if result.exit_code.to_i.zero?

      result.exit_code.to_i == ITEM_NOT_FOUND || result.stderr.to_s.match?(ITEM_NOT_FOUND_HINT)
    end

    # Names the account (non-secret) and the tool's own diagnostic, which `failure_suffix`
    # already redacts and reduces to one line. The credential value appears nowhere: `security`
    # does not echo it, and nothing here reads it.
    def delete_failure_message(account, result)
      "the macOS Keychain refused to remove the item #{account}#{failure_suffix(result)}. " \
        "It is still stored. Unlock your login keychain (Keychain Access ▸ login) and try again."
    end

    # Refused rather than truncated. The value itself is never named in the message.
    def deliverable!(value, label)
      text = value.to_s
      raise Error, "the #{label} is empty, so nothing was written to the macOS Keychain" if text.empty?
      return unless text.match?(UNDELIVERABLE)

      raise Error, "the #{label} contains whitespace, a quote, or a backslash, which this " \
                   "release cannot store in the macOS Keychain without risking a truncated " \
                   "value. Nothing was written."
    end

    def run(argv, stdin_data: nil)
      runner.run(argv, chdir: Dir.pwd, env: { "PATH" => ENV["PATH"].to_s },
                 timeout_seconds: TIMEOUT_SECONDS, stdin_data: stdin_data)
    rescue SystemCallError
      # `security` could not be launched at all. Treated as a failure rather than an
      # exception so the caller reports one clear remedy.
      nil
    end

    def failure_message(label, result)
      "could not save the #{label} to the macOS Keychain#{failure_suffix(result)}. " \
        "Unlock your login keychain (Keychain Access ▸ login) and run the connect command again."
    end

    # The tool's exit status and first stderr line. `security` never echoes the password
    # value it was handed, so this is safe to surface; it is still passed through
    # Redaction as defence in depth.
    #
    # A timeout is reported as a timeout. It used to arrive here as an empty exit status and
    # print as "(exit )", which told an operator nothing about what had actually happened.
    def failure_suffix(result)
      return " (the `security` command could not be run)" if result.nil?
      return " (the `security` command did not finish within #{TIMEOUT_SECONDS}s)" if result.timed_out?

      detail = Redaction.redact(result.stderr.to_s.strip.lines.first.to_s.strip)
      detail.empty? ? " (exit #{result.exit_code})" : " (exit #{result.exit_code}: #{detail})"
    end
  end
end
