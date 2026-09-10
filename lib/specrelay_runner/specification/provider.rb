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
    # `on_output` is the OPTIONAL consumer of live progress, the same `(stream, line)`
    # shape CommandRunner uses. Both providers report through it, because both are real models
    # whose work is worth watching.
    #
    # TWO implementations ship, and they are the two APPROVED REAL PROFILES — Claude and Codex —
    # resolved by {ImplementationProfile}, the same exact whole-hash authority the implementation
    # lane launches against. There is deliberately no third: no built-in composer, no
    # operator-configured executable, no registry, no base class and no discovery. A lane that
    # could reach a deterministic writer or an arbitrary command by configuration is a lane whose
    # output an operator cannot attribute, and the live run that exposed this proved the plausible
    # substitute is the one nobody notices.
    #
    # The boundary is narrow on purpose. Scope 9 requires that "the runner must not embed
    # unreviewable prompt strings deep inside command glue", so the entire input a provider
    # receives is the Packet — one reviewable, redacted document built in one place — and the
    # entire output it may produce is a file map that DocumentSet then validates. A provider
    # cannot reach the assignment, the Platform client, the filesystem, or the environment
    # through this interface, because none of them is passed to it.
    #
    # Neither implementation writes a file. Writing is PackageWriter's job and happens after
    # validation, so a provider failure — including a model that dies halfway through its
    # output — cannot leave a partial package anywhere.
    module Provider
      # Raised at PREFLIGHT: no approved provider can be used at all. Distinct from Failed because
      # it must refuse before any staging happens.
      Unavailable = Class.new(StandardError)
      # Raised DURING generation: the provider ran and did not produce usable output.
      Failed = Class.new(StandardError)

      # The adapter for one already-validated real profile, or a refusal.
      #
      # The profile is the WHOLE selection: it arrived as one of the exact canonical hashes and was
      # compared byte for byte before this method saw it, so there is nothing left here to decide
      # except which of the two decoders reads the process. A nil profile is the deterministic
      # fixture or no selection at all — neither is a model-backed specification writer, and both
      # refuse rather than falling back to something that would produce plausible prose.
      def self.resolve(profile:, env: ENV)
        # `env` is forwarded, not defaulted. Process.spawn resolves the executable through the PATH
        # it is handed, so a provider built without it would look its command up on the runner
        # PROCESS's environment while every other stage — the readiness probe, the executor
        # mismatch guard — used the runner's own. That is the precise failure the profiles warn
        # about: "readiness pass against one CLI and execution run another".
        case profile
        when ClaudeProfile then Claude.new(profile: profile, env: env)
        when CodexProfile then Codex.new(profile: profile, env: env)
        else raise Unavailable, UNCONFIGURED
        end
      end

      # The sentence an operator reads when the lane cannot proceed. It names both ways out, and
      # only ways that still exist: the selection is a provider name, on the screen they chose it
      # on or in this runner's own file — never a command, a kind, or a fixture.
      UNCONFIGURED =
        "no specification generation provider is configured. Select `claude` or `codex` as this " \
        "workspace's AI provider in Platform's Project Setup, or name one under runner.executor " \
        "on this runner."

      # The ONE content contract both real providers answer to: the same specification prompt, the
      # same balanced JSON file map, and the same sentences when a provider does not deliver one.
      #
      # It is shared rather than copied because it is one rule, not two: a Codex package and a
      # Claude package are the same artifact, validated by the same {DocumentSet}, and a second
      # prompt or a second parser could only ever drift from the first. What is NOT shared is what
      # genuinely differs — how each provider is launched, and which decoder reads its output.
      module PackageContract
        # PATH to find the executable and HOME to find the operator's own provider credentials —
        # the same two the implementation lane forwards, and nothing else. The profile's own
        # `extra_env` is merged last because it is part of the profile identity the exact-profile
        # comparison already validated.
        FORWARDED_ENV = %w[PATH HOME].freeze

        # Already redacted by the profile, and it names the executable and how the prompt is
        # delivered — enough for an operator to recognise which provider ran, with nothing that
        # could carry a credential.
        def describe = "#{kind.capitalize} profile — #{profile.describe}"

        private

        attr_reader :profile, :env, :command_runner

        # The provider's whole run, from the prompt to a parsed file map. Every rule about what a
        # usable answer IS lives here, once; the adapter supplies only its decoder and its launch.
        # What happens once the process has STARTED is one rule for both providers. What happens
        # when it cannot be started at all is not: Claude's accepted behaviour is that the
        # operating system's own error escapes, and this slice may not change it. Each adapter
        # therefore owns its own `launch`, and only Codex's classifies a failure to start.
        def generate_package(packet, stream)
          result = launch(prompt_for(packet), stream)
          raise Failed, "#{failure_prefix} timed out" if result.timed_out?
          raise Failed, "#{failure_prefix} exited #{result.exit_code}" unless result.success?

          failure = stream.close.failure
          raise Failed, "#{failure_prefix}'s output could not be read: #{failure}" if failure

          parse(stream.final_text)
        end

        def failure_prefix = "the #{kind.capitalize} specification provider"

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

            PREVIOUS ACCEPTED IMPLEMENTATION (only when the evidence below has a
            "previous_accepted_package" key) — this ticket's specification has already been
            implemented and that implementation was ACCEPTED. The block names the accepted
            package, the specification it implemented, and the pull requests that carry it with
            their exact heads. It is READ-ONLY CONTEXT: write the revision so it is coherent with
            what already exists — say what changes relative to it, and do not re-specify work that
            is already shipped — and never state that the implementation is missing when the block
            says it exists. You are writing documents only: never check out, clone, modify, push
            to, or open a pull request against an implementation repository, and never treat a
            local checkout as the authority for what those pull requests contain.

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
        # first balanced object is extracted rather than the whole answer parsed. Anything else is
        # a failure the run records — never a partial package.
        # The size bound belongs to the decoder, which is where the bytes arrive; a second check
        # here would be a second owner of the same rule, and an unreachable one.
        def parse(text)
          document = JSON.parse(json_object(text))
          raise Failed, "#{failure_prefix} did not return a JSON object of file paths" unless document.is_a?(Hash)

          document.to_h { |name, content| [ name.to_s, content.to_s ] }
        rescue JSON::ParserError
          raise Failed, "#{failure_prefix} did not return valid JSON"
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
          raise Failed, "#{failure_prefix} returned no JSON object"
        end
      end

      # The operator's REAL Claude profile, writing the specification.
      #
      # The profile owns the argv, the timeout, the prompt delivery and the child environment —
      # this class adds none of them. That is what makes the provider that writes a specification
      # verifiably the same one an operator selected and the readiness check probed.
      class Claude
        include PackageContract

        KIND = "claude"

        def initialize(profile:, env: ENV, command_runner: CommandRunner)
          @profile = profile
          @env = env
          @command_runner = command_runner
        end

        def kind = KIND

        # The profile is structured-output-only, so the process is read through the
        # SAME {ClaudeStream} the implementation lane uses. Progress reaches `on_output` while the
        # model works; the document map still comes only from the terminal result, and still goes
        # only to {DocumentSet}. One decoder per provider, two lanes, no second normalization rule.
        def generate(packet, on_output: nil)
          # No repository is assigned to this lane, so containment can never be proven and the
          # decoder shows no path at all — the same projection rule, applied to a lane with no root.
          generate_package(packet, ClaudeStream.new(sink: on_output))
        end

        private

        # The packet reaches the model as ONE argv element, exactly as the implementation lane
        # delivers this profile's prompt.
        def launch(prompt, stream)
          Dir.mktmpdir("specrelay-spec-claude-") do |workdir|
            command_runner.run([ profile.command, *profile.args, prompt ], chdir: workdir,
                                                                          env: child_env,
                                                                          timeout_seconds: profile.timeout_seconds,
                                                                          on_output: stream.sink)
          end
        end
      end

      # The operator's REAL Codex profile, writing the specification.
      #
      # It is a sibling of {Claude}, not a subclass and not a registry entry: the two share the
      # prompt and the file-map contract through {PackageContract} and differ only in the two
      # things that genuinely differ — Codex takes its prompt on STDIN, so the specification never
      # becomes a process argument, and its turn is read by {CodexStream}, whose terminal contract
      # is materially different from Claude's single `result` frame.
      class Codex
        include PackageContract

        KIND = "codex"

        def initialize(profile:, env: ENV, command_runner: CommandRunner)
          @profile = profile
          @env = env
          @command_runner = command_runner
        end

        def kind = KIND

        def generate(packet, on_output: nil)
          generate_package(packet, CodexStream.new(sink: on_output))
        end

        private

        # Run in a throwaway directory, not in either checkout. A provider that decides to write
        # next to itself then cannot touch the specification repository or the source tree — the
        # atomicity guarantee in scope 10 is only as strong as the set of places something can
        # write. The prompt goes on stdin because that is this profile's approved delivery.
        def launch(prompt, stream)
          Dir.mktmpdir("specrelay-spec-codex-") do |workdir|
            command_runner.run([ profile.command, *profile.args ], chdir: workdir,
                                                                   env: child_env,
                                                                   timeout_seconds: profile.timeout_seconds,
                                                                   stdin_data: prompt,
                                                                   on_output: stream.sink)
          end
        rescue SystemCallError => e
          # A Codex CLI that cannot be started is a bounded generation failure rather than an
          # exception escaping the lane, which would leave the claim held with no recorded reason
          # (S07). The underlying error names a host path, so this names the condition and the
          # error CLASS and nothing else.
          raise Failed, "#{failure_prefix} could not be launched (#{e.class})"
        end
      end
    end
  end
end
