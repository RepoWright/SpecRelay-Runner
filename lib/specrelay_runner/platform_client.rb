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

    # The exceptions that leave a request's fate UNKNOWN, and only those.
    #
    # The first three happen before Platform can have read anything. The last three happen after
    # the request was sent — the connection dies mid-exchange, which is precisely the "Platform
    # committed it and the answer vanished" case a review delivery must survive (review-001 F4).
    # Deliberately a named list rather than StandardError: a bug in this client, a JSON failure,
    # or a programming error must surface, not be retried as weather.
    TRANSPORT_FAILURES = [ SocketError, Errno::ECONNREFUSED, Timeout::Error,
                           EOFError, Errno::ECONNRESET, Errno::EPIPE ].freeze

    # The durable ending each review delivery produces, as Platform names it back (review-002
    # F1). A delivery is confirmed by ITS OWN ending and by no other: a failure answered with
    # `WAITING` describes an attempt that is queued for a runner, not one that ended, and
    # accepting it let this machine exit believing Platform held something it does not.
    #
    # Only these two endings are stated as constants. A verdict's ending is derived from the
    # outcome that was submitted rather than tabulated, so the supported outcome set stays
    # Platform's alone (design 1) and no copy of it appears here.
    FAILED_ENDING = { "state" => "FAILED", "outcome" => nil }.freeze
    STALE_ENDING = { "state" => "STALE", "outcome" => nil }.freeze
    # The one outcome that does not COMPLETE its attempt: NEEDS_INPUT ends the delivery and the
    # reviewer process, and leaves the review itself waiting on a Product Owner answer.
    AWAITING_ANSWER_OUTCOME = "NEEDS_INPUT"
    # MAPIAI-88 — the one answer to an ACCEPT that is NOT an ending: Platform validated the verdict,
    # recorded none of it, and authorized this runner to close a bounded set of obsolete pull
    # requests first. Accepted only for an ACCEPT, because it is the only outcome that can produce
    # a replacement package.
    ACCEPT_OUTCOME = "ACCEPT"
    RETIRING_ANSWER = { "state" => "RETIRING", "outcome" => nil }.freeze

    # MAPIAI-90 — the status Platform answers a review delivery with when it RECORDED the verdict
    # and the ticket's Jira description update did not complete. Neither a refusal (the body was
    # accepted) nor a success this machine may report, so the identical delivery is what finishes
    # it, inside the same bound.
    INCOMPLETE_DELIVERY_STATUS = 503

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
    # The most task environments one project holds, and so the most candidates one cancellation
    # read offers; and the longest identity either side of that read accepts.
    MAX_CLEANUP_CANDIDATES = 90
    MAX_CLEANUP_IDENTITY = 200

    # POST /api/runner/cancellation_cleanup_target. `[run_id, task_id]` for the one offered Run
    # Platform says this registered runner may now release, or nil for none.
    #
    # Anything but that exact shape raises. A target is acted on by deleting local work, so an
    # answer this client cannot read in full is never guessed at.
    def cancellation_cleanup_target(workspace_key:, candidates:)
      offered = candidates.first(MAX_CLEANUP_CANDIDATES).map { |run_id, task_id| { run_id: run_id, task_id: task_id } }
      status, body = post_json("/api/runner/cancellation_cleanup_target",
                               { workspace_key: workspace_key, candidates: offered })
      raise_for(status, body) unless status == 200

      cleanup_target(body)
    end

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
      with_transport_retries(max_attempts) do
        status, body = post_json("/api/runner/events", { claim: claim, event: event })
        status == 201 ? body : raise_for(status, body)
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

    # POST /api/runner/status. The machine's latest provider status snapshot.
    #
    # A third sibling of #heartbeat and #report_presence, and separate from both for the same
    # reason they are separate from each other: those two are LIVENESS on a cadence Platform
    # enforces, and this is a DESCRIPTION nobody waits on. Sharing an endpoint would put an
    # optional, slow-to-collect payload on a path whose deadline keeps a claim alive.
    #
    # The whole object is offered or none of it — Platform validates and stores it atomically,
    # so a refusal changes nothing and needs no local repair. Not retried here: the reporter's
    # next cycle sends the current state again, which is a better answer than re-sending a
    # measurement that has since aged.
    def report_status(snapshot:)
      status, body = post_json("/api/runner/status", { status: snapshot })
      status == 200 ? body : raise_for(status, body)
    end

    # POST /api/runner/preview_results (MAPIAI-97). One step of the live preview this runner
    # holds: the sources it resolved, the environment it started, the boundary that failed, or
    # the outcome of releasing.
    #
    # Its own endpoint rather than another report shape, for the reason every result lane here is
    # separate: Platform moves a different aggregate for each, and a shared endpoint would let a
    # runner reach the wrong transition by posting the wrong body.
    def submit_preview_result(claim:, result:)
      status, body = post_json("/api/runner/preview_results", { claim: claim, result: result })
      status == 201 ? body : raise_for(status, body)
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

    # POST /api/runner/specification_packages (MVP-0034 CR-001). Submits ONE closed
    # specification-package preflight result — either the bytes this runner read at the pinned
    # commit, or the classified reason it refused.
    #
    # Platform decides everything the response reports: it recomputes every digest from these
    # bytes, compares them to its own recorded publication, pins the package, and only then moves
    # Jira. The runner reads `authorized` for whether it may launch a provider and never infers it
    # from having submitted successfully.
    def submit_specification_package(claim:, package:)
      status, body = post_json("/api/runner/specification_packages", { claim: claim, package: package })
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
    # `attempt_id` and the expected ENDING are what the acknowledgement is checked against: a 201
    # only means "delivered" when the answer names the attempt this runner holds and the durable
    # ending this particular delivery produces.
    # An ACCEPT may be answered with the verdict OR with `RETIRING` plus a retirement plan, so both
    # are acknowledgeable answers and the CALLER reads the response to tell which it got. The
    # runner never infers that it may close anything from having submitted successfully.
    def submit_review_result(claim:, attempt_id:, review:)
      answers = [ verdict_ending(review["outcome"]) ]
      answers << RETIRING_ANSWER if review["outcome"] == ACCEPT_OUTCOME
      deliver_review(claim, { review: review }, attempt_id: attempt_id, answers: answers)
    end

    # POST /api/runner/review_results again — the completion of an authorized retirement (MAPIAI-88
    # design 4).
    #
    # `review` is the IDENTICAL body the prepare carried, never a rebuilt one: Platform recomputes
    # the plan from durable authority and compares digests, and a body that differs in any stored
    # field is a plan this runner's closes were not authorized by. Only the verdict acknowledges
    # this delivery — a second `RETIRING` answer would mean Platform never read the completion.
    def complete_review_retirement(claim:, attempt_id:, review:, digest:, pull_requests:)
      deliver_review(claim,
                     { review: review,
                       retirement: { digest: digest, pull_requests: pull_requests } },
                     attempt_id: attempt_id, answers: [ verdict_ending(review["outcome"]) ])
    end

    # The same endpoint, a DIFFERENT body: the reviewer produced no usable result at all, so
    # there is no verdict to send (MAPIAI-78 design 2). Reported explicitly rather than as an
    # outcome-less review, because Platform must keep the runner's own reason instead of
    # replacing it with its generic outcome-validation refusal.
    def report_review_failure(claim:, attempt_id:, kind:, reason:)
      deliver_review(claim, { failure: { kind: kind, reason: reason } },
                     attempt_id: attempt_id, answers: [ FAILED_ENDING ])
    end

    # The same endpoint, a DIFFERENT body: the pull request's branch no longer points at the
    # pinned head, so there is no verdict to send. Reported explicitly rather than as an
    # outcome-less result, because Platform closes the assignment for a moved target and offers
    # a fresh attempt for a failed reviewer (MVP-0033 CR-001 F3).
    def report_stale_target(claim:, attempt_id:, reason:)
      deliver_review(claim, { stale: { reason: reason } },
                     attempt_id: attempt_id, answers: [ STALE_ENDING ])
    end

    # POST /api/runner/claim_releases — abandon THIS claim before anything executed (MVP-0035).
    #
    # A sibling of `submit_report`, never a shape of it: a report is an outcome and finalizes the
    # run, and this says there was none. Platform frees the machine's capacity slot and leaves
    # the run claimable, so a corrected input can be picked up by this machine or another.
    def release_claim(claim:, reason:)
      status, body = post_json("/api/runner/claim_releases", { claim: claim, reason: reason })
      status == 201 ? body : raise_for(status, body)
    end

    # POST /api/runner/executor_questions (MVP-0036). Submits ONE bounded question batch from
    # the local bridge, plus the bounded public continuation context, for a claim whose
    # provider session is still alive.
    #
    # A sibling of the result endpoints rather than a shape of `submit_report`: this body
    # finalizes nothing and touches no Jira, GitHub or report — it asks Platform to hold the
    # session open. Platform decides the deadline and the state; the runner reads what it
    # DECIDED rather than assuming its own policy.
    #
    # A 4xx is a REFUSAL the provider may correct (an invalid document) or must obey (a stale
    # claim). It raises like any other refusal so the bridge fails closed rather than retrying
    # a body Platform will never accept.
    # `checkpoint` is this parent's OWN package of the uncommitted work the provider asked from,
    # sent beside the provider's document rather than inside it: the provider writes the question,
    # and only the parent can measure and package the machine. Platform requires it, so a machine
    # that could not package its work reports a capture failure instead of asking.
    def submit_executor_question(claim:, question:, checkpoint: nil)
      body = { claim: claim, question: question, checkpoint: checkpoint }.compact
      status, body = post_json("/api/runner/executor_questions", body)
      status == 201 ? body : raise_for(status, body)
    end

    # The same endpoint, a DIFFERENT body: no question could be captured at all, because the
    # provider exited or the bridge could not recover. Reported explicitly rather than left to
    # a lapsing lease, so the attempt ends as a distinct recoverable failure and the machine is
    # freed now.
    def report_input_capture_failure(claim:, reason:)
      status, body = post_json("/api/runner/executor_questions",
                               { claim: claim, capture_failure: { reason: reason } })
      status == 201 ? body : raise_for(status, body)
    end

    # PATCH /api/runner/executor_questions/<id> (MVP-0036 CR-002). The runner reporting that it
    # wrote the accepted answers into the live session's bridge.
    #
    # Platform cannot observe a provider process, so this is the only honest source for "the
    # same session received the answers" — and it is what makes the batch durably ANSWERED.
    # Idempotent on Platform, so a replay is harmless; a refusal or fault is raised, because a
    # delivery Platform did not confirm must not be treated as one it did.
    def confirm_executor_question_delivery(claim:, public_id:)
      path = "/api/runner/executor_questions/#{URI.encode_www_form_component(public_id.to_s)}"
      status, body = request_json(Net::HTTP::Patch, path, payload: { claim: claim })
      status == 200 ? body : raise_for(status, body)
    end

    # GET /api/runner/executor_questions/<id> (MVP-0036). What Platform durably believes about
    # one batch: whether the window is still open, and the answers once they exist.
    #
    # This poll IS the answer channel. Platform pushes nothing and this MVP opens no socket, so
    # a waiting provider is served by the runner parent re-reading durable state — which is
    # also what makes a dropped response harmless.
    def executor_question(claim:, public_id:)
      path = "/api/runner/executor_questions/#{URI.encode_www_form_component(public_id.to_s)}" \
             "?claim=#{URI.encode_www_form_component(claim.to_s)}"
      status, body = request_json(Net::HTTP::Get, path)
      status == 200 ? body : raise_for(status, body)
    end

    # GET the recorded portable checkpoint for one batch, at the claim-bound path Platform put in
    # the assignment. The bytes come back base64-encoded, exactly as they were submitted, so this
    # one JSON transport carries the package in both directions and there is no second encoding
    # for the two halves of the same round trip to disagree about.
    #
    # The path is Platform's, and it is checked before it is joined: `URI.join` with an absolute
    # url would send this runner's bearer token to whatever host that url named.
    def executor_question_checkpoint(claim:, path:)
      location = path.to_s
      raise RequestFailed, "Platform sent an unusable checkpoint location" unless location.start_with?("/")

      status, body = request_json(Net::HTTP::Get,
                                  "#{location}?claim=#{URI.encode_www_form_component(claim.to_s)}")
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

    # The three review deliveries, through ONE poster (MAPIAI-78 design 3).
    #
    # A lost response leaves this machine unable to tell "Platform never saw it" from "Platform
    # committed it and the answer vanished", so the identical body is delivered again — never a
    # rebuilt one, and never after rerunning the provider. Platform makes the replay idempotent;
    # this side's job is only to keep the body byte-identical across attempts.
    #
    # An UNCONFIRMED answer is the same fact as a lost one and is retried the same way: a 201
    # from a proxy, a captive portal or a truncated response is not Platform recording anything
    # (review-001 F5).
    def deliver_review(claim, body, attempt_id:, answers:, max_attempts: 3)
      with_transport_retries(max_attempts, unfinished_status: INCOMPLETE_DELIVERY_STATUS) do
        status, response = post_json("/api/runner/review_results", { claim: claim }.merge(body))
        raise_for(status, response) unless status == 201
        raise Error, "Platform's answer did not record this attempt's ending" unless
          answers.any? { |answer| acknowledged?(response, attempt_id, answer) }

        response
      end
    end

    # What makes a 201 a DELIVERY: Platform answered about the attempt this runner holds, and the
    # state it reports is one this delivery can produce. Both halves are load-bearing — the right
    # answer for the wrong attempt, and the wrong answer for the right attempt, are each a delivery
    # this machine cannot claim landed. The set of acceptable answers is the caller's, because only
    # the caller knows which delivery this is.
    def acknowledged?(response, attempt_id, ending)
      recorded = response.is_a?(Hash) ? response["review"] : nil
      return false unless recorded.is_a?(Hash)

      recorded["attempt_id"].to_s == attempt_id.to_s &&
        recorded["state"] == ending["state"] &&
        recorded["outcome"] == ending["outcome"]
    end

    def verdict_ending(outcome)
      { "state" => outcome == AWAITING_ANSWER_OUTCOME ? "AWAITING_ANSWER" : "COMPLETED",
        "outcome" => outcome }
    end

    # Retry a request a retry can still change the outcome of, and only that. A refusal
    # (Unauthorized/NotFound/RequestFailed) means Platform read the body and answered, so
    # re-sending it would only ask the same question again; the bare transport Error is the one
    # that leaves a caller unable to say whether anything was recorded.
    #
    # `unfinished_status` names a SECOND such case the caller knows about: Platform answered that
    # it recorded the delivery and could not finish it (MAPIAI-90). Only a caller whose body is
    # safe to re-deliver byte-for-byte may pass one, which is why it is the caller's decision and
    # not a rule about every 5xx.
    def with_transport_retries(max_attempts, unfinished_status: nil)
      attempt = 0
      begin
        attempt += 1
        yield
      rescue Error => e
        raise if attempt >= max_attempts
        raise unless e.instance_of?(Error) || e.status.to_i == unfinished_status

        retry
      end
    end

    # The workspace key is a path SEGMENT, so it is escaped rather than interpolated: a key
    # containing a slash or a space would otherwise silently address a different route.
    def connection_path(workspace_key)
      "/api/runner/workspace_connections/#{URI.encode_www_form_component(workspace_key.to_s)}"
    end

    # `payload` is always an explicit Hash at every call site: this method takes a keyword
    # argument, so a trailing `key: value` list would be parsed as keywords rather than converted
    # into the positional payload hash.
    def cleanup_target(body)
      unless body.is_a?(Hash) && body.keys == [ "target" ]
        raise RequestFailed.new("Platform's cancellation answer carried no target field", status: 200)
      end

      target = body["target"]
      return nil if target.nil?
      return [ target["run_id"], target["task_id"] ] if cleanup_identity?(target)

      raise RequestFailed.new("Platform named a cancellation target this runner could not read", status: 200)
    end

    def cleanup_identity?(target)
      target.is_a?(Hash) && target.keys.sort == %w[run_id task_id] &&
        target.values.all? { |value| value.is_a?(String) && !value.empty? && value.length <= MAX_CLEANUP_IDENTITY }
    end

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
    rescue *TRANSPORT_FAILURES => e
      raise Error, "could not reach Platform at #{base}: #{e.class}"
    end

    def parse(body)
      body.to_s.strip.empty? ? {} : JSON.parse(body)
    rescue JSON::ParserError
      {}
    end

    def raise_for(status, body)
      message = refusal_detail(body)
      detail = message.empty? ? "" : ": #{message}"
      raise Unauthorized.new("Platform rejected the runner token (401)#{detail}", status: status) if status == 401
      raise NotFound.new("Platform found no such resource (404)#{detail}", status: status) if status == 404

      raise RequestFailed.new("Platform request failed (#{status})#{detail}", status: status)
    end

    # A refusal's reason arrives in one of two shapes: an authority refusal's single `error`, or a
    # validation refusal's `errors` — the field messages a live provider must be handed to correct
    # its request. Both are the detail; neither is dropped.
    def refusal_detail(body)
      return "" unless body.is_a?(Hash)

      message = body["error"].to_s
      message.empty? ? Array(body["errors"]).map(&:to_s).reject(&:empty?).join("; ") : message
    end
  end
end
