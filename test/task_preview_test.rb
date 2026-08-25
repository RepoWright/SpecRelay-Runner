# frozen_string_literal: true

require_relative "test_helper"

# MAPIAI-97 — the project-owned task-environment preview, at its own boundary.
#
# Every case drives the REAL command boundary against a scripted `bin/worktree`, because the two
# facts this class is trusted for are which argv it runs and what it refuses to project from the
# answer. A stubbed runner would prove neither.
class TaskPreviewTest < Minitest::Test
  TASK = "DEMO-0001"

  def setup
    @root = Dir.mktmpdir("specrelay-preview-")
    FileUtils.mkdir_p(File.join(@root, "bin"))
    write_project_command
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # A `bin/worktree` that records every invocation and answers from files the test writes:
  # `up.exit`/`status.exit` for exit codes, `status.json` for the status payload, `*.sleep` to
  # overrun a timeout, and `break-after-<verb>` to make the NEXT invocation unlaunchable.
  def write_project_command
    path = File.join(@root, "bin", "worktree")
    File.write(path, <<~SH)
      #!/usr/bin/env sh
      ROOT="$(cd "$(dirname "$0")/.." && pwd)"
      echo "$*" >> "$ROOT/invocations.log"
      CMD="${1:-}"
      if [ -f "$ROOT/$CMD.sleep" ]; then sleep "$(cat "$ROOT/$CMD.sleep")"; fi
      if [ -f "$ROOT/break-after-$CMD" ]; then
        printf '#!/nonexistent/interpreter\nexit 0\n' > "$0.broken"
        chmod +x "$0.broken"
        mv "$0.broken" "$0"
      fi
      if [ "$CMD" = "status" ] && [ -f "$ROOT/status.json" ]; then cat "$ROOT/status.json"; fi
      if [ -f "$ROOT/$CMD.exit" ]; then exit "$(cat "$ROOT/$CMD.exit")"; fi
      exit 0
    SH
    FileUtils.chmod(0o755, path)
  end

  # An executable file this host cannot start: the interpreter its shebang names does not exist.
  # `File.executable?` stays true, so capability detection passes and the failure happens at the
  # spawn — the real shape of a replaced command or a broken interpreter (CR-001 F1).
  def break_launch
    path = File.join(@root, "bin", "worktree")
    File.write("#{path}.broken", "#!/nonexistent/interpreter\nexit 0\n")
    FileUtils.chmod(0o755, "#{path}.broken")
    FileUtils.mv("#{path}.broken", path)
  end

  def break_launch_after(command) = File.write(File.join(@root, "break-after-#{command}"), "")

  def write_status(payload) = File.write(File.join(@root, "status.json"), payload.is_a?(String) ? payload : JSON.generate(payload))
  def write_exit(command, code) = File.write(File.join(@root, "#{command}.exit"), code.to_s)
  def write_sleep(command, seconds) = File.write(File.join(@root, "#{command}.sleep"), seconds.to_s)
  def invocations = File.read(File.join(@root, "invocations.log")).lines.map(&:strip)

  def preview(task_id: TASK, timeout_seconds: SpecrelayRunner::Workspace::COMMAND_TIMEOUT_SECONDS)
    SpecrelayRunner::TaskPreview.call(root: @root, task_id: task_id, env: { "PATH" => ENV["PATH"].to_s },
                                      timeout_seconds: timeout_seconds)
  end

  # One healthy running environment, as `scripts/worktree/engine.py#status` reports it. Extra keys
  # are deliberate: the projection is an allowlist, so the ones this product really emits must be
  # present in the fixture the allowlist is proven against.
  def running_status(services: nil, primary_url: "http://127.0.0.1:3700", task_id: TASK, state: "RUNNING")
    {
      "task_id" => task_id, "branch" => "MAPIAI-1-x", "state" => state, "slot" => 2,
      "port_block" => [ 3700, 3799 ], "compose_project" => "srt-demo-92c16d",
      "primary_url" => primary_url, "data_warning" => "shared development database",
      "development_data_modes" => { "platform" => "shared" }, "test_data_modes" => {},
      "services" => services || [ service("platform", url: "http://127.0.0.1:3700"),
                                  service("runner", url: "http://127.0.0.1:3701", health: "none") ],
      "repositories" => [ { "name" => "platform", "worktree_path" => "/Users/someone/secret/path",
                            "dirty" => true, "branch" => "MAPIAI-1-x" } ],
      "missing_repositories" => []
    }
  end

  def service(name, url:, state: "running", health: "healthy", host_port: 3700)
    { "service" => name, "state" => state, "health" => health, "host_port" => host_port, "url" => url }
  end

  # --- lifecycle -------------------------------------------------------------------------------

  def test_a_preview_capable_project_runs_up_then_status_once_each_with_exact_argv
    write_status(running_status)

    result = preview

    assert_equal [ "up #{TASK}", "status #{TASK} --json" ], invocations
    assert_equal "available", result["status"]
    assert_nil result["reason"]
    assert_equal "RUNNING", result["runtime_state"]
    assert_equal "http://127.0.0.1:3700", result["primary_url"]
    assert_equal [ { "name" => "platform", "state" => "running", "health" => "healthy",
                     "url" => "http://127.0.0.1:3700" },
                   { "name" => "runner", "state" => "running", "health" => "none",
                     "url" => "http://127.0.0.1:3701" } ], result["services"]
  end

  def test_no_executable_project_command_is_unsupported_and_runs_nothing
    FileUtils.rm_f(File.join(@root, "bin", "worktree"))

    assert_equal unavailable, preview
    refute File.exist?(File.join(@root, "invocations.log")), "no command may run without bin/worktree"
  end

  def test_a_non_executable_project_command_is_unsupported
    FileUtils.chmod(0o644, File.join(@root, "bin", "worktree"))

    assert_equal unavailable, preview
  end

  def test_an_empty_task_id_is_unsupported_and_runs_nothing
    assert_equal unavailable, preview(task_id: "")
    refute File.exist?(File.join(@root, "invocations.log"))
  end

  def test_a_failing_up_is_startup_failed_and_never_asks_for_status
    write_exit("up", 1)

    assert_equal failed("startup_failed"), preview
    assert_equal [ "up #{TASK}" ], invocations
  end

  def test_an_overrunning_up_is_startup_failed
    write_sleep("up", 5)

    assert_equal failed("startup_failed"), preview(timeout_seconds: 1)
    assert_equal [ "up #{TASK}" ], invocations
  end

  # CR-001 F1 — a command that passes the executable check and still cannot be spawned. The
  # failure belongs to the preview, not to the attempt that had already succeeded.
  def test_an_up_that_cannot_be_launched_is_startup_failed
    break_launch

    assert File.executable?(File.join(@root, "bin", "worktree")), "the capability check must still pass"
    assert_equal failed("startup_failed"), preview
  end

  def test_a_status_that_cannot_be_launched_after_a_successful_up_is_status_failed
    break_launch_after("up")
    write_status(running_status)

    assert_equal failed("status_failed"), preview
    assert_equal [ "up #{TASK}" ], invocations, "status never ran, so it never recorded itself"
  end

  def test_a_failing_status_is_status_failed
    write_exit("status", 1)
    write_status(running_status)

    assert_equal failed("status_failed"), preview
    assert_equal [ "up #{TASK}", "status #{TASK} --json" ], invocations
  end

  def test_an_overrunning_status_is_status_failed
    write_sleep("status", 5)
    write_status(running_status)

    assert_equal failed("status_failed"), preview(timeout_seconds: 1)
  end

  # --- status payload --------------------------------------------------------------------------

  def test_unparseable_status_is_invalid_status
    write_status("not json at all")

    assert_equal failed("invalid_status"), preview
  end

  def test_a_status_payload_over_the_byte_bound_is_invalid_status
    oversized = running_status
    oversized["data_warning"] = "x" * (64 * 1024)
    write_status(oversized)

    assert_equal failed("invalid_status"), preview
  end

  def test_a_status_payload_for_another_task_is_invalid_status
    write_status(running_status(task_id: "OTHER-9"))

    assert_equal failed("invalid_status"), preview
  end

  def test_a_status_payload_that_is_not_an_object_is_invalid_status
    write_status("[]")

    assert_equal failed("invalid_status"), preview
  end

  def test_a_non_running_environment_is_invalid_status
    write_status(running_status(state: "STOPPED"))

    assert_equal failed("invalid_status"), preview
  end

  def test_an_environment_with_no_reportable_service_is_invalid_status
    write_status(running_status(services: []))

    assert_equal failed("invalid_status"), preview
  end

  def test_a_primary_url_naming_no_reported_service_is_invalid_status
    write_status(running_status(primary_url: "http://127.0.0.1:3999"))

    assert_equal failed("invalid_status"), preview
  end

  def test_an_absent_primary_url_is_invalid_status
    write_status(running_status(primary_url: nil))

    assert_equal failed("invalid_status"), preview
  end

  def test_more_than_twenty_reportable_services_is_invalid_status
    many = (1..21).map { |index| service("svc-#{index}", url: "http://127.0.0.1:#{3700 + index}") }
    write_status(running_status(services: many, primary_url: "http://127.0.0.1:3701"))

    assert_equal failed("invalid_status"), preview
  end

  def test_twenty_reportable_services_are_accepted
    many = (1..20).map { |index| service("svc-#{index}", url: "http://127.0.0.1:#{3700 + index}") }
    write_status(running_status(services: many, primary_url: "http://127.0.0.1:3701"))

    assert_equal 20, preview["services"].length
  end

  # --- what is filtered rather than refused ------------------------------------------------------

  def test_services_that_are_not_running_or_healthy_are_dropped_rather_than_reported
    write_status(running_status(services: [
                                  service("platform", url: "http://127.0.0.1:3700"),
                                  service("stopped", url: "http://127.0.0.1:3701", state: "exited"),
                                  service("sick", url: "http://127.0.0.1:3702", health: "unhealthy"),
                                  service("starting", url: "http://127.0.0.1:3703", health: "starting")
                                ]))

    assert_equal [ "platform" ], preview["services"].map { |svc| svc["name"] }
  end

  def test_an_internal_service_without_a_url_is_dropped_rather_than_refused
    write_status(running_status(services: [ service("platform", url: "http://127.0.0.1:3700"),
                                            service("postgres", url: nil) ]))

    assert_equal [ "platform" ], preview["services"].map { |svc| svc["name"] }
  end

  # --- URL and name matrix -----------------------------------------------------------------------

  UNSAFE_URLS = {
    "javascript scheme" => "javascript:alert(1)",
    "data scheme" => "data:text/html,<script>alert(1)</script>",
    "file scheme" => "file:///etc/passwd",
    "another host" => "http://example.com:3700",
    "localhost name" => "http://localhost:3700",
    "loopback alias" => "http://127.0.0.2:3700",
    "userinfo" => "http://user:token@127.0.0.1:3700",
    "query string" => "http://127.0.0.1:3700?token=secret",
    "fragment" => "http://127.0.0.1:3700#secret",
    "non root path" => "http://127.0.0.1:3700/admin",
    "implicit port" => "http://127.0.0.1",
    "privileged port" => "http://127.0.0.1:80",
    "port above range" => "http://127.0.0.1:99999",
    "empty" => "",
    "not a string" => 3700
  }.freeze

  UNSAFE_URLS.each do |label, url|
    define_method(:"test_a_service_url_with_#{label.tr(' ', '_')}_refuses_the_whole_preview") do
      write_status(running_status(services: [ service("platform", url: "http://127.0.0.1:3700"),
                                              service("other", url: url) ]))

      assert_equal failed("invalid_status"), preview, "#{label} must fail closed"
    end
  end

  def test_an_over_long_url_refuses_the_whole_preview
    long = "http://127.0.0.1:3700/#{'a' * 2100}"
    write_status(running_status(services: [ service("platform", url: "http://127.0.0.1:3700"),
                                            service("other", url: long) ]))

    assert_equal failed("invalid_status"), preview
  end

  def test_duplicate_service_urls_refuse_the_whole_preview
    write_status(running_status(services: [ service("platform", url: "http://127.0.0.1:3700"),
                                            service("clone", url: "http://127.0.0.1:3700") ]))

    assert_equal failed("invalid_status"), preview
  end

  def test_duplicate_service_names_refuse_the_whole_preview
    write_status(running_status(services: [ service("platform", url: "http://127.0.0.1:3700"),
                                            service("platform", url: "http://127.0.0.1:3701") ]))

    assert_equal failed("invalid_status"), preview
  end

  UNSAFE_NAMES = { "markup" => "<script>", "space" => "web app", "slash" => "a/b",
                   "empty" => "", "too long" => "n" * 65 }.freeze

  UNSAFE_NAMES.each do |label, name|
    define_method(:"test_a_service_name_with_#{label.tr(' ', '_')}_refuses_the_whole_preview") do
      write_status(running_status(services: [ service("platform", url: "http://127.0.0.1:3700"),
                                              service(name, url: "http://127.0.0.1:3701") ]))

      assert_equal failed("invalid_status"), preview, "#{label} must fail closed"
    end
  end

  def test_a_service_entry_that_is_not_an_object_refuses_the_whole_preview
    write_status(running_status(services: [ service("platform", url: "http://127.0.0.1:3700"), "platform" ]))

    assert_equal failed("invalid_status"), preview
  end

  # --- projection allowlist -----------------------------------------------------------------------

  def test_the_projection_carries_no_local_path_port_block_or_repository_record
    write_status(running_status)

    wire = JSON.generate(preview)
    [ "worktree_path", "/Users/someone/secret/path", "port_block", "compose_project", "srt-demo-92c16d",
      "repositories", "host_port", "data_warning", "development_data_modes", "branch",
      "missing_repositories", "slot" ].each do |forbidden|
      refute_includes wire, forbidden, "#{forbidden} must never reach the wire"
    end
    assert_equal %w[status reason runtime_state primary_url services], preview.keys
    assert_equal %w[name state health url], preview["services"].first.keys
  end

  def unavailable = { "status" => "unavailable", "reason" => "unsupported", "runtime_state" => nil,
                      "primary_url" => nil, "services" => [] }

  def failed(reason) = { "status" => "failed", "reason" => reason, "runtime_state" => nil,
                         "primary_url" => nil, "services" => [] }
end
