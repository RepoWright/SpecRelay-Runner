# frozen_string_literal: true

require "date"

module SpecrelayRunner
  # The machine's window onto its own local Claude Code installation, and the ONLY one the
  # Status Reporter has. It runs two documented commands plus a version probe through argv
  # arrays under a short timeout, and returns a handful of parsed values.
  #
  # THE PARSERS ARE CLOSED ON PURPOSE, and that is the whole safety argument. Both commands
  # print material that must never leave this host — an account email, an organisation, a cost
  # panel, a model breakdown, an MCP server's command line, its environment and its URL — and
  # the only protection against carrying one is a parser that recognises the documented shape
  # and NOTHING else. So every method here returns either the exact documented fields or nil.
  # There is no partial result, no repair, no "best effort", and no path on which raw output
  # is stored, returned, logged or interpolated into a message.
  #
  # A refusal is also never an estimate. An unrecognised, localised, duplicated, reordered,
  # out-of-range or absent value means this machine measured nothing, and nil says exactly
  # that. A number inferred from anything else would be a fact the provider never reported.
  #
  # `command` is the one seam: it takes an argv array and returns a CommandRunner::Result, or
  # nil when the executable could not be launched at all. Tests drive it with fixtures, so no
  # automated run ever invokes a real authenticated command or reads a real account.
  class ClaudeStatusReader
    EXECUTABLE = "claude"

    # The three documented invocations, as frozen argv arrays. An array rather than a string
    # is what makes a shell structurally impossible here, not merely avoided.
    USAGE_ARGV = [ EXECUTABLE, "-p", "/usage" ].freeze
    MCP_ARGV = [ EXECUTABLE, "mcp", "list" ].freeze
    VERSION_ARGV = [ EXECUTABLE, "--version" ].freeze

    # Bounded so a hung CLI can never hold a reporting cycle open. These are local metadata
    # reads with no inference behind them, so a few seconds is already generous.
    TIMEOUT_SECONDS = 20

    # The two windows this product reports, keyed by the EXACT English heading that identifies
    # each. Matching on the heading rather than on block order is what stops a reordered result
    # from swapping the two numbers, and what keeps the model-specific blocks — which carry an
    # identical percentage and reset shape — out of the answer entirely.
    WINDOW_HEADINGS = { "Current session" => "five_hour",
                        "Current week (all models)" => "weekly_all_models" }.freeze

    # Exactly one of each per block, or the block is not the documented shape.
    USAGE_PERCENT = /(\d{1,3})%\s+used/
    USAGE_RESET = /^\s*Resets\s+(.+?)\s*$/

    # The reset instants the documented output is allowed to name: a time today, or a weekday
    # and a time. Anything else is unparseable, which makes the whole capacity unavailable.
    RESET_TIME = /\A(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\z/i
    RESET_WEEKDAY_TIME = /\A(#{Date::ABBR_DAYNAMES.join('|')})\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\z/i

    # `name: <command or url> - <health>`. The middle group is captured only so it can be
    # DISCARDED: it is the server's command line or URL, and it is the single most sensitive
    # thing either command prints.
    MCP_ENTRY = /\A(\S+?):\s+(?:.*?)\s+-\s+(.+?)\s*\z/
    # A server name is an identifier, never prose. An entry whose name is not one is dropped
    # rather than cleaned up.
    MCP_NAME = /\A[A-Za-z0-9._-]{1,64}\z/
    # Bounded so a runaway inventory cannot grow the snapshot without limit.
    MCP_MAX_SERVERS = 50

    # The closed health vocabulary, matched against the documented status phrases. `unknown` is
    # the answer for a phrase this reader has no word for — the server IS configured, so
    # dropping it would understate the inventory, and carrying the phrase itself would defeat
    # the point of having a vocabulary.
    HEALTHY = "healthy"
    FAILED = "failed"
    PENDING_APPROVAL = "pending_approval"
    DISABLED = "disabled"
    UNKNOWN = "unknown"
    MCP_HEALTH = [
      [ /disabled/i, DISABLED ],
      [ /needs\s+auth|authenticat|pending\s+approval|not\s+approved/i, PENDING_APPROVAL ],
      [ /fail|error|could\s+not\s+connect|unavailable|✗|✘/i, FAILED ],
      [ /connected|healthy|✓|✔/i, HEALTHY ]
    ].freeze

    READY = "ready"
    UNAVAILABLE = "unavailable"
    # `claude --version` leads with the bare version. Only that is kept; the build description
    # after it is the CLI's prose.
    VERSION = /\A(\d+\.\d+\.\d+)/

    # ANSI colour and cursor sequences, stripped before anything is matched. The CLI renders
    # this output for a terminal, so the documented words arrive wrapped in escapes.
    ANSI = /\e\[[0-9;?]*[ -\/]*[@-~]/

    # The default launcher, mirroring ClaudeProfile's probe: the executable is resolved through
    # the runner's EFFECTIVE PATH rather than a global, so status reads the same installation
    # the executor will later launch.
    def self.default_command(env: ENV)
      path = env["PATH"].to_s
      lambda do |argv|
        CommandRunner.run(argv, chdir: Dir.pwd, env: { "PATH" => path },
                                timeout_seconds: TIMEOUT_SECONDS)
      rescue SystemCallError
        nil
      end
    end

    def initialize(command: self.class.default_command)
      @command = command
    end

    # The two documented capacity windows, or nil. `now` resolves a reset's wall-clock text to
    # an instant; it is supplied rather than read so the resolution is deterministic.
    def capacity(now:)
      text = output_of(USAGE_ARGV)
      return nil if text.nil?

      lines = text.lines.map { |line| line.rstrip }
      return nil unless documented_order?(lines)

      windows = WINDOW_HEADINGS.to_h { |heading, key| [ key, window_in(lines, heading, now) ] }
      return nil if windows.value?(nil)

      { "state" => "available", "windows" => windows }
    end

    # The configured MCP servers as name/health pairs, or nil when the command gave nothing
    # this reader recognises. An empty inventory is a real answer and stays an empty list.
    def mcp_servers(now:)
      text = output_of(MCP_ARGV)
      return nil if text.nil?

      entries = text.lines.filter_map { |line| mcp_entry(line) }
      entries.empty? ? nil : entries.first(MCP_MAX_SERVERS)
    end

    # Whether the local CLI answers at all, and which version it reports. Nothing else: the
    # rest of that output, and everything `claude auth status` would add, is account material.
    def readiness(now:)
      version = output_of(VERSION_ARGV).to_s[VERSION, 1]
      version.nil? ? { "state" => UNAVAILABLE } : { "state" => READY, "cli_version" => version }
    end

    private

    attr_reader :command

    # The command's stdout, or nil for every way it can fail to produce one. A timeout, a
    # nonzero exit and an absent executable are the same answer here — this machine measured
    # nothing — and none of them carries stderr anywhere.
    def output_of(argv)
      result = command.call(argv)
      return nil if result.nil? || result.timed_out? || !result.success?

      result.stdout.to_s.gsub(ANSI, "")
    end

    # Both documented headings, each appearing EXACTLY ONCE and in the order the documented
    # output prints them. Order is part of the contract rather than an incidental property: a
    # result whose blocks are not in that order is not the documented output, and reading it
    # anyway would be this reader deciding that something close enough is close enough. It is
    # checked before any value is read, so a reordered result yields no capacity at all rather
    # than one window.
    def documented_order?(lines)
      starts = WINDOW_HEADINGS.keys.map { |heading| sole_heading_index(lines, heading) }
      starts.none?(&:nil?) && starts == starts.sort
    end

    # The line a heading opens, when it appears EXACTLY ONCE. A missing heading has no block, and
    # a duplicated one means the output is not the documented one — choosing either occurrence
    # would be a guess about which the provider meant.
    def sole_heading_index(lines, heading)
      found = lines.each_index.select { |index| lines[index].strip == heading }
      found.length == 1 ? found.first : nil
    end

    # One window, read from the block its own heading opens. The block ends at the next heading
    # of any kind, so a following model-specific section can never lend this one its values.
    def window_in(lines, heading, now)
      block = block_for(lines, heading)
      return nil if block.nil?

      percent = sole_match(block, USAGE_PERCENT)&.to_i
      reset = reset_instant(sole_match(block, USAGE_RESET), now)
      return nil if percent.nil? || reset.nil? || !percent.between?(0, 100)

      { "used_percent" => percent, "resets_at" => reset }
    end

    # The lines under a heading, up to the next heading of any kind.
    def block_for(lines, heading)
      start = sole_heading_index(lines, heading)
      return nil if start.nil?

      following = lines[(start + 1)..] || []
      following.take_while { |line| !heading?(line) }
    end

    def heading?(line) = WINDOW_HEADINGS.key?(line.strip) || line.strip.start_with?("Current ")

    # The captured value when the pattern matches exactly once in the block, else nil. Two
    # percentages or two reset lines mean the block is not the documented shape, and taking
    # the first would be choosing one of two contradictory facts.
    def sole_match(lines, pattern)
      matches = lines.filter_map { |line| line[pattern, 1] }
      matches.length == 1 ? matches.first : nil
    end

    # A reset's wall-clock text as an exact UTC instant: the NEXT occurrence of the time it
    # names, in this machine's own zone. That is normalisation rather than estimation — the
    # provider named a time, and a window's reset is always ahead of the observation.
    def reset_instant(text, now)
      return nil if text.nil?

      parts = reset_parts(text.strip)
      return nil if parts.nil?

      weekday, hour, minute = parts
      return nil unless hour.between?(0, 23) && minute.between?(0, 59)

      next_occurrence(now, weekday, hour, minute)&.utc&.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    # `[weekday or nil, hour, minute]` for the two documented shapes, else nil.
    def reset_parts(text)
      if (match = RESET_WEEKDAY_TIME.match(text))
        [ Date::ABBR_DAYNAMES.index(match[1].capitalize), clock_hour(match[2], match[4]), match[3].to_i ]
      elsif (match = RESET_TIME.match(text))
        [ nil, clock_hour(match[1], match[3]), match[2].to_i ]
      end
    end

    # A 12-hour reading only when the output actually said am/pm; otherwise the hour is already
    # the 24-hour one and must not be shifted.
    def clock_hour(hour, meridiem)
      value = hour.to_i
      return value if meridiem.nil?
      return value % 12 if meridiem.casecmp("am").zero?

      (value % 12) + 12
    end

    # The soonest instant at or after `now` that matches the named weekday and time. Local
    # rather than UTC, because the provider prints the operator's own wall clock.
    def next_occurrence(now, weekday, hour, minute)
      local = now.getlocal
      candidate = Time.new(local.year, local.month, local.day, hour, minute, 0, local.utc_offset)
      candidate += 86_400 while weekday && candidate.wday != weekday
      candidate <= local ? candidate + (weekday ? 604_800 : 86_400) : candidate
    end

    # One inventory line reduced to the two fields that may travel. The command line or URL
    # between them is matched only so the line's shape can be recognised, and is never captured
    # into the result.
    def mcp_entry(line)
      match = MCP_ENTRY.match(line.gsub(ANSI, "").strip)
      return nil if match.nil? || !MCP_NAME.match?(match[1])

      { "name" => match[1], "health" => mcp_health(match[2]) }
    end

    def mcp_health(text)
      MCP_HEALTH.each { |pattern, state| return state if pattern.match?(text) }
      UNKNOWN
    end
  end
end
