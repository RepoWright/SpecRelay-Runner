# frozen_string_literal: true

# An in-memory stand-in for the macOS Keychain, exercising the same narrow seam the real
# SecretStore exposes (MVP-0017, extended for MVP-0021 deletion).
#
# It is used INSTEAD of shelling out to `security` so the suite never touches the developer's
# real Keychain and never raises an interactive prompt in CI. The real tool's own behaviour —
# how it reads a value, how it reports failure — is covered separately by `secret_store_test.rb`
# against a recording runner and by `keychain_tty_test.rb` under a real pty. This fake exists to
# let the flows ABOVE that seam be tested as behaviour.
#
# It is shared rather than redefined per test file so "what the Keychain seam does" has one
# definition; a per-file copy is how the fake and the real class drift apart.
class FakeSecretStore
  attr_reader :writes, :deletes, :refused_deletes, :probes
  attr_writer :fail_probe, :fail_delete

  # `fail_probe` defaults to `fail_write` because a Keychain that refuses writes refuses the
  # writability probe too. They are separable so one example can model a Keychain that passes
  # the pre-flight and then fails at the real write.
  def initialize(fail_write: false, fail_probe: fail_write, fail_delete: false, entries: {})
    @entries = entries.dup
    @writes = []
    @deletes = []
    @refused_deletes = []
    @probes = 0
    @fail_write = fail_write
    @fail_probe = fail_probe
    @fail_delete = fail_delete
  end

  def write(account:, credential:)
    raise SpecrelayRunner::SecretStore::Error, "keychain access was denied" if @fail_write

    @writes << account
    @entries[account] = credential
    true
  end

  # The real store writes, reads back, and deletes a throwaway item; the fake only has to
  # record that the check happened and whether it passed.
  def verify_writable!
    @probes += 1
    raise SpecrelayRunner::SecretStore::Error, "keychain access was denied" if @fail_probe

    true
  end

  def read(account:) = @entries[account]

  # MVP-0021 scope 5. Mirrors the real store: removing an item that is not there is SUCCESS,
  # because the caller has got the state it asked for. A Keychain that REFUSED the deletion is a
  # failure, and — this is the part round 001 could not express — the item is still stored
  # afterwards.
  #
  # `fail_delete` existed before CR-001 but nothing used it, and the fake deleted the entry even
  # when it was set. That was the coverage gap review-001 named: a double that cannot answer
  # *wrongly* cannot catch a caller that believes every answer. It now leaves the entry in place,
  # so a test can assert both the reported failure AND that the credential really survived.
  def delete_credential(account:)
    if @fail_delete
      @refused_deletes << account
      raise SpecrelayRunner::SecretStore::Error,
            "the macOS Keychain refused to remove the item #{account} (exit 36: security: " \
            "SecKeychainItemDelete: User interaction is not allowed.). It is still stored."
    end

    @deletes << account
    @entries.delete(account)
    true
  end

  def stored?(account) = @entries.key?(account)
  def accounts = @entries.keys
end
