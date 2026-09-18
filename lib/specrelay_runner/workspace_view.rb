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

    # `selector` is the connection's full identity, handed over by the row the operator chose.
    # Every action below re-resolves it, so the view can never act on a different project than
    # the one on screen — including when two projects use the same workspace key.
    def open(selector)
      loop do
        connection = operations.connection_for(selector)
        # It can genuinely be gone — disconnected here a moment ago, or removed from another
        # terminal. Returning to the top level is the honest response, not an error.
        return if connection.nil?

        action = menu.select(title: "#{Dashboard::TITLE} — #{ConnectionView.selection_label(connection)}",
                             header: detail_rows(connection), entries: entries(connection),
                             footer: FOOTER)
        return if action == TerminalMenu::CANCEL || action == :back
        return if perform(selector, action) == :leave
      end
    end

    private

    attr_reader :operations, :dispatch, :out, :menu

    def detail_rows(connection)
      identity = ConnectionStore.selector_for(connection)
      rows = ConnectionView.detail_rows(connection, default: operations.listing.default?(connection),
                                        readiness: @last_readiness[identity])
      label_width = rows.map { |label, _| label.length }.max
      lines = rows.map { |label, value| "  #{label.ljust(label_width)}  #{value}" }
      lines << "  #{'Selector'.ljust(label_width)}  #{identity}"
    end

    # The `D` row's LABEL changes with state rather than the menu offering both a set and a
    # clear action: exactly one of them is ever meaningful, and showing the inapplicable one
    # invites pressing it.
    def entries(connection)
      default = operations.listing.default?(connection)
      [
        entry("L", "Start live loop — poll and execute work for this project", :loop),
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
    def perform(selector, action)
      case action
      when :loop then run_command([ "loop", "--workspace", selector ], acknowledge: false)
      when :claim_once then run_command([ "claim-once", "--workspace", selector ])
      when :test then test(selector)
      when :show then show(selector)
      when :default then toggle_default(selector)
      when :disconnect_local then disconnect_local(selector)
      when :disconnect_platform then disconnect_platform(selector)
      end
    end

    # --- run a real command --------------------------------------------------

    # Cooked mode is re-asserted BEFORE dispatching so the command's own output and its signal
    # handling behave exactly as they do when it is typed directly. The echoed command line is
    # printed for the same reason: an operator should be able to see, copy, and re-run what the
    # menu just did.
    def run_command(argv, acknowledge: true)
      menu.restore
      menu.clear
      out.puts "$ specrelay-runner #{argv.join(' ')}"
      out.puts ""
      status = dispatch.call(argv)
      acknowledge_exit(argv, status, acknowledge)
      nil
    rescue Interrupt
      # Ctrl-C stops the dispatched command and returns here — the same contract `loop`
      # documents for a directly-typed invocation. The dashboard itself is not torn down.
      out.puts ""
      out.puts "Interrupted. Nothing was left claimed by this terminal."
      menu.pause
      nil
    end

    # WHERE Ctrl-C LEAVES YOU is a property of HOW the command was invoked, so it is passed in
    # here rather than inferred from anything mutable (RUNNER-0001 scope 6).
    #
    # A live loop the operator started from THIS menu returns straight back to it when it
    # stopped cleanly: Ctrl-C was the operator asking to come back, and a `Press any key`
    # in between is a keypress they did not ask for. The loop has already printed its own
    # final summary.
    #
    # Everything else keeps the deliberate acknowledgement — a one-shot `claim-once`, and a
    # loop that ended in a failed run or a rejected credential. The next menu frame clears
    # the screen, so without the pause the result would be erased before it could be read.
    def acknowledge_exit(argv, status, acknowledge)
      return nil if !acknowledge && status == CLI::SUCCESS

      out.puts ""
      out.puts "(#{argv.first} exited #{status})"
      menu.pause
      nil
    end

    # --- non-destructive actions ---------------------------------------------

    def test(selector)
      menu.restore
      menu.clear
      out.puts "Testing #{selector} — this claims no work and changes nothing."
      out.puts ""
      outcome = operations.test(selector)
      print_checks(outcome.payload)
      report(outcome)
      remember_readiness(selector, outcome)
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

    # Keyed by the full identity, so a readiness result shown for one project can never be
    # attributed to another that happens to share its workspace key.
    def remember_readiness(selector, outcome)
      connection = operations.connection_for(selector)
      return if connection.nil?

      @last_readiness[ConnectionStore.selector_for(connection)] =
        outcome.ok? ? "ready (tested just now)" : "#{outcome.payload&.outcome} (tested just now)"
    end

    def show(selector)
      connection = operations.connection_for(selector)
      return :leave if connection.nil?

      menu.restore
      menu.clear
      detail_rows(connection).each { |line| out.puts line }
      menu.pause
      nil
    end

    def toggle_default(selector)
      menu.restore
      menu.clear
      connection = operations.connection_for(selector)
      return :leave if connection.nil?

      currently_default = operations.listing.default?(connection)
      report(currently_default ? operations.clear_default : operations.set_default(selector))
      menu.pause
      nil
    end

    # --- local disconnect ----------------------------------------------------

    # Both questions are asked BEFORE anything is removed, so the whole change is one atomic
    # operation the operator has already agreed to in full. The first names the workspace AND
    # the repository, because a workspace key alone is easy to misread when several are
    # connected.
    def disconnect_local(selector)
      connection = operations.connection_for(selector)
      return :leave if connection.nil?

      menu.restore
      menu.clear
      out.puts local_disconnect_warning(connection)
      return nil unless menu.confirm("Remove the LOCAL connection for " \
                                     "#{ConnectionStore.selector_for(connection)} " \
                                     "(#{ConnectionView.repository_label(connection)})?")

      remove_credential = ask_about_credential(selector)
      report(operations.disconnect_local(selector, remove_credential: remove_credential))
      menu.pause
      :leave
    end

    def local_disconnect_warning(connection)
      "This will remove only THIS MACHINE's memory of " \
        "#{ConnectionStore.selector_for(connection)}.\n" \
        "It will NOT remove Platform-side authorization: Platform will still list this runner " \
        "as connected to that workspace.\nUse 'Disconnect from Platform' for that."
    end

    # Asked only when the credential really would be left with nothing depending on it. The
    # credential is scoped to the RUNNER, not the workspace, so removing it while another local
    # connection still uses it would break a working connection as a side effect of tidying up
    # an unrelated one.
    def ask_about_credential(selector)
      return false unless operations.credential_orphaned_by?(selector)

      out.puts ""
      out.puts "After this, no local connection will use runner credential " \
               "#{operations.credential_account_for(selector)}."
      out.puts "Keeping it is safe and lets a later `connect` reuse it."
      menu.confirm("Also remove that credential from the macOS Keychain?")
    end

    # --- Platform disconnect -------------------------------------------------

    # Platform first, local second, and only after Platform CONFIRMS. Deleting local state after
    # a failed Platform call would leave a machine holding authorization it can no longer see or
    # manage from here.
    def disconnect_platform(selector)
      connection = operations.connection_for(selector)
      return :leave if connection.nil?

      menu.restore
      menu.clear
      out.puts platform_disconnect_warning(connection)
      return nil unless menu.confirm("Ask Platform to remove this runner's grant for " \
                                     "#{connection.workspace_key}?")

      outcome = operations.disconnect_platform(selector)
      report(outcome)
      outcome.ok? ? offer_local_removal(selector) : keep_local_after_failure
    end

    def platform_disconnect_warning(connection)
      "This will ask Platform to remove THIS runner's grant for #{connection.workspace_key} " \
        "(#{ConnectionView.repository_label(connection)}).\n" \
        "Your runner identity, its credential, and every other connected workspace are " \
        "unaffected.\nNo project, workspace, Jira connection, run, execution report, or branch " \
        "is deleted."
    end

    def offer_local_removal(selector)
      out.puts ""
      unless menu.confirm("Platform confirmed. Also remove this machine's local entry for #{selector}?")
        return keep_local_entry
      end

      remove_credential = ask_about_credential(selector)
      report(operations.disconnect_local(selector, remove_credential: remove_credential))
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
