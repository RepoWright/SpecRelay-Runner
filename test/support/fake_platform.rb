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

  attr_reader :requests

  # `token` is the shared development token (fallback mode). `registration_token`
  # is the one-time token the runner presents to /registration; on success the
  # fake issues ISSUED_CREDENTIAL, which it then also accepts as a registered
  # bearer for the remaining endpoints (registered mode).
  def initialize(claim_payload:, token: EXPECTED_TOKEN, registration_token: EXPECTED_REGISTRATION_TOKEN,
                 lease_signal: { "state" => "active", "cancel_requested" => false })
    @claim_payload = claim_payload
    @token = token
    @registration_token = registration_token
    @requests = []
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
  def requests_to(path) = requests.select { |r| r[:path] == path }
  def last_report = requests_to("/api/runner/reports").last
  def last_registration = requests_to("/api/runner/registration").last

  # MVP-0013: the v1 protocol events the runner sent (the `event` sub-hash of each
  # /events request), in receipt order, and the terminal-result envelope uploaded
  # with the last report.
  def protocol_events = requests_to("/api/runner/events").map { |r| r[:body]["event"] }.compact
  def last_terminal_result = last_report&.dig(:body, "terminal_result")
  def protocol_attempt_id = @claim_payload.dig("claim", "runner_execution_id")

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
    if request[:path].to_s.split("?").first == "/api/runner/registration"
      presented == "Bearer #{@registration_token}"
    else
      presented == "Bearer #{@token}" || presented == "Bearer #{ISSUED_CREDENTIAL}"
    end
  end

  def route(request)
    case request[:path]
    when "/api/runner/registration" then registration
    when "/api/runner/claim" then claim
    when "/api/runner/events" then events(request)
    when "/api/runner/heartbeat" then [ 200, { acknowledged: true, state: "EXECUTING", lease: lease_signal } ]
    when "/api/runner/reports" then report(request)
    else [ 404, { error: "not found" } ]
    end
  end

  def registration
    [ 201, { contract_version: "mvp-0010",
             runner: { id: "local-dev-runner-1", public_id: "rnr_fake", display_name: "Local Developer Runner",
                       registered_at: "2026-07-24T00:00:00Z" },
             credential: ISSUED_CREDENTIAL, credential_env: "SPECRELAY_RUNNER_CREDENTIAL" } ]
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

  def respond(socket, status, body)
    json = JSON.generate(body)
    socket.write("HTTP/1.1 #{status} #{reason(status)}\r\n")
    socket.write("Content-Type: application/json\r\n")
    socket.write("Content-Length: #{json.bytesize}\r\n")
    socket.write("Connection: close\r\n\r\n")
    socket.write(json)
  end

  def reason(status)
    { 200 => "OK", 201 => "Created", 401 => "Unauthorized", 404 => "Not Found",
      422 => "Unprocessable Content", 500 => "Internal Server Error" }.fetch(status, "OK")
  end
end
