# frozen_string_literal: true

require "socket"
require "json"

# A minimal, dependency-free fake Platform runner API for the standalone runner
# runner tests. It is a real HTTP server on an ephemeral loopback port,
# so the runner exercises its real Net::HTTP client and the real process boundary
# — not an in-process stub. It records every request so tests can assert the
# claim/event/heartbeat/report contract the runner actually sent.
#
# It only implements what the runner needs and is intentionally dumb about
# domain rules (the Platform request specs cover the real server): it checks the
# bearer token, returns a scripted claim payload, and 201/200s the rest.
class FakePlatform
  EXPECTED_TOKEN = "fake-dev-token"
  ISSUED_CREDENTIAL = "src_fake-issued-credential"
  # The machine's own preview connector token, issued alongside the credential on every
  # successful exchange — including a reconnect, which replaces only this one.
  ISSUED_CONNECTOR_TOKEN = "cft_fake-issued-connector-token"

  # Guided connection. `enrollment_code` is the one-time code the runner
  # presents to /enrollment; on success the fake issues ISSUED_CREDENTIAL and then
  # accepts it as a registered bearer, exactly as Platform does. The readiness
  # verdict is scripted per-instance so a test can prove the runner renders the
  # state PLATFORM decided rather than its own opinion.
  attr_accessor :enrollment_code, :readiness_verdict, :enrollment_status

  # The runner identity the fake issues, and the `preview_connector` object it returns with it.
  # Both are settable: two machines must be able to arrive at two identities, and a test has to be
  # able to model an otherwise successful exchange whose connector object is absent or malformed.
  attr_accessor :runner_public_id, :preview_connector

  # The credential the fake believes this machine already holds. When the runner
  # presents it on the exchange, the fake responds `credential_unchanged` and issues nothing —
  # mirroring Platform's non-destructive reconnect.
  attr_accessor :held_credential

  # What the per-workspace GET reports. Scripted so a test can model a grant an
  # operator blocked, a workspace that was deactivated, and a healthy one — the runner must
  # render Platform's verdict rather than deciding for itself.
  attr_accessor :grant_state, :grant_failure_class, :workspace_active

  # Make DELETE answer 200 with a body that confirms nothing. Set to a Hash (rendered as
  # the JSON body) — `{}` for "no disconnected block", or a block with a missing/unrecognised
  # `outcome`. A non-JSON 200 is modelled by `unconfirmed_disconnect_raw`.
  attr_accessor :unconfirmed_disconnect, :unconfirmed_disconnect_raw

  # Script the publication endpoint's answer so a test can model
  # Platform READING a locally successful publication and REFUSING it. Set to a
  # `[status, body]` pair; the live case this models is the 422 that fired during the round's
  # live pass. Distinct from `unconfirmed_disconnect` because it must also cover 5xx, which
  # the runner treats as a transport fault rather than a refusal.
  attr_accessor :publication_response

  # The same scripted answer for the execution-report and specification-generation endpoints, so
  # a test can tell an accepted terminal result from a superseded, refused or unreachable one.
  attr_accessor :report_response, :generation_response

  # Script the review-result endpoint's answer, so a test can model Platform's
  # strict validation refusing a submission the runner considered fine.
  attr_accessor :review_response

  # A SEQUENCE of scripted answers, consumed one per delivery, so a test can model
  # Platform recording the verdict and then reporting that the ticket's Jira description update did
  # not complete — followed by whatever the identical retry earns. Takes precedence over
  # `review_response`, which stays the always-the-same script.
  attr_accessor :review_responses

  # The closed retirement plan Platform returns instead of a verdict for the FIRST
  # ACCEPT delivery. Set to `{ "digest" => ..., "pull_requests" => [...] }` to model a candidate
  # that omits current pull requests; nil keeps the ordinary one-request acceptance. The
  # completion delivery (the one carrying `retirement`) is always answered with the verdict, so
  # a test asserts on what the runner did between the two rather than on the fake's opinion.
  attr_accessor :retirement_plan

  # Replace the whole scripted assignment, so one fake can serve a guided connection and then
  # offer a claim of a DIFFERENT lane — the enrollment assignment and a review packet are
  # different documents, and a machine only ever sees them in that order.
  attr_writer :claim_payload

  # Lets a test model a SECOND workspace on the same Platform and the same machine, which is the
  # shape that used to orphan the first workspace's stored credential.
  def claim_payload_workspace_key=(key)
    @claim_payload["workspace"]["workspace_key"] = key
  end

  # The executor the workspace resolves to, as reported by the assignment and the
  # per-workspace GET. Scripted so a test can model the real Claude profile (which triggers the
  # bounded provider readiness check) as well as the deterministic fixture (which must not).
  def claim_payload_executor=(executor)
    @claim_payload["executor"] = executor
  end

  # A SECOND attempt at the same task, which is what an operator retry of a partially
  # published run is. The fake serves the same assignment again, so the retry is a genuine second
  # pass over one task workspace rather than a different run that happens to look similar.
  def offer_claim_again = tap { @claimed = false }

  attr_reader :requests

  # `token` is the shared development token (fallback mode). A guided connection issues
  # ISSUED_CREDENTIAL, which the fake then accepts as a registered bearer for the remaining
  # endpoints (registered mode).
  def initialize(claim_payload:, token: EXPECTED_TOKEN,
                 enrollment_code: nil, claim_limit: nil, release_status: 201,
                 lease_signal: { "state" => "active", "cancel_requested" => false })
    @claim_payload = claim_payload
    @claim_limit = claim_limit
    @claims_served = 0
    @release_status = release_status
    @token = token
    @enrollment_code = enrollment_code
    @enrollment_status = 201
    @runner_public_id = "rnr_fake"
    @preview_connector = { token: ISSUED_CONNECTOR_TOKEN }
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
    # The answer window starts OPEN and stays open until a test plays the Product
    # Owner, so a test that scripts nothing models a provider that is still waiting.
    @question = nil
    @question_answers = []
    @question_settle_state = nil
    @question_settle_after = 1
    @question_polls = 0
    @question_delivered = false
    @question_refusals = []
    @mutex = Mutex.new
  end

  # Flip the lease/cancellation signal the heartbeat/event responses
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

  # What the runner actually submitted for a claimed review. `review_results` being
  # EMPTY is as load-bearing as its contents: a refused checkout must not produce a verdict.
  #
  # A stale-target report and an explicit failure report go to the same
  # endpoint with different bodies, and are kept apart here for the same reason Platform keeps
  # them apart: "no verdict because the reviewer failed", "no verdict because the reviewer
  # produced nothing usable" and "no verdict because the target moved" are different facts.
  def review_submissions = requests_to("/api/runner/review_results")
  def review_results = review_submissions.select { |request| request[:body].to_h.key?("review") }
  def stale_reports = review_submissions.filter_map { |request| request[:body].to_h if request[:body].to_h.key?("stale") }
  def review_failures = review_submissions.filter_map { |request| request[:body].to_h["failure"] }
  def last_review = review_results.last&.dig(:body, "review")
  def last_review_failure = review_failures.last

  # The completion half of a two-phase ACCEPT. `retirement_completions` being EMPTY
  # while `review_results` is not is the shape of "the prepare landed and the closes did not", so
  # the two are counted separately rather than folded into one list.
  def retirement_completions = review_submissions.filter_map { |request| request[:body].to_h["retirement"] }
  def last_retirement_completion = retirement_completions.last

  # What the provider actually asked through the bridge. An EMPTY list is as
  # load-bearing as its contents: a locally refused request must never reach Platform.
  def executor_questions = requests_to("/api/runner/executor_questions")
  def asked_question = @mutex.synchronize { @question }
  def capture_failures = executor_questions.select { |r| r[:body].to_h.key?("capture_failure") }
  def question_submissions = executor_questions.reject { |r| r[:body].to_h.key?("capture_failure") }

  # F1 — the acknowledgement the runner sends once it has written the answers into the
  # live session's bridge.
  def delivery_acknowledgements
    requests.select { |r| r[:method] == "PATCH" && r[:path].start_with?("/api/runner/executor_questions/") }
  end

  # What Platform durably believes right now. ANSWERED is reachable ONLY through the
  # acknowledgement above, so a test cannot prove same-session delivery without the runner
  # having reported it.
  def question_state
    @mutex.synchronize { @question_delivered ? "ANSWERED" : (@question_settle_state || "LIVE_WAIT") }
  end

  # Play the Product Owner. The settlement lands on the Nth POLL rather than immediately, so the
  # runner's waiting loop is exercised rather than short-circuited by the submission response.
  def answer_question!(answers, after_polls: 1) = settle_question("ANSWER_READY", answers, after_polls)
  def release_question!(after_polls: 1) = settle_question("OFFLINE_WAIT", [], after_polls)

  def settle_question(state, answers, after_polls)
    @mutex.synchronize do
      @question_settle_state = state
      @question_answers = answers
      @question_settle_after = after_polls
    end
  end

  # Script a refusal (a 4xx the provider may correct) or a fault (5xx / a body Platform never
  # sends), so a test can prove the runner tells the two apart.
  attr_accessor :question_response

  # Script the NEXT submission as Platform's VALIDATION refusal — `{ accepted: false, errors }`, the
  # body a live provider may correct, and a different shape from an authority refusal's `error` —
  # while every later submission is accepted, so a test can play the observed refuse-then-correct
  # chain rather than a refusal that never ends.
  def refuse_next_question!(errors)
    @mutex.synchronize { @question_refusals << [ 422, { accepted: false, errors: errors } ] }
  end

  # F1: a slow answer poll, so a test can put the provider's exit INSIDE the poll the
  # runner is waiting on, and a scripted answer for the acknowledgement itself.
  attr_accessor :question_poll_delay, :delivery_response

  # The recorded portable checkpoint this fake hands back on the claim-bound download path, and
  # a scripted response so a test can put a transfer failure in front of a runner that has not
  # yet built anything.
  attr_accessor :checkpoint_payload, :checkpoint_response

  # How long a live-log response is withheld, so a test can put a Platform
  # that has stopped answering UNDERNEATH an attempt that is finishing. Only `log.*` events are
  # held, and only on their own connection thread — a delay that also stalled this fake's accept
  # loop would postpone the result-path requests the test measures and prove nothing.
  attr_accessor :log_event_delay
  def last_enrollment = requests_to("/api/runner/enrollment").last
  def last_enrollment_preview = requests_to("/api/runner/enrollment_preview").last
  def last_readiness_report = requests_to("/api/runner/workspace_connections").last
  # What the runner reported about a specification-generation attempt, and — just
  # as load-bearing for criterion 15 — the fact that nothing was sent to /reports.
  def specification_generations = requests_to("/api/runner/specification_generations")

  # What Platform would have KEPT of the last generation result, not the raw body.
  #
  # The distinction is a real defect this closes. Platform's controller takes an allowlist and the
  # result contract closes the document with `additionalProperties: false`, so a field the
  # contract does not declare is dropped on arrival and never stored. This fake used to hand back
  # whatever it was sent, which meant a runner test could assert a field that Platform silently
  # discards and pass — the runner looked correct while the operator's run page showed nothing.
  #
  # Raising rather than quietly filtering, because the quiet version fails a later assertion with
  # a bare nil and sends the reader looking in the wrong place. A test may only assert what the
  # published contract admits; widening that is a contract change, which is reviewed.
  def last_specification_generation
    body = specification_generations.last&.dig(:body, "generation")
    return nil if body.nil?

    undeclared = body.keys - self.class.generation_result_keys
    unless undeclared.empty?
      raise "the runner reported #{undeclared.sort.join(', ')}, which " \
            "contracts/runner/v1/specification-generation-result.schema.json does not declare. " \
            "Platform drops an undeclared field on arrival, so asserting it here would prove " \
            "nothing about what an operator sees."
    end

    body
  end
  # What the runner reported about a publication attempt, and the fact that a
  # publication claim sent nothing to the generation endpoint.
  def specification_publications = requests_to("/api/runner/specification_publications")
  def last_specification_publication = specification_publications.last&.dig(:body, "publication")

  # The v1 protocol events the runner sent (the `event` sub-hash of each
  # /events request), in receipt order, and the terminal-result envelope uploaded
  # with the last report.
  def protocol_events = requests_to("/api/runner/events").map { |r| r[:body]["event"] }.compact
  def last_terminal_result = last_report&.dig(:body, "terminal_result")
  def protocol_attempt_id = @claim_payload.dig("claim", "runner_execution_id")

  # The workspace grants this fake holds for the calling runner. It starts as the one
  # workspace the claim payload models; a test clears or inspects it to model a grant an operator
  # revoked in Platform, and DELETE removes from it, which is what makes the fake's idempotency
  # real rather than assumed.
  def grants = @grants ||= [ @claim_payload.dig("workspace", "workspace_key") ]

  # Authorize no work at all, so a test can assert what the runner PRINTS while resolving which
  # workspace to claim for without also executing a whole run. "Nothing eligible" is a normal,
  # exit-0 poll, so the resolution is proven on the real code path rather than a stubbed one.
  def offer_no_work! = @claimed = true

  # Offer the SAME assignment again, which is what real Platform does after
  # `bin/platform runner retry-publication` returns a blocked run to the publishable state. It
  # is how a retry is exercised end to end through the CLI rather than by calling a publisher
  # twice in-process — and the retry-idempotency rule is about what a second CLAIM does.
  def offer_again! = @claimed = false

  private

  def handle(socket)
    request = read_request(socket)
    return respond(socket, 401, { error: "unauthorized" }) unless authorized?(request)

    status, body = route(request)
    @requests << request.merge(response_status: status)
    held = hold(socket, request, status, body)
    respond(socket, status, body) unless held
  rescue StandardError => e
    respond(socket, 500, { error: e.message })
  ensure
    socket.close unless held
  end

  # A live-log response withheld for `log_event_delay`, answered on its own thread so this fake
  # keeps serving the requests the attempt's RESULT path makes while one progress request hangs.
  def hold(socket, request, status, body)
    return nil unless @log_event_delay && request[:path] == "/api/runner/events" &&
                      request.dig(:body, "event", "event_type").to_s.start_with?("log.")

    Thread.new do
      sleep @log_event_delay
      respond(socket, status, body)
    rescue StandardError
      nil # the runner gave up on this response, which is the point of the delay
    ensure
      socket.close
    end
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

  # The enrollment endpoints authenticate the one-time connection code; every other
  # endpoint accepts the shared development token OR the issued registered credential,
  # mirroring Platform's two authentication modes.
  def authorized?(request)
    presented = request[:headers]["authorization"].to_s
    case request[:path].to_s.split("?").first
    when "/api/runner/enrollment", "/api/runner/enrollment_preview"
      presented == "Bearer #{@enrollment_code}"
    else presented == "Bearer #{@token}" || presented == "Bearer #{ISSUED_CREDENTIAL}"
    end
  end

  def route(request)
    case request[:path]
    when "/api/runner/enrollment" then enrollment(request)
    when "/api/runner/enrollment_preview" then code_spent? ? spent_code : [ 200, assignment ]
    when "/api/runner/workspace_connections" then workspace_connection(request)
    when %r{\A/api/runner/workspace_connections/(?<key>.+)\z} then member(request, Regexp.last_match[:key])
    when "/api/runner/claim" then claim
    when "/api/runner/events" then events(request)
    when "/api/runner/heartbeat" then [ 200, { acknowledged: true, state: "EXECUTING", lease: lease_signal } ]
    when "/api/runner/reports" then report(request)
    # A runner abandoning its own claim before it executed anything. The fake answers
    # what Platform answers, because the runner PRINTS the run state back and a constant would
    # let a released claim and an unreleased one look identical in the operator's output.
    when "/api/runner/claim_releases" then claim_release
    when "/api/runner/specification_generations" then specification_generation(request)
    when "/api/runner/specification_publications" then specification_publication(request)
    when "/api/runner/review_results" then review_result(request)
    when "/api/runner/executor_questions" then executor_question(request)
    when %r{\A/api/runner/executor_questions/[^/]+/checkpoint\z} then executor_question_checkpoint
    when %r{\A/api/runner/executor_questions/(?<id>.+)\z} then executor_question_member(request)
    else [ 404, { error: "not found" } ]
    end
  end

  # The question bridge's endpoint. Deliberately dumb about the document schema
  # (Platform's own specs cover that) but NOT dumb about the state it reports back: the runner
  # branches on it to decide whether to keep the provider alive, hand it the answers, or end
  # it, so a fake that always said LIVE_WAIT would let every one of those branches pass
  # vacuously.
  def executor_question(request)
    # The capture-failure body is answered BEFORE any scripted response: a test scripts a fault
    # to provoke the failure, and having that same script also reject the report of it would
    # make "the runner told Platform" unprovable.
    #
    # The execution state is the one Platform KEPT, because the runner classifies the attempt
    # from it: a release that already won leaves the execution terminal and
    # AWAITING_INPUT, and a genuinely lost question does not.
    return [ 201, { contract_version: "mvp-0036", execution: { state: kept_execution_state } } ] if
      request[:body].to_h.key?("capture_failure")
    refusal = @mutex.synchronize { @question_refusals.shift }
    return refusal if refusal
    return @question_response if @question_response

    @mutex.synchronize { @question = request.dig(:body, "question").to_h }
    question_body(201, "LIVE_WAIT", [])
  end

  def kept_execution_state = question_state == "OFFLINE_WAIT" ? "AWAITING_INPUT" : "INPUT_CAPTURE_FAILED"

  def executor_question_member(request)
    request[:method] == "PATCH" ? confirm_delivery : executor_question_state
  end

  # The claim-bound download. The bytes travel base64-encoded exactly as they were submitted,
  # because the runner verifies them against the size and checksum the assignment recorded.
  #
  # No version field: the runner declares its own on the way out and never reads the server's, so
  # a fixture that echoed one would only be an unverified copy of a Platform constant.
  def executor_question_checkpoint
    return @checkpoint_response if @checkpoint_response
    return [ 404, { error: "no checkpoint for the given claim" } ] if @checkpoint_payload.nil?

    [ 200, { payload: @checkpoint_payload } ]
  end

  # The POLL. Every read moves the counter, so a settlement scheduled for the Nth poll happens
  # while the runner is genuinely waiting.
  def executor_question_state
    sleep @question_poll_delay if @question_poll_delay
    state, answers = @mutex.synchronize do
      @question_polls += 1
      settled = @question_settle_state && @question_polls >= @question_settle_after
      [ settled ? @question_settle_state : "LIVE_WAIT", settled ? @question_answers : [] ]
    end
    question_body(200, state, answers)
  end

  # The delivery acknowledgement, with Platform's own compare-and-set: only an answer that was
  # waiting to be delivered becomes ANSWERED, and a replay changes nothing.
  def confirm_delivery
    return @delivery_response if @delivery_response

    @mutex.synchronize { @question_delivered = true if @question_settle_state == "ANSWER_READY" }
    question_body(200, question_state, @question_answers)
  end

  def question_body(status, state, answers)
    [ status, { contract_version: "mvp-0036",
                question: { id: "exq_fake", state: state, deadline_at: "2026-08-13T12:00:00Z",
                            remaining_seconds: state == "LIVE_WAIT" ? 600 : 0, answers: answers } } ]
  end


  # The specification-generation result endpoint. Deliberately dumb about domain
  # rules (Platform's own request specs cover the real state transitions) but NOT dumb about
  # the run state it reports back: the runner prints it, and a fake that always said the same
  # thing would let a generated run and a refused one look identical in the runner's output.
  # The committed result contract's declared top-level keys.
  #
  # This fake records whatever body it is handed, which is what made it possible for a runner
  # test to assert a field the REAL Platform silently drops on arrival and still pass. Platform's
  # controller takes an allowlist and the contract closes the document with
  # `additionalProperties: false`; mirroring that here is what keeps a green runner test a
  # statement about something Platform would actually store.
  #
  # Read from the workspace contract rather than restated, so the only way to widen what a runner
  # test may assert is to widen the published contract — which is reviewed.
  # The contract lives in the WORKSPACE, and this repository is checked out in one of two
  # supported places relative to it:
  #
  #   standalone  <parent>/specrelay-runner        and <parent>/contracts
  #   task        <workspace>/repositories/specrelay-runner and <workspace>/contracts
  #
  # Both are stated, in that order, rather than searched upwards: a resolver that walked parents
  # would silently bind to whatever `contracts` directory it met first, which is exactly the kind
  # of accident this fixture exists to prevent. Neither copies the schema, and neither weakens the
  # check — the authoritative published document is read in both layouts.
  CONTRACT_RELATIVE_PATH = "contracts/runner/v1/specification-generation-result.schema.json"
  SUPPORTED_CONTRACT_ROOTS = [
    File.expand_path("../../..", __dir__),
    File.expand_path("../../../..", __dir__)
  ].freeze

  def self.generation_result_contract
    @generation_result_contract ||= contract_in(SUPPORTED_CONTRACT_ROOTS)
  end

  # The first of the STATED roots that actually holds the contract. Public so both supported
  # layouts can be exercised against synthetic roots rather than by moving this checkout.
  #
  # It fails loudly and says where it looked. A fixture that quietly skipped the check would let a
  # runner test assert a field Platform drops on arrival and still pass, which is the defect this
  # contract read exists to catch.
  def self.contract_in(roots)
    found = roots.map { |root| File.join(root, CONTRACT_RELATIVE_PATH) }.find { |path| File.file?(path) }
    return found if found

    raise "could not find #{CONTRACT_RELATIVE_PATH} in any supported layout. Looked in: " \
          "#{roots.join(', ')}. The workspace contract is authoritative; do not copy it into " \
          "this repository."
  end

  def self.generation_result_keys
    @generation_result_keys ||=
      JSON.parse(File.read(generation_result_contract)).fetch("properties").keys.freeze
  end

  def specification_generation(request)
    return @generation_response if @generation_response

    outcome = request.dig(:body, "generation", "outcome").to_s
    return [ 422, { error: "generation outcome is required" } ] if outcome.empty?

    [ 201, { outcome: outcome,
             execution_state: outcome == "generated" ? "COMPLETED" : "GENERATION_REFUSED",
             run_state: outcome == "generated" ? "AWAITING_SPECIFICATION_PUBLICATION" :
                          "BLOCKED_SPECIFICATION_GENERATION" } ]
  end

  # The specification-publication result endpoint. Dumb about domain rules for the
  # same reason its sibling is — Platform's own specs cover the real validation — but honest
  # about the run state it reports back, because the runner prints it and a fake that always
  # said "published" would let a fail-closed path look identical to a success in the output.
  def review_result(request)
    return review_responses.shift if review_responses&.any?
    return review_response if review_response
    return [ 201, { contract_version: "mvp-0033",
                    review: { attempt_id: "rvt_fake", state: "STALE", outcome: nil } } ] if request[:body].to_h.key?("stale")
    return [ 201, { contract_version: "mvp-0033",
                    review: { attempt_id: "rvt_fake", state: "FAILED", outcome: nil } } ] if request[:body].to_h.key?("failure")

    # The state Platform really records, not one constant for every verdict: NEEDS_INPUT leaves
    # the attempt awaiting a Product Owner answer, and the runner checks the acknowledgement
    # against the ending its delivery produces.
    review = request[:body].to_h["review"].to_h
    return retiring_answer if retirement_plan && review["outcome"] == "ACCEPT" && !request[:body].to_h.key?("retirement")

    state = review["outcome"] == "NEEDS_INPUT" ? "AWAITING_ANSWER" : "COMPLETED"
    [ 201, { contract_version: "mvp-0033",
             review: { attempt_id: "rvt_fake", state: state, outcome: review["outcome"] } } ]
  end

  # The prepare answer: no verdict yet, and the exact pull requests the runner is
  # authorized to close.
  def retiring_answer
    [ 201, { contract_version: "mvp-0033",
             review: { attempt_id: "rvt_fake", state: "RETIRING", outcome: nil },
             retirement_plan: retirement_plan } ]
  end

  def specification_publication(request)
    return @publication_response if @publication_response

    outcome = request.dig(:body, "publication", "outcome").to_s
    return [ 422, { error: "publication outcome is required" } ] if outcome.empty?

    published = outcome == "published"
    [ 201, { outcome: outcome,
             execution_state: published ? "COMPLETED" : "PUBLICATION_FAILED",
             run_state: published ? "AWAITING_SPECIFICATION_APPROVAL" : "BLOCKED_SPECIFICATION_PUBLICATION" } ]
  end

  # The per-workspace member routes. GET describes this runner's grant; DELETE
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

  # A 200 that is NOT a confirmation must be expressible, because that is the shape the
  # runner used to accept. `unconfirmed_disconnect` replaces the body while
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

  # Guided connection: consume the code and return the durable credential once — unless
  # the runner presented the credential it already holds, in which case nothing is issued.
  def enrollment(request)
    return spent_code if code_spent?

    # The held credential arrives in a HEADER, never the body, so the
    # fake reads it where Platform reads it.
    presented = request.dig(:headers, "x-specrelay-runner-credential")
    unchanged = !@held_credential.nil? && presented == @held_credential
    @consumed_codes << @enrollment_code
    [ @enrollment_status,
      assignment.merge(
        runner: { id: "host-runner", public_id: @runner_public_id, display_name: "host runner",
                  connection_public_id: "rwc_fake", reconnected: unchanged },
        credential: unchanged ? nil : ISSUED_CREDENTIAL,
        credential_unchanged: unchanged,
        preview_connector: @preview_connector
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

  # V1 event ingest: classify a repeat (attempt_id, sequence) as an
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
    return [ 401, { error: "claim_limit_reached" } ] if claim_limit_reached?
    if @claimed
      [ 200, { claimed: false, reason: "already claimed" } ]
    else
      @claimed = true
      @claims_served += 1
      [ 201, @claim_payload ]
    end
  end

  # The BOUND a session-termination test needs. A released run really is offered
  # again, forever, so a `loop` that fails to stop does not fail a test: it never returns. Past
  # this limit the fake answers the one thing the loop treats as fatal, so a session that should
  # have stopped by itself ends with a claim count that says it did not.
  def claim_limit_reached? = !@claim_limit.nil? && @claims_served >= @claim_limit

  # A released run is CLAIMABLE AGAIN, which is the whole point of releasing it and
  # the reason a repeated claim loop was possible at all. The fake said "already claimed"
  # afterwards, so a session that reclaimed its own refusal looked healthy here while the live
  # runner refused the same run twelve times.
  #
  # `release_status` models the release Platform did NOT accept. The run then stays
  # CLAIMED here, because that is what actually happens: nothing was released, and the lease has
  # to expire before any machine sees the run again.
  def claim_release
    return [ @release_status, { error: "release_rejected" } ] unless @release_status == 201

    @claimed = false
    [ 201, { outcome: "released", run_state: "AWAITING_EXECUTION_REPORT" } ]
  end

  def report(request)
    return @report_response if @report_response

    status = request.dig(:body, "report", "files")&.any? ? 201 : 422
    [ status, { outcome: "completed", execution_state: "COMPLETED",
               report: { round_label: "001-initial", status: "succeeded", url: "#{base_url}/reports/rpt_fake" },
               run_state: "COMPLETED" } ]
  end

  # `:raw` is an escape hatch for a 200 whose body is NOT JSON — an HTML error page from
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
