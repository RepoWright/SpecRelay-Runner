# frozen_string_literal: true

module SpecrelayRunner
  # `specrelay-runner connections <subcommand>` — the scriptable equivalent of every
  # dashboard action (MVP-0021 scope 7).
  #
  # The dashboard is the normal experience, but a normal experience that is the ONLY way to
  # do something is a trap: it cannot be run from a script, over ssh without a terminal, in
  # CI, or in a support transcript an operator pastes into a ticket. So every material action
  # has a direct command, all of them work without a TTY, and none of them prompt.
  #
  # This class is presentation only. It parses argv, calls ONE ConnectionOperations method,
  # prints the Outcome, and maps it to an exit code — the same object the dashboard drives, so
  # the two cannot disagree about what "disconnect locally" means.
  #
  # Exit codes are a contract a script can rely on:
  #
  #   0  the operation succeeded
  #   1  an expected operation failure — Platform rejected it, a readiness check failed
  #   2  usage, or local state that could not be used
  #
  # The distinction matters for automation: 1 means "the answer is no", 2 means "the question
  # was wrong". A wrapper script retries neither, but it reports them differently.
  class ConnectionsCommand
    SUBCOMMANDS = %w[list show test default clear-default disconnect-local disconnect-platform
                     forget-legacy-credential].freeze

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(args:, out:, err:, operations:)
      @args = Array(args)
      @out = out
      @err = err
      @operations = operations
    end

    def call
      subcommand, *rest = args
      case subcommand
      when "list" then list
      when "show" then show(rest.first)
      when "test" then report(operations.test(rest.first))
      when "default" then report(operations.set_default(rest.first))
      when "clear-default" then report(operations.clear_default)
      when "disconnect-local" then disconnect_local(rest)
      when "disconnect-platform" then report(operations.disconnect_platform(rest.first))
      when "forget-legacy-credential" then report(operations.forget_legacy_credential(rest.first))
      else usage(subcommand)
      end
    end

    private

    attr_reader :args, :out, :err, :operations

    # Machine-readable enough to grep and human-readable enough to read: one line per
    # connection, the default marked, and the local state file named so an operator who does
    # want to look at it knows where it is without being told to edit it.
    def list
      listing = operations.listing
      return unreadable(listing) unless listing.readable?
      return empty_state(listing) if listing.empty?

      out.puts "Connected workspaces (#{listing.connections.length}) — #{listing.path}"
      listing.connections.each do |connection|
        marker = listing.default?(connection) ? "*" : " "
        out.puts " #{marker} #{ConnectionView.summary_line(connection)}"
        # The COMPLETE selector, on its own line and never clipped: this is the string an
        # operator copies into `--workspace`, and a truncated one names nothing. It is the only
        # place the full identity appears, because the row above it is what they read.
        out.puts "     #{ConnectionStore.selector_for(connection)}"
      end
      out.puts ""
      out.puts default_line(listing)
      CLI::SUCCESS
    end

    def default_line(listing)
      if listing.default_selector.nil?
        "Default workspace: none set. `loop` and `claim-once` need --workspace when several " \
          "are connected."
      elsif listing.default_missing?
        "Default workspace: #{listing.default_selector} — NOT RESOLVABLE. `loop` and " \
          "`claim-once` will fail closed until you set another or clear it."
      else
        "Default workspace: #{listing.default_selector} (marked *)."
      end
    end

    def show(selector)
      return usage_error("usage: specrelay-runner connections show <selector>") if selector.to_s.strip.empty?

      listing = operations.listing
      connection = operations.connection_for(selector.to_s)
      return report(unknown(selector)) if connection.nil?

      rows = ConnectionView.detail_rows(connection, default: listing.default?(connection))
      width = rows.map { |label, _| label.length }.max
      rows.each { |label, value| out.puts "#{label.ljust(width)}  #{value}" }
      out.puts "#{'Selector'.ljust(width)}  #{ConnectionStore.selector_for(connection)}"
      CLI::SUCCESS
    end

    # The credential decision is a FLAG, never a prompt: this command must work in a script,
    # and a prompt is how a scripted cleanup silently hangs. Without the flag the credential is
    # kept and the outcome says how to remove it — the safe default.
    def disconnect_local(rest)
      selector = rest.find { |arg| !arg.start_with?("-") }
      unknown_flag = rest.find { |arg| arg.start_with?("-") && arg != "--remove-credential" }
      return usage_error("unknown option for disconnect-local: #{unknown_flag}") if unknown_flag

      report(operations.disconnect_local(selector,
                                        remove_credential: rest.include?("--remove-credential")))
    end

    # One outcome, printed the same way every time: the sentence on stdout, the remedy on
    # stderr when the operation did not succeed (so a script's stdout stays the result), and
    # the exit code from `ok?`/`invalid?`.
    def report(outcome)
      if outcome.ok?
        out.puts outcome.message
        out.puts "Next: #{outcome.remedy}" if outcome.remedy
        return CLI::SUCCESS
      end

      out.flush if out.respond_to?(:flush)
      err.puts outcome.message
      err.puts "Remedy: #{outcome.remedy}" if outcome.remedy
      outcome.invalid? ? CLI::USAGE_ERROR : CLI::RUN_FAILED
    end

    def unknown(selector)
      ConnectionOperations::Outcome.new(
        ok: false, invalid: true,
        message: "'#{selector}' does not name exactly one local connection.",
        remedy: "run `specrelay-runner connections list` to see what this machine is connected to"
      )
    end

    def empty_state(listing)
      out.puts "This machine is not connected to any workspace."
      out.puts "Connect one: specrelay-runner connect <enrollment-code>"
      out.puts "Get the code from your project's setup page in Platform (\"Connect a Runner\")."
      out.puts "Local state file (created on first connect): #{listing.path}"
      # A dangling default survives every connection being removed, and it is what will make the
      # next `loop` fail closed. Reporting it here is the difference between an operator seeing
      # the cause and hitting it later with no idea where it came from.
      out.puts default_line(listing) if listing.default_missing?
      CLI::SUCCESS
    end

    def unreadable(listing)
      err.puts "the local runner state file #{listing.path} exists but could not be read as " \
               "SpecRelay connection state."
      err.puts "Remedy: move it aside and reconnect: `specrelay-runner connect <enrollment-code>`"
      CLI::USAGE_ERROR
    end

    def usage_error(message)
      err.puts message
      CLI::USAGE_ERROR
    end

    def usage(subcommand)
      err.puts(subcommand.nil? ? "specrelay-runner connections needs a subcommand" : "unknown connections subcommand: #{subcommand}")
      err.puts "Usage: specrelay-runner connections list"
      err.puts "       specrelay-runner connections show <selector>"
      err.puts "       specrelay-runner connections test <selector>"
      err.puts "       specrelay-runner connections default <selector>"
      err.puts "       specrelay-runner connections clear-default"
      err.puts "       specrelay-runner connections disconnect-local <selector> [--remove-credential]"
      err.puts "       specrelay-runner connections disconnect-platform <selector>"
      err.puts "       specrelay-runner connections forget-legacy-credential <workspace-key>"
      CLI::USAGE_ERROR
    end
  end
end
