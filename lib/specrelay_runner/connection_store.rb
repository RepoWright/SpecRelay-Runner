# frozen_string_literal: true

require "json"
require "fileutils"

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
  class ConnectionStore
    Error = Class.new(StandardError)

    VERSION = 1
    DEFAULT_RELATIVE_PATH = ".specrelay/runner/connections.json"

    # One connected workspace. `workspace_key` is the identity every other lookup uses.
    Connection = Struct.new(
      :base_url, :runner_id, :runner_public_id, :runner_display_name,
      :project_slug, :workspace_key, :project_key, :workspace_display_name,
      :repository_url, :default_branch, :local_path, :connected_at,
      keyword_init: true
    ) do
      def to_h_document = to_h.transform_keys(&:to_s)
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
    # invalid JSON should tell the operator to reconnect, not crash on startup.
    def connections
      document = read_document
      Array(document["connections"]).filter_map { |entry| build(entry) }
    end

    def connection_for(workspace_key)
      connections.find { |connection| connection.workspace_key == workspace_key.to_s }
    end

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
      write_document("version" => VERSION,
                     "connections" => [ connection.to_h_document, *others.map(&:to_h_document) ])
      connection
    end

    private

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
