# frozen_string_literal: true

require "json"

module SpecrelayRunner
  # MAPIAI-97 — the running task environment a reviewer can open after a successful implementation.
  #
  # The project already owns this lifecycle: `bin/worktree up <TASK-ID>` starts the environment and
  # `bin/worktree status <TASK-ID> --json` reports it. This class runs those two commands and
  # nothing else. It never executes the workspace's display-only `dev_command`, never scans ports,
  # sockets or processes, never calls Docker or Compose, and never parses human output — a second
  # discovery mechanism would be a second answer to a question the project has already answered.
  #
  # Its result is an ALLOWLIST projection, not a filtered copy of the status document. The status
  # payload carries local worktree paths, Compose identifiers, port blocks and per-repository
  # change records; none of them may reach the wire, so the projection names the five fields that
  # may and drops the document.
  #
  # Every outcome is a value. An unsupported project, a failed startup and an unusable status are
  # reported, never raised: the implementation they follow has already succeeded and published, and
  # a preview must not be able to take that back.
  class TaskPreview
    AVAILABLE = "available"
    UNAVAILABLE = "unavailable"
    FAILED = "failed"

    UNSUPPORTED = "unsupported"
    STARTUP_FAILED = "startup_failed"
    STATUS_FAILED = "status_failed"
    INVALID_STATUS = "invalid_status"

    # The project's own vocabulary for a live environment and for a service worth linking to.
    RUNTIME_RUNNING = "RUNNING"
    SERVICE_RUNNING = "running"
    REPORTABLE_HEALTH = %w[healthy none].freeze

    MAX_STATUS_BYTES = 64 * 1024
    MAX_SERVICES = 20
    MAX_URL_LENGTH = 2_048
    NAME_PATTERN = /\A[A-Za-z0-9._-]{1,64}\z/

    # An allowlist for the WHOLE URL rather than a list of things to strip. Scheme, loopback host,
    # explicit port, absent userinfo, absent query, absent fragment and a root-or-empty path are
    # one shape, and a URL either has that shape or is refused. A denylist would have to remember
    # every other one.
    URL_PATTERN = %r{\Ahttps?://127\.0\.0\.1:(\d{4,5})/?\z}
    PORT_RANGE = (1024..65_535)

    def self.call(**kwargs) = new(**kwargs).call

    # `timeout_seconds` is the workspace command bound, injected so a test can prove the timeout
    # branches without waiting five minutes for them.
    def initialize(root:, task_id:, env: {}, timeout_seconds: Workspace::COMMAND_TIMEOUT_SECONDS)
      @root = root.to_s
      @task_id = task_id.to_s
      @env = env
      @timeout_seconds = timeout_seconds
    end

    def call
      return unavailable unless startable?
      return failure(STARTUP_FAILED) unless project("up", task_id)&.success?

      status = project("status", task_id, "--json")
      return failure(STATUS_FAILED) unless status&.success?

      snapshot(status.stdout) || failure(INVALID_STATUS)
    end

    private

    attr_reader :root, :task_id, :env, :timeout_seconds

    def startable? = !task_id.empty? && File.executable?(command_path)
    def command_path = File.join(root, Workspace::PROJECT_COMMAND)

    # The project command's result, or nil when this host could not START it (CR-001 F1).
    #
    # An executable file can still fail to spawn: a shebang naming an interpreter that is not
    # installed, a command replaced or removed between the capability check and the invocation, or
    # a process/descriptor limit. Process spawn failures surface as Errno subclasses, so
    # SystemCallError is the narrowest boundary that covers them — the same one Publication and
    # Executor already put around this runner.
    #
    # nil rather than a fabricated failed Result: the caller knows which phase it asked for and
    # maps it to that phase's bounded reason, and an invented exit code would be a second way of
    # saying "this did not run". Nothing is retried: a command that cannot be launched now is not
    # a transient condition this attempt may spend its remaining time on.
    def project(*arguments)
      CommandRunner.run([ command_path, *arguments ], chdir: root, env: env, timeout_seconds: timeout_seconds)
    rescue SystemCallError
      nil
    end

    # The available snapshot, or nil for every payload that cannot honestly produce one — which the
    # caller reports as `invalid_status`. Deliberately one refusal rather than a reason per rule:
    # the difference between "this JSON was truncated" and "this JSON described another task" is a
    # detail of a machine the reviewer is not looking at, and stating it would put runner-supplied
    # text on a Platform page for no decision it changes.
    def snapshot(raw)
      return nil if raw.to_s.bytesize > MAX_STATUS_BYTES

      status = JSON.parse(raw)
      return nil unless status.is_a?(Hash)
      return nil unless status["task_id"].to_s == task_id && status["state"].to_s == RUNTIME_RUNNING

      services = reportable_services(status["services"])
      return nil if services.nil? || services.empty? || services.length > MAX_SERVICES

      primary_url = status["primary_url"]
      return nil unless services.any? { |service| service["url"] == primary_url }

      { "status" => AVAILABLE, "reason" => nil, "runtime_state" => RUNTIME_RUNNING,
        "primary_url" => primary_url, "services" => services }
    rescue JSON::ParserError
      nil
    end

    # The services worth linking to, or nil when the list cannot be trusted at all.
    #
    # The two answers are different on purpose. A service that is not running, is unhealthy, or
    # publishes no URL is an ordinary fact about a live environment and is DROPPED. An unsafe URL,
    # an unusable name, a repeated name or URL, or an entry that is not an object means the
    # document is not the one this contract describes, and a list missing one refused row would
    # still present itself as complete — so the whole preview is REFUSED instead.
    def reportable_services(entries)
      return nil unless entries.is_a?(Array)

      services = []
      entries.each do |entry|
        return nil unless entry.is_a?(Hash)
        next unless reportable?(entry)

        service = safe_service(entry)
        return nil if service.nil?

        services << service
      end
      unique?(services) ? services : nil
    end

    def reportable?(entry)
      entry["state"].to_s == SERVICE_RUNNING && REPORTABLE_HEALTH.include?(entry["health"].to_s) &&
        !entry["url"].nil?
    end

    # One service as the wire may carry it: its name, the runner's own words for the state and
    # health it just checked, and a URL that passed the allowlist. No host port, no container name,
    # no source key that happened to be beside them.
    def safe_service(entry)
      name = entry["service"].to_s
      return nil unless name.match?(NAME_PATTERN) && safe_url?(entry["url"])

      { "name" => name, "state" => SERVICE_RUNNING, "health" => entry["health"].to_s,
        "url" => entry["url"] }
    end

    def safe_url?(value)
      return false unless value.is_a?(String) && value.length <= MAX_URL_LENGTH

      port = URL_PATTERN.match(value)&.captures&.first
      !port.nil? && PORT_RANGE.cover?(port.to_i)
    end

    def unique?(services)
      %w[name url].all? do |field|
        values = services.map { |service| service[field] }
        values.uniq.length == values.length
      end
    end

    def unavailable = result(UNAVAILABLE, UNSUPPORTED)
    def failure(reason) = result(FAILED, reason)

    def result(status, reason)
      { "status" => status, "reason" => reason, "runtime_state" => nil, "primary_url" => nil,
        "services" => [] }
    end
  end
end
