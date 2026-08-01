# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # READ-ONLY inspection of the execution workspace's source checkout, plus the structural
    # and semantic tool evidence that inspection is corroborated with (MVP-0026 scope 7).
    #
    # This is the class that makes `analysis/technical.md` a technical document rather than
    # a restatement of the Jira ticket. Criterion 4 requires the generated analysis to name
    # real source files, real Graphify output, and real Context+ evidence — so all three are
    # gathered here, from the machine the runner is actually running on, and each is recorded
    # with what it FAILED to provide as well as what it provided.
    #
    # Three rules it exists to enforce:
    #
    #   - Nothing is modified. No file is written, no branch is touched, no command that
    #     could mutate the checkout is run. Scope 7 says "inspect the current source
    #     checkout without modifying it", and the only commands invoked are the read-only
    #     Graphify wrappers.
    #   - Graphify goes through the WORKSPACE WRAPPERS, never bare `graphify`. A bare
    #     invocation resolves `graphify-out/` against the current directory and would read —
    #     or overwrite — another worktree's graph. The wrappers pin it to the checkout they
    #     live in, which is the whole reason they exist.
    #   - A tool that returns nothing is recorded as having returned nothing. A false
    #     negative presented as an absence of impact is the specific failure scope 5 names,
    #     so `notes` carries the honest verdict and the direct-source fallback that was used
    #     instead.
    class SourceEvidence
      # The wrappers, relative to the checkout root. Named as data so the refusal message
      # can print the exact path the operator is missing.
      GRAPH_CHECK = "bin/graph-check"
      GRAPH_QUERY = "bin/graph-query"

      # `graph-check` exit codes, from the workspace contract: 0 fresh, 1 unavailable or
      # missing, 3 stale. A STALE graph is explicitly not evidence, so it is recorded as
      # unusable rather than quietly queried anyway.
      FRESH = 0
      STALE = 3

      # Bounded so a large repository cannot turn one generation into a full-tree walk, and
      # so the packet handed to the provider stays a summary rather than a corpus.
      MAX_ENTRY_POINTS = 40
      MAX_QUERY_CHARS = 4_000
      GRAPH_TIMEOUT_SECONDS = 300

      # Source files worth naming as entry points. Deliberately a small, language-agnostic
      # set: this is evidence that the runner looked at the real checkout, not an attempt to
      # index it.
      INTERESTING = %w[.rb .py .js .ts .tsx .jsx .go .java .kt .rs .ex .php].freeze
      SKIP_DIRS = %w[.git node_modules tmp log vendor coverage graphify-out .bundle dist build].freeze

      # One tool's outcome, with TWO verdicts that are deliberately not the same question.
      #
      #   usable?      — may generation proceed? True when the tool worked, and also when it
      #                  did not but the operator recorded an approved substitute. This is
      #                  what Preflight gates on.
      #   contributed? — did this tool actually produce evidence for this package? False for
      #                  a substituted tool, because a substitute is not the tool.
      #
      # Collapsing them into one flag is the bug this pair exists to prevent: a stale graph
      # with a substitute recorded would pass preflight (correct) and then be described in
      # `analysis/technical.md` as having been used (false). Criterion 4 requires the analysis
      # to name tool false negatives and substitutes, which is impossible if the document
      # cannot tell "it worked" from "we were allowed to continue without it".
      Tool = Struct.new(:name, :usable, :contributed, :summary, :detail, keyword_init: true) do
        def usable? = usable ? true : false
        def contributed? = contributed ? true : false
      end

      Result = Struct.new(:root, :repository_name, :entry_points, :graphify, :context_plus,
                          :fallbacks, keyword_init: true) do
        # Repository-relative paths only. Criterion 11 forbids private host filesystem paths
        # in generated output, and this is the accessor every generated document reads.
        def entry_point_paths = entry_points
      end

      def self.gather(**kwargs) = new(**kwargs).gather

      def initialize(root:, settings:, env: ENV, command_runner: CommandRunner)
        @root = File.expand_path(root.to_s)
        @settings = settings
        @env = env
        @command_runner = command_runner
      end

      def gather
        Result.new(
          root: root, repository_name: File.basename(root), entry_points: entry_points,
          graphify: graphify_evidence, context_plus: context_plus_evidence, fallbacks: fallbacks
        )
      end

      private

      attr_reader :root, :settings, :env, :command_runner

      # A bounded, deterministic sample of the checkout's real source files, as
      # repository-relative paths. Sorted so two runs over an unchanged checkout produce the
      # same list — a generated document that reordered itself on every run would make every
      # re-generation look like a change.
      def entry_points
        @entry_points ||= begin
          found = []
          walk(root, "", found, 0)
          found.sort.first(MAX_ENTRY_POINTS)
        end
      end

      def walk(dir, prefix, found, depth)
        return if depth > 4 || found.length >= MAX_ENTRY_POINTS * 4

        Dir.children(dir).sort.each do |name|
          next if name.start_with?(".") && name != ".env.example"
          next if SKIP_DIRS.include?(name)

          path = File.join(dir, name)
          relative = prefix.empty? ? name : "#{prefix}/#{name}"
          if File.directory?(path)
            walk(path, relative, found, depth + 1)
          elsif INTERESTING.include?(File.extname(name))
            found << relative
          end
        end
      rescue SystemCallError
        # An unreadable directory is a gap in the sample, not a failure of the run. It is
        # surfaced through `fallbacks` rather than aborting evidence gathering.
        nil
      end

      # Structural evidence, through the wrappers. The freshness check runs FIRST and its
      # verdict is authoritative: a stale or missing graph short-circuits, so no query result
      # from an out-of-date graph can be recorded as if it described the current source.
      def graphify_evidence
        @graphify_evidence ||= begin
          check = wrapper_path(GRAPH_CHECK)
          query = wrapper_path(GRAPH_QUERY)
          if check.nil? || query.nil?
            unusable_graph("the workspace Graphify wrappers are not present in this checkout " \
                           "(expected #{GRAPH_CHECK} and #{GRAPH_QUERY})")
          else
            run_graph_check(check, query)
          end
        end
      end

      def run_graph_check(check, query)
        result = run([ check ])
        return unusable_graph("`#{GRAPH_CHECK}` reports the graph is STALE; a stale graph is not evidence") if
          result.exit_code == STALE
        return unusable_graph("`#{GRAPH_CHECK}` reports no usable graph for this checkout (exit #{result.exit_code})") unless
          result.exit_code == FRESH

        Tool.new(name: "graphify", usable: true, contributed: true,
                 summary: "graph FRESH for this checkout, verified with `#{GRAPH_CHECK}`",
                 detail: [ clip(result.stdout), graph_query(query) ].reject(&:empty?).join("\n\n"))
      end

      # One scoped traversal, not a tour of the codebase. The question is derived from the
      # repository under inspection so the recorded command is reproducible by a reviewer.
      def graph_query(query)
        question = "what are the main entry points and how are the top-level modules connected"
        result = run([ query, question ])
        return "`#{GRAPH_QUERY} \"#{question}\"` returned no output." unless result.success?

        "`#{GRAPH_QUERY} \"#{question}\"`:\n\n```text\n#{clip(result.stdout)}\n```"
      end

      # `contributed: false` unconditionally. A substitute lets the run proceed; it does not
      # turn an unusable graph into structural evidence, and the generated analysis must say
      # so rather than presenting the substitute under the tool's name.
      def unusable_graph(reason)
        substitute = settings.graphify.substitute
        Tool.new(name: "graphify", usable: substitute.to_s.strip != "", contributed: false,
                 summary: reason,
                 detail: substitute.to_s.strip.empty? ? reason : "#{reason}. Approved substitute: #{substitute}")
      end

      # Semantic evidence. The runner is a separate OS process with no MCP client of its
      # own, so it cannot probe Context+ the way it probes Graphify — it reports what the
      # operator declared and nothing more. Claiming a semantic pass this process did not
      # perform would be exactly the dishonest evidence criterion 4 is written against.
      def context_plus_evidence
        capability = settings.context_plus
        Tool.new(name: "context_plus", usable: capability.usable?, contributed: capability.available?,
                 summary: capability.evidence,
                 detail: capability.available? ?
                   "Context+ was declared available for this runner; semantic discovery supplements the " \
                   "structural evidence above." : capability.evidence)
      end

      # What direct source inspection found that the tools did not. Recorded unconditionally,
      # because "the graph was fresh and the direct read agreed" is itself a corroboration
      # result worth stating — scope 7 asks for the fallback to be recorded, and a fallback
      # that is only mentioned when it disagrees leaves a reader unable to tell a corroborated
      # claim from an unchecked one.
      def fallbacks
        notes = [ "Direct read-only inspection of the checkout found #{entry_points.length} source " \
                  "#{entry_points.length == 1 ? 'file' : 'files'} across the sampled tree." ]
        notes << "Graphify contributed no structural evidence for this package, so the source files " \
                 "named below come from direct inspection alone." unless graphify_evidence.contributed?
        notes << "Context+ contributed no semantic evidence for this package; the technical analysis " \
                 "is grounded in direct inspection and the structural graph only." unless
          settings.context_plus.available?
        notes
      end

      # The wrapper's absolute path when it exists and is executable, else nil. Executability
      # is checked rather than assumed: a wrapper that lost its bit after a checkout on a
      # foreign filesystem would otherwise fail as an opaque ENOEXEC mid-generation.
      def wrapper_path(relative)
        path = File.join(root, relative)
        File.file?(path) && File.executable?(path) ? path : nil
      end

      # Read-only, argv-array, no shell, bounded, and rooted at the checkout. PATH is passed
      # through because the wrappers resolve `graphify` from it; nothing else from the
      # runner's environment is, so a provider credential in the operator's shell cannot
      # leak into a tool invocation.
      def run(argv)
        command_runner.run(argv, chdir: root, env: { "PATH" => env["PATH"].to_s },
                                 timeout_seconds: GRAPH_TIMEOUT_SECONDS)
      end

      # Tool output, made safe to quote in a generated document: redacted, made
      # repository-relative, and bounded.
      #
      # The relativizing step is not cosmetic. `bin/graph-check` prints its workspace root and
      # graph path as ABSOLUTE paths, and `bin/graph-query` prints absolute source locations —
      # so quoting either verbatim puts the operator's home directory into a file that is
      # meant to be committed to a shared specification repository. Criterion 11 forbids
      # exactly that, and the live evidence pass caught it: PackageWriter's host-path guard
      # failed the whole generation, which was the correct fail-closed behaviour and the wrong
      # outcome. The fix belongs here, where the path enters the evidence.
      #
      # The guard in the writer stays as the last line of defence. This makes it stop firing
      # on legitimate output; it does not make it unnecessary.
      def clip(text)
        repository_relative(Redaction.redact(text.to_s.strip))[0, MAX_QUERY_CHARS].to_s
      end

      # The checkout root becomes nothing (so `/abs/root/app/x.rb` reads `app/x.rb`), and any
      # OTHER absolute path under the operator's home is removed rather than shortened — a
      # path outside this checkout is not evidence about this repository, and there is no
      # relative form of it worth printing.
      def repository_relative(text)
        stripped = text.gsub("#{root}/", "").gsub(root, ".")
        home = safe_home
        home.nil? ? stripped : stripped.gsub(%r{#{Regexp.escape(home)}/\S*}, "<host path omitted>")
      end

      def safe_home
        home = Dir.home.to_s
        home.empty? || home == "/" ? nil : home
      rescue StandardError
        nil
      end
    end
  end
end
