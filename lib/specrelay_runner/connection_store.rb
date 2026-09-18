# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module SpecrelayRunner
  # The runner's own NON-SECRET local connection record (MVP-0017 scope 2 item 6).
  #
  # After a guided connection the runner must be able to claim work with no further
  # input: no YAML to author, no workspace key to type, no environment variable to
  # export. That state lives here, in Runner-owned storage the user never needs to edit:
  #
  #   ~/.specrelay/runner/connections.json
  #
  # It holds ONLY non-secret facts: the Platform base URL, the runner's own public
  # identity, the assigned project/workspace identity, the repository the checkout was
  # validated against, and the LOCAL PATH of that checkout. The local path is stored here
  # and deliberately never sent to Platform — a machine-specific path is the runner's to
  # keep, and Platform must never infer or access it.
  #
  # The durable credential is NOT here. It goes to the OS secret store (SecretStore), so
  # this file stays safe to read, back up, or inspect.
  #
  # Writes are atomic (write-then-rename) so an interrupted `connect` can never leave a
  # truncated file that would make a working runner unusable. The file is created 0600
  # even though it carries no secret, because it names the operator's local paths.
  #
  # MVP-0021 added the operator's EXPLICIT default workspace to this document. Version 2
  # is a superset of version 1 — one optional top-level key — so a file written by an
  # earlier runner loads unchanged and simply has no default. Reading deliberately does
  # not gate on `version` at all: an older document is complete, and a NEWER one written
  # by a later runner must not make this one unusable either. The version is recorded for
  # display and for a future migration that genuinely needs to branch.
  class ConnectionStore
    Error = Class.new(StandardError)

    VERSION = 2
    DEFAULT_RELATIVE_PATH = ".specrelay/runner/connections.json"
    # The top-level key holding the operator's explicit default selection. Non-secret, like
    # everything else in this file. The field name is unchanged, and so is its type: a document
    # written by an earlier runner holds a bare workspace key there and still resolves, because a
    # bare key is one of the ways a connection may be named.
    DEFAULT_KEY_FIELD = "default_workspace_key"

    # A connection's durable identity is the tuple (base_url, project_slug, workspace_key).
    # Platform scopes a workspace key to ONE project, so the key alone is not an identity: two
    # projects may legitimately use the same one, and treating it as unique is what let a second
    # project's record overwrite the first's.
    #
    # The selector renders that tuple as one string an operator can copy:
    #
    #   https://platform.example#beta/tiny-demo-workspace
    #
    # It is a DERIVED LOCAL LABEL and never a stored or transmitted value. Platform still receives
    # the raw workspace key, and nothing here parses a selector back into parts — matching
    # compares a requested string against the selectors generated from the records on disk, so
    # there is no format to keep two implementations of.
    PROJECT_SEPARATOR = "#"
    WORKSPACE_SEPARATOR = "/"
    # What stands in for a project on a record written before the project was stored. Visible and
    # stable, so such a record still has one identity rather than none.
    UNKNOWN_PROJECT = "-"

    # The fields the runner cannot operate without. `build` below already refuses an entry
    # missing a workspace key or base URL; these are what a structurally valid-LOOKING entry
    # must also carry before a claim could succeed, and their absence is the
    # `local_state_invalid` diagnosis (MVP-0021 scope 3) rather than a later, vaguer failure.
    REQUIRED_CONNECTION_FIELDS = %i[base_url workspace_key runner_id runner_public_id
                                    repository_url default_branch local_path].freeze

    # One connected workspace. `workspace_key` is the identity every other lookup uses.
    #
    # MAPIAI-91 added `reviewer_provider`: the supported provider identifier the guided connection
    # selected for the REVIEWER role, so `Config.from_connection` can reconstruct the same
    # reviewer the machine advertised as ready. It is one more OPTIONAL non-secret key, exactly
    # like `default_workspace_key`, and it is deliberately the only reviewer fact stored — the
    # command, arguments, timeout and environment stay out of this file entirely. A record without
    # it is complete: absence means this machine reviews nothing, and nothing may guess otherwise.
    Connection = Struct.new(
      :base_url, :runner_id, :runner_public_id, :runner_display_name,
      :project_slug, :workspace_key, :project_key, :workspace_display_name,
      :repository_url, :default_branch, :local_path, :reviewer_provider, :connected_at,
      keyword_init: true
    ) do
      def to_h_document = to_h.transform_keys(&:to_s)

      def missing_fields = REQUIRED_CONNECTION_FIELDS.select { |field| self[field].to_s.strip.empty? }
      def complete? = missing_fields.empty?
    end

    # The one complete name for one connection. Every surface that has to identify a connection in
    # a single string — a menu row's value, a dashboard action, a stored default, a disconnect
    # target, a copied command — uses this one.
    def self.selector_for(connection)
      "#{connection.base_url}#{PROJECT_SEPARATOR}#{project_segment(connection)}" \
        "#{WORKSPACE_SEPARATOR}#{connection.workspace_key}"
    end

    def self.project_segment(connection)
      slug = connection.project_slug.to_s.strip
      slug.empty? ? UNKNOWN_PROJECT : slug
    end

    # Every string that may name this connection, from the complete selector down to the bare
    # workspace key. The shorter two are conveniences: they identify a connection only while they
    # match exactly one stored record, which is what `#resolve` decides.
    def self.selectors_for(connection)
      [ selector_for(connection),
        "#{project_segment(connection)}#{WORKSPACE_SEPARATOR}#{connection.workspace_key}",
        connection.workspace_key.to_s ]
    end

    # What one requested selector named. `matches` is deliberately the whole list rather than a
    # count, so a caller can list the real alternatives instead of saying only "ambiguous".
    Resolution = Struct.new(:connection, :matches, keyword_init: true) do
      def resolved? = !connection.nil?
      def ambiguous? = matches.length > 1
      def none? = matches.empty?
    end

    def self.default_path(env: ENV, home: Dir.home)
      override = env["SPECRELAY_RUNNER_STATE_FILE"].to_s.strip
      override.empty? ? File.join(home, DEFAULT_RELATIVE_PATH) : override
    end

    def self.load(path: nil, env: ENV)
      new(path || default_path(env: env))
    end

    def initialize(path)
      @path = path.to_s
    end

    attr_reader :path

    # Every stored connection, newest first. An unreadable or corrupt file is reported as
    # an empty store rather than raising: a runner whose state file was hand-edited into
    # invalid JSON should tell the operator to reconnect, not crash on startup. Use
    # `#readable?` to tell "nothing connected" from "the file is damaged".
    #
    # `connected_at` decides the order, so the listing is newest-first even if the file was
    # reordered by hand; entries with no usable timestamp keep their relative file order and
    # sort last. `save` already prepends, so for an untouched file this is the file order.
    def connections
      document = read_document
      entries = Array(document["connections"]).filter_map { |entry| build(entry) }
      entries.each_with_index.sort_by { |connection, index| [ -connected_at_rank(connection), index ] }
             .map(&:first)
    end

    # THE one matching rule. Every adapter asks this rather than comparing keys itself, so an
    # ambiguous selector cannot be resolved one way by the menu and another by a command.
    #
    # A selector that names several connections resolves to NONE of them. Choosing by recency,
    # by file order, or by which project was seen first would be the silent substitution the
    # fail-closed rule exists to prevent — and here it would mean claiming another project's work.
    def resolve(selector)
      wanted = selector.to_s.strip
      return Resolution.new(connection: nil, matches: []) if wanted.empty?

      matches = connections.select { |connection| self.class.selectors_for(connection).include?(wanted) }
      Resolution.new(connection: (matches.first if matches.one?), matches: matches)
    end

    # Every stored connection registered against one Platform project. This is what decides
    # whether this machine already holds a registration there, and therefore whether a new
    # workspace joins an existing registration or needs a new one.
    def project_connections(base_url, project_slug)
      connections.select do |connection|
        connection.base_url == base_url.to_s && connection.project_slug.to_s == project_slug.to_s
      end
    end

    # False only when the file EXISTS and cannot be understood — the `local_state_invalid`
    # condition the readiness test and the `connections` commands must report as a distinct
    # problem instead of silently as "not connected yet" (MVP-0021 scope 3). A missing file
    # is a normal not-connected-yet state and is readable.
    def readable?
      return true unless File.file?(path)

      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) && (parsed["connections"].nil? || parsed["connections"].is_a?(Array))
    rescue JSON::ParserError, SystemCallError, IOError
      false
    end

    # The document version on disk, or nil when there is no file. Displayed by the
    # dashboard's diagnostics so an operator can see which state format they are on.
    def document_version = File.file?(path) ? read_document["version"] : nil

    # The selector the operator explicitly chose as this machine's default, exactly as stored —
    # WITHOUT checking that it still names one connection. The caller needs that difference: a
    # default that no longer resolves must fail closed with a focused remedy, never fall through
    # to another workspace. A document written by an earlier runner holds a bare workspace key
    # here, which resolves while it still names exactly one connection.
    def default_selector
      value = read_document[DEFAULT_KEY_FIELD].to_s.strip
      value.empty? ? nil : value
    end

    def default?(connection)
      selector = default_selector
      !selector.nil? && self.class.selectors_for(connection).include?(selector)
    end

    # The default connection, or nil when no default is set OR the stored default no longer names
    # exactly one connection. `default_set_but_missing?` separates those two cases.
    def default_connection = resolve(default_selector).connection

    def default_set_but_missing? = !default_selector.nil? && default_connection.nil?

    # The single connection to use when the operator named none. Returns nil when the
    # store holds several, so the runner asks rather than guessing which workspace to
    # claim for — the same fail-closed rule Platform applies to workspace selection.
    def sole_connection
      found = connections
      found.one? ? found.first : nil
    end

    # Upsert one connection by its full identity, so a retried `connect` replaces its own entry
    # while a DIFFERENT project that happens to use the same workspace key is added beside it.
    #
    # The existing default is rewritten as the full selector of whatever it names right now,
    # BEFORE the new record joins the file and in the same atomic write. Leaving a bare key there
    # is how a default set for one project silently becomes ambiguous — or attaches to the new
    # record — the moment a second project reuses that key.
    def save(connection)
      identity = self.class.selector_for(connection)
      pinned = pinned_default
      others = connections.reject { |existing| self.class.selector_for(existing) == identity }
      write_connections([ connection, *others ], pinned)
      connection
    end

    # The stored default as the full selector of the connection it names today, or nil when none
    # is set. Raises when it is set and no longer names exactly one connection.
    #
    # Callers that are about to ADD a record use this as a pre-flight: a stale or ambiguous
    # default must be fixed by the operator rather than carried into a file where it could attach
    # to a new record. `connect` asks before it spends the enrollment code, so a refusal here
    # costs nothing.
    def pinned_default
      stored = default_selector
      return nil if stored.nil?

      resolution = resolve(stored)
      return self.class.selector_for(resolution.connection) if resolution.resolved?

      raise Error, unusable_default_message(stored, resolution)
    end

    # Record the operator's explicit default, stored as the full selector so it cannot later be
    # claimed by another project's record. Refused unless the selector names exactly one
    # connection this machine holds: storing one that cannot resolve would only move the error.
    def set_default(selector)
      resolution = resolve(selector)
      raise Error, unusable_default_message(selector.to_s.strip, resolution) unless resolution.resolved?

      chosen = self.class.selector_for(resolution.connection)
      write_connections(connections, chosen)
      chosen
    end

    def clear_default
      write_connections(connections, nil)
      nil
    end

    # Remove exactly ONE workspace's local connection entry. Returns the removed connection,
    # or nil when nothing matched — so an idempotent retry is a normal outcome rather than an
    # error. A default pointing at the removed workspace is cleared in the SAME atomic write,
    # because leaving it behind would turn a clean disconnect into a dangling default that
    # fails every later `loop`.
    def delete(selector)
      removed = resolve(selector).connection
      return nil if removed.nil?

      identity = self.class.selector_for(removed)
      remaining = connections.reject { |connection| self.class.selector_for(connection) == identity }
      write_connections(remaining, surviving_default(removed))
      removed
    end

    private

    # The default to keep after one connection is removed: cleared when it named the removed one,
    # and otherwise left exactly as stored. Resolved leniently on purpose — an operator removing
    # one of two records that made a bare default ambiguous is fixing that state, and refusing the
    # removal would leave them with no way to.
    def surviving_default(removed)
      stored = default_selector
      return nil if stored.nil?

      named = resolve(stored).connection
      return nil if named && self.class.selector_for(named) == self.class.selector_for(removed)

      stored
    end

    def unusable_default_message(stored, resolution)
      unless resolution.ambiguous?
        return "the default '#{stored}' no longer names a connection on this machine; " \
               "set another or clear it"
      end

      alternatives = resolution.matches.map { |connection| self.class.selector_for(connection) }
      "the default '#{stored}' names several connections (#{alternatives.join(', ')}); " \
        "set it to one of them or clear it"
    end

    def write_connections(entries, default_key)
      document = { "version" => VERSION, "connections" => entries.map(&:to_h_document) }
      document[DEFAULT_KEY_FIELD] = default_key if default_key
      write_document(document)
    end

    # ISO-8601 `connected_at` as a comparable number; 0 when absent or unparseable, so a
    # hand-written entry with no timestamp sorts last instead of raising.
    def connected_at_rank(connection)
      Time.parse(connection.connected_at.to_s).to_f
    rescue ArgumentError, TypeError
      0
    end

    def read_document
      return {} unless File.file?(path)

      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError, SystemCallError, IOError
      {}
    end

    def build(entry)
      return nil unless entry.is_a?(Hash)

      attributes = Connection.members.to_h { |key| [ key, entry[key.to_s] ] }
      connection = Connection.new(**attributes)
      connection.workspace_key.to_s.empty? || connection.base_url.to_s.empty? ? nil : connection
    end

    # Atomic replace: the temporary file is in the same directory so the rename cannot
    # cross a filesystem boundary.
    def write_document(document)
      FileUtils.mkdir_p(File.dirname(path))
      temporary = "#{path}.#{Process.pid}.tmp"
      File.write(temporary, "#{JSON.pretty_generate(document)}\n")
      File.chmod(0o600, temporary)
      File.rename(temporary, path)
    rescue SystemCallError, IOError => e
      raise Error, "could not write the runner connection file #{path} (#{e.class})"
    end
  end
end
