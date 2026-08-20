# frozen_string_literal: true

module SpecrelayRunner
  module Review
    # The reviewer's ENTIRE input, rendered once as a reviewable document (MVP-0033
    # contract 6).
    #
    # One place builds it, for the same reason the specification lane's packet exists: a
    # reviewer prompt assembled from fragments scattered through command glue is a prompt
    # nobody can audit. Everything the provider process sees is here, and everything here came
    # from Platform's closed packet.
    #
    # What it does NOT contain is the point. There is no executor conversation, no chain of
    # thought, no local path, no credential, and no prior reviewer's reasoning — because none
    # of that was in the packet Platform sent, and this object adds nothing of its own beyond
    # the fixed instructions below (approved decision 5, S22, S24).
    class Packet
      def initialize(assignment)
        @assignment = assignment
      end

      # The complete prompt text handed to one fresh provider process.
      def prompt
        [ instructions, limits_section, ticket_section, specification_section, change_section,
          evidence_section, continuation_section ].compact.join("\n\n")
      end

      private

      attr_reader :assignment

      # The Reviewer role's fixed system instructions. They are part of the runner's source —
      # not operator configuration — so what a reviewer is asked to do is reviewable in version
      # control and identical on every machine.
      #
      # The one exception is the allowed OUTCOMES, rendered from the packet's own result
      # contract: they are Platform's rule, and a copy kept here would be free to describe a
      # set Platform no longer accepts (MAPIAI-78 design 1).
      def instructions
        <<~TEXT
          You are the independent Reviewer for a SpecRelay implementation round.

          You are a FRESH process. You have no memory of the executor that produced this change
          and no access to its reasoning. Judge only what is below and what you can inspect in
          the checked-out repositories at the pinned head.

          Do:
          - read the approved specification, the committed diff between base and head, and the tests;
          - run proportionate verification yourself; do not trust the report's claims about it;
          - perform the mandatory structural review (Graphify and Context+ where available);
          - conduct an independent browser pass when the change touched the UI;
          - lead with actionable findings, ordered by severity, each with a file/line location.

          Do not:
          - change any file, create a branch, push, merge, or comment on a pull request;
          - write anything to Jira;
          - restate the specification or the report back at the reader;
          - include your reasoning, a transcript, a credential, or an absolute local path.

          Return ONE JSON object and nothing else, as your own output: no prose before or after,
          no code fence, no provider envelope, and exactly one `outcome` member.

          {
            "outcome": #{outcome_choices},
            "summary": "one short paragraph: what you reviewed and what you concluded",
            "findings": [
              { "severity": "blocking" | "major" | "minor",
                "summary": "one sentence",
                "reason": "why it matters",
                "location": "repo-relative/path.rb:123" }
            ],
            "evidence": {
              "structural_review": true | false,
              "verification_run": true | false,
              "browser_review": true | false
            },
            "question": {
              "prompt": "the one decision you need",
              "reason": "why it blocks this review",
              "options": [
                { "key": "short_key", "label": "…", "trade_off": "one sentence", "recommended": true | false }
              ]
            }
          }

          Rules the submission is checked against, so return something that passes:
          - ACCEPT requires zero blocking findings, structural_review true, verification_run true,
            and browser_review true when the change touched the UI.
          - CHANGES_REQUESTED requires at least one finding.
          - NEEDS_INPUT requires exactly one question with TWO or THREE options, at most one
            marked recommended, each with a one-sentence trade-off. A free-text "Other" answer is
            added automatically — do not include one. Use NEEDS_INPUT only for a decision a human
            must make, never for something you could have investigated yourself.
          - Omit "question" entirely unless the outcome is NEEDS_INPUT.
          - Every field is LENGTH-BOUNDED and an over-long one loses the whole review. Stay
            inside the limits under "Length limits" below: be specific and short, and put the
            detail in the location rather than in prose.

          If a carried answer's option is `human_browser_pass`, the Product Owner ran the browser
          pass themselves because no reviewer could. Treat their note as evidence to assess, not as
          work you did:
          - check that it names the tested URL, the viewports, the result and the screenshot
            references, and return a finding when it does not;
          - report `browser_review` false, because you did not run the pass, and do not describe it
            as your own anywhere in your summary or findings;
          - you may still ACCEPT a UI change on that basis — Platform validates the human evidence
            separately, and records it as a fact distinct from yours;
          - never invent a URL, viewport, result or screenshot the note does not state.
        TEXT
      end

      def outcome_choices = assignment.supported_outcomes.map { |outcome| %("#{outcome}") }.join(" | ")

      # Platform states its own limits in the packet, so the reviewer is told the exact rule its
      # submission will be judged against rather than discovering it as a refusal after an
      # eight-minute pass. Rendered from what Platform sent — never a copy kept here, which
      # would be free to drift.
      def limits_section
        limits = assignment.result_contract.select { |key, _| key.to_s.start_with?("max_") }
        return nil if limits.empty?

        rows = limits.map { |key, value| "- #{key.to_s.delete_prefix('max_').tr('_', ' ')}: #{value}" }
        "## Length limits (an over-long field loses the whole review)\n#{rows.join("\n")}"
      end

      def ticket_section
        <<~TEXT.strip
          ## Ticket
          #{assignment.ticket_id} — #{assignment.task_id}
          Run: #{assignment.run_url}
        TEXT
      end

      # Rendered from the document MANIFEST, not from a single field. Today there is one
      # document; when a later MVP resolves a Spec PR into a complete package this renders all
      # of them with no change here.
      def specification_section
        documents = assignment.specification_documents.map do |document|
          "### #{document['role']} (sha256 #{document['digest'].to_s[0, 12]})\n#{document['content']}"
        end
        return "## Approved specification\n(none recorded)" if documents.empty?

        "## Approved specification\n#{documents.join("\n\n")}"
      end

      # What to review, and exactly where. The base and head are stated so the reviewer diffs
      # the committed change rather than the working tree.
      def change_section
        lines = assignment.repositories.map do |repository|
          "- #{repository['repository_key']} (#{repository['slug']}): " \
          "git diff #{repository['base_commit']}..#{repository['head_commit']} — #{repository['pull_request_url']}"
        end
        return "## Change under review\nNo repository changed; the report claims a no-change outcome." if lines.empty?

        "## Change under review\n#{lines.join("\n")}"
      end

      PROMPT_CHANGED_FILES = 100

      def evidence_section
        evidence = assignment.execution_evidence
        files = Array(evidence["files"]).map { |file| "- #{file['path']} (#{file['category']})" }
        <<~TEXT.strip
          ## Executor's own report (claims, not evidence — verify them)
          #{evidence['executor_summary']}

          #{changed_files_block(evidence)}
          #{verification_line(evidence)}
          Report: #{assignment.report_url}
          Attached evidence:
          #{files.empty? ? '(none)' : files.join("\n")}
        TEXT
      end

      # MAPIAI-93 — verification is no longer something the executor "says it ran". SpecRelay
      # re-ran every command from the changed repository itself, so this is the same measured
      # outcome the Run page shows, and the reviewer reads it as evidence rather than as a claim.
      def verification_line(evidence)
        results = Array(evidence["repository_verifications"])
        return "SpecRelay verification: no repository changed." if results.empty?

        listed = results.map { |result| "#{result['repository_path']} #{result['status']}" }
        "SpecRelay verification (re-run by SpecRelay, not claimed): #{listed.join(', ')}"
      end

      # The MEASURED change set, listed rather than summarized. The executor's own
      # `files_changed_summary` is prose it wrote and the runner truncates, so it is shown as a
      # claim; `changed_files` is what git reported and is what the review's browser-evidence
      # requirement is decided from (CR-001 F2).
      def changed_files_block(evidence)
        changed = Array(evidence["changed_files"])
        return "Files changed (executor's summary): #{evidence['files_changed_summary']}" if changed.empty?

        listed = changed.first(PROMPT_CHANGED_FILES).map { |path| "- #{path}" }
        listed << "- …and #{changed.size - PROMPT_CHANGED_FILES} more" if changed.size > PROMPT_CHANGED_FILES
        "Files changed (measured, #{changed.size}):\n#{listed.join("\n")}"
      end

      # Only on a follow-up attempt. It carries the prior FINDINGS and the Product Owner's
      # ANSWER — never the previous reviewer's reasoning (S38).
      #
      # The answer is labelled as theirs unconditionally. A reviewer reading an unattributed line
      # can mistake any carried answer for its own conclusion, and for `human_browser_pass` that
      # mistake would have it report a human's browser pass as work it did (MAPIAI-71).
      def continuation_section
        continuation = assignment.continuation
        return nil if continuation.nil?

        findings = Array(continuation["previous_findings"])
                   .map { |finding| "- [#{finding['severity']}] #{finding['location']}: #{finding['summary']}" }
        <<~TEXT.strip
          ## Continuing after a Product Owner answer
          Previous outcome: #{continuation['previous_outcome']}
          Question asked: #{continuation.dig('question', 'prompt')}
          Answer (the Product Owner's own words, not as work you did): #{answer_text(continuation['answer'])}
          Previous findings:
          #{findings.empty? ? '(none)' : findings.join("\n")}
        TEXT
      end

      def answer_text(answer)
        return "(none recorded)" if answer.nil?

        answer["text"].to_s.strip.empty? ? answer["option"].to_s : "#{answer['option']}: #{answer['text']}"
      end
    end
  end
end
