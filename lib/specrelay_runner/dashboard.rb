# frozen_string_literal: true

module SpecrelayRunner
  # The interactive runner control center (MVP-0021 scope 1) — the top level.
  #
  # `specrelay-runner` with no arguments, in a real terminal, opens this. It exists because
  # the honest refusal a multi-workspace machine used to get —
  #
  #   several workspaces are connected (a, b); choose one with --workspace <workspace-key>
  #
  # — was correct and still left the operator to work out where `connections.json` lives,
  # which workspace key means what, which stale entry is safe to delete, whether the stored
  # credential is still valid, and which command to run next. Refusing to guess was right.
  # Making the operator do state surgery to recover was not.
  #
  # It is a PRESENTATION LAYER AND NOTHING ELSE, which is the property that makes it safe:
  # every fact comes from ConnectionOperations / ConnectionView, and every action calls ONE
  # ConnectionOperations method — the same one the equivalent `specrelay-runner connections …`
  # command calls. See WorkspaceView for the per-workspace half.
  #
  # It never guesses a workspace: opening one is an explicit selection and setting a default is
  # an explicit action, so the MVP-0017 rule that a runner must not infer which workspace to
  # claim for is preserved exactly.
  class Dashboard
    TITLE = "SpecRelay Runner — local control center"
    FOOTER = "1–9 open · C clear default · H help · Q quit · ↑/↓ then Enter · Esc/Ctrl-C quits"

    def self.call(**kwargs) = new(**kwargs).call

    # `dispatch` is the CLI's own argv dispatcher, injected rather than reimplemented: it is
    # what makes "the menu reuses the direct command path" a structural fact.
    def initialize(operations:, dispatch:, out: $stdout, err: $stderr, input: $stdin, menu: nil)
      @operations = operations
      @out = out
      @err = err
      @menu = menu || TerminalMenu.new(input: input, out: out)
      @workspace_view = WorkspaceView.new(operations: operations, dispatch: dispatch, out: out,
                                         menu: @menu)
    end

    def call
      loop do
        choice = menu.select(title: TITLE, header: header, entries: entries, footer: FOOTER)
        return quit if choice == TerminalMenu::CANCEL || choice == :quit

        case choice
        when :help then show_help
        when :clear_default then clear_default
        else workspace_view.open(choice)
        end
      end
    end

    private

    attr_reader :operations, :out, :err, :menu, :workspace_view

    def quit
      menu.restore
      menu.clear
      CLI::SUCCESS
    end

    # The listing is re-read on every frame, so a disconnect here, a `connect` in another
    # terminal, or an operator's edit is reflected the next time the menu is drawn. A dashboard
    # showing state that is no longer true is worse than no dashboard.
    def header
      listing = operations.listing
      return unreadable_header(listing) unless listing.readable?
      return empty_header(listing) if listing.empty?

      count = listing.connections.length
      [ "#{count} connected workspace#{'s' unless count == 1}", default_header(listing) ]
    end

    def default_header(listing)
      if listing.default_workspace_key.nil?
        "Default workspace: none set — `loop` needs --workspace while several are connected"
      elsif listing.default_missing?
        "Default workspace: #{listing.default_workspace_key} — SET BUT NOT CONNECTED; " \
          "`loop` fails closed until you set another or clear it"
      else
        "Default workspace: #{listing.default_workspace_key}"
      end
    end

    # The empty state names the ONE command that fixes it and where the code comes from. An
    # empty dashboard that only said "no connections" would send the operator to the docs.
    def empty_header(_listing)
      [ "This machine is not connected to any workspace yet.",
        "Run:  specrelay-runner connect <enrollment-code>",
        "Get the code from your project's setup page in Platform (\"Connect a Runner\")." ]
    end

    def unreadable_header(listing)
      [ "The local runner state file could not be read as SpecRelay connection state:",
        "  #{listing.path}",
        "Move it aside, then run `specrelay-runner connect <enrollment-code>` again." ]
    end

    # Workspaces get 1–9. A machine with more than nine connected workspaces is not a case this
    # MVP designs for; the tenth onward stay reachable with the arrow keys, so nothing is hidden.
    #
    # No absolute local path appears on this screen — see ConnectionView for why the detail view
    # is the right place for it.
    def entries
      listing = operations.listing
      rows = listing.connections.each_with_index.map do |connection, index|
        TerminalMenu::Entry.new(
          shortcut: (index + 1).to_s, value: connection.workspace_key,
          label: ConnectionView.summary_line(connection, default: listing.default?(connection),
                                             width: menu.width - 8)
        )
      end
      rows.concat(global_entries(listing))
    end

    def global_entries(listing)
      rows = []
      if listing.default_workspace_key
        rows << TerminalMenu::Entry.new(shortcut: "C", label: "Clear the default workspace",
                                       value: :clear_default)
      end
      rows << TerminalMenu::Entry.new(shortcut: "H", label: "How this works", value: :help)
      rows << TerminalMenu::Entry.new(shortcut: "Q", label: "Quit", value: :quit)
    end

    def clear_default
      menu.restore
      menu.clear
      outcome = operations.clear_default
      out.puts outcome.message
      out.puts "Remedy: #{outcome.remedy}" if !outcome.ok? && outcome.remedy
      menu.pause
    end

    def show_help
      menu.restore
      menu.clear
      out.puts HELP
      menu.pause
    end

    HELP = <<~HELP
      SpecRelay Runner — local control center

      This dashboard manages the workspaces THIS MACHINE is connected to. It is a presentation
      layer over commands you can also run directly, so everything here is scriptable:

        specrelay-runner connections list
        specrelay-runner connections show <workspace-key>
        specrelay-runner connections test <workspace-key>
        specrelay-runner connections default <workspace-key>
        specrelay-runner connections clear-default
        specrelay-runner connections disconnect-local <workspace-key> [--remove-credential]
        specrelay-runner connections disconnect-platform <workspace-key>

      Two disconnects, two different meanings:

        Disconnect locally        Removes this machine's stored connection. Platform STILL
                                  authorizes this runner for that workspace — local deletion
                                  revokes nothing.
        Disconnect from Platform  Asks Platform to remove THIS runner's grant for THIS one
                                  workspace. Your runner identity, your credential, and every
                                  other connected workspace are untouched. It never revokes the
                                  runner itself.

      Default workspace: with several workspaces connected, `loop` and `claim-once` refuse to
      guess. Setting a default is an explicit choice that lets them run with no --workspace, and
      they print that the default was used. A default that no longer resolves fails closed — it
      never falls through to another workspace.

      Test connection and readiness claims no work at all: it checks the local entry, the stored
      credential, Platform's answer, the workspace grant, the repository, and the executor, and
      names one remedy for the first thing that is wrong.

      Secrets: no credential, Jira token, provider token, or raw provider auth output is ever
      printed here. The local state file holds no secret; the runner credential lives in the
      macOS Keychain and is only ever read in order to authenticate.
    HELP
  end
end
