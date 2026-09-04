# frozen_string_literal: true

module SpecrelayRunner
  # The `specrelay-runner` command-line entry point for the standalone runner
  # (MVP-0010). It is a thin adapter: parse argv, load local configuration, build the
  # Platform API client, claim at most one run, and — if claimed — execute it and
  # report back. It never reaches Platform except through PlatformClient.
  #
  # The NORMAL path is two commands and no files (MVP-0017):
  #
  #   specrelay-runner connect <enrollment-code>
  #   specrelay-runner claim-once
  #
  # `connect` obtains everything from Platform, asks only for the local checkout, and
  # stores the credential in the OS secret store; `claim-once` then reads that stored
  # connection, so there is no YAML to author and no credential to export.
  #
  # `register --config <path>` and `claim-once --config <path>` remain as the
  # ADVANCED/LEGACY path for an operator who already runs a hand-written config. They
  # are supported, not recommended, and are not the documented setup route.
  #
  # Exit codes mirror the in-process runner: 0 = completed or nothing eligible,
  # 1 = a claimed execution did not complete successfully, 2 = config/usage error.
  class CLI
    SUCCESS = 0
    RUN_FAILED = 1
    USAGE_ERROR = 2

    def self.run(argv, out: $stdout, err: $stderr, env: ENV, input: $stdin) =
      new(out:, err:, env:, input:).run(argv)

    # `secret_store` is the deterministic injection seam the engineering constraints require, and
    # the same one `Connect` and `ConnectionDiagnosis` already expose: it lets the stored-connection
    # claim path — including the explicit-default resolution — be exercised as behaviour without
    # touching the developer's real Keychain or raising an interactive prompt in CI.
    def initialize(out: $stdout, err: $stderr, env: ENV, input: $stdin, secret_store: nil)
      @out = out
      @err = err
      @env = env
      @input = input
      @injected_secret_store = secret_store
    end

    def run(argv)
      command, *rest = argv
      case command
      when "connect" then connect(rest)
      when "register" then register(rest)
      when "claim-once" then claim_once(rest)
      when "loop" then loop_mode(rest)
      when "connections" then connections(rest)
      when nil then no_arguments
      when "help", "-h", "--help" then print_help
      when "version", "--version" then print_version
      else usage("unknown command: #{command}")
      end
    rescue CleanupRequired => e
      # MAPIAI-97 — the work itself succeeded and was reported; what failed is handing the task
      # environment back. `loop` turns this into a stopped session at its own boundary, so this
      # is the SINGLE-shot path: say what is still allocated, and exit non-zero so a script does
      # not treat a machine holding an environment as a clean finish.
      err.puts(Redaction.redact(e.message))
      RUN_FAILED
    end

    private

    attr_reader :out, :err, :env, :input

    # The ONE terminal write boundary for everything that runs while work is in
    # progress (RUNNER-0001 scope 2). Built once per invocation and shared by the
    # loop's transient status, the live executor stream, the lease heartbeat, and
    # the execution's own lines, so no two of them can interleave and every durable
    # line clears the transient row first. Capability is detected from `out`, so a
    # pipe or a CI log gets plain lines and no cursor control.
    def presenter = @presenter ||= TerminalPresenter.for(out: out, err: err)

    # No arguments means two DIFFERENT things, decided by whether a human is actually there
    # (MVP-0021 scope 1).
    #
    # In a real terminal it opens the control center, because a connected machine's normal daily
    # action is to look at its workspaces and start one.
    #
    # Anywhere else — a pipe, a cron job, a CI step, an ssh command with no tty — it prints
    # usage and exits 2. Both halves matter. Opening a menu with no terminal would render
    # escape sequences into a log and then block forever on a keypress that can never arrive;
    # exiting 0 with only help text would let a mis-scripted `specrelay-runner` (a dropped
    # argument, a typo'd subcommand) pass as a successful run that executed nothing. `help`
    # still exits 0 — asking for help and getting it is a success.
    def no_arguments
      return usage("specrelay-runner needs a command when there is no terminal to open the dashboard in.") unless
        TerminalMenu.interactive?(input: input, out: out)

      Dashboard.call(operations: connection_operations, out: out, err: err, input: input,
                     dispatch: ->(argv) { run(argv) })
    end

    # The scriptable equivalent of every dashboard action. Both surfaces drive the SAME
    # ConnectionOperations instance type, so they cannot disagree about what an action means.
    def connections(args)
      ConnectionsCommand.call(args: args, out: out, err: err, operations: connection_operations)
    end

    def connection_operations = ConnectionOperations.new(env: env, secret_store: @injected_secret_store)

    def secret_store = @injected_secret_store || SecretStore.for(platform: RUBY_PLATFORM)

    # The guided connection (MVP-0017). Every failure mode reports ONE focused, redacted
    # remedy and leaves this runner not-ready rather than half-connected: an unsupported
    # platform, a malformed/expired code, a checkout that is not the assigned repository,
    # an unavailable or unauthenticated Claude, or a refused Keychain write.
    def connect(args)
      code = args.find { |arg| !arg.start_with?("-") }
      return usage("usage: specrelay-runner connect <enrollment-code>") if code.nil?

      result = Connect.call(code: code, out: out, err: err, env: env,
                            checkout_path: option(args, "--checkout"))
      print_connection(result)
      result.ready? ? SUCCESS : RUN_FAILED
    rescue SecretStore::UnsupportedPlatform => e
      connect_failed("Cannot connect: #{e.message}", USAGE_ERROR)
    rescue Connect::Error, SecretStore::Error, ConnectionStore::Error, PlatformClient::Error => e
      connect_failed("Connection failed: #{Redaction.redact(e.message)}", RUN_FAILED)
    end

    # stdout is block-buffered when redirected while stderr is not, so without this flush the
    # failure line appears BEFORE the assignment lines it refers to in a merged operator log —
    # the same ordering problem `executor_ready?` already guards against.
    def connect_failed(message, status)
      out.flush if out.respond_to?(:flush)
      err.puts message
      status
    end

    # Prints the state PLATFORM decided, never the runner's own opinion, and never the
    # credential (which is already in the Keychain by this point).
    def print_connection(result)
      out.puts ""
      if result.ready?
        out.puts "Connected. This machine is ready to execute #{result.workspace_key} work."
        # `loop` is named first because it is the normal mode for a connected machine
        # (MVP-0018); `claim-once` is the controlled single shot for a manual test.
        out.puts "Next: leave `specrelay-runner loop` running here to pick up work as it becomes ready,"
        out.puts "      or run `specrelay-runner claim-once` for a single controlled test."
        return
      end

      out.flush if out.respond_to?(:flush)
      err.puts "Platform recorded this connection as #{result.state}" \
               "#{" (#{result.failure_class})" if result.failure_class}."
      err.puts "Remedy: #{Redaction.redact(result.detail.to_s)}" if result.detail.to_s.strip != ""
    end

    # ADVANCED / LEGACY (MVP-0011). Enroll with a one-time registration token read from
    # the environment and receive the durable credential, printed EXACTLY ONCE for the
    # operator to export. Superseded by `connect`, which needs no file and no exported
    # credential — and, unlike this command, grants access to a specific workspace. A
    # runner enrolled here holds no workspace grant and can claim nothing until it
    # completes `connect`.
    def register(args)
      config = load_config(args)
      return USAGE_ERROR if config.nil?

      token = config.registration_token(env: env)
      client = PlatformClient.new(base_url: config.base_url, token: token)
      out.puts "Registering runner #{config.runner['display_name']} (#{config.runner['id']}) with #{config.base_url}…"
      print_registration(config, client.register(config.registration_identity))
      SUCCESS
    rescue Config::Error => e
      err.puts "Invalid runner config: #{e.message}"
      USAGE_ERROR
    rescue PlatformClient::Error => e
      err.puts "Registration failed: #{e.message}"
      RUN_FAILED
    end

    # Show the returned credential a single time with clear, secret-safe guidance.
    # This is the ONE place the runner prints a raw secret (never via the redacting
    # logger) because the operator must capture it now — Platform cannot re-show it.
    def print_registration(config, result)
      runner = result.fetch("runner")
      out.puts "Registered. Runner identity: #{runner['public_id']} (#{runner['id']})."
      out.puts ""
      out.puts "Per-runner credential (shown once — store it, do not commit it):"
      out.puts "  #{result.fetch('credential')}"
      out.puts ""
      out.puts "Export it before claiming work:"
      out.puts "  export #{config.credential_env}=<the value above>"
      out.puts ""
      out.puts "This runner has NO workspace access yet. Registration alone authorizes nothing:"
      out.puts "run `specrelay-runner connect <enrollment-code>` for the workspace it should execute."
    end

    def claim_once(args)
      config = resolve_claim_config(args)
      return USAGE_ERROR if config.nil?

      auth = config.resolve_auth(env: env)
      announce(config, auth)
      # MVP-0016: when this runner selected the real Claude Code profile, prove the
      # local dependency is ready BEFORE asking Platform for work. Claiming first
      # and discovering a missing CLI afterwards burns a real run and leaves it
      # stuck; this exits non-zero having sent no claim request at all.
      return RUN_FAILED unless executor_ready?(config)

      client = PlatformClient.new(base_url: config.base_url, token: auth.token)
      result = client.claim(config.claim_runner_params)
      unless result.claimed?
        out.puts not_claimed_message(result)
        return SUCCESS
      end

      execute(config, client, result.payload)
    rescue ClaudeProfile::Error => e
      err.puts "Invalid executor profile: #{e.message}"
      USAGE_ERROR
    rescue CleanupRequired => e
      # MAPIAI-97 — the report was accepted; the environment was not released. A single shot has
      # no loop to stop, so the non-zero exit is what stops the operator's script from claiming
      # again on a machine holding something unaccounted for.
      presenter.error(Redaction.redact(e.message))
      err.puts "Release it by hand, then run this runner again."
      RUN_FAILED
    rescue Config::Error => e
      err.puts "Invalid runner config: #{e.message}"
      USAGE_ERROR
    rescue PlatformClient::Error => e
      err.puts "Runner failed: #{e.message}"
      RUN_FAILED
    end

    # MVP-0018 — the normal operator mode for a connected personal runner: poll,
    # claim, execute, repeat, until interrupted.
    #
    # It reuses `claim-once`'s resolution and readiness gates verbatim — the same
    # stored connection, the same Keychain credential, the same executor readiness
    # check — and adds only repetition. The readiness gate runs ONCE here rather
    # than per poll: it probes the provider CLI, and doing that every minute would
    # be a cost with no new information.
    def loop_mode(args)
      interval = PollInterval.resolve(option(args, "--poll-interval"))
      return usage(interval.error) unless interval.valid?

      policy = option(args, "--on-failure").to_s.strip
      policy = LoopRunner::ON_FAILURE_CONTINUE if policy.empty?
      return usage("--on-failure must be one of: #{LoopRunner::FAILURE_POLICIES.join(', ')}") unless
        LoopRunner::FAILURE_POLICIES.include?(policy)

      start_loop(args, interval, policy)
    end

    def start_loop(args, interval, policy)
      config = resolve_claim_config(args)
      return USAGE_ERROR if config.nil?

      auth = config.resolve_auth(env: env)
      announce(config, auth)
      out.puts "Poll interval: #{interval.notice || "#{interval.seconds}s"}"
      return RUN_FAILED unless executor_ready?(config)

      run_loop(config, auth, interval, policy)
    rescue ClaudeProfile::Error => e
      err.puts "Invalid executor profile: #{e.message}"
      USAGE_ERROR
    rescue Config::Error => e
      err.puts "Invalid runner config: #{e.message}"
      USAGE_ERROR
    end

    def run_loop(config, auth, interval, policy)
      client = PlatformClient.new(base_url: config.base_url, token: auth.token)
      result = LoopRunner.call(
        out: out, err: err, presenter: presenter, label: loop_label(config),
        poll_seconds: interval.seconds, on_failure: policy,
        presence: loop_presence(config, client, interval),
        connector: loop_connector(config),
        claim: -> { client.claim(config.claim_runner_params) },
        execute: ->(payload) { loop_disposition(config, client, payload) }
      )
      result == LoopRunner::OK ? SUCCESS : RUN_FAILED
    end

    # MAPIAI-107 — what one claimed assignment tells the SESSION, which is one fact more than its
    # exit status.
    #
    # Every lane and every ordinary outcome reduces to the Boolean the loop has always read. The
    # exception is a deterministic pre-provider refusal that attempted to release its claim: the
    # run is left exactly as this machine found it, so a session told only "failed" polls again
    # and reaches the identical refusal. The fact is yielded by the same {Execution::Result} the
    # exit status is read from, so the two can never disagree, and `claim-once` is untouched — it
    # passes no block and keeps its unchanged nonzero single attempt.
    def loop_disposition(config, client, payload)
      refused = false
      code = execute(config, client, payload) { refused = true }
      refused ? LoopRunner::RELEASE_ATTEMPTED_REFUSAL : code == SUCCESS
    end

    # MVP-0031 — the idle presence session for this loop.
    #
    # Presence is recorded per runner/WORKSPACE connection, so a loop that has no connection
    # record (an advanced `--config` invocation) can address none and reports none. That is a
    # real limitation of the legacy path rather than something to paper over: Platform would
    # have no connection to attach the signal to.
    #
    # `claim-once` deliberately gets none at all. A single controlled shot is never Watching —
    # it may be Busy for the lease it holds, and Connected before and after.
    def loop_presence(config, client, interval)
      connection = config.connection
      return Presence::NONE if connection.nil?

      Presence.new(client: client, workspace_key: connection.workspace_key,
                   interval_seconds: interval.seconds,
                   on_notice: ->(message) { presenter.line("[loop] #{message}") })
    end

    # This loop session's own preview connector, read from the token the guided connection stored
    # under this machine's identity.
    #
    # An advanced `--config` invocation manages none. That path has no connection record, so it
    # has no machine identity to read a connector for and never ran the guided connection that
    # provisions one — the same real limitation of the legacy path that leaves it with no presence.
    def loop_connector(config)
      connection = config.connection
      return PreviewConnector::NONE if connection.nil?

      PreviewConnector.new(runner_public_id: connection.runner_public_id,
                           secret_store: secret_store,
                           on_notice: ->(message) { presenter.line("[loop] #{message}") })
    end

    # What the transient status row says this runner is polling for. The PROJECT is the
    # operator's concept, so it leads; the workspace key follows because it is the
    # routing fact and the only thing that disambiguates two connections to the same
    # project. A legacy record with no project metadata falls back to the workspace
    # key rather than inventing a name.
    #
    # An advanced/legacy `--config` invocation has NO connection record and therefore
    # no project identity, so it gets no label: the announce block above already
    # printed `Source: config file …`, and a config filename on the status row would
    # be identity theatre.
    def loop_label(config)
      connection = config.connection
      return nil if connection.nil?

      project = connection.project_slug.to_s.strip
      project.empty? ? connection.workspace_key.to_s : "#{project} (#{connection.workspace_key})"
    end

    # Print PLATFORM's reason for a not-claimed poll, so an unconnected runner is told to run
    # `connect` rather than being left to read "nothing eligible" as a healthy idle.
    def not_claimed_message(result)
      reason = Redaction.redact(result.reason)
      reason.strip.empty? ? "no eligible work (Platform authorized no run for this runner)." : "no work claimed: #{reason}"
    end

    # The local, no-edit readiness gate for the real provider profile. Returns true
    # immediately when no real profile is selected, so the deterministic
    # fake-executor regression path never requires Claude Code to be installed or
    # authenticated. Only classifications are printed — never probe output, which
    # carries the operator's account identity.
    def executor_ready?(config)
      profile = config.selected_claude_profile
      return true if profile.nil?

      out.puts "Executor: #{profile.describe}"
      readiness = profile.readiness(env: env)
      out.puts "Readiness: #{readiness.summary}"
      return true if readiness.ready?

      # stdout is block-buffered when redirected while stderr is not, so the
      # classification would otherwise appear AFTER the remedy in a merged
      # operator log — exactly the ordering that makes such a log hard to read.
      out.flush if out.respond_to?(:flush)
      err.puts "Claude Code is not ready on this host — no run was claimed and nothing was executed."
      err.puts "Remedy: #{readiness.remedy}"
      false
    end

    # MVP-0025: dispatch on the assignment's own LANE before anything is prepared or
    # launched. The check is first, so the specification path never touches the executor
    # readiness assumptions, the worktree, or the report contract — and a specification
    # assignment reaching an older code path is impossible rather than merely unlikely.
    def execute(config, client, payload, &released)
      # MVP-0033 — a REVIEW assignment is recognised by its explicit `assignment_type`, never
      # by what it lacks, so a future assignment kind can never be executed as an
      # implementation run by an older runner build.
      # MAPIAI-97 — a live preview leads, recognised by its own discriminated kind. It executes no
      # provider and produces no report, so falling through to any other lane would be a category
      # error rather than a degraded run.
      return preview(config, client, payload) if PreviewAssignment.preview?(payload)
      return review(config, client, payload) if Review::Assignment.review?(payload)
      return specification(config, client, payload) if
        Specification::Assignment.specification?(payload)
      # MVP-0034 CR-001 — a package PREFLIGHT is recognised the same explicit way, and it leads
      # the implementation path because it is the gate in front of it: the run it belongs to has
      # no pinned specification yet, so falling through to `Execution` would launch a provider on
      # a specification nobody has verified.
      return package_preflight(config, client, payload, &released) if
        PackagePreflight::Assignment.preflight?(payload)

      announce_claim(payload)
      run_execution(config, client, payload, &released)
    end

    # MAPIAI-97 — one claimed live preview, held open for as long as a human is testing it.
    #
    # It exits ZERO for every honest outcome, a refused assignment and a failed start included:
    # the claim reported what happened and the machine is free. Only a task environment this
    # runner could not account for is worth stopping a loop session over.
    def preview(config, client, payload)
      assignment = PreviewAssignment.read(payload)
      root = assignment.ok? ? config.workspace_root(assignment.workspace_key, env: env) : nil
      presenter.line(assignment.ok? ? "Claimed a live preview of #{assignment.ticket_key}." :
                       "Refusing a preview assignment: #{assignment.reason}")
      held = PreviewSession.call(payload: payload, client: client, root: root.to_s, io: presenter,
                                 env: env)
      held ? SUCCESS : RUN_FAILED
    rescue Config::Error => e
      # This machine holds a grant for the workspace but has no local root mapped for it. Nothing
      # was created, so the preview fails CLEAN and the machine is free — the same answer
      # {Execution} gives an implementation run in the same situation.
      preview_refused(client, assignment, Redaction.redact(e.message))
    end

    def preview_refused(client, assignment, reason)
      presenter.error(reason)
      client.submit_preview_result(
        claim: assignment.execution_id,
        result: { kind: "failed", failure_kind: PreviewExecution::WORKTREE_FAILED,
                  reason: reason, cleanup_required: false }
      )
      RUN_FAILED
    end

    # MVP-0033 — one claimed review, executed by a fresh provider process.
    #
    # A refused or failed review exits NON-ZERO, like a refused specification generation and
    # for the same reason: the claim did not produce what it was made for, and a `loop`
    # session that treated it as success would poll forever against a machine whose reviewer
    # is misconfigured while reporting health.
    def review(config, client, payload)
      assignment = Review::Assignment.new(payload)
      # Its own announcement rather than `announce_claim`: a review packet has no `run` block
      # and no claim policy, and printing empty fields for them would read as a broken claim.
      presenter.line "Claimed review of #{assignment.ticket_id} " \
                     "(attempt #{assignment.attempt_ordinal}); claim #{assignment.claim_token}."
      result = Review::Execution.call(config: config, client: client, payload: payload,
                                      env: env, io: presenter)
      presenter.line result.message
      # A STALE target exits zero. The claim did not produce a verdict, but the runner did
      # exactly what it should have — the code it was sent to review moved. Treating that as a
      # machine fault would stop a `loop` session on a healthy runner (CR-001 F3).
      result.success? || result.stale? ? SUCCESS : RUN_FAILED
    end

    # MVP-0026 — the specification lane now generates rather than acknowledging and stopping.
    #
    # A REFUSAL exits non-zero, unlike the MVP-0025 acknowledgement it replaces. That is the
    # right change of meaning: acknowledging an assignment was the whole of the correct
    # behaviour then, so exiting 0 was honest. Now the correct behaviour is a generated
    # package, and a refusal means the operator has something to fix — a `loop` session or a
    # CI step that treated it as success would poll forever against a misconfigured runner,
    # reporting health.
    #
    # An ABORTED attempt (Platform cancelled the claim or the lease lapsed) also exits
    # non-zero: the run did not produce what it was claimed for, and Platform — not this
    # process — owns what happens next.
    # MVP-0027 — the specification lane now has two phases, and which one a claim authorizes is
    # read from the ASSIGNMENT rather than inferred. Platform writes `expected_runner_action` for
    # exactly this purpose, so a runner build that meets a token it does not recognise refuses
    # instead of guessing — which is what stops a future phase from being executed by an older
    # runner that only knows how to generate.
    def specification(config, client, payload)
      assignment = Specification::Assignment.new(payload)
      return publish_specification(config, client, payload) if assignment.publication?
      return generate_specification(config, client, payload) if assignment.generation?

      unknown_specification_action(assignment)
    end

    def unknown_specification_action(assignment)
      err.puts "This Platform asked for a specification action this runner does not implement " \
               "(#{assignment.expected_runner_action.inspect})."
      err.puts "Upgrade the runner, or release the claim so a newer one can take it:"
      err.puts "  #{assignment.release_command}"
      RUN_FAILED
    end

    # MVP-0034 CR-001 — verify the ticket's Spec PR package, submit it, and execute ONLY if
    # Platform pins it and authorizes.
    #
    # The executor runs inside this same claim rather than after a re-claim, which is what keeps
    # one-active-task-per-runner true across both halves: the runner never holds two claims and
    # never releases this one between verifying a package and implementing it.
    #
    # A refusal exits non-zero for the same reason a refused generation does — the claim did not
    # produce what it was made for, and a `loop` session treating it as success would poll forever
    # against a machine whose GitHub access is misconfigured while reporting health.
    def package_preflight(config, client, payload, &released)
      assignment = PackagePreflight::Assignment.new(payload)
      presenter.line "Claimed a specification-package check for #{assignment.ticket_key}; " \
                     "claim #{assignment.claim_token}."
      result = PackagePreflight::Execution.call(config: config, client: client, payload: payload,
                                                env: env, io: presenter)
      presenter.line result.message
      return RUN_FAILED unless result.authorized?

      execute_authorized(config, client, result.assignment_payload, &released)
    end

    # The executable assignment Platform returned with its authorization. Absent it there is
    # nothing to run — and inventing one from the preflight payload is exactly the shortcut this
    # protocol forbids, because that payload deliberately carries no executor block.
    def execute_authorized(config, client, assignment_payload, &released)
      return RUN_FAILED if assignment_payload.nil?

      announce_claim(assignment_payload)
      run_execution(config, client, assignment_payload, &released)
    end

    # One implementation execution, and ONE mapping of its outcome to an exit status.
    #
    # `handled?` rather than `success?`: a released answer window did not complete the work, but
    # nothing failed either, and a loop must keep watching through it (MVP-0036 CR-001 F4). Both
    # entry points share this so the two can never classify the same outcome differently.
    def run_execution(config, client, payload)
      result = Execution.new(config: config, client: client, payload: payload, env: env,
                             io: presenter).call
      presenter.line result.message
      # MAPIAI-107 — the one fact a `loop` session needs beyond this exit status, reported at the
      # single place both entry points map an execution to one. `claim-once` passes no block, so
      # its behaviour is unchanged.
      yield if block_given? && result.refused_after_release_attempt?
      return RUN_FAILED unless result.handled?

      release_task_environment(config, payload) if result.completed_successfully?
      SUCCESS
    end

    # MAPIAI-97 — the environment a COMPLETED implementation leaves behind is released here, on
    # the one path both `loop` and `claim-once` reach, because the preview lane addresses the same
    # task id and would otherwise be built on top of it.
    #
    # `completed_successfully?`, not `handled?` and not `success?`. A question-paused attempt is an
    # approved pause whose worktree holds the answer the operator has yet to give; and an attempt
    # whose verification or publication FAILED reported that failure honestly and was accepted for
    # it, so its environment is the evidence — and the thing a retry reuses.
    #
    # It does not retract the accepted result — the report is already uploaded — but a refused
    # release raises {CleanupRequired}, because this machine is now holding something nobody has
    # accounted for and must not claim anything else until a person resolves it.
    def release_task_environment(config, payload)
      return unless Execution.implementation?(payload)

      task_id = payload.to_h["run"].to_h["task_id"].to_s
      return if task_id.empty?

      root = config.workspace_root(payload.to_h["workspace"].to_h["workspace_key"], env: env)
      TaskEnvironment.release!(root: root, task_id: task_id, io: presenter)
    end

    def generate_specification(config, client, payload)
      result = Specification::Generation.call(config: config, client: client, payload: payload,
                                              env: env, io: presenter)
      presenter.line result.message
      result.success? ? SUCCESS : RUN_FAILED
    end

    # A FAILED publication exits non-zero for the same reason a refused generation does: the run
    # did not produce what it was claimed for, and a `loop` session or a CI step that treated it
    # as success would poll forever against a runner that cannot reach GitHub, reporting health.
    def publish_specification(config, client, payload)
      result = Specification::Publication.call(config: config, client: client, payload: payload,
                                               env: env, io: presenter)
      presenter.line result.message
      result.success? ? SUCCESS : RUN_FAILED
    end

    # Prefer the guided connection (MVP-0017); fall back to the advanced/legacy config
    # file. An explicit `--config` (or SPECRELAY_RUNNER_CONFIG) always wins, so an
    # operator who deliberately runs a hand-written config is never silently overridden by
    # a stored connection.
    def resolve_claim_config(args)
      explicit = path_from(args) || Config.resolve_path(nil, env)
      return load_config(args) if explicit.to_s.strip != ""

      store = ConnectionStore.load(env: env)
      return not_connected if store.connections.empty?

      connection_config(store, args)
    end

    def not_connected
      err.puts "this machine is not connected to a workspace."
      err.puts "Run `specrelay-runner connect <enrollment-code>` — get the code from your " \
               "project's setup page in Platform."
      err.puts "(Advanced/legacy: point at a hand-written config with --config <path>.)"
      nil
    end

    # Build a config from a stored connection, reading its credential from the OS secret
    # store. Returns nil after printing ONE specific remedy when the connection cannot be
    # used, so a normal user is never shown a config-file error they did not cause.
    def connection_config(store, args)
      selection = select_connection(store, option(args, "--workspace"))
      return nil if selection.nil?

      credential = stored_credential(selection.connection)
      return missing_credential(selection.connection) if credential.nil?

      Config.from_connection(selection.connection, credential: credential,
                             selection_source: selection.source)
    rescue SecretStore::UnsupportedPlatform, SecretStore::Error => e
      err.puts "Cannot read the stored runner credential: #{Redaction.redact(e.message)}"
      nil
    end

    # The credential for this connection's RUNNER identity, falling back to the pre-round-003
    # per-workspace account so a machine that connected under the old scheme keeps working
    # (review-002, F3 residual). The credential is per runner, so keying it per workspace is what
    # let a second workspace's connection orphan the first's stored copy.
    def stored_credential(connection)
      store = secret_store
      runner_public_id = connection.runner_public_id.to_s.strip
      unless runner_public_id.empty?
        value = store.read(account: SecretStore.account_for_runner(runner_public_id))
        return value if value
      end
      store.read(account: SecretStore.legacy_account_for(connection.workspace_key))
    end

    # Which connection this invocation is for, and — just as importantly — WHY.
    #
    # Resolution order, all of it explicit:
    #
    #   1. `--workspace <key>`: the operator said so.
    #   2. An explicit default (MVP-0021 scope 4): the operator said so earlier, from the
    #      dashboard or `connections default`. Checked BEFORE the sole-connection shortcut, so
    #      a default that no longer resolves fails closed even on a machine with exactly one
    #      connection. Falling through to "well, there is only one" would be precisely the
    #      silent substitution the fail-closed rule forbids.
    #   3. The sole stored connection: unambiguous, so no inference is involved.
    #
    # Anything else asks. Guessing which workspace to claim for is the inference MVP-0017
    # removed, and a default the operator did not choose would reintroduce it — so there is no
    # implicit default by recency, alphabet, project, or last menu row.
    Selection = Struct.new(:connection, :source, keyword_init: true)

    def select_connection(store, workspace_key)
      requested = workspace_key.to_s.strip
      unless requested.empty?
        found = store.connection_for(requested)
        return found ? Selection.new(connection: found, source: :requested) : unknown_workspace(store, requested)
      end

      default_selection(store) || sole_selection(store)
    end

    # nil means "no default is set, carry on"; a set-but-unresolvable default returns nothing
    # AND has already reported, which `sole_selection` must not then override — so that case
    # sets a flag rather than relying on nil, which the two states would otherwise share.
    def default_selection(store)
      key = store.default_workspace_key
      return nil if key.nil?

      connection = store.connection_for(key)
      return Selection.new(connection: connection, source: :default) if connection

      @default_failed = true
      broken_default(store, key)
    end

    def sole_selection(store)
      return nil if @default_failed

      sole = store.sole_connection
      return Selection.new(connection: sole, source: :sole) if sole

      ambiguous_workspace(store)
    end

    def unknown_workspace(store, requested)
      err.puts "no connection for workspace '#{requested}'. Connected: " \
               "#{store.connections.map(&:workspace_key).join(', ')}"
      nil
    end

    # A default naming a workspace this machine no longer has is a configuration error with a
    # one-line fix, and it must never resolve to a different workspace: executing another
    # project's work because a default went stale is exactly the failure mode MVP-0017 fixed.
    def broken_default(store, key)
      err.puts "the default workspace '#{key}' is no longer connected on this machine, so nothing " \
               "was claimed."
      err.puts "Connected: #{store.connections.map(&:workspace_key).join(', ')}" if store.connections.any?
      err.puts "Remedy: choose another default (`specrelay-runner connections default <workspace-key>`), " \
               "clear it (`specrelay-runner connections clear-default`), or pass --workspace explicitly."
      nil
    end

    def ambiguous_workspace(store)
      err.puts "several workspaces are connected " \
               "(#{store.connections.map(&:workspace_key).join(', ')}); " \
               "choose one with --workspace <workspace-key>"
      err.puts "Or set a default once and stop passing it: `specrelay-runner connections default " \
               "<workspace-key>` — or just run `specrelay-runner` in a terminal for the dashboard."
      nil
    end

    def missing_credential(connection)
      err.puts "no stored credential for workspace #{connection.workspace_key}. " \
               "Reconnect it: specrelay-runner connect <enrollment-code>"
      nil
    end

    def load_config(args)
      Config.load(path_from(args), env: env)
    rescue Config::Error => e
      err.puts "Invalid runner config: #{e.message}"
      nil
    end

    def option(args, flag)
      index = args.index(flag)
      return args[index + 1] if index

      args.find { |arg| arg.start_with?("#{flag}=") }&.split("=", 2)&.last
    end

    def announce(config, auth)
      out.puts "SpecRelay standalone runner #{VERSION} (contract #{CONTRACT_VERSION})"
      out.puts "Platform: #{config.base_url}"
      out.puts "Runner:   #{config.runner['display_name']} (#{config.runner['id']})"
      out.puts "Source:   #{source_line(config)}"
      out.puts "Auth:     #{auth.mode == :registered ? 'registered runner credential' : 'development token (fallback)'}"
    end

    # Names WHICH workspace and, when it was not stated on the command line, WHY this one. An
    # operator who set a default weeks ago and now runs a bare `specrelay-runner loop` must be
    # able to see the decision in the output rather than infer it (MVP-0021 scope 4).
    def source_line(config)
      return "config file #{config.source_path}" if config.connection.nil?

      case config.selection_source
      when :default
        "connected workspace #{config.connection.workspace_key} (your explicit default workspace)"
      when :sole
        "connected workspace #{config.connection.workspace_key} (the only one connected here)"
      else
        "connected workspace #{config.connection.workspace_key}"
      end
    end

    def announce_claim(payload)
      claim = payload.fetch("claim")
      presenter.line "Claimed run #{payload.dig('run', 'task_id')} (#{payload.dig('run', 'id')}); " \
                     "execution #{claim['runner_execution_id']} via #{claim['claim_policy_mode']}."
    end

    def path_from(args)
      index = args.index("--config")
      return args[index + 1] if index

      flag = args.find { |a| a.start_with?("--config=") }
      flag&.split("=", 2)&.last
    end

    def usage(message)
      err.puts message if message
      err.puts "Usage: specrelay-runner                       (in a terminal: opens the dashboard)"
      err.puts "       specrelay-runner connect <enrollment-code>"
      err.puts "       specrelay-runner claim-once [--workspace <workspace-key>]"
      err.puts "       specrelay-runner loop [--workspace <workspace-key>] " \
               "[--poll-interval <#{PollInterval::MINIMUM}-#{PollInterval::MAXIMUM}>] [--on-failure continue|stop]"
      err.puts "       specrelay-runner connections <#{ConnectionsCommand::SUBCOMMANDS.join('|')}>"
      err.puts "       specrelay-runner help"
      USAGE_ERROR
    end

    def print_version
      out.puts VERSION
      SUCCESS
    end

    def print_help
      out.puts <<~HELP
        specrelay-runner — the SpecRelay execution plane

        A developer-installed runner that talks to Platform ONLY over the runner
        API (HTTP). It claims approved runs, runs the configured executor and
        tests locally, and uploads events/heartbeat/report through the API.

        This is the one supported way to execute SpecRelay work. Platform's
        `bin/platform runner once|loop` no longer executes anything.

        Day-to-day operation — run it with no arguments:

          specrelay-runner
              In a terminal, opens the local control center: every workspace this
              machine is connected to, with actions to start `loop` or `claim-once`
              for one, test its connection and readiness without claiming work, set
              or clear an explicit default workspace, and disconnect a workspace
              locally or from Platform. It is a presentation layer over the
              `connections` commands below, so anything you can do there you can
              also script.

              With no terminal (a pipe, cron, CI, `ssh host specrelay-runner`) it
              prints this usage and exits 2 rather than rendering a menu into a log.
              `specrelay-runner help` always prints help and exits 0.

        Normal setup — two commands, no files to edit:

          specrelay-runner connect <enrollment-code>
              Connect this machine to one workspace. Get the code from your
              project's setup page in Platform ("Connect a Runner"); it is shown
              once, works once, and expires shortly.

              The command obtains the Platform endpoint and the project/workspace
              assignment from the code exchange, asks you for ONE thing — the local
              checkout directory for the assigned repository — validates that
              checkout's remote and default branch against the assignment, checks
              the assigned executor is ready, and stores this runner's durable
              credential in the macOS Keychain. The credential is never printed,
              never written to a file, and never exported.

              macOS only in this release. On another system it stops before
              registering rather than saving a plaintext credential. Exits 0 when
              Platform records the runner ready, 1 otherwise, 2 on usage/platform.

          specrelay-runner claim-once [--workspace <workspace-key>]
              Claim at most one eligible run (Platform decides), execute it, and
              upload the report. With no arguments it uses the connection created
              by `connect`, reading the credential from the Keychain — no config
              file, no exported credential, and no workspace-root variable.
              --workspace picks one when several are connected. Exits 0 on
              completion or no eligible work, 1 on a failed execution, 2 on a
              config/usage error.

              Use this for a controlled, single-shot manual test. For day-to-day
              operation, leave `loop` running instead.

          specrelay-runner loop [--workspace <workspace-key>]
                                [--poll-interval <seconds>]
                                [--on-failure continue|stop]
              The normal mode for a connected machine: poll Platform for eligible
              work, claim ONE run at a time, execute it, and keep going. Uses the
              same stored connection and Keychain credential as `claim-once`.

              While the executor runs, safe redacted executor output is streamed to
              this terminal between [core.started] and [verification.started], and
              submitted to Platform as ordered live log events. When the provider is
              quiet, a periodic heartbeat line proves forward progress. Output is
              redacted, per-line clipped, and budget-capped; truncation is printed.

              --poll-interval defaults to #{PollInterval::DEFAULT}s; the supported
              range is #{PollInterval::MINIMUM}-#{PollInterval::MAXIMUM}s. A value
              outside it is clamped and the clamp is printed; a non-numeric value is
              refused.
              --on-failure continue (default) reports a failed run through the normal
              terminal-result contract and resumes polling; stop ends the session.

              Ctrl-C (or SIGTERM) stops it cleanly and says whether it was idle or an
              execution was in progress. Foreground only — installing it as a service
              is deliberately out of scope.

              Exits 0 when every executed run succeeded, 1 if any failed or the
              credential was rejected, 2 on a config/usage error.

        Managing this machine's connections — every dashboard action, scriptable, and
        usable with no terminal. Exit codes: 0 success, 1 the operation failed (Platform
        rejected it, a readiness check failed), 2 usage or unusable local state.

          specrelay-runner connections list
              Every workspace this machine is connected to, newest first, with the
              explicit default marked `*`. Shows no absolute local paths.

          specrelay-runner connections show <workspace-key>
              Everything stored locally for one workspace, including its local checkout
              path. No credential is read or shown.

          specrelay-runner connections test <workspace-key>
              Check that this connection could still execute — WITHOUT claiming any
              work. Verifies the local entry, the credential in the Keychain, that
              Platform accepts it, that the workspace grant is still ready, that the
              repository and branch still match this checkout, and that the executor is
              ready. Reports one focused remedy for the first thing that is wrong.

          specrelay-runner connections default <workspace-key>
          specrelay-runner connections clear-default
              Choose (or clear) this machine's default workspace. With several
              workspaces connected, `loop` and `claim-once` then run with no
              --workspace and print that the default was used. Nothing is ever
              defaulted implicitly, and a default that no longer resolves fails closed
              instead of falling through to another workspace.

          specrelay-runner connections disconnect-local <workspace-key>
                                                        [--remove-credential]
              Remove THIS MACHINE's stored connection for one workspace. Platform still
              authorizes this runner for it — local deletion revokes nothing. The
              runner credential is shared by every workspace of the same runner
              identity, so it is KEPT unless nothing depends on it any more and you
              pass --remove-credential.

          specrelay-runner connections disconnect-platform <workspace-key>
              Ask Platform to remove THIS runner's grant for THIS one workspace.
              Idempotent: a grant that is already gone succeeds. It never revokes the
              runner identity, never touches another workspace, and deletes no project,
              run, report, or branch. Local state is left alone — remove it separately
              with disconnect-local once Platform confirms.

          specrelay-runner connections forget-legacy-credential <workspace-key>
              Remove the pre-MVP-0017 per-workspace Keychain item
              `workspace:<workspace-key>`. Nothing else ever deletes a legacy item,
              because a machine that connected under the old scheme still
              authenticates from it.

        Never hand-edit ~/.specrelay/runner/connections.json. The commands above (and
        the dashboard) are the supported way to inspect and clean up local state; they
        write it atomically and keep its 0600 permissions.

        Advanced / legacy — supported for an existing hand-written setup, and NOT the
        documented way to set a machine up:

          specrelay-runner register --config <path>
              Enroll with a one-time registration token (read from the env var named
              by runner.registration_token_env, default
              SPECRELAY_RUNNER_REGISTRATION_TOKEN) and PRINT the durable credential
              once for you to export as SPECRELAY_RUNNER_CREDENTIAL. Unlike
              `connect`, it grants no workspace access on its own: a runner enrolled
              this way shows as `legacy setup` in Platform and can claim nothing
              until it completes `connect` for a workspace.

          specrelay-runner claim-once --config <path>
              Claim using a hand-written config file and a credential from the
              environment. An explicit --config always wins over a stored connection.

          specrelay-runner version
          specrelay-runner help
      HELP
      SUCCESS
    end
  end
end
