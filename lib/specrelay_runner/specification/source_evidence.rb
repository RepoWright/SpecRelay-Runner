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

      # What counts as a file worth naming, expressed as an EXCLUSION rather than an allowlist.
      #
      # It used to be a twelve-extension allowlist, and that produced the worst possible
      # outcome against the first non-Ruby checkout it met: the real Tiny Demo app — a Node ESM
      # app of `server.mjs`, `index.html`, `homepage.test.mjs` and `package.json` — matched
      # none of them, the walk returned ZERO entry points, and the run still reported
      # `generated` while the specification claimed to have been written against the checkout.
      # An allowlist fails closed for every language the product has not met yet, which is
      # exactly the set that matters.
      #
      # So the rule is inverted: sample anything that is not obviously not source. Binary
      # formats, lockfiles and archives are named here and everything else is fair game, so
      # meeting a new language produces a slightly noisier sample rather than an empty one.
      UNINTERESTING = %w[
        .png .jpg .jpeg .gif .svg .ico .webp .pdf .zip .gz .tar .tgz .bz2 .7z .rar
        .woff .woff2 .ttf .eot .otf .mp3 .mp4 .mov .avi .wav .bin .exe .dll .so .dylib
        .class .jar .pyc .pyo .o .a .lib .db .sqlite .sqlite3 .lock .map .min.js .min.css
      ].freeze
      SKIP_DIRS = %w[.git node_modules tmp log vendor coverage graphify-out .bundle dist build].freeze

      # A file larger than this is a data blob or a generated artifact, not something an
      # implementer reads to understand the change.
      MAX_ENTRY_POINT_BYTES = 512_000

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
                          :fallbacks, :warnings, keyword_init: true) do
        # Repository-relative paths only. Criterion 11 forbids private host filesystem paths
        # in generated output, and this is the accessor every generated document reads.
        def entry_point_paths = entry_points
        def inspected? = !entry_points.empty?
        def warnings = self[:warnings] || []
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
          graphify: graphify_evidence, context_plus: context_plus_evidence, fallbacks: fallbacks,
          warnings: inspection_warnings
        )
      end

      # A zero-file inspection is a FIRST-CLASS OUTCOME, not silence.
      #
      # The generation still proceeds — see the refuse-or-warn decision below — but the operator
      # must be told, because the resulting specification is grounded in the ticket alone and is
      # weaker than every other package the lane produces. Round 002 recorded
      # `entry_points_inspected: 0` and `warnings: []` on the same run, and the run page showed
      # nothing at all.
      #
      # WARN, DO NOT REFUSE. Scope §8 makes an *unresolvable* source workspace a refusal, and
      # this is a different condition: the checkout resolved, it is simply empty of anything
      # this runner can read. A specification written from a complete Jira ticket is still
      # useful to the person who has to implement it, provided it says what it is missing —
      # which the generated document now does, in its header, its Problem section, its
      # dependencies and its risks. Refusing would also make the lane unusable for any
      # repository whose sources this runner cannot classify, and failing closed on a
      # classification gap is how the allowlist above caused this in the first place.
      def inspection_warnings
        warnings = []
        warnings << "Graphify is not installed for this checkout; direct source inspection was used instead." if
          graphify_absent?
        unless settings.context_plus.usable?
          warnings << "Context+ is not available on this runner; direct source inspection was used without " \
                      "semantic Context+ evidence."
        end
        if entry_points.empty?
          warnings << "No source file could be read in the `#{File.basename(root)}` checkout, so this " \
                      "specification is grounded in the Jira ticket alone. Check that the workspace root " \
                      "points at the right directory; the generated documents say they are ungrounded."
        end
        warnings
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
          found.sort_by { |path| [ documentation?(path) ? 1 : 0, path ] }.first(MAX_ENTRY_POINTS)
        end
      end

      # Prose is sampled, but ranked last. A repository with forty specification documents and
      # four source files must show the four; the inverted rule that lets a new language be
      # sampled at all would otherwise let a wall of Markdown crowd the code out of the list.
      DOCUMENTATION = %w[.md .markdown .rst .txt .adoc].freeze

      def documentation?(path) = DOCUMENTATION.include?(::File.extname(path).downcase)

      def walk(dir, prefix, found, depth)
        return if depth > 4 || found.length >= MAX_ENTRY_POINTS * 4

        Dir.children(dir).sort.each do |name|
          next if name.start_with?(".") && name != ".env.example"
          next if SKIP_DIRS.include?(name)

          path = File.join(dir, name)
          relative = prefix.empty? ? name : "#{prefix}/#{name}"
          if File.directory?(path)
            walk(path, relative, found, depth + 1)
          elsif source_file?(path, name)
            found << relative
          end
        end
      rescue SystemCallError
        # An unreadable directory is a gap in the sample, not a failure of the run. It is
        # surfaced through `fallbacks` rather than aborting evidence gathering.
        nil
      end

      # Anything that is not a known non-source format, is not enormous, and is not binary.
      # The NUL-byte check is the cheap, reliable test for "a human does not read this": it
      # catches formats the extension list has never heard of, which is the whole point.
      def source_file?(path, name)
        return false if UNINTERESTING.include?(File.extname(name).downcase)
        return false if File.size(path) > MAX_ENTRY_POINT_BYTES

        !binary?(path)
      rescue SystemCallError
        false
      end

      def binary?(path)
        sample = ::File.binread(path, 1024).to_s
        sample.include?("\x00")
      rescue SystemCallError
        true
      end

      # Structural evidence, through the wrappers. The freshness check runs FIRST and its
      # verdict is authoritative: a stale or missing graph short-circuits, so no query result
      # from an out-of-date graph can be recorded as if it described the current source.
      def graphify_evidence
        @graphify_evidence ||= begin
          if graphify_absent?
            optional_graph_fallback
          else
            check = wrapper_path(GRAPH_CHECK)
            query = wrapper_path(GRAPH_QUERY)
            if check.nil? || query.nil?
              unusable_graph("the workspace Graphify installation is incomplete or not executable " \
                             "(expected executable #{GRAPH_CHECK} and #{GRAPH_QUERY})")
            else
              run_graph_check(check, query)
            end
          end
        end
      end

      # Graphify is an optional enhancement for repositories that do not ship the workspace
      # wrappers. Complete absence is therefore different from a damaged installation: when
      # neither wrapper exists, direct source inspection is the explicit fallback. If either
      # wrapper exists, both must be executable and healthy so a broken tool cannot be silently
      # reclassified as "not installed".
      def graphify_absent?
        [ GRAPH_CHECK, GRAPH_QUERY ].none? { |relative| File.exist?(File.join(root, relative)) }
      end

      def optional_graph_fallback
        reason = "Graphify is not installed for this checkout (neither #{GRAPH_CHECK} nor " \
                 "#{GRAPH_QUERY} exists); direct source inspection was used instead"
        Tool.new(name: "graphify", usable: true, contributed: false, summary: reason, detail: reason)
      end

      def run_graph_check(check, query)
        result = run([ check ])
        return unusable_graph("`#{GRAPH_CHECK}` reports the graph is STALE; a stale graph is not evidence") if
          result.exit_code == STALE
        return unusable_graph("`#{GRAPH_CHECK}` reports no usable graph for this checkout (exit #{result.exit_code})") unless
          result.exit_code == FRESH

        Tool.new(name: "graphify", usable: true, contributed: true,
                 summary: "graph FRESH for this checkout, verified with `#{GRAPH_CHECK}`",
                 detail: [ graph_check_block(result), graph_query(query) ].reject(&:empty?).join("\n\n"))
      end

      # Tool stdout is FENCED, both here and below. `graph-check` prints one fact per line —
      # version, graph path, source commits, freshness — and emitting them bare collapsed the
      # whole verdict into a single run-together paragraph in the generated analysis. It is
      # program output; it renders as program output.
      def graph_check_block(result)
        text = clip(result.stdout)
        return "" if text.empty?

        "`#{GRAPH_CHECK}`:\n\n#{Markdown.fenced(text, info: 'text')}"
      end

      # One scoped traversal, not a tour of the codebase. The question is derived from the
      # repository under inspection so the recorded command is reproducible by a reviewer.
      def graph_query(query)
        question = "what are the main entry points and how are the top-level modules connected"
        result = run([ query, question ])
        return "`#{GRAPH_QUERY} \"#{question}\"` returned no output." unless result.success?

        "`#{GRAPH_QUERY} \"#{question}\"`:\n\n#{Markdown.fenced(clip(result.stdout), info: 'text')}"
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

      # Semantic evidence — and the honest verdict about it.
      #
      # `contributed: false`, UNCONDITIONALLY. The runner is a separate OS process with no MCP
      # client, so it cannot run a Context+ query and cannot verify that one ran. Deriving
      # `contributed` from the operator's `available:` flag was the exact conflation the
      # two-verdict Tool struct exists to prevent, and it shipped: the generated analysis said
      # "Result: used", Platform's run page said "contributed evidence", and nothing had
      # queried anything.
      #
      # `usable` records whether the operator supplied a declaration or substitute. It does not
      # gate preflight: this process cannot query Context+, so requiring that declaration would
      # make the guided runner flow depend on an unverifiable configuration claim.
      #
      # An operator CAN put real semantic evidence into the package — `queries:` and
      # `evidence:` under `runner.specification.context_plus` are reproduced verbatim below.
      # That is an operator attestation, and it is labelled as one; it still does not make
      # `contributed` true, because the contributor was a person, not this process.
      NO_SEMANTIC_QUERY = "No semantic evidence was gathered by this process. The runner is a separate OS " \
                          "process with no MCP client, so it can neither run a Context+ query nor verify " \
                          "that one ran."

      def context_plus_evidence
        capability = settings.context_plus
        Tool.new(name: "context_plus", usable: capability.usable?, contributed: false,
                 summary: context_plus_summary(capability), detail: context_plus_detail(capability))
      end

      def context_plus_summary(capability)
        return "not queried by this process; operator-recorded semantic evidence is reproduced in the " \
               "technical analysis" if capability.recorded_evidence?
        return "not queried by this process; #{capability.evidence}" unless capability.available?

        "declared available, but this process performed no semantic query and no themes or hits were recorded"
      end

      def context_plus_detail(capability)
        parts = [ NO_SEMANTIC_QUERY ]
        parts << "Declared available in this runner's configuration. A declaration is not a query result." if
          capability.available?
        parts << "Approved substitute: #{Redaction.redact(capability.substitute.to_s)}" if capability.substitute?
        parts << operator_recorded_semantics(capability) if capability.recorded_evidence?
        parts.join("\n\n")
      end

      # Reproduced verbatim, and attributed. Criterion 4 asks the technical analysis to carry
      # query themes and material hits; when a human has them, the honest thing is to print
      # them under the heading they belong to and name whose they are.
      def operator_recorded_semantics(capability)
        lines = [ "**Operator-recorded Context+ evidence.** Reproduced verbatim from this runner's " \
                  "configuration. It is the operator's attestation, not this process's output." ]
        unless capability.queries.empty?
          lines << "" << "Query themes:"
          lines.concat(capability.queries.map { |query| "- #{clip(query)}" })
        end
        unless capability.notes.to_s.strip.empty?
          lines << "" << "Material hits:" << clip(capability.notes)
        end
        lines.join("\n")
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
        # Always recorded, because it is always true: this process never queries Context+.
        # The two wordings differ only in whether a human put semantic evidence in front of it.
        notes << context_plus_fallback
        notes
      end

      def context_plus_fallback
        return "Context+ was not queried by this process; the operator's recorded semantic evidence is " \
               "reproduced in the technical analysis and attributed to them." if
          settings.context_plus.recorded_evidence?

        "Context+ contributed no semantic evidence for this package; the technical analysis is " \
          "grounded in direct inspection and the structural graph only."
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
