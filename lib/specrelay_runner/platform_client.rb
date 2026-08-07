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
    # Every failure carries the HTTP status Platform answered with, or nil when Platform never
    # answered at all. The distinction is the whole point: a transport failure leaves the
    # request's fate unknown and a retry may still succeed, while a 4xx is Platform having
    # READ the payload and REFUSED it — no retry of the same body can change that, so a caller
    # holding a local success must fail closed rather than report it (MVP-0027 review-001 P2-2).
    class Error < StandardError
      attr_reader :status

      def initialize(message = nil, status: nil)
        super(message)
        @status = status
      end

      # Platform answered and rejected the payload. Deliberately NOT true for 5xx: Platform
      # failing to process a request it accepted is closer to a transport fault than to a
      # refusal, and the same body may well be accepted on the next attempt.
      def refused? = (400..499).cover?(status.to_i)
    end

    Unauthorized = Class.new(Error)
    RequestFailed = Class.new(Error)
    # A 404. Distinguished from RequestFailed because for the MVP-0021 connection test it is
    # not a failure at all — it is the specific, actionable answer "Platform holds no grant
    # for this runner on that workspace", which names a different remedy (reconnect) than a
    # rejected credential or an unreachable Platform.
    NotFound = Class.new(Error)

    # The header the non-destructive reconnect uses to present the credential this machine
    # already holds. Deliberately not the request body: see #enroll.
    CURRENT_CREDENTIAL_HEADER = "X-SpecRelay-Runner-Credential"

    # A claimed run payload, or a not-claimed signal.
    ClaimResult = Struct.new(:claimed, :payload, keyword_init: true) do
      def claimed? = claimed

      # Platform's own explanation for a not-claimed poll. Since MVP-0017 the two cases are
      # genuinely different problems — "you are not connected to any workspace" needs
      # `specrelay-runner connect`, while "nothing to do right now" needs nothing — so the
      # runner prints what Platform said instead of one generic line.
      def reason = payload.is_a?(Hash) ? payload["reason"].to_s : ""
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
      status, body = post_json("/api/runner/registration", { runner: runner_params })
      status == 201 ? body : raise_for(status, body)
    end

    # POST /api/runner/enrollment_preview (round 002). The bearer is the one-time enrollment
    # code, and the call does NOT consume it: it returns only the non-secret assignment, with no
    # credential. It exists so `connect` can validate the local checkout and provider readiness
    # BEFORE consuming anything, so a failed attempt costs the operator nothing — not even the
    # code. Raises Unauthorized (401) for an invalid, expired, or already-used code.
    def preview_enrollment
      status, body = post_json("/api/runner/enrollment_preview", {})
      status == 200 ? body : raise_for(status, body)
    end

    # POST /api/runner/enrollment (MVP-0017). The bearer for THIS call is the one-time
    # enrollment code, and this call DOES consume it. Returns the parsed body, which carries the
    # non-secret assignment plus the durable credential exactly once — unless
    # `credential_unchanged` is true, meaning Platform recognised `current_credential` and the
    # machine should keep using the credential it already holds (round 002, review-001 F3).
    # Raises Unauthorized (401) for an invalid, expired, or already-used code.
    def enroll(runner_params, current_credential: nil)
      # The held credential travels in a HEADER, never the request body. Round 002 sent it as a
      # body parameter, where Rails' parameter log wrote it in plaintext (review-002 N1). A header
      # is not part of the logged parameters at all — the same reason the bearer token was always
      # safe there.
      headers = current_credential ? { CURRENT_CREDENTIAL_HEADER => current_credential } : {}
      status, body = post_json("/api/runner/enrollment", { runner: runner_params }, headers: headers)
      status == 201 ? body : raise_for(status, body)
    end

    # POST /api/runner/workspace_connections (MVP-0017). Reports this runner's bounded
    # readiness result for one connected workspace. Platform — not the runner — decides
    # the resulting state, so the response is read for the DECIDED state rather than
    # assumed.
    def report_workspace_readiness(workspace_key:, report:)
      status, body = post_json("/api/runner/workspace_connections",
                               { workspace_key: workspace_key, report: report })
      status == 201 ? body : raise_for(status, body)
    end

    # GET /api/runner/workspace_connections/<workspace_key> (MVP-0021 scope 3). What Platform
    # currently believes about THIS runner's grant for one workspace: its state, the
    # repository identity the workspace defines today, and the executor it resolves to. A
    # pure read — it consumes nothing and cannot demote a working connection, so the
    # readiness test is safe to run repeatedly. Raises NotFound (404) when this runner holds
    # no grant for that workspace, which is a diagnosis rather than an error.
    def describe_workspace_connection(workspace_key:)
      status, body = request_json(Net::HTTP::Get, connection_path(workspace_key))
      status == 200 ? body : raise_for(status, body)
    end

    # DELETE /api/runner/workspace_connections/<workspace_key> (MVP-0021 scope 6). Asks
    # Platform to remove THIS runner's grant for ONE workspace. Idempotent server-side: a
    # grant that is already absent returns 200 with `outcome: already_absent`, so a retry
    # after a dropped response is a success. Never revokes the runner identity.
    def disconnect_workspace_connection(workspace_key:)
      status, body = request_json(Net::HTTP::Delete, connection_path(workspace_key))
      status == 200 ? body : raise_for(status, body)
    end

    # POST /api/runner/claim. Returns a ClaimResult: claimed with the run payload,
    # or not claimed when Platform authorizes no eligible work under the policy.
    def claim(runner_params)
      status, body = post_json("/api/runner/claim", { runner: runner_params })
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
        status, body = post_json("/api/runner/events", { claim: claim, event: event })
        return body if status == 201

        raise_for(status, body)
      rescue Error => e
        # Only the bare transport Error (not its Unauthorized/RequestFailed
        # subclasses) is transient and safely retryable with the same payload.
        raise if !e.instance_of?(Error) || attempt >= max_attempts

        retry
      end
    end

    # POST /api/runner/presence (MVP-0031). One IDLE presence signal for one workspace
    # connection: started, heartbeat, or stopped.
    #
    # A sibling of #heartbeat, never a variant of it. A heartbeat renews the lease on a run
    # this process CLAIMED and is proof of active work; this says only that a loop is watching
    # and owns nothing. Platform keeps them apart so an idle watcher can never appear to hold
    # work, and the two must not share a method that could send one where the other is meant.
    #
    # Platform decides the outcome — `accepted` or `superseded` — and advertises the cadence to
    # keep, so the response is read for what it DECIDED rather than assumed. Both are 200: a
    # superseded session is a well-formed request with a meaningful answer, not a transport
    # failure to retry.
    # `session_id` is absent on the opening call — that call is the request for a session, and
    # Platform answers it with the sequence the following `started` must present. Keys that do
    # not apply to an event are omitted rather than sent as null, so the payload stays the
    # closed set the endpoint validates.
    def report_presence(workspace_key:, event:, session_id: nil, session_seq: nil)
      payload = { workspace_key: workspace_key, event: event }
      payload[:session_id] = session_id if session_id
      payload[:session_seq] = session_seq if session_seq
      status, body = post_json("/api/runner/presence", payload)
      status == 200 ? body : raise_for(status, body)
    end

    # POST /api/runner/heartbeat.
    def heartbeat(claim:)
      status, body = post_json("/api/runner/heartbeat", { claim: claim })
      status == 200 ? body : raise_for(status, body)
    end

    # POST /api/runner/specification_generations (MVP-0026). Reports the outcome of ONE
    # specification-generation attempt: a generated package with its repository-relative
    # paths and digests, or a refusal/failure with its stable failure class.
    #
    # A separate endpoint from #submit_report rather than another report shape. The two
    # describe different things — an execution report is a directory of evidence about code
    # that ran, a generation result is a manifest of documents that were written — and
    # Platform imports them through different services with different state transitions.
    # Overloading one endpoint would mean a runner could accidentally finalize an
    # implementation run by submitting the wrong body.
    #
    # Platform decides the resulting run state; the response is read for what it DECIDED
    # rather than assumed. A rejected payload returns non-201 and is raised, so the runner
    # fails closed instead of printing a success it cannot substantiate.
    def submit_specification_generation(claim:, generation:)
      status, body = post_json("/api/runner/specification_generations",
                               { claim: claim, generation: generation })
      status == 201 ? body : raise_for(status, body)
    end

    # POST /api/runner/specification_publications (MVP-0027). Reports the outcome of ONE
    # specification-publication attempt: the branch, commit and draft pull request that reached
    # GitHub, or the failure that stopped it.
    #
    # A separate endpoint from #submit_specification_generation for the same reason that one is
    # separate from #submit_report: Platform moves the run to a different state for each, and a
    # shared endpoint would let a runner reach the approval transition by posting the wrong body.
    #
    # Platform decides the resulting run state; the response is read for what it DECIDED rather
    # than assumed. A rejected payload returns non-201 and is raised, so the runner fails closed
    # instead of printing a success it cannot substantiate.
    def submit_specification_publication(claim:, publication:)
      status, body = post_json("/api/runner/specification_publications",
                               { claim: claim, publication: publication })
      status == 201 ? body : raise_for(status, body)
    end

    # POST /api/runner/review_results (MVP-0033). Submits ONE structured review outcome for a
    # claimed review attempt. A sibling of the specification result endpoints, not a shape of
    # `submit_report`: this body carries a verdict about a frozen target and Platform records
    # it without touching Jira or GitHub.
    #
    # A 422 is a REFUSAL, not a transport failure — Platform validated the result and did not
    # accept it — so it raises like any other refusal and the caller reports the attempt as
    # failed rather than retrying a body that will never be accepted.
    def submit_review_result(claim:, review:)
      status, body = post_json("/api/runner/review_results", { claim: claim, review: review })
      status == 201 ? body : raise_for(status, body)
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

    # The workspace key is a path SEGMENT, so it is escaped rather than interpolated: a key
    # containing a slash or a space would otherwise silently address a different route.
    def connection_path(workspace_key)
      "/api/runner/workspace_connections/#{URI.encode_www_form_component(workspace_key.to_s)}"
    end

    # `payload` is always an explicit Hash at every call site: this method takes a keyword
    # argument, so a trailing `key: value` list would be parsed as keywords rather than converted
    # into the positional payload hash.
    def post_json(path, payload, headers: {})
      request_json(Net::HTTP::Post, path, payload: payload, headers: headers)
    end

    # One request shape for every verb. The bearer, the JSON headers, the timeouts, and the
    # transport-failure mapping are identical for a read and a write, so they live here once
    # rather than being re-derived per method.
    def request_json(verb, path, payload: nil, headers: {})
      uri = URI.join(base.to_s, path)
      request = verb.new(uri)
      request["Authorization"] = "Bearer #{token}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      headers.each { |name, value| request[name] = value }
      request.body = JSON.generate(payload) unless payload.nil?

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
      detail = message.empty? ? "" : ": #{message}"
      raise Unauthorized.new("Platform rejected the runner token (401)#{detail}", status: status) if status == 401
      raise NotFound.new("Platform found no such resource (404)#{detail}", status: status) if status == 404

      raise RequestFailed.new("Platform request failed (#{status})#{detail}", status: status)
    end
  end
end
