# frozen_string_literal: true

module SpecrelayRunner
  # The one rule for "this text names a place on somebody's computer".
  #
  # An absolute local path is private even when it carries no credential: it publishes the
  # operator's username, their home layout, their private temporary directories and where their
  # task worktrees live. {Redaction} deliberately does not touch it — that one owns secret SHAPES,
  # and a path is not a secret — so this is the second, separate rule.
  #
  # It lives here, on its own, because two lanes need the same answer and neither owns it: the
  # specification analyzer summarises a provider's prose, and the preview lane streams a project
  # command's raw output. One rule, one placeholder, one set of shapes; MAPIAI-77's Claude-lane
  # policy is a different thing again — that one RESOLVES paths against an approved root and can
  # therefore render them repository-relative, which is only possible when a root is known.
  #
  # Pure and stateless. It performs no I/O, and it decides on TEXT: nothing it matches has to
  # exist, so its behaviour is identical on a macOS and a Linux host.
  module PrivatePaths
    REDACTION = "[PRIVATE_PATH_REDACTED]"

    # A Windows separator, in the two forms one arrives in: as a project command prints it, and
    # as JSON escapes it. `JSON.generate` doubles every backslash, so the `worktree_path` of a
    # Windows machine reaches this rule as `C:\\Users\\...` — the escaped form has to come first
    # or the single-backslash alternative eats half of it and the match stops (CR-008 F10).
    SEPARATOR = %r{\\\\|[\\/]}

    # Where a private path STARTS. Order matters: the longer, more specific roots come first so
    # that `/private/tmp/x` is replaced whole rather than leaving `/private` stranded in front of
    # the placeholder.
    ROOT = %r{
      file://                              # a file URL, wherever it points
      | (?:/private)?/var/folders/         # macOS per-user temporary directories
      | /private/tmp/                      # and macOS's other private temporary root
      | /(?:Users|home|tmp)/               # POSIX home directories and the shared temporary root
      | [A-Za-z]:#{SEPARATOR}(?i:Users)#{SEPARATOR}   # a Windows drive path through a user profile
    }x

    # The longest byte sequence any alternative above can match (`/private/var/folders/`). A caller
    # that receives a path in pieces needs it to bound how much it has to hold back before it can
    # tell whether a root is forming; `private_paths_test` asserts it against the rule itself.
    LONGEST_ROOT_BYTES = 21

    # Where an UNQUOTED path stops. Whitespace is the obvious terminator, but the preview lane
    # streams `status --json`, whose whole document is one line with no spaces in it at all — so a
    # quote, an angle bracket or a backtick has to end the run too. Without that a path swallowed
    # the remainder of the document, and, worse, one URL swallowed a path.
    RUN = %r{[^\s"'<>`]+}

    # The same run, plus the one unambiguous way a BARE path carries a space: an escaped one.
    # `cd /Users/Jane\ Doe/Secret\ Project` is a single path and has to be removed as a single
    # path (CR-007 F8).
    BARE = %r{(?:\\[ ]|[^\s"'<>`])+}
    PATTERN = /#{ROOT}#{BARE}/

    # A QUOTED path ends where its quote does. Project output legitimately quotes paths with
    # spaces in them — `"worktree_path":"/Users/Jane Doe/My Project"` is what `status --json`
    # prints on such a machine — and stopping at the first space removed the username while
    # leaving the directory and file names standing, which reads as a redaction and is not one.
    #
    # The opening quote must be immediately followed by a ROOT, so a quoted URL, a quoted sentence
    # or a JSON key never matches and nothing after the value is consumed. The quotes themselves
    # are kept: they are the value's terminator, and a JSON document has to stay one. Only the
    # SAME quote ends the value — an apostrophe inside a double-quoted path is path content.
    QUOTED = /(?<quote>["'])#{ROOT}(?:(?!\k<quote>)[^\n])*\k<quote>/

    # An http(s) URL is protected from the patterns above while they are applied, so a service
    # link, a pull-request URL or a documentation link whose OWN path happens to contain `Users`
    # or `home` comes back byte for byte. A `file://` URL is not a network destination and is not
    # protected — it is exactly the thing being removed.
    URL_TAG = "SPECRELAY_URL_PLACEHOLDER"
    URL_PATTERN = /#{URL_TAG}_(\d+)_/
    SAFE_URL = %r{https?://#{RUN}}

    # A private path can be longer than one piece of the output a reader hands over. These two
    # describe one that runs off the END of a piece, so a caller streaming fragments can tell
    # "a path was cut here" from "a long token was cut here" — a distinction the caller cannot
    # make for itself without owning a second copy of this grammar (CR-008 F9).
    #
    # Both runs are atomic: a path's run is maximal by definition, so if the greedy run does not
    # reach the end then a terminator came first and the path is closed, not open. Making that
    # explicit also keeps the cost linear on an eight-kilobyte fragment.
    OPEN_QUOTED = /(?<quote>["'])(?<path>#{ROOT}(?>(?:(?!\k<quote>)[^\n])*))\z/
    OPEN_BARE = /#{ROOT}(?>#{BARE})?\z/

    # What is left of a cut BARE path at the start of the next piece, up to but not including the
    # terminator that finally ends it.
    BARE_REST = %r{\A(?>(?:\\[ ]|[^\s"'<>`])*)}

    # Sentence punctuation immediately after a bare path is kept OUTSIDE the placeholder: the run
    # above would otherwise swallow the `)` or `,` that ends it, and a redacted line would stop
    # reading as the prose — or the JSON — it is.
    TRAILING = /[)\]}>,;:'".]+\z/

    module_function

    def sanitize(text)
      urls = []
      body = text.to_s.gsub(SAFE_URL) do |url|
        urls << url
        "#{URL_TAG}_#{urls.length - 1}_"
      end
      body = body.gsub(QUOTED) { |match| quoted_value(match) }.gsub(PATTERN) { |match| bare_path(match) }
      body.gsub(URL_PATTERN) { urls[Regexp.last_match(1).to_i] }
    end

    # The quotes are the value's own terminator and they stay: without them a JSON document
    # stops being one. The match begins with the opening quote, and the pattern's backreference
    # guarantees it is also the closing one.
    def quoted_value(match) = "#{match[0]}#{REDACTION}#{match[0]}"

    def bare_path(match)
      core = match.sub(TRAILING, "")
      "#{REDACTION}#{match[core.length..]}"
    end

    # Nil when `text` does not end inside a private path. Otherwise the path's own text — what the
    # caller must replace — and the pattern matching its remainder in the piece that follows.
    def open_path(text)
      if (match = OPEN_QUOTED.match(text))
        return [ match[:path], /\A(?>(?:(?!#{Regexp.escape(match[:quote])})[^\n])*)/ ]
      end

      match = OPEN_BARE.match(text)
      match && [ match[0], BARE_REST ]
    end

    # True when `text`, once its placeholders are set aside, still says something. A summary whose
    # entire content was a path is not evidence — it is the placeholder wearing a costume.
    def meaningful?(text) = text.to_s.gsub(REDACTION, "").match?(/[[:alnum:]]/)
  end
end
