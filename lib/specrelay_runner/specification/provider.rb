# frozen_string_literal: true

require "json"

module SpecrelayRunner
  module Specification
    # The generation-provider BOUNDARY (MVP-0026 scope 9).
    #
    # Everything that turns evidence into prose goes through one interface with two methods:
    #
    #   describe -> String                       # what an operator sees in the log and the manifest
    #   generate(packet, on_output:) -> Hash      # { "spec.md" => "...", "analysis/business.md" => ... }
    #
    # `on_output` (MAPIAI-60) is an OPTIONAL consumer of live progress, the same `(stream, line)`
    # shape CommandRunner uses. Only the Claude provider has provider semantics to report through
    # it; the composer and a configured command ignore it rather than manufacture events they do
    # not have, so their existing lifecycle output stays truthful.
    #
    # Two implementations ship. `Composed` is the default and is deterministic: same packet,
    # same bytes, no network, no model — which is what lets the digests, the atomic replace,
    # and the Platform evidence be asserted in tests instead of smoke-checked. `Command` runs
    # an operator-configured local executable, which is where a real model-backed writer
    # plugs in.
    #
    # The boundary is narrow on purpose. Scope 9 requires that "the runner must not embed
    # unreviewable prompt strings deep inside command glue", so the entire input a provider
    # receives is the Packet — one reviewable, redacted document built in one place — and the
    # entire output it may produce is a file map that DocumentSet then validates. A provider
    # cannot reach the assignment, the Platform client, the filesystem, or the environment
    # through this interface, because none of them is passed to it.
    #
    # Neither implementation writes a file. Writing is PackageWriter's job and happens after
    # validation, so a provider failure — including a command that dies halfway through its
    # output — cannot leave a partial package anywhere.
    module Provider
      # Raised at PREFLIGHT: the configured provider cannot be used at all. Distinct from
      # Failed because it must refuse before any staging happens.
      Unavailable = Class.new(StandardError)
      # Raised DURING generation: the provider ran and did not produce usable output.
      Failed = Class.new(StandardError)

      # Read from the configured command's stdout. Bounded so a runaway provider cannot
      # exhaust runner memory, and small enough that anything larger is a bug rather than a
      # very thorough specification.
      MAX_OUTPUT_BYTES = 4_000_000

      # The configured kind and the resolved provider's own `kind` are the SAME vocabulary —
      # `composed`, `command` and `claude` — so the diagnostics Platform persists cannot
      # contradict the manifest. They used to: the default was configured as `fake` and reported
      # itself as `composed`, and the run page told operators the production default was a fake.
      #
      # **An unset kind is a question, not a default** (MVP-0028 remediation, defect 1). It used
      # to resolve to `Composed`, so an operator whose guided setup wrote no runner YAML — the
      # ordinary case — got the deterministic composer while believing they had selected the real
      # provider. The live MAPIAI-52 run proved it: `runner.executor` named the real Claude
      # profile and the specification lane never looked at it.
      #
      # So the precedence is: an EXPLICIT kind always wins, because an operator who names one has
      # decided; otherwise the operator's real Claude profile is used if they configured one; and
      # if neither exists this REFUSES. Falling back to the composer is what this method must
      # never do again, because the composer's output is plausible enough that nobody notices.
      def self.resolve(settings:, claude_profile: nil, env: ENV)
        return Composed.new if settings.composed_provider?
        return Command.build(settings: settings, env: env) if settings.provider_kind == Settings::PROVIDER_COMMAND
        # `env` is forwarded, not defaulted. Process.spawn resolves the executable through the PATH
        # it is handed, so a Claude provider built without it would look `claude` up on the runner
        # PROCESS's environment while every other stage — the readiness probe, the executor
        # mismatch guard — used the runner's own. That is the precise failure ClaudeProfile warns
        # about: "readiness pass against one CLI and execution run another". Found while proving
        # the defect-4 fix, when a test that put a stub `claude` first on its runner PATH launched
        # the host's real CLI instead.
        return Claude.build(profile: claude_profile, settings: settings, env: env) if settings.claude_provider?
        return Claude.new(profile: claude_profile, settings: settings, env: env) if claude_profile

        raise Unavailable, UNCONFIGURED
      end

      # Named here rather than inlined because it is the sentence an operator reads when the lane
      # cannot proceed, and it has to name every way out — including the fixture, so that choosing
      # the composer stays a real option rather than something only the source reveals.
      UNCONFIGURED =
        "no specification generation provider is configured. Set runner.specification.provider.kind " \
        "to `claude` to use this runner's configured Claude profile, to `command` with " \
        "runner.specification.provider.command for another executable, or to `composed` to use the " \
        "built-in deterministic composer as an explicit fixture. Configuring a runner.executor " \
        "Claude profile also selects `claude` for specifications."

      # The deterministic, built-in provider. It composes the documents from the packet with
      # no model call, which makes it both the test double the spec asks for and a genuinely
      # usable default: its output is grounded in the real bundle and the real source
      # evidence, so it is a weak writer rather than a fake one — which is why the
      # configuration value that selects it is `composed`.
      class Composed
        KIND = "composed"

        def describe = "built-in deterministic composer (no model, no network)"
        def kind = KIND

        def generate(packet, on_output: nil)
          _ = on_output
          Composer.call(packet)
        rescue StandardError => e
          # A composer bug must surface as a generation failure the run records, not as an
          # unhandled crash that leaves the claim held and the operator with a backtrace.
          raise Failed, "the built-in composer could not produce a package: #{e.class}"
        end
      end

      # The operator's REAL Claude profile, writing the specification.
      #
      # It is a distinct kind from {Command} even though both spawn a process, because the two
      # answer to different configuration and different failure advice: `command` is "an
      # executable I chose for this lane", while this is "the Claude profile this runner already
      # validated for execution". Collapsing them would make the refusal messages wrong for one of
      # them, and would hide the fact that no separate configuration is needed at all.
      #
      # The profile owns the argv, the timeout, the prompt delivery and the child environment —
      # this class adds none of them. That is what makes the provider that writes a specification
      # verifiably the same one an operator configured and the readiness check probed.
      class Claude
        KIND = "claude"

        MISSING_PROFILE =
          "runner.specification.provider.kind is `claude` but this runner has no Claude profile: " \
          "configure runner.executor with provider `claude`, or select another specification " \
          "provider kind."

        def self.build(profile:, settings:, env: ENV)
          raise Unavailable, MISSING_PROFILE if profile.nil?

          new(profile: profile, settings: settings, env: env)
        end

        def initialize(profile:, settings:, env: ENV, command_runner: CommandRunner)
          @profile = profile
          @settings = settings
          @env = env
          @command_runner = command_runner
        end

        def kind = KIND

        # Already redacted by the profile, and it names the executable and how the prompt is
        # delivered — enough for an operator to recognise which provider ran, with nothing that
        # could carry a credential.
        def describe = "Claude profile — #{profile.describe}"

        # The packet reaches the model as ONE argv element, exactly as the implementation lane
        # delivers its prompt, and the model must answer with the same JSON file map every
        # provider answers with. Both halves are deliberate: the instruction lives here in
        # reviewable source rather than "deep inside command glue" (MVP-0026 scope 9), and the
        # output contract is the provider boundary's, not this class's, so {DocumentSet} validates
        # a Claude package exactly as it validates any other.
        # MAPIAI-60 — the profile is structured-output-only, so the process is read through the
        # SAME {ClaudeStream} the implementation lane uses. Progress reaches `on_output` while the
        # model works; the document map still comes only from the terminal result, and still goes
        # only to {DocumentSet}. One decoder, two lanes, no second normalization rule.
        def generate(packet, on_output: nil)
          # No repository is assigned to this lane, so containment can never be proven and the
          # decoder shows no path at all — the same projection rule, applied to a lane with no root.
          stream = ClaudeStream.new(sink: on_output)
          result = run(prompt_for(packet), stream)
          raise Failed, "the Claude specification provider timed out" if result.timed_out?
          raise Failed, "the Claude specification provider exited #{result.exit_code}" unless result.success?

          failure = stream.close.failure
          raise Failed, "the Claude specification provider's output could not be read: #{failure}" if failure

          parse(stream.final_text)
        end

        private

        attr_reader :profile, :settings, :env, :command_runner

        # PATH to find the executable and HOME to find the operator's own Claude credentials —
        # the same two the implementation lane forwards, and nothing else. The profile's own
        # `extra_env` is merged last because it is the operator's explicit choice, and it is part
        # of the profile identity the readiness check already validated.
        FORWARDED_ENV = %w[PATH HOME].freeze

        def run(prompt, stream)
          Dir.mktmpdir("specrelay-spec-claude-") do |workdir|
            command_runner.run([ profile.command, *profile.args, prompt ], chdir: workdir,
                                                                          env: child_env,
                                                                          timeout_seconds: profile.timeout_seconds,
                                                                          on_output: stream.sink)
          end
        end

        def child_env
          FORWARDED_ENV.each_with_object({}) { |name, acc| acc[name] = env[name].to_s unless env[name].nil? }
                       .merge(profile.extra_env)
        end

        # The whole instruction, in one place a reviewer can read. It says what to produce and in
        # what shape, and nothing about WHAT to write — that is the packet's job, and a prompt
        # that restated the content requirements would be a second, diverging specification of
        # them.
        #
        # MVP-0028 remediation, defect 3: the live MAPIAI-52 run this prompt used to produce quoted
        # a Jira SECTION HEADING ("Acceptance criteria") as though it were the reporter's problem
        # statement, embedded the raw input bundle verbatim inside `spec.md`, and never resolved
        # the ticket's own vague "the text" to the element its Jam evidence actually named. Every
        # rule below traces to one of those failures; none is a style preference.
        #
        # Review 006 findings F1 and F2 tightened two more rules the same MAPIAI-52 package
        # exposed: it never named a linked issue at all, and a malformed open question would have
        # been silently accepted rather than rejected. Both are now enforced structurally by
        # {DocumentSet}, not only asked for here — this wording exists so a real model produces
        # something that PASSES that gate on the first attempt, not to be the only guard against it.
        #
        # MVP-0028 decision D6 adds the REVISION section below: present only when {Packet} carries
        # a previous package (a same-ticket revision), it is what lets stable open-question ids and
        # resolution history survive a real model's rewrite instead of a fresh, memoryless attempt.
        def prompt_for(packet)
          <<~PROMPT
            You are writing a software specification package for SpecRelay, for a human reviewer
            with limited attention and no prior context on this ticket.

            Return ONLY a JSON object mapping file paths to file contents, with no prose before or
            after it and no code fence. The keys must be exactly "spec.md", "#{PackagePath::INPUT_EVIDENCE_MD}",
            "#{PackagePath::BUSINESS_MD}", "#{PackagePath::TECHNICAL_MD}" — plus
            "#{PackagePath::OPEN_QUESTIONS_MD}" ONLY when at least one open question below is
            genuinely material (a decision that changes scope, behavior, or acceptance). Omit that
            key entirely otherwise; never include it as an empty string.

            TITLES — every document begins with its own `#` title on the first line, naming what
            the document is. "spec.md" is titled for the ticket (its key and summary);
            "#{PackagePath::INPUT_EVIDENCE_MD}" names "input evidence",
            "#{PackagePath::BUSINESS_MD}" names "business analysis",
            "#{PackagePath::TECHNICAL_MD}" names "technical analysis", and
            "#{PackagePath::OPEN_QUESTIONS_MD}" names "open questions". Never promote a `##`
            section name to the title, and never write anything about your own instructions,
            placeholders, or what content follows — the documents contain specification content
            and nothing else. Both are rejected before the package is written.

            SOURCE OF TRUTH
            - The Jira summary, description, acceptance criteria, and any reproduced ticket
              sections in the evidence below are the reporter's own words. Treat them as
              READ-ONLY: quote or paraphrase faithfully, never rewrite them, and never silently add
              a criterion the reporter did not state.
            - Describe the requested PRODUCT BEHAVIOR, not Jira labels, field names, or SpecRelay's
              own pipeline concepts (bundle, packet, tool evidence) — those are inputs to your
              writing, never its subject. A section heading the reporter typed (e.g. "Acceptance
              criteria") is structure, not prose describing the problem — never quote a heading as
              though it were the reporter's description of the problem.
            - Resolve a vague reference in the ticket (e.g. "the text", "this button") to the
              concrete element it names, using the ticket title and the supporting-input evidence
              below. State what you resolved it to and why, in one sentence — do not leave it vague
              when the evidence settles it.
            - When material ambiguity remains after using all the evidence, record ONE concise open
              question rather than guessing. A gap that does not change scope, behavior, or
              acceptance is not material and is not a question.

            SPEC.MD — required `##` sections, in this order: Problem, Outcome, Input summary,
            Proposed behavior, Non-goals, Acceptance criteria, Validation expectations,
            "Dependencies and assumptions", Analysis. Each needs real content under it — a heading
            with nothing under it is rejected.

            #{PackagePath::INPUT_EVIDENCE_MD} — one compact `##` entry per SUPPORTING input (a Jam
            recording, screenshot, Confluence page, log, attachment, external link, or linked Jira
            issue) named in the evidence below — never the ticket's own description or comments,
            already reflected in spec.md's own "Input summary". A linked issue that reached this
            evidence has already had its OWN key, title, and description read by Platform before
            generation — analyze that content exactly as you would a Jam recording or an
            attachment: quote or summarize what it actually says, and state what it implies for
            this ticket's requirement (including its own stated acceptance criteria, if any, and
            any constraint it places on this ticket's scope). Only if a linked issue's content is
            explicitly marked not read (an operational limitation this generation did not cause) do
            you say plainly that its content was not captured, rather than guessing at it. For each
            entry: its kind and name, whether it was actually read/analyzed (not just referenced),
            factual observations, what those observations imply for the requirement, limitations,
            and any conflict with the ticket or another input. Never copy raw transcript or tool
            output. Never include a credential or a local filesystem path. Label an inference as an
            inference, not an observation. A URL that was never analyzed is not evidence, however
            confidently it reads. If there is no supporting input beyond the
            ticket's own description and comments, say so in one sentence.

            #{PackagePath::BUSINESS_MD} — required `##` sections: "User problem and affected
            workflow", "Stakeholder impact", "Risks, edge cases, and missing product decisions",
            "Acceptance-criteria rationale", "Input conflicts and gaps", Recommendation.

            #{PackagePath::TECHNICAL_MD} — required `##` sections: "Source entry points inspected",
            "Graphify evidence", "Context+ evidence", "Dependency and blast-radius assessment",
            "Likely implementation approach", "Implementation surface", "Tests a future
            implementation ticket needs", "Technical risks, unknowns, and blocked evidence". Ground
            every claim in the actual source entry points and tool evidence below — naming a file
            without reading what it contains is a listing, not an analysis.

            #{PackagePath::OPEN_QUESTIONS_MD} (only if included) — one `##` entry per question, id
            "OQ-001", "OQ-002", ... Each entry is EXACTLY three bullets, in this order, each with a
            nonblank value after the colon: "- Why it blocks: ...", "- Decision required: ...",
            "- Consequence: ...". No other bullet, no repeated bullet, and no blank value — any of
            those is rejected before the package is written. Never invent a question the evidence
            already answers, and never treat a tool failure or unreadable input as a product
            question — that is an operational limitation and belongs in the technical analysis.

            REVISION (only when the evidence below has a "revision" key) — this ticket already has
            a published specification package on an open pull request, reproduced verbatim as
            "revision.previous_files", and this generation REVISES it rather than writing a first
            one. Base every document on the CURRENT ticket and evidence, but do not silently drop a
            requirement, risk, or acceptance criterion the previous package recorded unless the
            current ticket now contradicts it, and do not restate settled analysis just to sound
            different from before.
            - Stable ids: reuse the previous package's own "OQ-nnn" id for a question that is
              STILL open and substantively the same question — never renumber or reissue it. Only
              a genuinely NEW question gets a new id.
            - Mark a previous open question RESOLVED only when the CURRENT ticket, its comments, or
              another Product-Owner-approved source states the resolution explicitly. Never resolve
              from inference alone, and never because the linked pull request looks further along. A resolved
              entry keeps its own "## OQ-nnn" heading, and its body is EXACTLY these three bullets
              instead of the open three: "- Status: resolved", "- Decision: ...", "- Source: ..."
              (the authoritative place the resolution came from — a named Jira comment or field).
              Drop the prior argumentative prose; keep only the decision and its source.
            - Never resolve a question the current evidence does not actually settle: it keeps its
              original three open-question bullets unchanged.
            - Retain every previously RESOLVED question's own entry unchanged (same id, same
              "Status: resolved" body) so the file's resolution history stays visible across runs.
            - If the previous package recorded no #{PackagePath::OPEN_QUESTIONS_MD}, and this
              revision raises no material question either, omit the file exactly as a first
              generation would.

            BREVITY — this is an acceptance rule, not a style preference. Include a sentence,
            bullet, or row only when it changes a requirement, observation, decision, risk,
            dependency, validation action, blocker, or open question. Delete process narration,
            generic advice, and repeated conclusions. State each fact once across the whole
            package. Never dump the raw input bundle, a tool transcript, or a source listing —
            summarize only what is needed to support a decision.

            DURABLE TRUTH — these documents are committed to the specification repository and read
            after publication, not only before it. Never state or imply current publication,
            commit, branch, or Jira status ("not yet published", "no pull request exists",
            "generated locally"): that state is transient and lives in SpecRelay's own run records,
            not in a document a reviewer may read after it is already false.

            Base every statement on the evidence below. Do not invent requirements, and where the
            evidence is insufficient say so rather than guessing.

            EVIDENCE (JSON):
            #{JSON.generate(packet)}
          PROMPT
        end

        # A model may wrap JSON in a fence or add a sentence despite being asked not to, so the
        # first balanced object is extracted rather than the whole stdout parsed. Anything else is
        # a failure the run records — never a partial package.
        # The size bound belongs to {ClaudeStream}, which is where the bytes now arrive; a second
        # check here would be a second owner of the same rule, and an unreachable one.
        def parse(text)
          document = JSON.parse(json_object(text))
          raise Failed, "the Claude specification provider did not return a JSON object of file paths" unless
            document.is_a?(Hash)

          document.to_h { |name, content| [ name.to_s, content.to_s ] }
        rescue JSON::ParserError
          raise Failed, "the Claude specification provider did not return valid JSON"
        end

        # Genuinely balanced, not "first `{` to last `}`" (review-004 non-blocking note): a
        # brace inside a quoted string is not counted, so a trailing sentence or aside the model
        # appended despite instruction — one that itself happens to contain braces — cannot pull
        # the match past the object's own close. Only real object nesting inside the JSON can.
        # {BalancedJson} is the shared implementation; {ReferenceAnalyzer::Claude} (MVP-0028
        # remediation, defect 2) needs the identical judgment call against the same real profile.
        def json_object(text)
          BalancedJson.extract_object(text)
        rescue BalancedJson::NotFound
          raise Failed, "the Claude specification provider returned no JSON object"
        end
      end

      # An operator-configured local executable. The packet is handed to it as JSON on
      # stdin; it must return the file map as JSON on stdout. No shell is involved (argv
      # array), no environment is inherited beyond PATH, and the working directory is the
      # operator's own choice of a temporary directory — the provider is never given the
      # specification checkout to write into, because writing is not its job.
      class Command
        KIND = "command"

        def self.build(settings:, env: ENV)
          command = settings.provider_command
          raise Unavailable, "runner.specification.provider.kind is `command` but no provider command is " \
                             "configured (set runner.specification.provider.command or " \
                             "#{Settings::PROVIDER_COMMAND_ENV})" if command.nil?
          raise Unavailable, "the configured generation provider is not an executable file: #{command}" unless
            File.file?(command) && File.executable?(command)

          new(command: command, args: settings.provider_args, timeout_seconds: settings.provider_timeout_seconds,
              env: env)
        end

        def initialize(command:, args: [], timeout_seconds: Settings::DEFAULT_TIMEOUT_SECONDS, env: ENV,
                       command_runner: CommandRunner)
          @command = command
          @args = Array(args).map(&:to_s)
          @timeout_seconds = timeout_seconds
          @env = env
          @command_runner = command_runner
        end

        def kind = KIND
        def describe = "configured provider command `#{File.basename(command)}`"

        def generate(packet, on_output: nil)
          _ = on_output
          result = run(JSON.generate(packet))
          raise Failed, "the generation provider timed out after #{timeout_seconds}s" if result.timed_out?
          raise Failed, "the generation provider exited #{result.exit_code}: #{first_line(result)}" unless
            result.success?

          parse(result.stdout)
        end

        private

        attr_reader :command, :args, :timeout_seconds, :env, :command_runner

        # Run in a throwaway directory, not in either checkout. A provider that decides to
        # write next to itself then cannot touch the specification repository or the source
        # tree — the atomicity guarantee in scope 10 is only as strong as the set of places
        # something can write.
        def run(stdin_data)
          Dir.mktmpdir("specrelay-spec-provider-") do |workdir|
            command_runner.run([ command, *args ], chdir: workdir, env: { "PATH" => env["PATH"].to_s },
                                                   timeout_seconds: timeout_seconds, stdin_data: stdin_data)
          end
        end

        def parse(stdout)
          raise Failed, "the generation provider produced more output than the runner will accept" if
            stdout.to_s.bytesize > MAX_OUTPUT_BYTES

          document = JSON.parse(stdout.to_s)
          raise Failed, "the generation provider did not return a JSON object of file paths" unless
            document.is_a?(Hash)

          document.to_h { |name, content| [ name.to_s, content.to_s ] }
        rescue JSON::ParserError
          raise Failed, "the generation provider did not return valid JSON on stdout"
        end

        # Only the FIRST line of the provider's stderr reaches the failure message, redacted.
        # A provider's full output may contain anything, including its own configuration, and
        # this string is persisted by Platform and shown on the run page.
        def first_line(result)
          text = [ result.stderr, result.stdout ].map { |value| value.to_s.strip }.find { |value| !value.empty? }
          Redaction.redact(text.to_s.each_line.first.to_s.strip)[0, 300].to_s
        end
      end
    end
  end
end
