# frozen_string_literal: true

require "json"

module SpecrelayRunner
  module Review
    # Closes the exact pull requests Platform authorized, and nothing else (MAPIAI-88 design 3).
    #
    # It runs in the RUNNER PARENT, never in the reviewer process. The reviewer is read-only and
    # decides the outcome; a process that could both judge and mutate would be able to retire
    # accepted work on its own authority. The plan executed here is Platform's, recomputed and
    # re-verified there before any verdict is recorded.
    #
    # Only ONE mutating GitHub subcommand exists in this file — `pr close`, with no
    # branch-deletion option — and every command is an argv array through {CommandRunner}, so no
    # repository, url or GitHub response is ever interpolated into a shell line. There is no
    # merge, reopen, revert, force-push, base/head change, pull-request edit or Jira write, and no
    # code path from which one could be reached.
    #
    # It fails CLOSED. Anything it cannot establish is a classified failure that stops the whole
    # plan, so Platform keeps the previous package current rather than accepting a partial
    # replacement. The one exception is convergence: an exact pull request that is already CLOSED
    # and never merged is a success, because a retry on another machine must be able to finish what
    # this one started.
    class Retirement
      GH_TIMEOUT_SECONDS = 120
      MAX_ENTRIES = 100
      # The closed allowlist read back from `gh`. Nothing else is parsed, so a field GitHub adds
      # later cannot silently become a decision here.
      VIEW_FIELDS = "url,state,mergedAt"
      OPEN = "OPEN"
      CLOSED = "CLOSED"
      MERGED = "MERGED"

      # The two endings, named exactly as Platform's failure kinds. RETRYABLE is everything a later
      # attempt can converge on; PRODUCT_DECISION is the merged pull request, which no retry fixes
      # because SpecRelay never rolls a merge back.
      RETRYABLE = "retirement_failure"
      PRODUCT_DECISION = "product_decision_required"

      MERGED_REASON = "the obsolete pull request is already merged, so a human has to decide what " \
                      "replaces it; SpecRelay never closes, reopens or reverts a merged pull request"

      # `retired` is the confirmed pairs, in the order they were executed. A failure carries no
      # partial list: the closes that DID happen are live GitHub state, and a retry re-reads them
      # rather than trusting a local note.
      Result = Struct.new(:retired, :failure_kind, :reason, keyword_init: true) do
        def ok? = failure_kind.nil?
      end

      def initialize(plan:, chdir:, env: {}, timeout_seconds: GH_TIMEOUT_SECONDS, io: nil)
        @plan = plan.to_h
        @chdir = chdir.to_s
        @env = env
        @timeout_seconds = timeout_seconds
        @io = io
      end

      def call
        entries = planned_entries
        return refuse(RETRYABLE, "the authorized retirement plan could not be read") if entries.nil?

        retired = []
        entries.each do |entry|
          failure = retire(entry)
          return failure if failure

          retired << entry
        end
        Result.new(retired: retired)
      end

      private

      attr_reader :plan, :chdir, :env, :timeout_seconds, :io

      # The plan, revalidated on this side before a single call is made. Platform is trusted to
      # decide WHICH pull requests may be closed; it is not trusted to have produced a well-formed,
      # bounded, in-repository url, because this is the process that would do the closing.
      #
      # Returns nil — "unreadable" — rather than a partial list: executing the entries that happened
      # to parse is exactly the partial replacement this design refuses.
      def planned_entries
        rows = plan["pull_requests"]
        return nil unless plan["digest"].to_s.length.positive?
        return nil unless rows.is_a?(Array) && rows.any? && rows.size <= MAX_ENTRIES

        entries = rows.map { |row| entry(row) }
        return nil if entries.any?(&:nil?)

        # Stable sorted order, decided here rather than inherited, so this side's execution order is
        # its own guarantee and two machines replay the same plan identically.
        entries.sort_by { |candidate| [ candidate[:repository].downcase, candidate[:url] ] }
      end

      def entry(row)
        fields = row.to_h
        repository = fields["repository"].to_s
        url = fields["pull_request_url"].to_s
        return nil unless GithubRemote::SLUG.match?(repository)
        return nil unless GithubRemote.pull_request_slug(url) == repository

        { repository: repository, url: url }
      end

      # nil when this entry is retired; otherwise the classified failure that stops the plan.
      def retire(entry)
        before = view(entry)
        return refuse(RETRYABLE, before.error) if before.error
        return refuse(PRODUCT_DECISION, MERGED_REASON) if before.merged
        return log_converged(entry) if before.state == CLOSED
        return refuse(RETRYABLE, unexpected_state(entry, before.state)) unless before.state == OPEN

        close(entry)
      end

      # `pr close` names the exact url AND the planned repository, and carries no other option. A
      # branch-deletion flag is not omitted by accident here: there is nowhere in this file that
      # could add one.
      def close(entry)
        result = gh([ "pr", "close", entry[:url], "--repo", entry[:repository] ])
        return refuse(RETRYABLE, failure_reason(result, "gh pr close")) unless result.success?

        confirm(entry)
      end

      # A close is a success only when GitHub says so on a FRESH read of the same url. `gh` exiting
      # zero is the CLI's opinion about the request, not GitHub's about the pull request.
      def confirm(entry)
        after = view(entry)
        return refuse(RETRYABLE, after.error) if after.error
        return refuse(PRODUCT_DECISION, MERGED_REASON) if after.merged
        return refuse(RETRYABLE, "#{entry[:url]} still reports #{after.state} after it was closed") unless
          after.state == CLOSED

        log("Closed the obsolete pull request #{entry[:url]}")
        nil
      end

      View = Struct.new(:state, :merged, :error, keyword_init: true)

      def view(entry)
        result = gh([ "pr", "view", entry[:url], "--repo", entry[:repository], "--json", VIEW_FIELDS ])
        return View.new(error: failure_reason(result, "gh pr view")) unless result.success?

        fields = parse(result.stdout)
        return View.new(error: "the pull-request response for #{entry[:url]} could not be read") if fields.nil?
        return View.new(error: "the response describes a different pull request than #{entry[:url]}") unless
          fields["url"].to_s == entry[:url]

        state = fields["state"].to_s
        # Both fields, not only the state: a CLOSED row carrying a merge timestamp is a
        # contradiction, and reading state alone would retire it as an ordinary success.
        View.new(state: state, merged: state == MERGED || fields["mergedAt"].to_s != "")
      end

      # Already closed and never merged: the retirement this plan asks for has happened, so a second
      # close would be a duplicate mutation rather than progress. This is what makes a retry on
      # another machine converge instead of failing on work the first machine completed.
      def log_converged(entry)
        log("The obsolete pull request #{entry[:url]} is already closed")
        nil
      end

      def unexpected_state(entry, state)
        "#{entry[:url]} reports state #{state.empty? ? '(none)' : state}, which SpecRelay does not " \
          "close; a human has to look at it"
      end

      def refuse(kind, reason) = Result.new(failure_kind: kind, reason: Redaction.redact(reason.to_s))

      # Only the operator's `gh`/git session variables, through the ONE allowlist this repository
      # already uses for authenticated GitHub work. None of their values is ever logged.
      def gh(args)
        CommandRunner.run([ "gh", *args ], chdir: chdir, env: gh_env, timeout_seconds: timeout_seconds)
      rescue SystemCallError => e
        # `gh` missing or not executable on this host. A spawn failure must degrade into a reported
        # retryable retirement failure, never crash the attempt; Errno subclasses are the narrowest
        # boundary that covers it.
        CommandRunner::Result.new(exit_code: 127, stdout: "", stderr: e.message.to_s,
                                  duration_seconds: 0.0, timed_out: false)
      end

      def gh_env
        @gh_env ||= Publication::FORWARDED_ENV.each_with_object({}) do |name, acc|
          value = env[name]
          acc[name] = value.to_s unless value.nil?
        end
      end

      def parse(json)
        parsed = JSON.parse(json.to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      # A timeout leaves exit_code nil and the streams empty, so it is named explicitly rather than
      # reported as an empty reason. Everything else is redacted before it becomes a message.
      def failure_reason(result, label)
        return "#{label} timed out after #{result.duration_seconds.round}s on this runner host" if result.timed_out?

        detail = Redaction.redact([ result.stderr, result.stdout ].join("\n"))
                          .each_line.map(&:strip).find { |line| !line.empty? }.to_s
        return "#{label} failed with exit status #{result.exit_code.inspect} and no output" if detail.empty?

        "#{label} failed: #{detail}"
      end

      def log(message)
        return if io.nil?

        safe = Redaction.redact(message.to_s)
        io.respond_to?(:line) ? io.line(safe) : io.puts(safe)
      end
    end
  end
end
