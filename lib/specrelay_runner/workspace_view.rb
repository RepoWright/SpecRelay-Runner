# frozen_string_literal: true

module SpecrelayRunner
  # The per-workspace detail view and its actions (MVP-0021 scope 2, 3, 5, 6).
  #
  # Opened from Dashboard by selecting one connection. It shows everything the operator needs
  # to decide what to do about ONE workspace — including the absolute local checkout path,
  # which the top-level list deliberately omits — and offers the actions that change it.
  #
  # THE TWO PROPERTIES THAT MATTER HERE:
  #
  #   1. `Start loop` and `Claim once` contain no claim logic. They hand
  #      `["loop", "--workspace", key]` to the CLI's own dispatcher, so they cannot drift from
  #      `specrelay-runner loop --workspace <key>` — they ARE that command. Everything about
  #      the run (readiness gate, credential resolution, live logs, Ctrl-C handling, exit code)
  #      is therefore identical whether it was typed or selected.
  #   2. Every destructive action asks first, in the FUTURE tense, naming what it will affect,
  #      and the two irreversible-feeling ones — removing a Keychain credential, and removing
  #      local state after a Platform disconnect — are separate questions. Merging them would
  #      let one "y" do more than the operator agreed to.
  class WorkspaceView
    FOOTER = "shortcut keys act immediately · B or Esc goes back · ↑/↓ then Enter"

    def initialize(operations:, dispatch:, out:, menu:)
      @operations = operations
      @dispatch = dispatch
      @out = out
      @menu = menu
      @last_readiness = {}
    end

    def open(workspace_key)
      loop do
        connection = operations.connection_for(workspace_key)
        # It can genuinely be gone — disconnected here a moment ago, or removed from another
        # terminal. Returning to the top level is the honest response, not an error.
        return if connection.nil?

        action = menu.select(title: "#{Dashboard::TITLE} — #{workspace_key}",
                             header: detail_rows(connection), entries: entries(workspace_key),
                             footer: FOOTER)
        return if action == TerminalMenu::CANCEL || action == :back
        return if perform(workspace_key, action) == :leave
      end
    end

    private

    attr_reader :operations, :dispatch, :out, :menu

    def detail_rows(connection)
      rows = ConnectionView.detail_rows(connection, default: operations.listing.default?(connection),
                                        readiness: @last_readiness[connection.workspace_key])
      label_width = rows.map { |label, _| label.length }.max
      rows.map { |label, value| "  #{label.ljust(label_width)}  #{value}" }
    end

    # The `D` row's LABEL changes with state rather than the menu offering both a set and a
    # clear action: exactly one of them is ever meaningful, and showing the inapplicable one
    # invites pressing it.
    def entries(workspace_key)
      default = operations.listing.default_workspace_key == workspace_key
      [
        entry("L", "Start loop — poll and execute work for this workspace", :loop),
        entry("O", "Claim once — one controlled single-shot execution", :claim_once),
        entry("T", "Test connection and readiness (claims nothing)", :test),
        entry("S", "Show details", :show),
        entry("D", default ? "Clear the default workspace" : "Set as the default workspace", :default),
        entry("X", "Disconnect locally (this machine only)", :disconnect_local),
        entry("P", "Disconnect from Platform (remove this runner's grant)", :disconnect_platform),
        entry("B", "Back", :back)
      ]
    end

    def entry(shortcut, label, value) = TerminalMenu::Entry.new(shortcut: shortcut, label: label, value: value)

    # Returns :leave when this view should close, otherwise nil.
    def perform(workspace_key, action)
      case action
      when :loop then run_command([ "loop", "--workspace", workspace_key ])
      when :claim_once then run_command([ "claim-once", "--workspace", workspace_key ])
      when :test then test(workspace_key)
      when :show then show(workspace_key)
      when :default then toggle_default(workspace_key)
      when :disconnect_local then disconnect_local(workspace_key)
      when :disconnect_platform then disconnect_platform(workspace_key)
      end
    end

    # --- run a real command --------------------------------------------------

    # Cooked mode is re-asserted BEFORE dispatching so the command's own output and its signal
    # handling behave exactly as they do when it is typed directly. The echoed command line is
    # printed for the same reason: an operator should be able to see, copy, and re-run what the
    # menu just did.
    def run_command(argv)
      menu.restore
      menu.clear
      out.puts "$ specrelay-runner #{argv.join(' ')}"
      out.puts ""
      status = dispatch.call(argv)
      out.puts ""
      out.puts "(#{argv.first} exited #{status})"
      menu.pause
      nil
    rescue Interrupt
      # Ctrl-C stops the dispatched command and returns here — the same contract `loop`
      # documents for a directly-typed invocation. The dashboard itself is not torn down.
      out.puts ""
      out.puts "Interrupted. Nothing was left claimed by this terminal."
      menu.pause
      nil
    end

    # --- non-destructive actions ---------------------------------------------

    def test(workspace_key)
      menu.restore
      menu.clear
      out.puts "Testing #{workspace_key} — this claims no work and changes nothing."
      out.puts ""
      outcome = operations.test(workspace_key)
      print_checks(outcome.payload)
      report(outcome)
      remember_readiness(workspace_key, outcome)
      menu.pause
      nil
    end

    # The ordered trail, so the operator sees which preconditions held before the one that did
    # not — the difference between "something is wrong" and "this specific thing is wrong".
    def print_checks(result)
      return if result.nil? || result.checks.nil?

      result.checks.each do |check|
        marker = { ok: "✓", failed: "✗", skipped: "–" }.fetch(check.state, "?")
        out.puts "  #{marker} #{check.label}#{" — #{check.detail}" if check.detail}"
      end
      out.puts ""
    end

    def remember_readiness(workspace_key, outcome)
      @last_readiness[workspace_key] =
        outcome.ok? ? "ready (tested just now)" : "#{outcome.payload&.outcome} (tested just now)"
    end

    def show(workspace_key)
      connection = operations.connection_for(workspace_key)
      return :leave if connection.nil?

      menu.restore
      menu.clear
      detail_rows(connection).each { |line| out.puts line }
      menu.pause
      nil
    end

    def toggle_default(workspace_key)
      menu.restore
      menu.clear
      currently_default = operations.listing.default_workspace_key == workspace_key
      report(currently_default ? operations.clear_default : operations.set_default(workspace_key))
      menu.pause
      nil
    end

    # --- local disconnect ----------------------------------------------------

    # Both questions are asked BEFORE anything is removed, so the whole change is one atomic
    # operation the operator has already agreed to in full. The first names the workspace AND
    # the repository, because a workspace key alone is easy to misread when several are
    # connected.
    def disconnect_local(workspace_key)
      connection = operations.connection_for(workspace_key)
      return :leave if connection.nil?

      menu.restore
      menu.clear
      out.puts local_disconnect_warning(connection)
      return nil unless menu.confirm("Remove the LOCAL connection for #{workspace_key} " \
                                     "(#{ConnectionView.repository_label(connection)})?")

      remove_credential = ask_about_credential(workspace_key)
      report(operations.disconnect_local(workspace_key, remove_credential: remove_credential))
      menu.pause
      :leave
    end

    def local_disconnect_warning(connection)
      "This will remove only THIS MACHINE's memory of #{connection.workspace_key}.\n" \
        "It will NOT remove Platform-side authorization: Platform will still list this runner " \
        "as connected to that workspace.\nUse 'Disconnect from Platform' for that."
    end

    # Asked only when the credential really would be left with nothing depending on it. The
    # credential is scoped to the RUNNER, not the workspace, so removing it while another local
    # connection still uses it would break a working connection as a side effect of tidying up
    # an unrelated one.
    def ask_about_credential(workspace_key)
      return false unless operations.credential_orphaned_by?(workspace_key)

      out.puts ""
      out.puts "After this, no local connection will use runner credential " \
               "#{operations.credential_account_for(workspace_key)}."
      out.puts "Keeping it is safe and lets a later `connect` reuse it."
      menu.confirm("Also remove that credential from the macOS Keychain?")
    end

    # --- Platform disconnect -------------------------------------------------

    # Platform first, local second, and only after Platform CONFIRMS. Deleting local state after
    # a failed Platform call would leave a machine holding authorization it can no longer see or
    # manage from here.
    def disconnect_platform(workspace_key)
      connection = operations.connection_for(workspace_key)
      return :leave if connection.nil?

      menu.restore
      menu.clear
      out.puts platform_disconnect_warning(connection)
      return nil unless menu.confirm("Ask Platform to remove this runner's grant for #{workspace_key}?")

      outcome = operations.disconnect_platform(workspace_key)
      report(outcome)
      outcome.ok? ? offer_local_removal(workspace_key) : keep_local_after_failure
    end

    def platform_disconnect_warning(connection)
      "This will ask Platform to remove THIS runner's grant for #{connection.workspace_key} " \
        "(#{ConnectionView.repository_label(connection)}).\n" \
        "Your runner identity, its credential, and every other connected workspace are " \
        "unaffected.\nNo project, workspace, Jira connection, run, execution report, or branch " \
        "is deleted."
    end

    def offer_local_removal(workspace_key)
      out.puts ""
      unless menu.confirm("Platform confirmed. Also remove this machine's local entry for #{workspace_key}?")
        return keep_local_entry
      end

      remove_credential = ask_about_credential(workspace_key)
      report(operations.disconnect_local(workspace_key, remove_credential: remove_credential))
      menu.pause
      :leave
    end

    def keep_local_entry
      out.puts "Kept the local entry. `specrelay-runner connections disconnect-local` removes it later."
      menu.pause
      nil
    end

    def keep_local_after_failure
      out.puts ""
      out.puts "Nothing local was changed, because Platform did not confirm the disconnect."
      menu.pause
      nil
    end

    def report(outcome)
      out.puts outcome.message
      out.puts(outcome.ok? ? "Next: #{outcome.remedy}" : "Remedy: #{outcome.remedy}") if outcome.remedy
      nil
    end
  end
end
