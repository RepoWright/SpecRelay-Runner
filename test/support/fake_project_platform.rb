# frozen_string_literal: true

require "socket"
require "json"

# An isolated HTTP Platform that enforces PROJECT OWNERSHIP of a registered machine.
#
# `FakePlatform` models one project and accepts any machine identity, which is exactly why it
# cannot show the defect this fake exists for: Platform binds a registered runner to the project
# of the enrollment code that created it, and refuses to repoint that same machine id at a second
# project. A runner deriving its machine id from the hostname alone therefore connects the first
# project and is refused by the second — with the operator's one-time code already spent.
#
# So this fake reproduces the three server-side rules the local fix has to live with, and nothing
# else:
#
#   1. one registration per machine id, owned by the project that created it — a second project
#      presenting the same machine id is refused (422), as `Runner::Enrollment::ExchangeCode`
#      refuses it;
#   2. each registration gets its own public id and its own durable credential, and a machine
#      presenting the credential it already holds keeps it rather than being re-issued one;
#   3. a credential authorizes only the workspaces of ITS OWN registration, so a credential from
#      one project cannot read or claim another project's workspace.
#
# Workspace keys are unique per project and deliberately NOT globally unique, because Platform's
# `WorkspaceDefinition` scopes them to a project and the duplicate-key case is one this runner has
# to store, list and select correctly.
#
# It is a test collaborator: it holds no real credential, reaches no network but its own loopback
# socket, and stores everything in memory.
class FakeProjectPlatform
  # One project, its workspaces, and the unspent enrollment codes scoped to them.
  Project = Struct.new(:slug, :name, :workspaces, keyword_init: true)
  Workspace = Struct.new(:workspace_key, :project_key, :display_name, :repository_url,
                         :default_branch, keyword_init: true)
  # One machine Platform has registered. `project_slug` is the ownership the second-project
  # refusal is decided from.
  Registration = Struct.new(:runner_id, :display_name, :public_id, :project_slug, :credential,
                            :workspace_keys, keyword_init: true)

  CONNECTOR_TOKEN = "connector-token-fake"

  attr_reader :requests, :registrations

  def initialize
    @projects = {}
    @codes = {}
    @consumed = []
    @registrations = {}
    @requests = []
    @public_id_counter = 0
    @credential_counter = 0
    @mutex = Mutex.new
    @server = TCPServer.new("127.0.0.1", 0)
  end

  # --- fixture construction -------------------------------------------------

  # Add a project with one workspace and return the one-time enrollment code scoped to it. The
  # code carries the origin the way a real code does, so `connect` needs no endpoint flag.
  def add_project(slug:, workspace_key:, name: slug, project_key: slug, repository_url:,
                  default_branch: "main")
    project = @projects[slug] ||= Project.new(slug: slug, name: name, workspaces: {})
    project.workspaces[workspace_key] = Workspace.new(
      workspace_key: workspace_key, project_key: project_key,
      display_name: "#{name} workspace", repository_url: repository_url,
      default_branch: default_branch
    )
    issue_code(slug, workspace_key)
  end

  # Another one-time code for a workspace that already exists, which is how a reconnect and a
  # retry after a failed attempt are modelled: same assignment, a code that has not been spent.
  def issue_code(project_slug, workspace_key)
    code = "sre_#{Base64.urlsafe_encode64(base_url, padding: false)}.tail-#{@codes.length + 1}"
    @codes[code] = { project_slug: project_slug, workspace_key: workspace_key }
    code
  end

  def spent?(code) = @consumed.include?(code)

  # The registration that owns one project, or nil. Assertions read this to prove that two
  # projects really did produce two distinct machine registrations.
  def registration_for(project_slug)
    registrations.values.find { |registration| registration.project_slug == project_slug }
  end

  def machine_ids = registrations.keys.sort

  # --- server ---------------------------------------------------------------

  def port = @server.addr[1]
  def base_url = "http://127.0.0.1:#{port}"

  def start
    @thread = Thread.new do
      loop do
        handle(@server.accept)
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

  def requests_to(path) = requests.select { |request| request[:path] == path }

  private

  def handle(socket)
    request = read_request(socket)
    status, body = authorize(request) || route(request)
    @mutex.synchronize { @requests << request.merge(response_status: status) }
    respond(socket, status, body)
  rescue StandardError => e
    respond(socket, 500, { error: e.message })
  ensure
    socket.close
  end

  # The enrollment endpoints authenticate the one-time code; everything else authenticates a
  # registration's own durable credential. That split is what makes "B's credential cannot read
  # A's workspace" a property of this fake rather than of the test that uses it.
  def authorize(request)
    presented = request[:headers]["authorization"].to_s.delete_prefix("Bearer ")
    return nil if enrollment_path?(request[:path]) && @codes.key?(presented)
    return nil if !enrollment_path?(request[:path]) && registration_by_credential(presented)

    [ 401, { error: "unauthorized" } ]
  end

  def enrollment_path?(path)
    [ "/api/runner/enrollment", "/api/runner/enrollment_preview" ].include?(path)
  end

  def registration_by_credential(credential)
    return nil if credential.to_s.empty?

    registrations.values.find { |registration| registration.credential == credential }
  end

  def route(request)
    case request[:path]
    when "/api/runner/enrollment_preview" then preview(request)
    when "/api/runner/enrollment" then enroll(request)
    when "/api/runner/workspace_connections" then [ 201, readiness(request) ]
    when %r{\A/api/runner/workspace_connections/(?<key>.+)\z} then describe(request, Regexp.last_match[:key])
    when "/api/runner/claim" then [ 200, { claimed: false, reason: "no_eligible_runs" } ]
    else [ 404, { error: "not found" } ]
    end
  end

  # Read-only: a preview never consumes the code, so a local failure after it costs nothing.
  def preview(request)
    scope = scope_for(request) or return invalid_code
    [ 200, assignment(scope) ]
  end

  def enroll(request)
    scope = scope_for(request) or return invalid_code
    identity = request.dig(:body, "runner") || {}
    machine_id = identity["id"].to_s
    return [ 422, { error: "runner id is required" } ] if machine_id.empty?

    @mutex.synchronize { register(scope, machine_id, identity, request) }
  end

  # Rule 1 and rule 2 together. A machine id already owned by another project is refused BEFORE
  # the code is consumed, exactly as the transactional exchange refuses it.
  def register(scope, machine_id, identity, request)
    existing = registrations[machine_id]
    return second_project_refusal if existing && existing.project_slug != scope[:project_slug]

    presented = request.dig(:headers, "x-specrelay-runner-credential").to_s
    unchanged = !existing.nil? && !presented.empty? && existing.credential == presented
    registration = existing || create_registration(machine_id, identity, scope)
    registration.display_name = identity["display_name"].to_s
    registration.credential = next_credential unless unchanged || existing.nil?
    registration.workspace_keys |= [ scope[:workspace_key] ]
    @consumed << request_code(request)
    [ 201, enrollment_body(scope, registration, unchanged) ]
  end

  def second_project_refusal
    [ 422, { error: "this machine is already connected to another project; " \
                    "disconnect it there before connecting it here" } ]
  end

  def create_registration(machine_id, identity, scope)
    registrations[machine_id] = Registration.new(
      runner_id: machine_id, display_name: identity["display_name"].to_s,
      public_id: next_public_id, project_slug: scope[:project_slug],
      credential: next_credential, workspace_keys: []
    )
  end

  def enrollment_body(scope, registration, unchanged)
    assignment(scope).merge(
      runner: { id: registration.runner_id, public_id: registration.public_id,
                display_name: registration.display_name },
      credential: unchanged ? nil : registration.credential,
      credential_unchanged: unchanged,
      preview_connector: { token: "#{CONNECTOR_TOKEN}-#{registration.public_id}" }
    )
  end

  def assignment(scope)
    project = @projects.fetch(scope[:project_slug])
    workspace = project.workspaces.fetch(scope[:workspace_key])
    { contract_version: SpecrelayRunner::Connect::CONTRACT_VERSION,
      platform: { base_url: base_url },
      project: { slug: project.slug, name: project.name },
      workspace: workspace.to_h.transform_keys(&:to_s),
      executor: SpecrelayRunner::ImplementationProfile::FIXTURE_CANONICAL }
  end

  def readiness(request)
    { contract_version: SpecrelayRunner::Connect::CONTRACT_VERSION,
      connection: { public_id: "rwc_fake", workspace_key: request.dig(:body, "workspace_key"),
                    state: "ready", failure_class: nil,
                    detail: "Runner validated its local checkout.",
                    ready_at: "2026-09-18T00:00:00Z" } }
  end

  # Rule 3: a workspace this registration was never granted is not found, whatever the workspace
  # key alone might suggest. This is what a credential crossing a project boundary hits.
  def describe(request, workspace_key)
    presented = request[:headers]["authorization"].to_s.delete_prefix("Bearer ")
    registration = registration_by_credential(presented)
    return [ 404, { error: "no grant for this runner on #{workspace_key}" } ] unless
      registration.workspace_keys.include?(workspace_key)

    [ 200, { connection: { workspace_key: workspace_key, state: "ready",
                           repository_url: repository_url_for(registration, workspace_key),
                           default_branch: "main" } } ]
  end

  def repository_url_for(registration, workspace_key)
    project = @projects.fetch(registration.project_slug)
    project.workspaces.fetch(workspace_key).repository_url
  end

  def scope_for(request)
    code = request_code(request)
    return nil if code.nil? || @consumed.include?(code)

    @codes[code]
  end

  def request_code(request) = request[:headers]["authorization"].to_s.delete_prefix("Bearer ")

  # A spent code is indistinguishable from a wrong one, as on real Platform.
  def invalid_code = [ 401, { error: "invalid_enrollment_code" } ]

  def next_public_id = "rnr_#{@public_id_counter += 1}"
  def next_credential = "src_credential_#{@credential_counter += 1}"

  # --- HTTP plumbing --------------------------------------------------------

  def read_request(socket)
    method, path, = socket.gets.to_s.split(" ")
    headers = {}
    while (line = socket.gets) && line != "\r\n" && !line.chomp.empty?
      key, value = line.chomp.split(": ", 2)
      headers[key.to_s.downcase] = value
    end
    length = headers["content-length"].to_i
    body = length.positive? ? socket.read(length) : ""
    { method: method, path: path.to_s.split("?").first, headers: headers, body: parse(body) }
  end

  def parse(body)
    body.to_s.strip.empty? ? {} : JSON.parse(body)
  rescue JSON::ParserError
    {}
  end

  def respond(socket, status, body)
    payload = JSON.generate(body)
    socket.print("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{payload.bytesize}\r\n\r\n#{payload}")
  end
end
