# frozen_string_literal: true

module SpecrelayRunner
  # The ONE rule for turning a provider's public bytes into text an operator may see, for a lane
  # that HAS an approved root.
  #
  # It owns three things and nothing else: the local-path projection against that root, the call
  # into {Redaction}, and the per-block bounds. It owns them once because two decoders now need
  # the same answer — the two supported real providers emit different events, but "may this path
  # be shown, and how much of this block" is not a provider question. A second copy would be a
  # second privacy policy, and the one that drifted would be the one nobody tested.
  #
  # {PrivatePaths} remains the separate rule for a lane with NO approved root, which can prove
  # nothing about a path and therefore withholds every absolute one. {Redaction} remains the one
  # owner of secret SHAPES; it is called here, never reimplemented.
  #
  # Pure and stateless apart from the root it is constructed with. It performs no I/O and decides
  # on TEXT: a live transcript names files that do not exist yet, and the public question is about
  # the path text, not about filesystem authorization.
  class PublicProgress
    # ONE block — a file's contents, a command's output — may spend this much of the operator's
    # attention. ExecutorLogStream bounds the whole stream and says so; this stops a single large
    # read from spending that whole budget before anything else is seen. Both notices are
    # truthful; neither truncation is silent.
    MAX_BLOCK_LINES = 40
    MAX_LINE_CHARS = 500

    # What an absolute path this class cannot prove is in-root renders as. One stable token across
    # users, hosts, runs, lanes and path categories: keeping even a basename would still disclose
    # a private project, customer or temporary-file name.
    LOCAL_PATH = "[LOCAL_PATH]"

    # Deliberately NOT a filename-character list. Every such list has a next unenumerated
    # character: a space, a Unicode letter, then `:`, `=`, `,`, `()`, `[]`, `{}`, `*` and `?` —
    # all legal in a POSIX segment, and each one a scanner treats as a terminator publishes
    # whatever followed it. Recognizing LESS of a path is the fail-open direction, so the boundary
    # is stated ONCE and in the safe direction. A quoted token ends at its quote. A bare token
    # continues across ambiguous whitespace until a strong shell control or the line end, with a
    # following explicit `/...` left for the next independent scan. Everything swallowed is
    # withheld unless the complete candidate is provably in-root; only {WRAPPER} punctuation is
    # handed back.
    #
    # A token also ends at an UNESCAPED shell control. `;`, `&`, `|`, `<` and `>` are operators in
    # shell grammar with or without surrounding spaces, so `a.rb;echo` is two tokens; treating
    # them as path text swallowed the operator, the command after it, and a second path in a
    # redirection. This is a short fixed operator set, not a list of legal filename characters —
    # an escaped control (`\;`) is still path text.
    PATH_CHAR = %r{(?:\\.|[^\s'"\\;&|<>/])}
    # Assistant narration is not shell-quoted, so whitespace does NOT prove a path ended. Once a
    # bare absolute token is followed by ordinary text, no character rule can tell whether that
    # text is a multiword pathname or prose. Withhold through the next strong shell boundary (or
    # the line end) instead of guessing. A second explicit absolute span remains independently
    # recognizable because `/` cannot continue this whitespace branch.
    PATH_SPAN = %r{
      /(?:/|#{PATH_CHAR.source})+                       # the unambiguous absolute-token prefix
      (?:[ \t]+(?!/)[^'"\\;&|<>\n]*)?                # ambiguous narration: fail closed
    }x
    WRAPPER = %r{[)\]\}>.,;:!?'"`]+\z}
    # The lookbehind decides where a token may START, and fails safe in the other direction: a `/`
    # that CONTINUES something is not an absolute path. That leaves relative paths (`spec/models`),
    # git refs (`origin/main`), dates, Unicode segments, closing tags (`</h1>`), a URL's own path,
    # a separator after a closing wrapper (`Acme(Client)/report.md`) and a shell expansion
    # (`${HOME}/x`) alone. Requiring one character after the separator leaves prose
    # (`input / output`) alone. Windows syntax is deliberately not parsed.
    PATH_START = %r{(?<![[:word:].~/<)\]\}])}
    PATH_SCAN = %r{
      (?<q>['"])(?<quoted>(?:file://[^\s'"/]*)?/[^'"\n]*)\k<q>   # quoted: a literal space is path
      | (?<file>file://[^\s'"/]*#{PATH_SPAN.source})             # a local path wearing a scheme
      | (?<url>[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>]*)            # any other scheme: the network
      | (?<path>#{PATH_START.source}#{PATH_SPAN.source})         # a bare absolute POSIX token
    }x
    private_constant :PATH_CHAR, :PATH_SPAN, :WRAPPER, :PATH_START, :PATH_SCAN

    # `repository_path` is the assigned worktree, or nil for a lane that has none. It is the ONE
    # approved root: the only filesystem location this boundary can prove a path belongs to, and
    # therefore the only prefix a public path may be shown relative to.
    def initialize(repository_path: nil)
      @repository_path = repository_path && File.expand_path(repository_path.to_s)
    end

    # One public block as displayable lines. The order matters: path policy runs first, then
    # {Redaction} over the still-whole block, and only then does anything split or clip — a
    # sensitive span removed before both bounds cannot survive as a retained prefix or suffix on
    # the terminal, in the report's live-log evidence, or in a Platform chunk.
    def bounded(value)
      # The multiline private-key rule can only fire while the block is still whole, and this
      # method is where a block stops being whole. Redaction stays the ONE owner of credential
      # patterns; it is called before the split rather than only after it, and ExecutorLogStream
      # still redacts every line on its own way out ([REDACTED] is idempotent).
      text = redact(value)
      return [] if text.empty?

      lines = text.split("\n", -1)
      lines.pop while lines.last == ""
      return lines.map { |line| clip_line(line) } if lines.length <= MAX_BLOCK_LINES

      lines.first(MAX_BLOCK_LINES).map { |line| clip_line(line) } <<
        "[... #{lines.length - MAX_BLOCK_LINES} more lines]"
    end

    def indent(*values)
      values.flatten.flat_map { |value| value.is_a?(String) ? bounded(value) : [] }
            .map { |line| "  #{line}" }
    end

    def redact(value) = Redaction.redact(sanitize_paths(value.to_s))

    def clip_line(line)
      line.length > MAX_LINE_CHARS ? "#{line[0, MAX_LINE_CHARS]}[... clipped]" : line
    end

    private

    attr_reader :repository_path

    def sanitize_paths(text)
      return text unless text.include?("/")

      text.gsub(PATH_SCAN) do
        match = Regexp.last_match
        next match[:url] if match[:url]
        # The quote DELIMITS the span, so it stays outside the replacement while the complete
        # quoted path, spaces included, goes through the one projection.
        next "#{match[:q]}#{project(match[:quoted])}#{match[:q]}" if match[:quoted]

        span = match[:file] || match[:path]
        trailing_space = span[/[ \t]+\z/].to_s
        project(span.delete_suffix(trailing_space)) + trailing_space
      end
    end

    # Containment must be PROVEN lexically, never assumed: a traversal segment, a prefix collision
    # (`/repo` against `/repo-copy`), and a lane with no approved root all fail to the placeholder
    # rather than to the original span. Nothing here touches the filesystem, so no symlink is
    # resolved and no existence is required. Containment is decided from the UNSTRIPPED candidate,
    # and nothing is peeled first: wrapper recovery is PRESENTATION, and letting it run earlier is
    # what allowed `<root>.` and `<root>!` — outside siblings — to become the approved root itself.
    def project(span)
      path = span.start_with?("file://") ? file_url_path(span) : span
      return withheld(span) if path.nil? || traversal?(path) || repository_path.nil?
      return "." if path == repository_path
      return withheld(span) unless path.start_with?("#{repository_path}/")

      relative = path.delete_prefix("#{repository_path}/")
      # An in-root PREFIX must not carry an outside path out with it: a token that still holds an
      # absolute start is not ONE provable in-root path, so it is withheld rather than published.
      return withheld(span) if relative.match?(PATH_SCAN)

      # A proven in-root span needs no peeling: its trailing punctuation is already outside the
      # root prefix, so it survives in the relative form untouched.
      relative.empty? ? "." : relative
    end

    # The ONLY thing handed back from a withheld token. These characters wrap or end a path in
    # prose and in shell text; none of them can be path material on its own, so at worst a name
    # that really ended in one renders a stray delimiter beside the placeholder.
    def withheld(span) = LOCAL_PATH + span[WRAPPER].to_s

    def traversal?(path) = path.split("/").any? { |segment| segment == "." || segment == ".." }

    # A `file://` authority names a HOST. An empty one and `localhost` are THIS machine, so their
    # path can be tested against the approved root like any other. Any other authority describes a
    # filesystem this runner has no root for, so membership is unprovable by definition and `nil`
    # sends it to the placeholder.
    def file_url_path(span)
      authority, _, rest = span.delete_prefix("file://").partition("/")
      return nil unless authority.empty? || authority == "localhost"

      "/#{rest}"
    end
  end
end
