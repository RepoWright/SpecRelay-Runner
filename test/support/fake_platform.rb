# frozen_string_literal: true

require "socket"
require "json"

# A minimal, dependency-free fake Platform runner API for the standalone runner
# runner tests (MVP-0010). It is a real HTTP server on an ephemeral loopback port,
# so the runner exercises its real Net::HTTP client and the real process boundary
# — not an in-process stub. It records every request so tests can assert the
# claim/event/heartbeat/report contract the runner actually sent.
#
# It only implements what the runner needs and is intentionally dumb about
# domain rules (the Platform request specs cover the real server): it checks the
# bearer token, returns a scripted claim payload, and 201/200s the rest.
class FakePlatform
  EXPECTED_TOKEN = "fake-dev-token"
  EXPECTED_REGISTRATION_TOKEN = "srt_fake-registration-token"
  ISSUED_CREDENTIAL = "src_fake-issued-credential"

  # MVP-0017 guided connection. `enrollment_code` is the one-time code the runner
  # presents to /enrollment; on success the fake issues ISSUED_CREDENTIAL and then
  # accepts it as a registered bearer, exactly as Platform does. The readiness
  # verdict is scripted per-instance so a test can prove the runner renders the
  # state PLATFORM decided rather than its own opinion.
  attr_accessor :enrollment_code, :readiness_verdict, :enrollment_status

  # Round 002: the credential the fake believes this machine already holds. When the runner
  # presents it on the exchange, the fake responds `credential_unchanged` and issues nothing —
  # mirroring Platform's non-destructive reconnect (review-001 F3).
  attr_accessor :held_credential

  # MVP-0021: what the per-workspace GET reports. Scripted so a test can model a grant an
  # operator blocked, a workspace that was deactivated, and a healthy one — the runner must
  # render Platform's verdict rather than deciding for itself.
  attr_accessor :grant_state, :grant_failure_class, :workspace_active

  # CR-001: make DELETE answer 200 with a body that confirms nothing. Set to a Hash (rendered as
  # the JSON body) — `{}` for "no disconnected block", or a block with a missing/unrecognised
  # `outcome`. A non-JSON 200 is modelled by `unconfirmed_disconnect_raw`.
  attr_accessor :unconfirmed_disconnect, :unconfirmed_disconnect_raw

  # Lets a test model a SECOND workspace on the same Platform and the same machine, which is the
  # shape that used to orphan the first workspace's stored credential (review-002, F3 residual).
  def claim_payload_workspace_key=(key)
    @claim_payload["workspace"]["workspace_key"] = key
  end

  # MVP-0021: the executor the workspace resolves to, as reported by the assignment and the
  # per-workspace GET. Scripted so a test can model the real Claude profile (which triggers the
  # bounded provider readiness check) as well as the deterministic fixture (which must not).
  def claim_payload_executor=(executor)
    @claim_payload["executor"] = executor
  end

  attr_reader :requests

  # `token` is the shared development token (fallback mode). `registration_token`
  # is the one-time token the runner presents to /registration; on success the
  # fake issues ISSUED_CREDENTIAL, which it then also accepts as a registered
  # bearer for the remaining endpoints (registered mode).
  def initialize(claim_payload:, token: EXPECTED_TOKEN, registration_token: EXPECTED_REGISTRATION_TOKEN,
                 enrollment_code: nil,
                 lease_signal: { "state" => "active", "cancel_requested" => false })
    @claim_payload = claim_payload
    @token = token
    @registration_token = registration_token
    @enrollment_code = enrollment_code
    @enrollment_status = 201
    @grant_state = "ready"
    @grant_failure_class = nil
    @workspace_active = true
    @readiness_verdict = { "state" => "ready", "failure_class" => nil,
                           "detail" => "Runner validated its local checkout and reported the executor ready." }
    @requests = []
    # Enrollment codes are SINGLE USE on real Platform, so they are here too. Without this the
    # fake could not tell "the code was never spent" from "the code was spent and reused", and
    # every "the same code still works" assertion would pass vacuously.
    @consumed_codes = []
    @server = TCPServer.new("127.0.0.1", 0)
    @claimed = false
    @lease_signal = lease_signal
    @seen_sequences = []
    @mutex = Mutex.new
  end

  # MVP-0012: flip the lease/cancellation signal the heartbeat/event responses
  # carry, so a test can prove the runner OBSERVES an expiry/cancellation and
  # stops without uploading a success report.
  def signal_cancelled! = set_signal("state" => "cancelled", "cancel_requested" => true)
  def signal_expired! = set_signal("state" => "expired", "cancel_requested" => false)
  def set_signal(signal) = @mutex.synchronize { @lease_signal = signal }
  def lease_signal = @mutex.synchronize { @lease_signal }

  def port = @server.addr[1]
  def base_url = "http://127.0.0.1:#{port}"

  def start
    @thread = Thread.new do
      loop do
        socket = @server.accept
        handle(socket)
      rescue IOError, Errno::EBADF
        break
      end
    end
    self
  end

  def stop
    @server.close
    @thread&.kill
  end

  # Convenience accessors for assertions.
  # A spent code is indistinguishable from a wrong one, as on real Platform.
  def code_spent? = @consumed_codes.include?(@enrollment_code)
  def spent_code = [ 401, { error: "invalid_enrollment_code" } ]

  def requests_to(path) = requests.select { |r| r[:path] == path }
  def last_report = requests_to("/api/runner/reports").last
  def last_registration = requests_to("/api/runner/registration").last
  def last_enrollment = requests_to("/api/runner/enrollment").last
  def last_enrollment_preview = requests_to("/api/runner/enrollment_preview").last
  def last_readiness_report = requests_to("/api/runner/workspace_connections").last
  # MVP-0026: what the runner reported about a specification-generation attempt, and — just
  # as load-bearing for criterion 15 — the fact that nothing was sent to /reports.
  def specification_generations = requests_to("/api/runner/specification_generations")
  def last_specification_generation = specification_generations.last&.dig(:body, "generation")

  # MVP-0013: the v1 protocol events the runner sent (the `event` sub-hash of each
  # /events request), in receipt order, and the terminal-result envelope uploaded
  # with the last report.
  def protocol_events = requests_to("/api/runner/events").map { |r| r[:body]["event"] }.compact
  def last_terminal_result = last_report&.dig(:body, "terminal_result")
  def protocol_attempt_id = @claim_payload.dig("claim", "runner_execution_id")

  # MVP-0021: the workspace grants this fake holds for the calling runner. It starts as the one
  # workspace the claim payload models; a test clears or inspects it to model a grant an operator
  # revoked in Platform, and DELETE removes from it, which is what makes the fake's idempotency
  # real rather than assumed.
  def grants = @grants ||= [ @claim_payload.dig("workspace", "workspace_key") ]

  # Authorize no work at all, so a test can assert what the runner PRINTS while resolving which
  # workspace to claim for without also executing a whole run. "Nothing eligible" is a normal,
  # exit-0 poll, so the resolution is proven on the real code path rather than a stubbed one.
  def offer_no_work! = @claimed = true

  private

  def handle(socket)
    request = read_request(socket)
    return respond(socket, 401, { error: "unauthorized" }) unless authorized?(request)

    status, body = route(request)
    @requests << request.merge(response_status: status)
    respond(socket, status, body)
  rescue StandardError => e
    respond(socket, 500, { error: e.message })
  ensure
    socket.close
  end

  def read_request(socket)
    request_line = socket.gets.to_s
    method, path, = request_line.split(" ")
    headers = {}
    while (line = socket.gets) && line != "\r\n" && !line.chomp.empty?
      key, value = line.chomp.split(": ", 2)
      headers[key.to_s.downcase] = value
    end
    body = read_body(socket, headers)
    { method: method, path: path.to_s.split("?").first, headers: headers, body: parse(body) }
  end

  def read_body(socket, headers)
    length = headers["content-length"].to_i
    length.positive? ? socket.read(length) : ""
  end

  def parse(body)
    body.to_s.strip.empty? ? {} : JSON.parse(body)
  rescue JSON::ParserError
    {}
  end

  # The registration endpoint authenticates the one-time registration token; every
  # other endpoint accepts the shared development token OR the issued registered
  # credential, mirroring Platform's two authentication modes.
  def authorized?(request)
    presented = request[:headers]["authorization"].to_s
    case request[:path].to_s.split("?").first
    when "/api/runner/registration" then presented == "Bearer #{@registration_token}"
    when "/api/runner/enrollment", "/api/runner/enrollment_preview"
      presented == "Bearer #{@enrollment_code}"
    else presented == "Bearer #{@token}" || presented == "Bearer #{ISSUED_CREDENTIAL}"
    end
  end

  def route(request)
    case request[:path]
    when "/api/runner/registration" then registration
    when "/api/runner/enrollment" then enrollment(request)
    when "/api/runner/enrollment_preview" then code_spent? ? spent_code : [ 200, assignment ]
    when "/api/runner/workspace_connections" then workspace_connection(request)
    when %r{\A/api/runner/workspace_connections/(?<key>.+)\z} then member(request, Regexp.last_match[:key])
    when "/api/runner/claim" then claim
    when "/api/runner/events" then events(request)
    when "/api/runner/heartbeat" then [ 200, { acknowledged: true, state: "EXECUTING", lease: lease_signal } ]
    when "/api/runner/reports" then report(request)
    when "/api/runner/specification_generations" then specification_generation(request)
    else [ 404, { error: "not found" } ]
    end
  end

  # MVP-0026: the specification-generation result endpoint. Deliberately dumb about domain
  # rules (Platform's own request specs cover the real state transitions) but NOT dumb about
  # the run state it reports back: the runner prints it, and a fake that always said the same
  # thing would let a generated run and a refused one look identical in the runner's output.
  def specification_generation(request)
    outcome = request.dig(:body, "generation", "outcome").to_s
    return [ 422, { error: "generation outcome is required" } ] if outcome.empty?

    [ 201, { outcome: outcome,
             execution_state: outcome == "generated" ? "COMPLETED" : "GENERATION_REFUSED",
             run_state: outcome == "generated" ? "AWAITING_SPECIFICATION_PUBLICATION" :
                          "BLOCKED_SPECIFICATION_GENERATION" } ]
  end

  # MVP-0021: the per-workspace member routes. GET describes this runner's grant; DELETE
  # removes it and is idempotent, exactly as Platform's own controller is — the runner's
  # branching depends on that, so a fake that 404'd the second delete would let a broken
  # idempotency assumption pass.
  def member(request, key)
    case request[:method]
    when "GET" then describe_connection(key)
    when "DELETE" then disconnect_connection(key)
    else [ 404, { error: "not found" } ]
    end
  end

  def describe_connection(key)
    return [ 404, { error: "this runner has no connection for workspace '#{key}'" } ] unless grants.include?(key)

    [ 200, { contract_version: "mvp-0021",
             runner: { public_id: "rnr_fake", runner_id: "host-runner", display_name: "host runner",
                       revoked: false },
             connection: connection_state(key),
             project: { slug: "tiny-demo", name: "Tiny Demo" },
             workspace: assignment.fetch(:workspace).merge(project_slug: "tiny-demo", active: workspace_active),
             executor: @claim_payload.fetch("executor") } ]
  end

  def connection_state(key)
    { workspace_key: key, public_id: "rwc_fake", state: grant_state,
      ready: grant_state == "ready", failure_class: grant_failure_class,
      detail: "Runner validated its local checkout and reported the executor ready.",
      connected_at: "2026-07-24T00:00:00Z", ready_at: "2026-07-24T00:00:00Z",
      last_reported_at: "2026-07-24T00:00:00Z",
      reported_repository_url: @claim_payload.dig("workspace", "repository_url"),
      reported_default_branch: @claim_payload.dig("workspace", "default_branch") }
  end

  # CR-001: a 200 that is NOT a confirmation must be expressible, because that is the shape the
  # runner used to accept (review-001 F2). `unconfirmed_disconnect` replaces the body while
  # keeping the 200, modelling a proxy, a captive portal, or another service on that port — and,
  # deliberately, the grant is NOT removed, so a test can assert the runner refused to treat it
  # as done AND that Platform-side state is untouched.
  def disconnect_connection(key)
    return [ 200, { raw: @unconfirmed_disconnect_raw } ] if @unconfirmed_disconnect_raw
    return [ 200, @unconfirmed_disconnect ] if @unconfirmed_disconnect

    removed = grants.delete(key)
    [ 200, { contract_version: "mvp-0021",
             disconnected: { workspace_key: key,
                             outcome: removed ? "revoked" : "already_absent",
                             routing_label: removed ? "tiny-demo/#{key}" : nil,
                             detail: removed ? "Platform removed this runner's grant for tiny-demo/#{key}." :
                                       "Platform holds no grant for this runner on '#{key}'." } } ]
  end

  def registration
    [ 201, { contract_version: "mvp-0010",
             runner: { id: "local-dev-runner-1", public_id: "rnr_fake", display_name: "Local Developer Runner",
                       registered_at: "2026-07-24T00:00:00Z" },
             credential: ISSUED_CREDENTIAL, credential_env: "SPECRELAY_RUNNER_CREDENTIAL" } ]
  end

  # The non-secret assignment, identical for the preview and the exchange. The workspace block
  # deliberately mirrors the claim payload's, so a connection and a later claim describe the same
  # workspace.
  def assignment
    workspace = @claim_payload.fetch("workspace")
    { contract_version: "mvp-0017",
      platform: { base_url: base_url },
      project: { slug: "tiny-demo", name: "Tiny Demo" },
      workspace: workspace.slice("project_key", "workspace_key", "display_name",
                                 "repository_url", "default_branch"),
      executor: @claim_payload.fetch("executor") }
  end

  # MVP-0017 guided connection: consume the code and return the durable credential once — unless
  # the runner presented the credential it already holds, in which case nothing is issued.
  def enrollment(request)
    return spent_code if code_spent?

    # The held credential arrives in a HEADER, never the body (round 003, review-002 N1), so the
    # fake reads it where Platform reads it.
    presented = request.dig(:headers, "x-specrelay-runner-credential")
    unchanged = !@held_credential.nil? && presented == @held_credential
    @consumed_codes << @enrollment_code
    [ @enrollment_status,
      assignment.merge(
        runner: { id: "host-runner", public_id: "rnr_fake", display_name: "host runner",
                  connection_public_id: "rwc_fake", reconnected: unchanged },
        credential: unchanged ? nil : ISSUED_CREDENTIAL,
        credential_unchanged: unchanged
      ) ]
  end

  # Platform — not the runner — decides the state, so the verdict is scripted here and
  # the runner must render whatever comes back.
  def workspace_connection(request)
    [ 201, { contract_version: "mvp-0017",
             connection: { public_id: "rwc_fake",
                           workspace_key: request.dig(:body, "workspace_key"),
                           state: readiness_verdict["state"],
                           failure_class: readiness_verdict["failure_class"],
                           detail: readiness_verdict["detail"],
                           ready_at: "2026-07-26T00:00:00Z" } } ]
  end

  # MVP-0013 v1 event ingest: classify a repeat (attempt_id, sequence) as an
  # idempotent duplicate, everything else as accepted_current. This is a dumb
  # stand-in; the real Platform request specs cover full classification.
  def events(request)
    event = request.dig(:body, "event") || {}
    sequence = event["sequence"]
    key = [ event["attempt_id"], sequence ]
    duplicate = !sequence.nil? && @seen_sequences.include?(key)
    @seen_sequences << key if sequence
    classification = duplicate ? "duplicate" : "accepted_current"
    [ 201, { recorded: true, classification: classification, duplicate: duplicate,
             event: { sequence: sequence, event_type: event["event_type"], classification: classification },
             lease: lease_signal } ]
  end

  def claim
    if @claimed
      [ 200, { claimed: false, reason: "already claimed" } ]
    else
      @claimed = true
      [ 201, @claim_payload ]
    end
  end

  def report(request)
    status = request.dig(:body, "report", "files")&.any? ? 201 : 422
    [ status, { outcome: "completed", execution_state: "COMPLETED",
               report: { round_label: "001-initial", status: "succeeded", url: "#{base_url}/reports/rpt_fake" },
               run_state: "COMPLETED" } ]
  end

  # CR-001: `:raw` is an escape hatch for a 200 whose body is NOT JSON — an HTML error page from
  # a proxy or a captive portal. The runner's client parses that to `{}`, which is exactly the
  # input that used to reach the operator as "Platform confirmed".
  def respond(socket, status, body)
    raw = body.is_a?(Hash) && body[:raw]
    payload = raw || JSON.generate(body)
    socket.write("HTTP/1.1 #{status} #{reason(status)}\r\n")
    socket.write("Content-Type: #{raw ? 'text/html' : 'application/json'}\r\n")
    socket.write("Content-Length: #{payload.bytesize}\r\n")
    socket.write("Connection: close\r\n\r\n")
    socket.write(payload)
  end

  def reason(status)
    { 200 => "OK", 201 => "Created", 401 => "Unauthorized", 404 => "Not Found",
      422 => "Unprocessable Content", 500 => "Internal Server Error" }.fetch(status, "OK")
  end
end
