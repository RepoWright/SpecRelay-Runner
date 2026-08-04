# frozen_string_literal: true

require "json"

module SpecrelayRunner
  module Specification
    # Creates or reuses the ONE draft pull request for a published specification branch
    # (MVP-0027 criteria 4 and 5).
    #
    # Reuse before create, and the lookup FAILS CLOSED: if we cannot establish whether a pull
    # request already exists we report that and stop, because guessing "none" and creating is
    # exactly how a retry produces a duplicate. The decision about whether a found pull request
    # may be reported as THIS run's output is {PullRequestReuse}'s — shared with the
    # implementation lane, whose four review rounds produced the table.
    #
    # A branch without the required draft pull request is an INCOMPLETE publication (spec §3),
    # so every failure here is a publication failure even though the push already succeeded.
    # That is deliberate: a pushed branch nobody was asked to review is not a reviewable
    # specification, and reporting it as one is the fail-open this MVP is written against.
    class PullRequestPublisher
      GH_UNAVAILABLE = "github_cli_unavailable"
      CREATION_FAILED = "pull_request_creation_failed"
      VERIFICATION_FAILED = "publication_verification_failed"
      MAX_BODY_FILES = 25

      Result = Struct.new(:url, :draft, :reused, :failure_class, :message, keyword_init: true) do
        def ok? = failure_class.nil?
        def reused? = reused ? true : false
        def draft? = draft ? true : false
      end

      def self.call(**kwargs) = new(**kwargs).call

      # `available_check` is run BEFORE any git mutation by the orchestrator and again here only
      # if it was not; see {Publication} for why the order matters.
      # +branch+ is explicit for the same reason it is on {GitPublisher}: MVP-0028 gave it two
      # possible sources, and choosing between them is the caller's job.
      def initialize(commands:, assignment:, branch:, files:, head_commit:, io: $stdout)
        @commands = commands
        @assignment = assignment
        @branch = branch
        @files = files
        @head_commit = head_commit
        @io = io
      end

      # A pure precondition check, called before anything is committed: `gh` must be installed
      # AND authenticated on this host. Checking it first is what stops a publication from
      # pushing a branch it then cannot open a pull request for.
      def self.available?(commands:) = commands.gh(%w[auth status]).success?

      def self.unavailable_message
        "the GitHub CLI (gh) is unavailable or unauthenticated on this runner host, so no draft pull " \
          "request can be opened. Run `gh auth login` where the runner executes, then retry publication"
      end

      # `find_open_pull_request` returns a Result — reusable or refused — or nil, which is the
      # only value that means "there is definitively none, so creating is safe".
      def call
        lookup = find_open_pull_request
        lookup.nil? ? create : lookup
      end

      private

      attr_reader :commands, :assignment, :branch, :files, :head_commit, :io

      def slug = assignment.publication_slug

      # Only an OPEN pull request on this exact branch may be reused. `--state open` rather than
      # `all`: a closed or merged pull request from an earlier round no longer tracks the branch,
      # so reporting it would link something that does not contain this run's commit.
      #
      # Returns a reusable Result, a failure Result, or nil meaning "definitively none — creating
      # is safe".
      def find_open_pull_request
        result = commands.gh([ "pr", "list", "--repo", slug, "--head", branch, "--state", "open",
                               "--limit", "10", "--json", "url,state,headRefName,headRefOid,isDraft" ])
        return lookup_failure(result) unless result.success?

        entries = parse(result.stdout)
        return failure(VERIFICATION_FAILED, "could not read the pull-request list for #{branch}") if entries.nil?

        reusable(entries)
      end

      def lookup_failure(result)
        failure(VERIFICATION_FAILED,
                "could not determine whether a draft pull request already exists for #{branch} " \
                "(#{commands.failure_reason(result, 'gh pr list')}); SpecRelay will not create one without " \
                "knowing, so retry publication once GitHub is reachable")
      end

      def reusable(entries)
        candidates = entries.select { |pr| pr["headRefName"].to_s == branch && pr["url"].to_s.start_with?("https://") }
        return nil if candidates.empty?

        decisions = candidates.to_h { |pr| [ pr, decide(pr) ] }
        match = PullRequestReuse::REUSABLE_DECISIONS.lazy.filter_map { |decision| decisions.key(decision) }.first
        return refusal(*decisions.first) if match.nil?

        log("Reusing the existing draft pull request for #{branch}: #{match['url']}")
        Result.new(url: match["url"], draft: match["isDraft"] == true, reused: true)
      end

      def decide(pull_request)
        PullRequestReuse.decide(reported: pull_request["headRefOid"].to_s, pushed: head_commit.to_s,
                                ancestor: ->(a, b) { commands.success?([ "merge-base", "--is-ancestor", a, b ]) })
      end

      # Every non-reusable decision refuses. The wording differs because the situations do: a
      # pull request whose head is AHEAD of this run's commit verifiably contains it plus commits
      # SpecRelay never produced, which is a different fact from a diverged one — and saying
      # "may not contain this run's commit" about it would assert the opposite of what git proved.
      def refusal(pull_request, decision)
        reported = pull_request["headRefOid"].to_s
        detail =
          case decision
          when :pushed_head_unknown then "SpecRelay could not establish which commit it pushed"
          when :reported_head_unknown then "GitHub reported no head commit for #{pull_request['url']}"
          when :reported_head_ahead
            "#{pull_request['url']} reports head #{reported[0, 12]}, which contains this run's commit " \
              "plus later commits SpecRelay did not produce"
          else
            "#{pull_request['url']} reports head #{reported[0, 12]} but this run pushed #{head_commit[0, 12]}"
          end
        failure(VERIFICATION_FAILED,
                "#{detail}, so it cannot be reported as this run's specification. Review that pull " \
                "request, then retry publication")
      end

      def create
        argv = [ "pr", "create", "--repo", slug, "--head", branch, "--base", assignment.publication_base_branch,
                 "--title", title, "--body", body ]
        argv << "--draft" if assignment.draft_pull_request?
        created = commands.gh(argv)
        return failure(CREATION_FAILED, commands.failure_reason(created, "gh pr create")) unless created.success?

        url = created.stdout.to_s[%r{https://github\.com/\S+/pull/\d+}]
        return failure(CREATION_FAILED, "gh pr create reported no pull-request URL") if url.nil?

        log("Opened a draft pull request for #{branch}: #{url}")
        Result.new(url: url, draft: assignment.draft_pull_request?, reused: false)
      end

      def title = "#{assignment.issue_key}: specification for review"

      # Short, and generated from validated fields only. It links the Platform run and the Jira
      # issue using the URLs PLATFORM supplied — never runner-invented — and lists the generated
      # files. It carries no prompt text, no provider transcript, no command output, no local
      # path, and no credential, and it is redacted on the way out regardless.
      #
      # It states what this pull request is NOT, in one line, because a reviewer arriving from a
      # GitHub notification has none of the run page's context: nobody has approved this, and
      # SpecRelay has not told Jira about it.
      def body
        links = assignment
        lines = [
          "SpecRelay generated this specification package from #{links.issue_key} and published it for review.",
          "", "- Jira issue: #{links.issue_url}", "- Platform run: #{links.run_url}",
          "- Package: `#{links.generated_package_path}`", "",
          "## Files (#{files.length})", ""
        ]
        lines.concat(files.first(MAX_BODY_FILES).map { |file| "- `#{file.repository_path}`" })
        lines << "- …and #{files.length - MAX_BODY_FILES} more" if files.length > MAX_BODY_FILES
        lines.concat([ "", "This is a draft. No one has approved it, and no Jira field, status, or comment " \
                           "has been changed." ])
        Redaction.redact(lines.reject { |line| line.end_with?(": ") }.join("\n"))
      end

      def parse(json)
        parsed = JSON.parse(json.to_s)
        parsed.is_a?(Array) ? parsed.select { |entry| entry.is_a?(Hash) } : nil
      rescue JSON::ParserError
        nil
      end

      def failure(failure_class, message)
        Result.new(failure_class: failure_class, message: Redaction.redact(message.to_s))
      end

      def log(message) = io.puts(Redaction.redact(message.to_s))
    end
  end
end
