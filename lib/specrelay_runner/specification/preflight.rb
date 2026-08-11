# frozen_string_literal: true

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
      # Runner-owned isolated worktree the package is written into (MAPIAI-62 design 1).
      Ready = Struct.new(:package_path, :seed_root, :workspace, :source, :inputs, :provider, :revision,
                        keyword_init: true) do
        def refused? = false
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
      # The source checkout is resolved BEFORE the state root is established, because the state
      # root cannot be judged without it: "is this directory inside a repository the operator
      # owns" is a question about both checkouts (review-001 F1).
      def finish(seed, package)
        source_root = resolve_source_root
        return source_root if source_root.is_a?(Refusal)

        root = prepare_workspace_root(seed, source_root)
        return root if root.is_a?(Refusal)

        gather_and_verify(seed, package, source_root)
      end

      def gather_and_verify(seed, package, source_root)
        # Resolved ONCE, before anything reads it, because it can refuse: a profile Platform
        # named but this runner will not launch has to become a refusal here rather than an
        # exception raised from inside evidence gathering.
        profile = claude_profile
        return profile if profile.is_a?(Refusal)

        # The SAME real Claude profile {resolve_provider} would use, offered here as the ordinary
        # external-reference analyzer (MVP-0028 remediation, defect 2 — review-005 finding F2).
        inputs = InputEvidence.gather(assignment: assignment, settings: settings, env: env,
                                      claude_profile: profile)
        blocked = check_inputs(inputs)
        return blocked if blocked

        source = source_gatherer.gather(root: source_root, settings: settings, env: env)
        tools = check_tools(source)
        return tools if tools

        provider = resolve_provider(profile)
        return provider if provider.is_a?(Refusal)

        redaction = check_redaction
        return redaction if redaction

        revision = resolve_revision(seed, package)
        return revision if revision.is_a?(Refusal)

        # LAST, and only once every read-only check has passed. The isolated workspace is the
        # first and only thing this class creates, so "a refusal wrote nothing" stays a property
        # of the control flow: there is no path from any `refuse` above to this line.
        workspace = create_workspace(seed, package)
        return workspace if workspace.is_a?(Refusal)

        Ready.new(package_path: package, seed_root: seed, workspace: workspace, source: source,
                  inputs: inputs, provider: provider, revision: revision)
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
      def resolve_revision(seed, package)
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

        previous = PreviousSpecificationPackage.call(commands: commands, branch: existing.branch,
                                                     package_path: package.relative_package_path)
        return refuse(SPECIFICATION_REVISION_UNREADABLE, previous.message) unless previous.ok?

        previous
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
      #   1. this runner's own `runner.executor:` block, when the operator hand-wrote one —
      #      an operator who names a profile locally has decided, exactly as they have for
      #      every other setting with both a local and a Platform source;
      #   2. otherwise the profile Platform's Project Setup selected and sent with this
      #      assignment (MVP-0028 remediation, defect 4).
      #
      # Order 2 is the ordinary case and used to be missing entirely, which is what made a
      # correctly configured project refuse: a guided connection writes no YAML, so step 1
      # is nil for every runner set up the supported way.
      def claude_profile
        config.selected_claude_profile || assignment.selected_claude_profile
      rescue ClaudeProfile::Error => e
        refuse(GENERATION_PROVIDER_UNAVAILABLE, e.message)
      end

      def resolve_provider(profile)
        # Provider.resolve turns a nil profile into a refusal rather than a quiet fixture. The
        # message is Provider's own except when Platform selected a profile this lane has no
        # provider for — the fixture — where naming the selection is the difference between an
        # operator re-reading their YAML and going back to the screen they chose it on.
        @injected_provider || Provider.resolve(settings: settings, claude_profile: profile, env: env)
      rescue Provider::Unavailable, Settings::Error => e
        refuse(GENERATION_PROVIDER_UNAVAILABLE, provider_unavailable_message(e))
      end

      def provider_unavailable_message(error)
        profile = assignment.selected_provider_profile
        return error.message if profile.empty? || profile == ClaudeProfile::PROVIDER

        "#{error.message} This project's workspace is set to the `#{profile}` executor profile in " \
          "Platform's Project Setup, and the specification lane has no provider for it: select " \
          "\"Claude Code (real provider)\" there, or choose a specification provider explicitly."
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
