# frozen_string_literal: true

require "json"
require "uri"

module SpecrelayRunner
  # MAPIAI-97 — the authoritative project-owned status document, read and reduced to the closed
  # shape Platform accepts.
  #
  # TWO documents are involved and conflating them would break the feature. The project's own
  # `bin/worktree status --json` legitimately carries slots, port blocks, Compose project names,
  # repository paths, commits and data-service options — operational facts a preview page must
  # never receive. That document is RICH, not closed: this class projects an allowlist from it,
  # ignoring unexported fields rather than refusing them, because refusing them would refuse every
  # real project.
  #
  # What it produces is the closed wire document, and THAT one is strict: Platform independently
  # applies the same rules to it and rejects any unknown or missing field. Runner ignoring
  # unexported fields in the rich document does not permit Platform to ignore fields in the wire
  # document.
  #
  # The projection runs in two phases, and the order is the point:
  #
  #   1. validate the COMPLETE project-owned service list, internal services included;
  #   2. project only the validated openable services onto the wire.
  #
  # A service with no browser url is internal — a database, a queue — and must not become a link.
  # But it is still part of the application whose readiness this document claims, so filtering
  # first would let an exited database ship a page announcing that everything is running.
  #
  # It refuses the COMPLETE available result rather than dropping an unsafe entry: a page showing
  # three of four services, silently, is a page that lies about what is running.
  class PreviewStatus
    CONTRACT_VERSION = "mapiai-97"

    RUNNING = "RUNNING"
    SERVICE_RUNNING = "running"
    # A service that reports no health check is `none`; anything else must be healthy. Both are
    # coherent with a RUNNING environment; `starting`, `unhealthy` and unknown values are not.
    HEALTH = %w[healthy none].freeze
    # The fields every project-owned service must carry. Operational extras beside them, such as
    # `host_port`, are ignored by the projection.
    SERVICE_KEYS = %w[service state health url].freeze

    MAX_SERVICES = 20
    MAX_NAME_BYTES = 64
    MAX_URL_BYTES = 2048
    MAX_DOCUMENT_BYTES = 512 * 1024
    SAFE_NAME = /\A[a-z0-9][a-z0-9._-]*\z/i
    SAFE_SCHEMES = %w[http https].freeze
    LOOPBACK = "127.0.0.1"
    PORTS = (1024..65_535)

    Result = Struct.new(:ok, :reason, :document, keyword_init: true) do
      def ok? = ok
      def services = Array(document&.dig("services"))
    end

    # `raw` is the command's stdout. The task id is the one this claim was ASSIGNED, never one
    # read back out of the document: a status document for another task is a different
    # environment, and trusting its own id would make that undetectable.
    def self.project(raw, task_id:)
      new(raw, task_id).project
    end

    def initialize(raw, task_id)
      @raw = raw.to_s
      @task_id = task_id.to_s
    end

    def project
      document = parsed
      return document if document.is_a?(Result)

      refusal = envelope_refusal(document)
      return refuse(refusal) if refusal

      services = validated_services(document["services"])
      return services if services.is_a?(Result)

      wire(document["primary_url"].to_s, services)
    end

    private

    def refuse(reason) = Result.new(ok: false, reason: reason)

    def parsed
      return refuse("the project reported no status document") if @raw.strip.empty?
      return refuse("the project's status document is larger than #{MAX_DOCUMENT_BYTES} bytes") if
        @raw.bytesize > MAX_DOCUMENT_BYTES

      document = JSON.parse(@raw)
      document.is_a?(Hash) ? document : refuse("the project's status document is not an object")
    rescue JSON::ParserError
      refuse("the project's status document is not valid JSON")
    end

    # The two facts that decide whether this document describes THIS environment, running.
    def envelope_refusal(document)
      reported = document["task_id"].to_s
      return "the project reported status for #{quoted(reported)}, not #{quoted(@task_id)}" unless
        reported == @task_id

      state = document["state"].to_s
      return "the task environment reports #{quoted(state)}, not #{RUNNING}" unless state == RUNNING

      nil
    end

    # Phase one, then phase two. Nothing is dropped until every raw service has been judged.
    def validated_services(entries)
      return refuse("the project reported no service list") unless entries.is_a?(Array)

      refusal = raw_refusal(entries)
      return refuse(refusal) if refusal

      openable(entries)
    end

    def raw_refusal(entries)
      names = {}
      entries.each do |entry|
        refusal = service_refusal(entry, names)
        return refusal if refusal
      end
      nil
    end

    # One raw service, judged whole: shape, the required project-owned fields, a safe unique name,
    # coherence with a RUNNING environment, and a url that is either absent or a plain bounded
    # string. Names are unique across ALL services, internal ones included, because two services
    # sharing a name means the document cannot be read unambiguously at all.
    def service_refusal(entry, names)
      return "a reported service is not an object" unless entry.is_a?(Hash)

      missing = SERVICE_KEYS.find { |key| !entry.key?(key) }
      return "a reported service is missing #{quoted(missing)}" if missing

      name = entry["service"].to_s
      refusal = name_refusal(name, names)
      return refusal if refusal

      names[name.downcase] = true
      coherence_refusal(entry, name) || plain_url_refusal(entry["url"], name)
    end

    def name_refusal(name, names)
      return "a reported service has no name" if name.empty?
      return "the service name #{quoted(name)} is longer than #{MAX_NAME_BYTES} bytes" if
        name.bytesize > MAX_NAME_BYTES
      return "the service name #{quoted(name)} is not a safe name" unless SAFE_NAME.match?(name)
      return "the task environment reports the service #{quoted(name)} twice" if names.key?(name.downcase)

      nil
    end

    # A RUNNING environment whose service is not running, or whose health is a value this contract
    # does not know, is incoherent — and an incoherent document refuses the whole result rather
    # than being partially believed. This applies to internal services too: an exited database is
    # not a preview a human can test.
    def coherence_refusal(entry, name)
      state = entry["state"].to_s
      return "the service #{quoted(name)} reports #{quoted(state)}, not #{SERVICE_RUNNING}" unless
        state == SERVICE_RUNNING

      health = entry["health"].to_s
      return "the service #{quoted(name)} reports the health #{quoted(health)}" unless HEALTH.include?(health)

      nil
    end

    # The project's one convention for "this service has no browser url" is an explicit null or an
    # empty string. Anything else must be a plain bounded string: a structured value is refused
    # rather than coerced, because `to_s` on an Array would manufacture a url nothing recognises
    # as malformed.
    def plain_url_refusal(value, name)
      return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)
      return "the url of #{quoted(name)} is not a plain value" unless value.is_a?(String)
      return "the url of #{quoted(name)} is longer than #{MAX_URL_BYTES} bytes" if
        value.bytesize > MAX_URL_BYTES

      nil
    end

    # Phase two. Only now may a url-less service be omitted: it has already been proved coherent.
    # Zero openable services is unavailable, because a human has nothing to open.
    def openable(entries)
      offered = entries.reject { |entry| entry["url"].to_s.strip.empty? }
      return refuse("the task environment reports no service to open") if offered.empty?
      return refuse("the task environment reports more than #{MAX_SERVICES} services") if
        offered.length > MAX_SERVICES

      collect(offered)
    end

    def collect(entries)
      urls = {}
      services = []
      entries.each do |entry|
        name = entry["service"].to_s
        refusal = url_refusal(entry["url"], name, urls)
        return refuse(refusal) if refusal

        urls[entry["url"]] = true
        services << { "service" => name, "state" => SERVICE_RUNNING, "health" => entry["health"].to_s,
                      "url" => entry["url"] }
      end
      services
    end

    # The complete URL rule, stated once here and independently again in Platform. Only an explicit
    # loopback address with an explicit ordinary port and no path beyond root may become a link.
    def url_refusal(url, name, urls)
      return "the task environment reports the url #{quoted(url)} twice" if urls.key?(url)

      parsed = begin
        URI.parse(url)
      rescue URI::InvalidURIError
        nil
      end
      return "the url of #{quoted(name)} is not a valid url" if parsed.nil?
      return "the url of #{quoted(name)} does not use http or https" unless SAFE_SCHEMES.include?(parsed.scheme)
      return "the url of #{quoted(name)} is not on #{LOOPBACK}" unless parsed.host == LOOPBACK
      return "the url of #{quoted(name)} carries credentials" unless parsed.userinfo.nil?
      return "the url of #{quoted(name)} carries a query or fragment" unless
        parsed.query.nil? && parsed.fragment.nil?
      # Path before port, so a sub-root url is refused for the reason it is actually wrong rather
      # than for the port pattern it also fails.
      return "the url of #{quoted(name)} names a path" unless [ "", "/" ].include?(parsed.path.to_s)
      return "the url of #{quoted(name)} names no explicit port" unless explicit_port?(url)
      return "the url of #{quoted(name)} is not on an ordinary port" unless PORTS.cover?(parsed.port.to_i)

      nil
    end

    # `URI` fills in a default port, so the text itself is what proves the port was written down.
    def explicit_port?(url) = url.match?(%r{\A[a-z]+://#{Regexp.escape(LOOPBACK)}:\d+(/)?\z}i)

    # Exactly one primary, and it must be one of the services offered: a primary marker pointing at
    # something not in the list is a link with no row.
    def wire(primary, services)
      return refuse("the task environment reports no primary url") if primary.empty?
      return refuse("the primary url is not one of the reported services") unless
        services.any? { |service| service["url"] == primary }

      Result.new(ok: true, document: { "contract_version" => CONTRACT_VERSION, "task_id" => @task_id,
                                       "state" => RUNNING, "primary_url" => primary,
                                       "services" => services })
    end

    def quoted(value) = "\"#{value}\""
  end
end
