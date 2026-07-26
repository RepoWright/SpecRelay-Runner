# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module SpecrelayRunner
  # The runner's HTTP client for the Platform runner API (MVP-0010). This is the
  # ONLY way the standalone runner talks to Platform: there is no ActiveRecord,
  # no Rails constant, and no direct database access anywhere in this runner — the
  # process boundary is real. Every call carries the development bearer token and
  # returns parsed JSON.
  #
  # Errors are mapped to a small, runner-facing hierarchy so the CLI can print a
  # sanitized message and exit non-zero without leaking the token (which is never
  # logged and only ever set in the Authorization header).
  class PlatformClient
    Error = Class.new(StandardError)
    Unauthorized = Class.new(Error)
    RequestFailed = Class.new(Error)

    # A claimed run payload, or a not-claimed signal.
    ClaimResult = Struct.new(:claimed, :payload, keyword_init: true) do
      def claimed? = claimed
    end

    def initialize(base_url:, token:, open_timeout: 5, read_timeout: 1800, http: Net::HTTP)
      @base = URI.parse(base_url)
      @token = token
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @http = http
    end

    # POST /api/runner/registration. The bearer for THIS call is the one-time
    # registration token (not a runner credential — the runner has none yet).
    # Returns the parsed body, which carries the per-runner credential exactly
    # once. Raises Unauthorized (401) for an invalid/expired/used token.
    def register(runner_params)
      status, body = post_json("/api/runner/registration", runner: runner_params)
      status == 201 ? body : raise_for(status, body)
    end

    # POST /api/runner/claim. Returns a ClaimResult: claimed with the run payload,
    # or not claimed when Platform authorizes no eligible work under the policy.
    def claim(runner_params)
      status, body = post_json("/api/runner/claim", runner: runner_params)
      case status
      when 201 then ClaimResult.new(claimed: true, payload: body)
      when 200 then ClaimResult.new(claimed: false, payload: body)
      else raise_for(status, body)
      end
    end

    # POST /api/runner/events with a v1 protocol event (MVP-0013). `event` is the
    # full envelope: contract_version, run_id, attempt_id, sequence, event_type,
    # schema_version, occurred_at, public_summary, attributes, and optional
    # sanitized_log_chunk/artifact_reference. Platform enforces idempotency on
    # (attempt_id, sequence).
    #
    # Retry safety (spec §6): a transient TRANSPORT failure is retried with the
    # EXACT same payload — never a mutated one — so a retry can never reuse a
    # sequence for a different payload. An HTTP rejection (401/422) is NOT retried;
    # it is surfaced so the caller fails closed.
    def submit_protocol_event(claim:, event:, max_attempts: 3)
      attempt = 0
      begin
        attempt += 1
        status, body = post_json("/api/runner/events", claim: claim, event: event)
        return body if status == 201

        raise_for(status, body)
      rescue Error => e
        # Only the bare transport Error (not its Unauthorized/RequestFailed
        # subclasses) is transient and safely retryable with the same payload.
        raise if !e.instance_of?(Error) || attempt >= max_attempts

        retry
      end
    end

    # POST /api/runner/heartbeat.
    def heartbeat(claim:)
      status, body = post_json("/api/runner/heartbeat", claim: claim)
      status == 200 ? body : raise_for(status, body)
    end

    # POST /api/runner/reports. bundle is { round_label:, files: [...] }.
    # terminal_result, when given, is the MVP-0013 terminal-result envelope
    # validated by Platform BEFORE import; a rejected envelope returns non-201 and
    # is raised so the runner fails closed without claiming success.
    def submit_report(claim:, bundle:, terminal_result: nil)
      payload = { claim: claim, report: bundle }
      payload[:terminal_result] = terminal_result if terminal_result
      status, body = post_json("/api/runner/reports", payload)
      status == 201 ? body : raise_for(status, body)
    end

    private

    attr_reader :base, :token, :http

    def post_json(path, payload)
      uri = URI.join(base.to_s, path)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{token}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = JSON.generate(payload)

      response = http.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                            open_timeout: @open_timeout, read_timeout: @read_timeout) do |conn|
        conn.request(request)
      end
      [ response.code.to_i, parse(response.body) ]
    rescue SocketError, Errno::ECONNREFUSED, Timeout::Error => e
      raise Error, "could not reach Platform at #{base}: #{e.class}"
    end

    def parse(body)
      body.to_s.strip.empty? ? {} : JSON.parse(body)
    rescue JSON::ParserError
      {}
    end

    def raise_for(status, body)
      message = body.is_a?(Hash) ? body["error"].to_s : ""
      raise Unauthorized, "Platform rejected the runner token (401)#{": #{message}" unless message.empty?}" if status == 401
      raise RequestFailed, "Platform request failed (#{status})#{": #{message}" unless message.empty?}"
    end
  end
end
