# frozen_string_literal: true

require "fileutils"

module SpecrelayRunner
  module Specification
    # Everything that must be true BEFORE the first output byte exists (MVP-0026 scope 8).
    #
    # This class is the load-bearing safety property of the whole MVP. Criterion 5 does not
    # ask for a generation that cleans up after itself when a capability turns out to be
    # missing — it asks for one that never starts. So every check lives here, ahead of the
    # writer: it stats paths, reads configuration, probes read-only tools, and returns a
    # verdict. The proof that zero output files were written after a refusal is therefore
    # structural — there is no code path from a refusal to a file handle — rather than a
    # promise backed by a cleanup routine that might itself fail.
    #
    # MAPIAI-62 gave it ONE creation, and placed it deliberately: the Runner-owned isolated
    # worktree the package will be written into is created as the LAST step, after every check
    # that can refuse has passed. So the class still writes nothing an operator owns, still
    # writes nothing on any refusal path, and satisfies design 1's "create and validate the
    # isolated workspace before launching the provider" as an ordering the code cannot get
    # wrong rather than a rule the orchestrator has to remember.
    #
    # Workspace-grounded generation gave it a SECOND creation, and the two are different in
    # kind. The ticket's
    # canonical TASK WORKSPACE is the prepared multi-repository source state a specification is
    # written from: the provider runs there, Graphify and Context+ resolve there, and the package
    # is materialized there. It is built through the project's own `bin/worktree` — the same
    # single authority the implementation lane uses, so the two lanes cannot disagree about what
    # a task environment is — and it is deliberately built BEFORE evidence gathering, because
    # evidence gathered anywhere else would describe a checkout the provider never sees.
    #
    # A refusal after that point therefore no longer means "nothing was created". It still means
    # no output file was written, which is the property criterion 5 asks for; the task workspace
    # is a durable, inspectable environment the operator's own tooling created and owns, and this
    # class never cleans one up to make a failure look tidier.
    #
    # The ORDER is deliberate and is part of the contract. Checks run cheapest-and-most-
    # fundamental first, so the operator is told the one thing they must fix first rather
    # than the last thing that happened to fail. An assignment that names no repository can
    # produce no useful message about a missing generation provider.
    #
    # Each refusal carries a STABLE failure class. Platform persists it verbatim and the run
    # page branches on it, so these tokens are a wire contract: they may be added to, never
    # renamed.
    class Preflight
      # Ordered exactly as they are evaluated.
      ASSIGNMENT_MALFORMED = "assignment_malformed"
      SPECIFICATION_REPOSITORY_UNRESOLVED = "specification_repository_unresolved"
      SPECIFICATION_FOLDER_UNSAFE = "specification_folder_unsafe"
      # The source state a specification must be grounded in could not be resolved. It now covers
      # three conditions, because all three are that one fact and each carries its own remedy in
      # the message: the workspace mapping is missing, the ticket's canonical task environment
      # could not be built or reused, or the ticket's accepted implementation could not be placed
      # in it. They are deliberately NOT three tokens: the generation-result contract's failure
      # classes are a closed set this delivery is not authorized to widen, and a class the
      # contract refuses would be worse than one message an operator has to read.
      SOURCE_WORKSPACE_UNRESOLVED = "source_workspace_unresolved"
      # MAPIAI-62 — this runner cannot hold a package workspace: its state root is unusable, sits
      # inside one of the operator's checkouts (review-001 F1), the seed has no resolvable commit,
      # or `git worktree add` refused. It REPLACES `specification_folder_unwritable` and
      # `existing_package_present`, both of which were statements about the operator's checkout as
      # a destination. It is not one of them renamed: the condition, the remedy and the directory
      # are all different, and the two old classes describe a path this ticket deletes.
      #
      # It is evaluated after the source workspace because judging the state root needs both
      # checkouts in hand.
      PACKAGE_WORKSPACE_UNAVAILABLE = "package_workspace_unavailable"
      INPUT_CONTENT_UNREADABLE = "input_content_unreadable"
      EXTERNAL_REFERENCE_ANALYSIS_UNAVAILABLE = "external_reference_analysis_unavailable"
      GRAPHIFY_UNAVAILABLE = "graphify_unavailable"
      CONTEXT_PLUS_UNAVAILABLE = "context_plus_unavailable"
      GENERATION_PROVIDER_UNAVAILABLE = "generation_provider_unavailable"
      REDACTION_VALIDATION_UNAVAILABLE = "redaction_validation_unavailable"
      # MVP-0028 decision D6 — a same-ticket revision fails CLOSED at two distinct points, each
      # with its own operator-actionable remedy: the pull request itself is unusable (closed,
      # merged, wrong repository, wrong base, unreadable — the same judgment {ExistingPullRequest}
      # already makes at publication time), or it is usable but its previous package could not be
      # read off its branch (a git-level failure, or the branch genuinely carries none).
      SPECIFICATION_REVISION_PULL_REQUEST_UNUSABLE = "specification_revision_pull_request_unusable"
      SPECIFICATION_REVISION_UNREADABLE = PreviousSpecificationPackage::UNREADABLE

      FAILURE_CLASSES = [
        ASSIGNMENT_MALFORMED, SPECIFICATION_REPOSITORY_UNRESOLVED, SPECIFICATION_FOLDER_UNSAFE,
        SOURCE_WORKSPACE_UNRESOLVED, PACKAGE_WORKSPACE_UNAVAILABLE,
        INPUT_CONTENT_UNREADABLE, EXTERNAL_REFERENCE_ANALYSIS_UNAVAILABLE, GRAPHIFY_UNAVAILABLE,
        CONTEXT_PLUS_UNAVAILABLE, GENERATION_PROVIDER_UNAVAILABLE, REDACTION_VALIDATION_UNAVAILABLE,
        SPECIFICATION_REVISION_PULL_REQUEST_UNUSABLE, SPECIFICATION_REVISION_UNREADABLE
      ].freeze

      # A refusal. `message` is written for the operator who has to fix it, so it names the
      # variable, the path, or the configuration key — never just the condition.
      Refusal = Struct.new(:failure_class, :message, keyword_init: true) do
        def refused? = true
      end

      # Everything the later stages need, gathered once. Passing this forward rather than
      # re-deriving is what guarantees the writer targets the very workspace preflight created.
      # `revision` is nil for a first specification and a {PreviousSpecificationPackage::Result}
      # for a same-ticket revision (MVP-0028 decision D6).
      #
      # `seed_root` is the operator's checkout, and it is named that way on purpose: it is a
      # validated git seed and credential source, never a destination. `workspace` is the
      # Runner-owned isolated worktree the package is SNAPSHOTTED into for publication, and
      # `task_root` is the ticket's canonical task workspace the provider runs in and the package
      # is materialized into.
      #
      # `task_reused` is false when THIS run built the environment. It is evidence rather than
      # control flow by the time it reaches here — the one decision that depends on it, how an
      # accepted implementation is placed, is already made below.
      #
      # `repository_state` is that environment as it stood the instant before the provider was
      # launched, captured by {repository_state}. It travels forward because the only honest way
      # to say what a provider changed is to compare with what was there first; asking the tree
      # afterwards answers a different question, and answers it wrongly for any provider that
      # committed.
      # `workspace_root` is the operator's MAIN workspace checkout — the directory the task
      # environment is built inside. It is carried for one reason: it is a private local path,
      # the task workspace is no longer it, and a generated document that echoed it would put
      # this machine's layout into a durable specification.
      Ready = Struct.new(:package_path, :seed_root, :workspace_root, :task_root, :task_reused,
                        :workspace, :source, :inputs, :provider, :revision, :repository_state,
                        keyword_init: true) do
        def refused? = false
      end

      BOUNDARY_TIMEOUT_SECONDS = 120

      # THE STATE of a prepared task environment, and what it means for it to have changed.
      #
      # ONE authority, because three callers ask about the same environment at three moments and
      # must not disagree: this class asks it to decide whether an EXISTING environment may be
      # reused, it asks it again to record the state a provider is about to be let loose in, and
      # {Generation} asks it afterwards to decide whether the result may be published. A second
      # implementation is how a run could reuse an environment it would then refuse to publish
      # from — or, worse, publish one it never actually measured.
      #
      # The state is captured PER REPOSITORY, over every git root the environment CONTAINS. The
      # workspace repository's own status cannot see inside an independent checkout, and the
      # inspected set is deliberately not derived from the identity map: a repository whose
      # `origin` this product does not recognise is still a repository the provider can rewrite,
      # and deriving the set from identity is what let a re-pointed remote remove one from
      # measurement entirely.
      #
      # What is recorded is the minimum that makes a mutation detectable and nothing more: the
      # branch, the head, the `origin` value, and the change set. A commit, a reset, a branch
      # switch and a replaced remote all move one of the first three; ordinary work moves the
      # last. No file contents, no index state, no timestamps — this is a comparison, not a
      # backup, and it deliberately adds no watcher, lock or snapshot store.
      #
      # NIL is a refusal input, never an empty answer: an environment that cannot be inspected is
      # not an unchanged one.
      #
      # `--untracked-files=all` is load-bearing rather than thorough. Git's DEFAULT collapses an
      # untracked directory to its own name, so an environment whose specification root is itself
      # untracked reports that root — the ANCESTOR of the allowed path — and every run would refuse
      # for a directory it was told to write in. Asking for files makes each path comparable on its
      # own terms, and a stray file beside the package is still seen individually.
      #
      # Read-only. Nothing here stages an intent-to-add, so asking leaves every index untouched.
      def self.repository_state(task_root:, env: ENV)
        contained = ContainedRepositories.discover(task_root)
        return nil unless contained.ok?

        ([ task_root ] + contained.roots.to_a).each_with_object({}) do |root, state|
          prefix = contained_prefix(task_root, root)
          return nil if prefix.nil?
          # The task root is normally a git worktree and so is discovered as well; keying by its
          # place in the environment is what makes the two spellings one repository.
          next if state.key?(prefix)

          facts = repository_facts(root, prefix, env)
          return nil if facts.nil?

          state[prefix] = facts
        end
      end

      # The offending task-relative paths of a captured state, or `[]` when only the allowed
      # directory changed. Kept separate from {repository_state} because the state is a fact about
      # the environment while "allowed" is a fact about this run.
      def self.changes_outside_package(state, allowed)
        state.values.flat_map { |facts| facts[:changes] }
             .reject { |path| path == allowed || path.start_with?("#{allowed}/") }
      end

      # WHAT CHANGED in a prepared task environment, outside one allowed directory, as a single
      # question. This is the reuse-time form: there is no earlier state to compare against, so
      # the environment is judged on what it currently holds.
      def self.changes_outside(task_root:, allowed:, env: ENV)
        state = repository_state(task_root: task_root, env: env)
        state && changes_outside_package(state, allowed)
      end

      # WHAT THE PROVIDER DID, as the difference between the state captured before it ran and the
      # state now, plus anything the environment holds outside the allowed directory.
      #
      # Both halves are needed and neither implies the other. A provider that COMMITS its change
      # leaves a clean status and is only visible as a moved head; a provider that drops a scratch
      # file leaves the head alone. Each entry names the repository by its task-relative path and
      # states the fact, never the value — an `origin` can carry credential userinfo, and this
      # text travels to Platform.
      def self.state_differences(before:, after:, allowed:)
        (before.keys - after.keys).map { |prefix| "#{named(prefix)}: the repository is gone" } +
          (after.keys - before.keys).map { |prefix| "#{named(prefix)}: a repository appeared here" } +
          (before.keys & after.keys).flat_map { |prefix| moved(prefix, before[prefix], after[prefix]) } +
          changes_outside_package(after, allowed).sort
      end

      # The three facts a provider must leave exactly as it found them.
      def self.moved(prefix, before, after)
        { branch: "its checked-out branch", head: "its head commit",
          origin: "its `origin` remote" }.filter_map do |fact, description|
          "#{named(prefix)}: #{description} changed" unless before[fact] == after[fact]
        end
      end

      def self.named(prefix) = prefix.empty? ? "the workspace repository" : prefix

      # One repository's comparable state, or nil when git could not answer at all. A missing
      # `origin` or an unborn head is a legitimate state and compares as such; a failed `status`
      # is not, because it means the tree was not measured.
      def self.repository_facts(root, prefix, env)
        status = git_result(root, %w[status --porcelain --untracked-files=all], env)
        return nil if status.nil?

        { branch: git_value(root, %w[rev-parse --abbrev-ref HEAD], env),
          head: git_value(root, %w[rev-parse HEAD], env),
          origin: git_value(root, %w[remote get-url origin], env),
          changes: changed_paths(status, prefix) }
      end

      def self.git_result(root, args, env)
        result = CommandRunner.run(
          [ "git", "-C", root, *args ], chdir: root,
          env: { "PATH" => env["PATH"].to_s }, timeout_seconds: BOUNDARY_TIMEOUT_SECONDS
        )
        result.exit_code.to_i.zero? ? result.stdout.to_s : nil
      rescue SystemCallError
        nil
      end

      def self.git_value(root, args, env) = git_result(root, args, env)&.strip

      def self.changed_paths(status, prefix)
        status.each_line.filter_map do |line|
          path = changed_path(line)
          next if path.nil?

          prefix.empty? ? path : "#{prefix}/#{path}"
        end
      end

      # Where a contained repository sits inside the task environment. Resolved through real paths
      # on both sides, so a symlinked or `/private`-prefixed root cannot make a contained
      # repository look like a sibling of the environment.
      def self.contained_prefix(task_root, root)
        task = File.realpath(task_root)
        resolved = File.realpath(root)
        resolved == task ? "" : resolved.delete_prefix("#{task}/")
      rescue SystemCallError
        nil
      end

      # `XY <path>`, or `XY <old> -> <new>` for a rename, where the new name is the one on disk.
      def self.changed_path(line)
        entry = line.chomp[3..].to_s
        return nil if entry.empty?

        entry.include?(" -> ") ? entry.split(" -> ").last : entry
      end

      def self.call(**kwargs) = new(**kwargs).call

      def initialize(assignment:, settings:, config:, env: ENV, provider: nil,
                     source_gatherer: SourceEvidence, workspaces: nil, clock: Time)
        @assignment = assignment
        @settings = settings
        @config = config
        @env = env
        @injected_provider = provider
        @source_gatherer = source_gatherer
        @workspaces = workspaces || PackageWorkspaceStore.for(env: env)
        @clock = clock
      end

      def call
        seed = resolve_seed_checkout
        return seed if seed.is_a?(Refusal)

        package = resolve_package_path
        return package if package.is_a?(Refusal)

        finish(seed, package)
      rescue Assignment::Malformed => e
        refuse(ASSIGNMENT_MALFORMED, e.message)
      end

      private

      attr_reader :assignment, :settings, :config, :env, :source_gatherer, :workspaces, :clock

      # The remaining checks, after the two that can each end the run on their own. Split
      # out so the entry point stays a readable sequence rather than a nested chain of
      # early returns.
      #
      # The exact profile is resolved FIRST, and resolved once. It is a pure comparison against a
      # canonical hash that can refuse, and everything below it either reads the operator's disk
      # or writes to this machine: `prepare_workspace_root` runs `FileUtils.mkdir_p` on the runner
      # state root. An unknown, missing, extra or altered profile therefore refuses before any of
      # it, which is what makes "a refused claim created nothing" a property of this order rather
      # than a claim about the cleanup path.
      #
      # The seed and destination checks in {#call} stay ahead of it: both are pure reads that can
      # each end the run on their own, and neither touches anything.
      #
      # The source checkout is resolved BEFORE the state root is established, because the state
      # root cannot be judged without it: "is this directory inside a repository the operator
      # owns" is a question about both checkouts (review-001 F1).
      def finish(seed, package)
        profile = selected_profile
        return profile if profile.is_a?(Refusal)

        source_root = resolve_source_root
        return source_root if source_root.is_a?(Refusal)

        root = prepare_workspace_root(seed, source_root)
        return root if root.is_a?(Refusal)

        gather_and_verify(seed, package, source_root, profile)
      end

      # `profile` arrives already resolved and already proven launchable. It is passed forward
      # rather than asked for again: a second call would be a second judgement of the same claim,
      # and the one place that decides which provider may run is the point of this lane.
      def gather_and_verify(seed, package, source_root, profile)
        # External-reference analysis is a separate OPTIONAL capability with a Claude-only
        # analyzer, so it is offered the selected profile only when that profile IS Claude. A
        # Codex-generating runner keeps the existing explicit refusal/substitute behaviour for
        # that capability rather than gaining a second analyzer this ticket did not approve.
        inputs = InputEvidence.gather(assignment: assignment, settings: settings, env: env,
                                      claude_profile: (profile if profile.is_a?(ClaudeProfile)))
        blocked = check_inputs(inputs)
        return blocked if blocked

        # The ticket's canonical task workspace, and the accepted implementation it
        # must hold. Everything below reads and runs THERE: gathering evidence from the operator's
        # main checkout and then launching the provider somewhere else would produce a technical
        # analysis about a tree the writer never saw.
        task = prepare_task_workspace(source_root, package)
        return task if task.is_a?(Refusal)

        accepted = materialize_previous_accepted(task)
        return accepted if accepted

        source = source_gatherer.gather(root: task.path, settings: settings, env: env)
        tools = check_tools(source)
        return tools if tools

        provider = resolve_provider(profile, task.path)
        return provider if provider.is_a?(Refusal)

        redaction = check_redaction
        return redaction if redaction

        revision = resolve_revision(seed, package, task)
        return revision if revision.is_a?(Refusal)

        # The BASELINE, taken after everything this class legitimately places in the environment
        # and before anything else can touch it. Later is not an option: from here on the only
        # writer is the provider, and a baseline taken after it would describe its own work.
        state = capture_repository_state(task)
        return state if state.is_a?(Refusal)

        # LAST, and only once every read-only check has passed. The isolated workspace holds the
        # publication snapshot and nothing else, so it is created after everything that could
        # still refuse: there is no path from any `refuse` above to this line.
        workspace = create_workspace(seed, package)
        return workspace if workspace.is_a?(Refusal)

        Ready.new(package_path: package, seed_root: seed, workspace_root: source_root,
                  task_root: task.path, task_reused: !task.created?, workspace: workspace,
                  source: source, inputs: inputs, provider: provider, revision: revision,
                  repository_state: state)
      end

      # The ticket's canonical task workspace, created or reused through the project's own
      # command — {Workspace} is the single authority for what a task environment IS, and the
      # implementation lane builds one exactly this way. A project whose task environment is
      # several repositories can only be assembled by the project itself, so nothing here knows
      # or invents a layout.
      #
      # An existing worktree carrying uncommitted work is refused by that owner rather than
      # reused: a specification written on top of somebody else's half-finished change would
      # describe a tree that is not in any repository.
      def prepare_task_workspace(source_root, package)
        owner = task_workspace_owner(source_root)
        existing = owner.existing
        return reuse_task_workspace(existing, package) if existing

        owner.create
      rescue Workspace::Error => e
        refuse(SOURCE_WORKSPACE_UNRESOLVED, task_unavailable_message(e.message))
      end

      # Built with this generation's Run identity, so the SAME owner gate the implementation lane
      # applies applies here: an environment this run cannot prove it owns is refused before the
      # package is read, before the accepted implementation is reconciled and before the provider
      # is launched. A manual worktree on the canonical branch stays a manual worktree.
      def task_workspace_owner(source_root)
        Workspace.new(root: source_root, canonical_branch: assignment.canonical_branch,
                      task_id: assignment.task_id, run_id: assignment.run_id,
                      create_command: assignment.worktree_create_command,
                      env: { "PATH" => env["PATH"].to_s })
      end

      # An environment that already exists is REUSED when everything changed in it is inside this
      # ticket's own package directory.
      #
      # `Workspace#create`'s own rule — refuse any uncommitted change — is right for the
      # implementation lane and wrong here, and the difference is this lane's own output: a
      # successful generation deliberately LEAVES the package in the environment, so that rule
      # would refuse every re-run and every revision of a ticket this runner had already
      # generated. What must not be reused is an environment holding work this lane did not do,
      # which is exactly the boundary {changes_outside} draws — asked here with the same authority
      # that will judge the result, so reuse and publication cannot disagree.
      def reuse_task_workspace(existing, package)
        outside = self.class.changes_outside(task_root: existing.path, env: env,
                                             allowed: package.relative_package_path)
        return refuse(SOURCE_WORKSPACE_UNRESOLVED, task_unavailable_message(UNINSPECTABLE)) if outside.nil?
        return existing if outside.empty?

        refuse(SOURCE_WORKSPACE_UNRESOLVED,
               task_unavailable_message("it holds #{outside.length} change(s) outside " \
                                        "#{package.relative_package_path}: " \
                                        "#{outside.sort.first(5).join(', ')}. Preserve or release " \
                                        "the task workspace before retrying"))
      end

      # An environment that cannot be measured cannot be handed to a provider: there would be no
      # way afterwards to say what the provider did in it.
      def capture_repository_state(task)
        self.class.repository_state(task_root: task.path, env: env) ||
          refuse(SOURCE_WORKSPACE_UNRESOLVED, task_unavailable_message(UNINSPECTABLE))
      end

      UNINSPECTABLE = "its repositories could not be inspected"

      def task_unavailable_message(reason)
        "the task workspace for #{assignment.task_id} could not be prepared: #{reason}. A " \
          "specification is written from the ticket's own prepared source state, so generation " \
          "stops here rather than inventing one."
      end

      # The implementation lane's own verification authority, reused rather than re-implemented:
      # every accepted repository is proved against GitHub's CURRENT state before anything reads
      # the tree.
      #
      # How it is PLACED depends on who built the environment, and only that. A workspace this run
      # created is put at the exact accepted heads. A reused one is RECONCILED instead: it may
      # already hold newer work for the ticket, and resetting it to the older heads would move the
      # run backward. What a reused workspace does not get is a pass — skipping the proof for one
      # is how a worktree left behind on another runner came to generate a specification from code
      # this ticket never accepted.
      def materialize_previous_accepted(task)
        package = assignment.previous_accepted_claim(env: env).package
        return nil if package.nil?

        result = task.created? ? package.materialize(task_root: task.path)
                               : package.reconcile(task_root: task.path)
        result.ok? ? nil : refuse(SOURCE_WORKSPACE_UNRESOLVED, accepted_unusable_message(result))
      end

      # The accepted implementation is part of the ticket's CURRENT state, so a head this machine
      # cannot confirm stops the run instead of being analysed around.
      def accepted_unusable_message(result)
        "#{result.reason}. The ticket's accepted implementation is part of the source state a " \
          "specification for it must be written from, so generation stops here rather than " \
          "analysing code it cannot confirm was shipped."
      end

      # The workspace, created from the seed at the seed's own resolved HEAD. A sweep runs first
      # so a machine that has accumulated retained workspaces reclaims space before adding one,
      # and `keep` is not needed here because the new id does not exist yet.
      def create_workspace(seed, package)
        workspaces.sweep(clock: clock)
        commands = GitCommands.new(checkout_root: seed, env: env)
        base = commands.git_value(%w[rev-parse HEAD])
        return refuse(PACKAGE_WORKSPACE_UNAVAILABLE, no_base_commit_message(seed)) unless
          GitPublisher::COMMIT_PATTERN.match?(base.to_s)

        workspaces.create(commands: commands, base_commit: base, clock: clock,
                          identity: workspace_identity(package.relative_package_path))
      rescue PackageWorkspace::Error => e
        refuse(PACKAGE_WORKSPACE_UNAVAILABLE, e.message)
      end

      def no_base_commit_message(seed)
        "the specification repository seed on this runner has no resolvable commit, so an " \
          "isolated package worktree cannot be created from it: #{seed}. Fetch or check out the " \
          "repository's default branch there, then retry generation."
      end

      # What this workspace belongs to. Every field is a Platform-supplied identity or a
      # repository-relative path — no credential, no Jira payload, and no local path — because
      # this document is what publication checks a resumed workspace against.
      def workspace_identity(package_path)
        {
          "run_id" => assignment.run_id,
          "runner_execution_id" => assignment.runner_execution_id,
          "runner_id" => assignment.runner_id,
          "runner_public_id" => config.connection&.runner_public_id.to_s,
          "repository_slug" => assignment.target_slug.to_s,
          "repository_url" => assignment.repository_url,
          "package_path" => package_path
        }
      end

      # MVP-0028 decision D6 — nil for a first specification. For a same-ticket revision, this
      # runs the identical judgment {ExistingPullRequest} makes at publication time (the pull
      # request must exist, be open, target the configured base, and belong to this repository)
      # against `specification_target`'s facts rather than `publication`'s — the only section
      # available this early — then reads the previous package off its branch.
      def resolve_revision(seed, package, task)
        url = assignment.revision_pull_request_url
        return nil if url.empty?

        # Read through the SEED, and only with commands that write nothing but FETCH_HEAD and
        # the object database — the same non-mutating pattern {GitPublisher#fetch_base}
        # established. The isolated worktree does not exist yet at this point, and creating it
        # before a check that can still refuse would be the one write a refusal must not make.
        commands = GitCommands.new(checkout_root: seed, env: env)
        existing = ExistingPullRequest.call(commands: commands, slug: assignment.target_slug,
                                           base_branch: assignment.default_branch, url: url)
        return refuse(SPECIFICATION_REVISION_PULL_REQUEST_UNUSABLE, existing.message) unless existing.ok?

        foreign = check_revision_branch(existing.branch)
        return foreign if foreign

        previous = PreviousSpecificationPackage.call(commands: commands, branch: existing.branch,
                                                     package_path: package.relative_package_path)
        return refuse(SPECIFICATION_REVISION_UNREADABLE, previous.message) unless previous.ok?

        materialize_revision(task, package, previous) || previous
      end

      # A ticket owns ONE branch, so the pull request Jira links must be on it.
      #
      # {ExistingPullRequest} answers "is this a pull request SpecRelay may push to" — open, on
      # this repository, against this base, not a fork. It cannot answer "is it THIS TICKET's",
      # because that is Platform's fact and arrives in the assignment. A pull request that passes
      # every other check while sitting on another branch is a different ticket's review object,
      # or a leftover from when the two lanes named branches separately; reading a "previous
      # package" off it would hand the provider a specification from a history this ticket does
      # not own, and publication would then refuse it after a provider had already run.
      #
      # Refused HERE, before the previous package is read and before the provider is launched, so
      # a mismatch costs one `gh` call and leaves nothing behind. It reuses the revision refusal
      # class rather than adding a wire token: this IS the linked pull request being unusable for
      # this revision, which is exactly what that class already names.
      #
      # The OBSERVED head branch is deliberately not in the message. It is a value GitHub
      # reported for a pull request an operator pasted into a Jira field — external input on its
      # way to a Platform record, a run page and a log — and this refusal is already fully
      # actionable from the two facts SpecRelay itself owns: which ticket, and which branch that
      # ticket may be revised on.
      def check_revision_branch(head_branch)
        return nil if head_branch == assignment.canonical_branch

        refuse(SPECIFICATION_REVISION_PULL_REQUEST_UNUSABLE,
               "the specification pull request #{assignment.issue_key} links is not on that " \
               "ticket's branch #{assignment.canonical_branch}, so it is not this ticket's pull " \
               "request. Clear the Jira Spec PR field to start one on " \
               "#{assignment.canonical_branch}, then run specification creation again")
      end

      # The ticket's canonical branch in the task environment, put ON the published head the
      # previous package was just read from.
      #
      # It used to COPY those files into the package directory instead, and that is wrong in the
      # shape the product actually runs: publication builds its commit with plumbing and pushes
      # it, so an accepted round leaves the package on the remote branch and no local branch at
      # all. A task environment built afterwards branches from the base, the copy lands as
      # UNTRACKED files, and the round that revises a published specification cannot see the
      # history it is revising — `git status`, `git log` and every diff describe a first draft.
      # Checking the branch out at the published head makes the same bytes TRACKED, which is what
      # the provider, the change boundary and publication all already assume.
      #
      # PLACED for an environment this run built and RECONCILED for one it reused — the same
      # distinction, for the same reason, as {materialize_previous_accepted}: a created
      # environment has nothing to lose, while a reused one may already carry the ticket's later
      # work and must never be rewound.
      #
      # It imports the validated pull request's branch and nothing else. Every check that decides
      # WHICH history this is has already run — the pull request is open, on this repository,
      # against the configured base, not a fork, and on this ticket's own branch — and the exact
      # commit is required to be present here afterwards, so a branch that moved, was
      # force-pushed, or belongs to another clone refuses instead of being checked out.
      #
      # CONTAINMENT is resolved FIRST, before either path acts, and it guards both. A
      # specification root that resolves through a symbolic link puts the package directory
      # outside the task environment, and a checkout is not the harmless half of that: `git reset
      # --hard` replaces whatever stands at the package path with the published tree, so a link an
      # operator committed is discarded by the very step that would otherwise never have been
      # reached. The same {PackagePath} judgment that refuses to WRITE through such a root
      # therefore refuses to reset onto it.
      def materialize_revision(task, package, previous)
        destination = package.absolute_in(task.path)
        commands = GitCommands.new(checkout_root: task.path, env: env)
        return place_revision_files(destination, previous) unless specification_checkout?(commands)

        return revision_refusal(unreachable_head_message(previous)) unless available?(commands, previous)

        return reset_to(commands, previous) if task.created?
        return nil if ancestor?(commands, previous.commit, "HEAD")
        return reset_to(commands, previous) if ancestor?(commands, "HEAD", previous.commit)

        revision_refusal(diverged_message(previous))
      rescue PackagePath::Unsafe, SystemCallError, IOError => e
        revision_refusal("the previous specification package could not be placed in the task " \
                         "workspace: #{e.class}")
      end

      # The validated head, in THIS checkout. An environment created for this run has never seen
      # the published branch, so one fetch is the ordinary path rather than a repair: the package
      # is read through the specification checkout, and `repository_roots` and `workspace_roots`
      # are separate settings, so the environment need not be built from that same clone.
      #
      # A fetch that still cannot produce the commit is refused rather than fallen through, and
      # the refusal has to be its own: the checks below would read a commit this checkout has
      # never seen as a divergence, which is a different thing to tell an operator.
      def available?(commands, previous)
        return true if commit?(commands, previous.commit)

        commands.git([ "fetch", "--quiet", PreviousSpecificationPackage::REMOTE, previous.branch ])
        commit?(commands, previous.commit)
      end

      def commit?(commands, commit) = commands.success?([ "cat-file", "-e", "#{commit}^{commit}" ])

      def ancestor?(commands, ancestor, descendant)
        commands.success?([ "merge-base", "--is-ancestor", ancestor, descendant ])
      end

      # `reset --hard` rather than `checkout` or `merge --ff-only`, because the package directory
      # legitimately holds an earlier round's untracked copy of these very files and both of those
      # abort rather than replace one. What it can discard is bounded before this runs:
      # {reuse_task_workspace} already refused every environment carrying a change outside this
      # ticket's package directory.
      def reset_to(commands, previous)
        return nil if commands.success?([ "reset", "--hard", "--quiet", previous.commit ])

        revision_refusal("this ticket's task environment could not be put on " \
                         "#{assignment.canonical_branch} at the published specification head " \
                         "#{previous.commit[0, 12]}. Release the task environment, then run " \
                         "specification creation again")
      end

      def unreachable_head_message(previous)
        "the specification pull request #{assignment.issue_key} links was read at " \
          "#{previous.commit[0, 12]}, and this ticket's task environment cannot reach that commit. " \
          "Check that #{assignment.canonical_branch} still carries the published specification, " \
          "then run specification creation again"
      end

      def diverged_message(previous)
        "this ticket's task environment has diverged from the published specification head " \
          "#{previous.commit[0, 12]} on #{assignment.canonical_branch}. Preserve or release the " \
          "task environment, then run specification creation again"
      end

      def revision_refusal(message) = refuse(SPECIFICATION_REVISION_UNREADABLE, message)

      # Is the environment's own repository the one this specification is published to?
      #
      # It is in the shape the product deploys: the workspace whose `bin/worktree` builds the task
      # environment IS the specification repository, so the ticket's canonical branch in that
      # environment is the branch the package is published on. An operator who configures a
      # SEPARATE specification clone has no checkout of it in the environment at all — there is no
      # published history to check out there, and the validated files are placed as files below.
      # That is a different topology rather than an older path: both are supported today, and
      # only one of them HAS a branch to track the package in.
      #
      # Asked of the checkout's own `origin` and resolved to a GitHub `owner/repo`, exactly as
      # {GitPublisher#verify_remote} and {#reuse_source_workspace_checkout} ask it, so the
      # answers cannot disagree. An unresolvable remote is "not it", which keeps the file path —
      # never the reset — as the answer to a question this cannot settle.
      def specification_checkout?(commands)
        slug = RepositorySlug.for(commands.git_value(%w[remote get-url origin]))
        !slug.nil? && slug == assignment.target_slug
      end

      # The pull request's CURRENT package, placed in the ticket package directory the provider
      # works in, for an environment that holds no checkout of the specification repository. The
      # packet already carries the previous text; this is what lets a provider that reads its
      # working directory revise the real files rather than a copy of them, and it is the same
      # directory the new package replaces, so nothing lands outside the one path this run is
      # allowed to change.
      #
      # Every name comes from `git ls-tree` under the package path, so it is repository-relative
      # and cannot traverse: git trees carry no `..` and no absolute entry. `destination` is the
      # contained path {materialize_revision} already resolved, and a write failure surfaces
      # through its refusal.
      def place_revision_files(destination, previous)
        FileUtils.rm_rf(destination)
        previous.files.each do |name, content|
          target = File.join(destination, name)
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, content)
        end
        nil
      end

      # The operator's local clone of the specification repository, resolved as a SEED
      # (MAPIAI-62 design 1). Platform knows the repository URL; only this machine knows where
      # it is checked out, and it is never cloned automatically — a runner that silently cloned
      # a repository would be doing network work nobody asked for, into a directory nobody chose.
      #
      # What this checkout is FOR changed with MAPIAI-62 and the resolution did not: it supplies
      # the git object database, the `origin` remote and the credential helper that the isolated
      # worktree inherits. It is never written to, and nothing downstream is handed it as a
      # destination.
      #
      # An EXPLICIT mapping always wins when one is configured — the same "an operator who
      # named one has decided" precedence {Provider.resolve} uses for the generation provider.
      # Only when none exists is reuse of the source workspace checkout even considered
      # (MVP-0028 remediation, defect 5), and only when it can be VERIFIED, never assumed from
      # workspace naming alone. That reuse stays useful for exactly the reason it was added —
      # locating the seed with no second mapping — and is no longer a way for a package to land
      # in the operator's source checkout.
      def resolve_seed_checkout
        slug = assignment.target_slug || assignment.repository_url
        configured = settings.repository_root(slug, repository_url: assignment.repository_url)
        return resolve_configured_checkout(configured) unless configured.nil?

        reused = reuse_source_workspace_checkout
        return reused unless reused.nil?

        missing_checkout(slug)
      end

      def resolve_configured_checkout(root)
        expanded = File.expand_path(root)
        return refuse(SPECIFICATION_REPOSITORY_UNRESOLVED,
                      "the configured specification repository checkout does not exist: #{expanded}") unless
          File.directory?(expanded)

        expanded
      end

      # Reuse the SOURCE workspace checkout Platform already assigned and this runner already
      # validated (`config.workspace_root`) when it is verifiably a clone of the SAME repository
      # the specification is destined for. Before this, an operator whose specification
      # repository IS their source workspace repository had to configure a second, duplicate
      # mapping under `runner.specification.repository_roots` for the identical clone — a step
      # a guided connection, which writes no runner YAML at all, could never satisfy.
      #
      # Reuse is offered, never assumed. "Same workspace" is not evidence of "same repository":
      # the destination could genuinely be a separate specification repository, and Platform's
      # assignment carries no repository URL for the source workspace to compare against (by
      # design — this lane creates no worktree and runs no test, so it was never given one). So
      # the ONLY safe signal is the workspace checkout's own ACTUAL git remote, verified exactly
      # the way {GitPublisher} verifies a publication checkout: resolved to a GitHub `owner/repo`
      # and compared to the one Platform assigned. Anything inconclusive — no workspace mapping,
      # no remote, a remote that does not resolve, or one that resolves to something else —
      # is treated as "cannot be matched unambiguously" and falls through to the ordinary
      # missing-checkout refusal, which correctly tells the operator to add the explicit mapping
      # instead.
      def reuse_source_workspace_checkout
        expected = assignment.target_slug
        return nil if expected.to_s.empty?

        root = config.workspace_root(assignment.workspace_key, env: env)
        remote = GitCommands.new(checkout_root: root, env: env).git_value(%w[remote get-url origin])
        RepositorySlug.for(remote) == expected ? File.expand_path(root) : nil
      rescue Config::Error
        nil
      end

      def missing_checkout(slug)
        refuse(SPECIFICATION_REPOSITORY_UNRESOLVED,
               "no local checkout is configured for the specification repository " \
               "#{assignment.repository_url}. Set #{settings.repository_root_env(slug)} to its absolute path, " \
               "or add it under runner.specification.repository_roots. If this repository is also this run's " \
               "source workspace, this runner will reuse that checkout automatically once its `origin` remote " \
               "matches — no separate mapping is needed in that case.")
      end

      # The package's repository-relative identity. It is validated here, before any root is
      # bound to it, because everything that can be wrong with it — an absolute or traversing
      # configured folder, an issue key that is not a usable path component — is wrong
      # independently of where the package is written.
      def resolve_package_path
        PackagePath.build(specification_root: assignment.specification_root,
                          issue_key: assignment.issue_key, summary: assignment.issue_title)
      rescue PackagePath::Unsafe => e
        refuse(SPECIFICATION_FOLDER_UNSAFE, e.message)
      end

      # The Runner's own state root, proven DISJOINT from both operator checkouts and then proven
      # writable — in that order, because establishing the root is itself a write, and a root
      # inside a checkout must not create so much as a directory there.
      #
      # review-001 F1: a state root inside a checkout made generation write `swp_<id>/` into a
      # repository the operator owns, while the runner's own output told them their checkout was
      # untouched. Criterion 1 is a statement about their disk, so it is checked against their
      # disk rather than trusted to configuration.
      #
      # Writability is still proven WITHOUT a probe file. This replaces the old writability check
      # on the operator's specification folder: that folder is no longer written to, so its
      # permissions no longer decide whether a generation can succeed.
      def prepare_workspace_root(seed, source_root)
        inside = [ seed, source_root ].find { |checkout| workspaces.overlaps?(checkout) }
        return refuse(PACKAGE_WORKSPACE_UNAVAILABLE, overlapping_root_message(inside)) if inside

        workspaces.prepare!
        nil
      rescue PackageWorkspace::Error, SystemCallError, IOError => e
        refuse(PACKAGE_WORKSPACE_UNAVAILABLE,
               "this runner cannot hold a specification package workspace: #{e.message}. Check that " \
               "#{PackageWorkspaceStore::DEFAULT_RELATIVE_PATH}, under this runner's home directory, " \
               "is a writable location.")
      end

      def overlapping_root_message(checkout)
        "this runner keeps its specification packages in #{workspaces.root}, which is inside the " \
          "repository checkout #{checkout}. Generating there would write into a repository you own, " \
          "so nothing was created. Run this runner as a user whose home directory is outside your " \
          "checkouts, or move the checkout out of the runner's home directory."
      end

      # The SOURCE checkout — the code a specification is being written about, which is a
      # different repository from the one the specification goes into. Resolved through the
      # established runner workspace mapping so this lane and the implementation lane cannot
      # disagree about where a workspace lives.
      def resolve_source_root
        config.workspace_root(assignment.workspace_key, env: env)
      rescue Config::Error => e
        refuse(SOURCE_WORKSPACE_UNRESOLVED,
               "#{e.message}. A specification must be grounded in the real source checkout, so generation " \
               "stops here rather than writing one from the ticket alone.")
      end

      # Inputs the bundle offers but this runner cannot analyse. Split into two failure
      # classes because they need different fixes: a deferred external reference needs an
      # MCP capability or a recorded substitute, while any other unusable status means the
      # bundle and the run disagree and the ticket has to be re-read.
      def check_inputs(inputs)
        return nil unless inputs.blocked?

        deferred = inputs.inputs.reject(&:readable?).select do |input|
          input.read_status == InputEvidence::DEFERRED_TO_RUNNER_MCP
        end
        return external_reference_refusal(inputs) if deferred.any?

        refuse(INPUT_CONTENT_UNREADABLE,
               "required input-bundle content cannot be read: #{inputs.blockers.join('; ')}")
      end

      def external_reference_refusal(inputs)
        refuse(EXTERNAL_REFERENCE_ANALYSIS_UNAVAILABLE,
               "this bundle defers external references to the runner, and this runner cannot analyse them: " \
               "#{inputs.blockers.join('; ')}. Enable the capability, or record a substitute under " \
               "runner.specification.external_references.substitute.")
      end

      def check_tools(source)
        return graphify_refusal(source) unless source.graphify.usable?

        nil
      end

      def graphify_refusal(source)
        refuse(GRAPHIFY_UNAVAILABLE,
               "#{source.graphify.summary}. Rebuild it with `#{SourceEvidence::GRAPH_CHECK}` / " \
               "`bin/graph-build` in the source checkout, or record an approved source-based substitute " \
               "under runner.specification.graphify.substitute.")
      end

      # WHERE the real provider profile comes from, in precedence order:
      #
      #   1. this runner's own `runner.executor:` block, when the operator selected a provider
      #      locally — an operator who names one has decided, exactly as they have for every
      #      other setting with both a local and a Platform source;
      #   2. otherwise the profile Platform's Project Setup selected and sent with this
      #      assignment (MVP-0028 remediation, defect 4).
      #
      # Order 2 is the ordinary case: a guided connection writes no YAML, so step 1 is absent for
      # every runner set up the supported way.
      #
      # A LOCAL SELECTION IS READ AS PRESENT, NOT AS A PROFILE. Both an explicit local fixture and
      # no local block at all resolve to no real profile, and falling through on the first would
      # generate with Platform's provider on a machine whose operator had chosen the deterministic
      # fixture. The selection block itself is what distinguishes them, so it is what is asked.
      def selected_profile
        return config.selected_implementation_profile unless config.executor_override.empty?

        assignment.selected_implementation_profile
      rescue ImplementationProfile::Error => e
        refuse(GENERATION_PROVIDER_UNAVAILABLE, e.message)
      end

      def resolve_provider(profile, working_directory)
        # Provider.resolve turns a nil profile into a refusal rather than a quiet substitute. The
        # message is Provider's own except when Platform selected a profile this lane has no
        # provider for — the fixture — where naming the selection is the difference between an
        # operator re-reading their YAML and going back to the screen they chose it on.
        #
        # `working_directory` is the prepared task workspace. It is bound
        # HERE, where the workspace is known, so no provider can be constructed without one.
        @injected_provider || Provider.resolve(profile: profile, env: env, working_directory: working_directory)
      rescue Provider::Unavailable => e
        refuse(GENERATION_PROVIDER_UNAVAILABLE, provider_unavailable_message(e))
      end

      # When Platform named a profile this lane cannot generate with, its name REPLACES the general
      # refusal rather than being appended to it: the operator needs one remedy, addressed to the
      # screen they actually chose on, not the same advice twice.
      def provider_unavailable_message(error)
        profile = assignment.selected_provider_profile
        return error.message if profile.empty? || ImplementationProfile::OWNERS.key?(profile)

        "this project's workspace is set to the `#{profile}` executor profile in Platform's " \
          "Project Setup, and the specification lane has no provider for it: select `claude` or " \
          "`codex` there, or name one under runner.executor on this runner."
      end

      # Redaction is a pure function in this runner, so "unavailable" can only mean it is
      # not behaving as a redactor. Checked with a known secret shape rather than assumed:
      # criterion 11 makes redaction a precondition of writing anything, and a precondition
      # that is never verified is a comment, not a check.
      def check_redaction
        probe = "Authorization: Bearer abcdefgh12345678"
        return nil unless Redaction.redact(probe).include?("abcdefgh12345678")

        refuse(REDACTION_VALIDATION_UNAVAILABLE,
               "the runner's redaction guard did not remove a known secret shape, so generated output " \
               "cannot be proven safe to write.")
      end

      def refuse(failure_class, message)
        Refusal.new(failure_class: failure_class, message: Redaction.redact(message.to_s))
      end
    end
  end
end
