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
  # There is no repair, no "best effort", and no path on which raw output is stored, returned,
  # logged or interpolated into a message.
  #
  # Capacity IS reported per window, and that is not a relaxation of the above. Each documented
  # window is recognised by its own exact heading and stands on its own line, so a window this
  # reader cannot resolve is omitted while a window it read perfectly well is still reported.
  # Order carries no meaning — the heading identifies the window, so the two cannot be swapped
  # by printing them the other way round. Only when NO known window survives is there nothing
  # to report at all.
  #
  # A refusal is still never an estimate. An unrecognised, localised, duplicated, out-of-range
  # or absent measurement means this machine measured THAT window not at all, and its absence
  # says exactly that. A number inferred from anything else — from the other window, from a
  # clock, or from the better-formed of two copies — would be a fact the provider never
  # reported.
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
    # each. Matching on the heading rather than on line order is what stops a reordered result
    # from swapping the two numbers, and what keeps every model-specific line — which carries an
    # identical percentage and reset shape — out of the answer entirely.
    WINDOW_HEADINGS = { "Current session" => "five_hour",
                        "Current week (all models)" => "weekly_all_models" }.freeze

    # One measurement, whole, on one line: `<heading>: <n>% used` and, when the provider prints
    # one, `· resets <when>`. Anchored end to end, so a line carrying a second percentage, a
    # second reset, or any trailing material is not this shape at all. There is no sub-scan that
    # could lift one value out of a line this does not match.
    #
    # The reset clause is OPTIONAL because an unused window genuinely has none to print — there
    # is nothing to reset yet. Its absence is part of the documented output, not a damaged line,
    # and the percentage beside it is a measurement like any other.
    MEASUREMENT = /\A(.+?):\s+(\d{1,3})%\s+used(?:\s+·\s+resets\s+(\S.*?))?\z/

    # The heading alone: everything before the first colon, whatever follows it. Used only to
    # count how many times the output names a known window, which is a question about the
    # heading and not about the measurement beside it.
    HEADING = /\A(.+?):/

    # The reset instant the documented output names: a printed month and day, a 12-hour clock
    # time, and the operator's own IANA zone. The month is matched against the known
    # abbreviations rather than any three letters, so `Foo 12` is refused instead of resolved.
    MONTH = Date::ABBR_MONTHNAMES.compact.join("|")
    ZONE = %r{[A-Za-z][A-Za-z0-9+_-]*(?:/[A-Za-z0-9+_-]+)*}
    RESET = /\A(#{MONTH})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?(?i:(am|pm))\s+\((#{ZONE})\)\z/

    # The host's own copy of the tz database, and the only thing that makes a printed zone name
    # real. Setting TZ to a name this host does not know does NOT fail — it silently resolves to
    # UTC — so an unrecognised name would turn a foreign wall clock into a confidently wrong
    # instant. Checked before any time is built, so an unknown zone is a refusal rather than a
    # shifted answer.
    ZONE_DATABASE = "/usr/share/zoneinfo"

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

    # The two documented capacity windows, or nil. `now` resolves each printed date to an exact
    # instant; it is supplied rather than read so the resolution is deterministic.
    def capacity(now:)
      text = output_of(USAGE_ARGV)
      return nil if text.nil?

      lines = text.lines
      # A window the output NAMES twice is not a measurement this reader can resolve: there is no
      # basis for preferring either copy, so every copy goes.
      #
      # Counted over the exact known HEADINGS rather than over the lines that parse, because a
      # repeat whose measurement is malformed still makes the window ambiguous. Counting only
      # the readable copies would let that twin hide: one clean line would look unique, and the
      # reported number would be decided by which copy happened to be well formed.
      duplicated = lines.filter_map { |line| heading(line) }.tally
                        .select { |_, count| count > 1 }.keys
      kept = lines.filter_map { |line| measurement(line) }
                  .reject { |key, _, _| duplicated.include?(key) }

      # Each window stands or falls on its OWN line. A window this reader cannot resolve is
      # dropped alone, because the window beside it was measured perfectly well and hiding it
      # would report an absence the provider never described.
      windows = kept.to_h { |key, percent, reset| [ key, window(percent, reset, now) ] }.compact
      return nil if windows.empty?

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

    # One line reduced to the known window it NAMES, or nil. This reads only the heading, so a
    # line that names a documented window but states its measurement in a shape this reader does
    # not recognise is still counted as naming that window. Exact headings only: a model-specific
    # line names a window this product does not report and is not counted at all.
    def heading(line)
      match = HEADING.match(line.strip)
      match.nil? ? nil : WINDOW_HEADINGS[match[1]]
    end

    # One line reduced to the window it measures, or nil when it is not a measurement this
    # reader reports. A model-specific line — `Current week (Fable): 0% used · …` — is a
    # perfectly well-formed measurement whose heading is simply not in the table, so it is
    # dropped here and can never lend its percentage or its reset to a window that is.
    def measurement(line)
      match = MEASUREMENT.match(line.strip)
      return nil if match.nil?

      key = WINDOW_HEADINGS[match[1]]
      key.nil? ? nil : [ key, match[2].to_i, match[3] ]
    end

    # `0%` is a measurement like any other: the provider reported that nothing has been used,
    # which is a fact about this account and not an absence of one.
    #
    # A reset the provider never PRINTED and one this reader cannot RESOLVE are different facts
    # and get different answers. The first is the documented unused shape, so the percentage is
    # reported with no reset beside it — nil here is the absence itself, never a time inferred
    # from the other window or from this machine's clock. The second is a line whose shape is
    # wrong, and a percentage read off it would be a number from output this reader does not
    # recognise, so the whole window goes.
    def window(percent, reset, now)
      return nil unless percent.between?(0, 100)
      return { "used_percent" => percent, "resets_at" => nil } if reset.nil?

      instant = reset_instant(reset, now)
      instant.nil? ? nil : { "used_percent" => percent, "resets_at" => instant }
    end

    # A reset's printed wall clock as an exact UTC instant, or nil. Every field is checked
    # against what it is allowed to be BEFORE a time is built, because `Time.local` does not
    # refuse an impossible date — it ROLLS IT OVER, turning `Sep 31` into October and `Feb 29`
    # in a common year into March. A rolled-over date is a confidently wrong instant, which is
    # the one answer this reader may never give.
    def reset_instant(text, now)
      match = RESET.match(text.strip)
      return nil if match.nil?

      hour = clock_hour(match[3], match[5])
      minute = match[4].to_i
      zone = match[6]
      return nil if hour.nil? || !minute.between?(0, 59) || !known_zone?(zone)

      next_occurrence(now, zone, Date::ABBR_MONTHNAMES.index(match[1]), match[2].to_i,
                      hour, minute)
    end

    # The printed clock is a 12-hour one and always names its half, so 1..12 is the only reading
    # this parser has. `13pm` is not a late hour to be repaired; it is not the documented shape.
    def clock_hour(hour, meridiem)
      value = hour.to_i
      return nil unless value.between?(1, 12)

      meridiem.casecmp("am").zero? ? value % 12 : (value % 12) + 12
    end

    def known_zone?(name) = File.file?(File.join(ZONE_DATABASE, name))

    # The soonest instant at or after `now` that the printed month and day can name: the
    # observation year, or the one after it once that date has already passed. The provider
    # prints no year, and a window's reset is always ahead of the observation that reported it.
    def next_occurrence(now, zone, month, day, hour, minute)
      [ now.year, now.year + 1 ].each do |year|
        next unless Date.valid_date?(year, month, day)

        instant = in_zone(zone) { Time.local(year, month, day, hour, minute, 0) }
        return instant.getutc.strftime("%Y-%m-%dT%H:%M:%SZ") if instant >= now
      end
      nil
    end

    # The block evaluated with the PRINTED zone in force, with TZ restored however it ends.
    # Ruby's standard library resolves an IANA zone name through this variable and nothing else,
    # and the provider names the operator's zone rather than this machine's — which are only
    # usually the same, so reading the host's would be an assumption rather than a measurement.
    #
    # TZ is process-wide, which is why this is contained around a single construction: no other
    # code in this program builds a time from a local wall clock or reads a zone, so nothing
    # else can observe the swap, and an absolute instant — what everything here reports — does
    # not depend on TZ at all.
    def in_zone(name)
      previous = ENV["TZ"]
      ENV["TZ"] = name
      yield
    ensure
      previous.nil? ? ENV.delete("TZ") : (ENV["TZ"] = previous)
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
