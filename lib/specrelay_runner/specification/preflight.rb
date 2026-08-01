# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # Everything that must be true BEFORE the first output byte exists (MVP-0026 scope 8).
    #
    # This class is the load-bearing safety property of the whole MVP. Criterion 5 does not
    # ask for a generation that cleans up after itself when a capability turns out to be
    # missing — it asks for one that never starts. So every check lives here, ahead of the
    # writer, and this class performs NO write of any kind: it stats paths, reads
    # configuration, probes read-only tools, and returns a verdict. The proof that zero
    # output files were written after a refusal is therefore structural — there is no code
    # path from a refusal to a file handle — rather than a promise backed by a cleanup
    # routine that might itself fail.
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
      SPECIFICATION_FOLDER_UNWRITABLE = "specification_folder_unwritable"
      EXISTING_PACKAGE_PRESENT = "existing_package_present"
      SOURCE_WORKSPACE_UNRESOLVED = "source_workspace_unresolved"
      INPUT_CONTENT_UNREADABLE = "input_content_unreadable"
      EXTERNAL_REFERENCE_ANALYSIS_UNAVAILABLE = "external_reference_analysis_unavailable"
      GRAPHIFY_UNAVAILABLE = "graphify_unavailable"
      CONTEXT_PLUS_UNAVAILABLE = "context_plus_unavailable"
      GENERATION_PROVIDER_UNAVAILABLE = "generation_provider_unavailable"
      REDACTION_VALIDATION_UNAVAILABLE = "redaction_validation_unavailable"

      FAILURE_CLASSES = [
        ASSIGNMENT_MALFORMED, SPECIFICATION_REPOSITORY_UNRESOLVED, SPECIFICATION_FOLDER_UNSAFE,
        SPECIFICATION_FOLDER_UNWRITABLE, EXISTING_PACKAGE_PRESENT, SOURCE_WORKSPACE_UNRESOLVED,
        INPUT_CONTENT_UNREADABLE, EXTERNAL_REFERENCE_ANALYSIS_UNAVAILABLE, GRAPHIFY_UNAVAILABLE,
        CONTEXT_PLUS_UNAVAILABLE, GENERATION_PROVIDER_UNAVAILABLE, REDACTION_VALIDATION_UNAVAILABLE
      ].freeze

      # A refusal. `message` is written for the operator who has to fix it, so it names the
      # variable, the path, or the configuration key — never just the condition.
      Refusal = Struct.new(:failure_class, :message, keyword_init: true) do
        def refused? = true
      end

      # Everything the later stages need, gathered once. Passing this forward rather than
      # re-deriving is what guarantees the writer targets the very path preflight validated.
      Ready = Struct.new(:package_path, :checkout_root, :source, :inputs, :provider, keyword_init: true) do
        def refused? = false
      end

      def self.call(**kwargs) = new(**kwargs).call

      def initialize(assignment:, settings:, config:, env: ENV, provider: nil, source_gatherer: SourceEvidence)
        @assignment = assignment
        @settings = settings
        @config = config
        @env = env
        @injected_provider = provider
        @source_gatherer = source_gatherer
      end

      def call
        checkout = resolve_specification_checkout
        return checkout if checkout.is_a?(Refusal)

        package = resolve_package_path(checkout)
        return package if package.is_a?(Refusal)

        finish(checkout, package)
      rescue Assignment::Malformed => e
        refuse(ASSIGNMENT_MALFORMED, e.message)
      end

      private

      attr_reader :assignment, :settings, :config, :env, :source_gatherer

      # The remaining checks, after the two that can each end the run on their own. Split
      # out so the entry point stays a readable sequence rather than a nested chain of
      # early returns.
      def finish(checkout, package)
        writable = check_writable(checkout, package)
        return writable if writable

        existing = check_existing_package(package)
        return existing if existing

        source_root = resolve_source_root
        return source_root if source_root.is_a?(Refusal)

        gather_and_verify(checkout, package, source_root)
      end

      def gather_and_verify(checkout, package, source_root)
        inputs = InputEvidence.gather(assignment: assignment, settings: settings)
        blocked = check_inputs(inputs)
        return blocked if blocked

        source = source_gatherer.gather(root: source_root, settings: settings, env: env)
        tools = check_tools(source)
        return tools if tools

        provider = resolve_provider
        return provider if provider.is_a?(Refusal)

        redaction = check_redaction
        return redaction if redaction

        Ready.new(package_path: package, checkout_root: checkout, source: source, inputs: inputs,
                  provider: provider)
      end

      # The operator's local clone of the specification repository. Platform knows the
      # repository URL; only this machine knows where it is checked out, and it is never
      # cloned automatically — a runner that silently cloned a repository would be doing
      # network work nobody asked for, into a directory nobody chose.
      def resolve_specification_checkout
        slug = assignment.target_slug || assignment.repository_url
        root = settings.repository_root(slug, repository_url: assignment.repository_url)
        return missing_checkout(slug) if root.nil?

        expanded = File.expand_path(root)
        return refuse(SPECIFICATION_REPOSITORY_UNRESOLVED,
                      "the configured specification repository checkout does not exist: #{expanded}") unless
          File.directory?(expanded)

        expanded
      end

      def missing_checkout(slug)
        refuse(SPECIFICATION_REPOSITORY_UNRESOLVED,
               "no local checkout is configured for the specification repository " \
               "#{assignment.repository_url}. Set #{settings.repository_root_env(slug)} to its absolute path, " \
               "or add it under runner.specification.repository_roots.")
      end

      def resolve_package_path(checkout)
        PackagePath.build(checkout_root: checkout, specification_root: assignment.specification_root,
                          issue_key: assignment.issue_key, summary: assignment.issue_title)
      rescue PackagePath::Unsafe => e
        refuse(SPECIFICATION_FOLDER_UNSAFE, e.message)
      end

      # Writability, established WITHOUT writing. The nearest existing ancestor of the
      # target is stat-ed, because the package folder itself usually does not exist yet and
      # `File.writable?` on a missing path is always false. Creating a probe file to find
      # out would be the one thing this class must not do.
      def check_writable(checkout, package)
        target = package.absolute_package_path
        ancestor = existing_ancestor(target)
        return nil if ancestor && File.writable?(ancestor)

        refuse(SPECIFICATION_FOLDER_UNWRITABLE,
               "the configured specification folder is not writable: " \
               "#{package.relative_package_path} under #{checkout}")
      rescue PackagePath::Unsafe => e
        refuse(SPECIFICATION_FOLDER_UNSAFE, e.message)
      end

      def existing_ancestor(path)
        current = path
        current = File.dirname(current) until File.directory?(current) || File.dirname(current) == current
        File.directory?(current) ? current : nil
      end

      # Scope 10's replace-or-refuse choice, evaluated here rather than in the writer so the
      # `refuse` half never reaches a staging directory at all. The default is `replace`;
      # this is only reached when an operator configured otherwise.
      def check_existing_package(package)
        return nil if settings.replace_existing? || !package.exists?

        refuse(EXISTING_PACKAGE_PRESENT,
               "a generated package already exists at #{package.relative_package_path} and this runner is " \
               "configured with on_existing_package: refuse. Remove or move it, or set " \
               "#{Settings::EXISTING_POLICY_ENV}=replace.")
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
        return context_plus_refusal unless settings.context_plus.usable?

        nil
      end

      def graphify_refusal(source)
        refuse(GRAPHIFY_UNAVAILABLE,
               "#{source.graphify.summary}. Rebuild it with `#{SourceEvidence::GRAPH_CHECK}` / " \
               "`bin/graph-build` in the source checkout, or record an approved source-based substitute " \
               "under runner.specification.graphify.substitute.")
      end

      def context_plus_refusal
        refuse(CONTEXT_PLUS_UNAVAILABLE,
               "Context+ is required for this lane and is neither available nor substituted on this runner. " \
               "Set runner.specification.context_plus.available, or record what was used instead under " \
               "runner.specification.context_plus.substitute.")
      end

      def resolve_provider
        @injected_provider || Provider.resolve(settings: settings, env: env)
      rescue Provider::Unavailable, Settings::Error => e
        refuse(GENERATION_PROVIDER_UNAVAILABLE, e.message)
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
