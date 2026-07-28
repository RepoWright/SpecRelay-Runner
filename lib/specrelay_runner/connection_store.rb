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
    # The top-level key holding the operator's explicit default workspace key. Non-secret,
    # like everything else in this file.
    DEFAULT_KEY_FIELD = "default_workspace_key"

    # The fields the runner cannot operate without. `build` below already refuses an entry
    # missing a workspace key or base URL; these are what a structurally valid-LOOKING entry
    # must also carry before a claim could succeed, and their absence is the
    # `local_state_invalid` diagnosis (MVP-0021 scope 3) rather than a later, vaguer failure.
    REQUIRED_CONNECTION_FIELDS = %i[base_url workspace_key runner_id runner_public_id
                                    repository_url default_branch local_path].freeze

    # One connected workspace. `workspace_key` is the identity every other lookup uses.
    Connection = Struct.new(
      :base_url, :runner_id, :runner_public_id, :runner_display_name,
      :project_slug, :workspace_key, :project_key, :workspace_display_name,
      :repository_url, :default_branch, :local_path, :connected_at,
      keyword_init: true
    ) do
      def to_h_document = to_h.transform_keys(&:to_s)

      def missing_fields = REQUIRED_CONNECTION_FIELDS.select { |field| self[field].to_s.strip.empty? }
      def complete? = missing_fields.empty?
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

    def connection_for(workspace_key)
      connections.find { |connection| connection.workspace_key == workspace_key.to_s }
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

    # The workspace key the operator explicitly chose as this machine's default, exactly as
    # stored — WITHOUT checking that it still names a connection. The caller needs that
    # difference: a default naming a workspace that is no longer connected must fail closed
    # with a focused remedy, never fall through to another workspace (MVP-0021 scope 4).
    def default_workspace_key
      value = read_document[DEFAULT_KEY_FIELD].to_s.strip
      value.empty? ? nil : value
    end

    def default?(workspace_key) = !default_workspace_key.nil? && default_workspace_key == workspace_key.to_s

    # The default connection, or nil when no default is set OR the stored default no longer
    # names a connection. `default_set_but_missing?` separates those two cases.
    def default_connection
      key = default_workspace_key
      key.nil? ? nil : connection_for(key)
    end

    def default_set_but_missing? = !default_workspace_key.nil? && default_connection.nil?

    # The single connection to use when the operator named none. Returns nil when the
    # store holds several, so the runner asks rather than guessing which workspace to
    # claim for — the same fail-closed rule Platform applies to workspace selection.
    def sole_connection
      found = connections
      found.one? ? found.first : nil
    end

    # Upsert one connection by workspace key, so a retried `connect` replaces its own
    # entry instead of appending a duplicate.
    def save(connection)
      others = connections.reject { |existing| existing.workspace_key == connection.workspace_key }
      write_connections([ connection, *others ], default_workspace_key)
      connection
    end

    # Record the operator's explicit default. Refused unless the key names a connection this
    # machine actually holds: a default that cannot resolve is the fail-closed failure mode
    # scope 4 exists to prevent, and storing one would only move the error later.
    def set_default(workspace_key)
      key = workspace_key.to_s.strip
      raise Error, "no connection for workspace '#{key}'" if connection_for(key).nil?

      write_connections(connections, key)
      key
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
    def delete(workspace_key)
      key = workspace_key.to_s.strip
      removed = connection_for(key)
      return nil if removed.nil?

      remaining = connections.reject { |connection| connection.workspace_key == key }
      write_connections(remaining, default_workspace_key == key ? nil : default_workspace_key)
      removed
    end

    private

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
