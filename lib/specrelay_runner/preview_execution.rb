# frozen_string_literal: true

module SpecrelayRunner
  # MAPIAI-97 — the ONE Runner-owned path a live preview takes: a claimed assignment in, a running
  # local application or a mapped failure out, and later a released task environment.
  #
  # Everything it does to the machine goes through the PROJECT'S OWN lifecycle commands — create,
  # up, status, release — as fixed argv arrays addressed to the assigned task id and run in the
  # connected checkout root. It never invokes Docker, Compose, a port scanner, a probe or any
  # application command, and no browser-supplied value ever becomes an argument: the only
  # interpolated value is the task id, which {PreviewAssignment} already restricted to a safe
  # token. A second environment system beside the project's own is exactly what this must not be.
  #
  # THE ORDER IS THE PRODUCT RULE. The complete source set is resolved before anything is created,
  # so a bad assignment is a clean failure with nothing to release; `status` runs only after `up`
  # succeeded, so a URL can never describe an application that failed to start.
  #
  # FAILURE OWNERSHIP is the other half, and it is answered pessimistically. `cleanup_required` is
  # this Runner's honest statement that it may still hold a task environment, which is what keeps
  # it reserved. Once `create` may have allocated one, only the project-owned lifecycle's own
  # `unknown task environment` exit code may say otherwise — a status command that merely failed
  # proves nothing.
  class PreviewExecution
    PROJECT_COMMAND = Workspace::PROJECT_COMMAND

    AVAILABLE = :available
    FAILED_CLEAN = :failed_clean
    FAILED_CLEANUP = :failed_cleanup
    STOPPED = :stopped
    RELEASED = :released
    RELEASE_FAILED = :release_failed

    # The closed failure vocabulary, matching Platform's. Each names the boundary that refused,
    # because that is what decides whether the operator may simply Start again.
    INVALID_ASSIGNMENT = "invalid_assignment"
    SOURCE_UNAVAILABLE = "source_unavailable"
    WORKTREE_FAILED = "worktree_failed"
    STARTUP_FAILED = "startup_failed"
    STATUS_FAILED = "status_failed"
    INVALID_STATUS = "invalid_status"

    # The project-owned lifecycle's documented exit code for an unknown task environment. It is
    # the ONLY evidence that downgrades a create failure to a clean one, and the only thing that
    # makes releasing a non-existent environment a success rather than a lie.
    UNKNOWN_ENVIRONMENT = 4
    TIMEOUTS = { "up" => 900, "status" => 120, "release" => 600 }.freeze

    Outcome = Struct.new(:state, :reason, :failure_kind, :cleanup_required, :document, :snapshot,
                         keyword_init: true) do
      def available? = state == AVAILABLE
      def cleanup_required? = cleanup_required ? true : false
    end

    def initialize(payload:, root:, env: ENV, stop_check: nil, on_output: nil, on_sources: nil,
                   github: PreviousAcceptedPackage::GitHub)
      @payload = payload
      @root = root.to_s
      @env = env
      @stop_check = stop_check
      @on_output = on_output
      @on_sources = on_sources
      @github = github
    end

    # Steps 1-13. Returns the closed preview document, or the mapped failure that owns cleanup.
    def start
      assignment = PreviewAssignment.read(@payload)
      return clean(INVALID_ASSIGNMENT, assignment.reason) unless assignment.ok?

      @assignment = assignment
      resolver = PreviewSources.new(assignment.sources, root, env: env, github: github)
      resolved = resolver.resolve
      return clean(SOURCE_UNAVAILABLE, resolved.reason) unless resolved.ok?

      @snapshot = resolved.snapshot
      @on_sources&.call(@snapshot)
      prepare(resolver, resolved.sources)
    end

    # Step 16, and the one command that returns this Runner to polling. Idempotent by memo, so a
    # duplicated Stop control cannot run a second release; a FAILED release is deliberately not
    # memoized, because Retry release is the same attempt trying the same command again.
    def release
      return @released if @released

      result = project("release")
      return @released = Outcome.new(state: RELEASED) if released?(result)

      Outcome.new(state: RELEASE_FAILED, reason: reason_for("release", result), cleanup_required: true)
    end

    private

    attr_reader :root, :env, :github, :assignment, :snapshot

    def task_id = assignment.task_id

    # Steps 5-9: the create authority, containment, and every resolved head placed on the canonical
    # branch. Nothing is started until the whole base is built.
    def prepare(resolver, sources)
      return stopped(cleanup: false) if stop?
      return clean(WORKTREE_FAILED, "this project owns no #{PROJECT_COMMAND} command") unless project?

      info = create
      return info if info.is_a?(Outcome)

      refusal = containment_refusal(info.path)
      return cleanup(WORKTREE_FAILED, refusal) if refusal

      placed = resolver.materialize(task_root: info.path, canonical_branch: assignment.canonical_branch,
                                    sources: sources)
      placed.ok? ? launch : cleanup(WORKTREE_FAILED, placed.reason)
    end

    # Steps 10-13. `status` is unreachable unless `up` succeeded, and the projected document is
    # validated before it can become a URL.
    def launch
      return stopped if stop?

      up = project("up")
      return cleanup(STARTUP_FAILED, reason_for("up", up)) unless up&.success?
      return stopped if stop?

      status = project("status", "--json")
      return cleanup(STATUS_FAILED, reason_for("status", status)) unless status&.success?

      projected = PreviewStatus.project(status.stdout, task_id: task_id)
      return cleanup(INVALID_STATUS, projected.reason) unless projected.ok?

      return stopped if stop?

      # An available preview is holding a task environment by definition, so it owns cleanup for
      # exactly as long as it is available.
      Outcome.new(state: AVAILABLE, document: projected.document, snapshot: snapshot,
                  cleanup_required: true)
    end

    # The project-owned create authority, reused rather than reimplemented: {Workspace} already
    # owns invoking it once and LOCATING the result by asking git which worktree holds the
    # canonical branch, so no layout convention is needed here either.
    def create
      emit("#{PROJECT_COMMAND} create #{task_id}")
      workspace.create
    rescue Workspace::Error, SystemCallError => e
      create_failure(redacted(e.message))
    end

    def workspace
      # No create command travels in a preview assignment: the project's own is the only authority
      # this lane accepts, and `project?` has already proved it exists.
      @workspace ||= Workspace.new(root: root, canonical_branch: assignment.canonical_branch,
                                   create_command: "", task_id: task_id, on_output: @on_output)
    end

    # The one boundary that may prove creation never happened. Anything other than the documented
    # `unknown task environment` answer — including a status command that itself failed — leaves
    # this attempt owning cleanup.
    def create_failure(reason)
      probe = project("status", "--json")
      return clean(WORKTREE_FAILED, reason) if probe&.exit_code == UNKNOWN_ENVIRONMENT

      cleanup(WORKTREE_FAILED, reason)
    end

    # Step 6. The created root must be a real directory that is NOT the connected checkout and does
    # not contain it — releasing either would delete the operator's own workspace — and it must
    # hold the assigned task's canonical branch, which is what makes it this task's environment
    # rather than some other worktree that happened to be there.
    def containment_refusal(path)
      created = real(path)
      connected = real(root)
      return "the created task environment could not be resolved" if created.nil?
      return "the created task environment is the connected checkout itself" if created == connected
      return "the connected checkout is inside the created task environment" if
        connected.to_s.start_with?("#{created}#{File::SEPARATOR}")

      branch = branch_of(created)
      return nil if branch == assignment.canonical_branch

      "the created task environment is on #{quoted(branch)}, not #{quoted(assignment.canonical_branch)}"
    end

    def branch_of(path)
      result = CommandRunner.run([ "git", "-C", path, "symbolic-ref", "--quiet", "--short", "HEAD" ],
                                 chdir: path, env: {}, timeout_seconds: 60)
      result.success? ? result.stdout.to_s.strip : nil
    rescue SystemCallError
      nil
    end

    # Every project-owned command: a fixed argv array, the assigned task id, the connected root.
    # The narration carries the argv WITHOUT that root — the operator's local path is a Runner
    # concern and must never reach Platform or a preview page.
    #
    # EVERY verb streams. `up` is the loudest, but it is not the one that usually fails: create
    # refuses a dirty repository, status prints the document that was rejected, and a release that
    # will not release says why. Streaming only `up` left the operator watching a blank panel for
    # exactly those steps (CR-005 F5).
    #
    # The stop check stays on `up` alone. That is the one long wait a Stop may cut short; cutting
    # `status` would prove nothing and cutting `release` would abandon the cleanup being asked for.
    def project(verb, *flags)
      argv = [ File.join(root, PROJECT_COMMAND), verb, task_id, *flags ]
      emit([ PROJECT_COMMAND, verb, task_id, *flags ].join(" "))
      CommandRunner.run(argv, chdir: root, env: {}, timeout_seconds: TIMEOUTS.fetch(verb),
                        on_output: @on_output, stop_check: (@stop_check if verb == "up"))
    rescue SystemCallError
      nil
    end

    def project? = File.executable?(File.join(root, PROJECT_COMMAND))

    def released?(result) = result&.success? || result&.exit_code == UNKNOWN_ENVIRONMENT

    def reason_for(verb, result)
      return "`#{PROJECT_COMMAND} #{verb}` could not be started" if result.nil?
      return "`#{PROJECT_COMMAND} #{verb}` timed out" if result.timed_out?

      "`#{PROJECT_COMMAND} #{verb}` failed (exit #{result.exit_code}): " \
        "#{redacted(first_line(result.stderr, result.stdout))}"
    end

    def clean(kind, reason)
      Outcome.new(state: FAILED_CLEAN, failure_kind: kind, reason: reason, cleanup_required: false,
                  snapshot: snapshot)
    end

    def cleanup(kind, reason)
      Outcome.new(state: FAILED_CLEANUP, failure_kind: kind, reason: reason, cleanup_required: true,
                  snapshot: snapshot)
    end

    # A Stop seen before `create` owns nothing; after it, only a release can prove otherwise.
    def stopped(cleanup: true)
      Outcome.new(state: STOPPED, reason: "this preview was stopped before it became available",
                  cleanup_required: cleanup, snapshot: snapshot)
    end

    def stop? = @stop_check&.call ? true : false

    def emit(line) = @on_output&.call(CommandRunner::STDOUT, line)

    def real(path)
      File.realpath(path.to_s)
    rescue SystemCallError
      nil
    end

    def first_line(*candidates)
      candidates.map { |candidate| candidate.to_s.strip }.find { |text| !text.empty? }
                .to_s.each_line.first.to_s.strip
    end

    # Every reason this class reports is built from a command's own stderr or from a Workspace
    # error, so both carry a host path as readily as the raw stream does — and a reason is queued
    # and rendered on the same page (CR-006).
    def redacted(text) = PrivatePaths.sanitize(Redaction.redact(text.to_s))

    def quoted(value) = "\"#{value}\""
  end
end
