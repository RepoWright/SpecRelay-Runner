# frozen_string_literal: true

require "json"

module SpecrelayRunner
  module Specification
    # Reads and VALIDATES the specification pull request a Jira ticket already has, before this
    # run publishes anything (MVP-0028 criteria 3 and 4).
    #
    # Platform supplies the URL — it read it out of the ticket's `Spec PR` field and checked that
    # it names a pull request on the configured specification repository — and stops there,
    # because Platform holds no GitHub credentials and cannot know whether that pull request is
    # still OPEN, still targets the right base, or exists at all. Only the runner can ask GitHub,
    # so the runner asks, and this is where.
    #
    # What it returns on success is the one fact the rest of the publication needs: **the branch**.
    # That is the point of asking rather than deriving. The ticket-owned branch name contains a
    # slug of the ticket TITLE, and a ticket can be renamed after its pull request is open; the
    # open pull request stays the source of truth and its head branch keeps the old name. Deriving
    # the branch from the current title would open a second pull request for the same ticket,
    # which is exactly what criterion 3 forbids.
    #
    # It FAILS CLOSED on every uncertainty. A pull request that is closed, merged, missing, on the
    # wrong repository, against the wrong base, or simply unreadable produces a failure with an
    # operator-actionable reason and NOTHING is committed, pushed, or opened — the checks all run
    # before {GitPublisher}, so refusing here costs a `gh` call and no repository state.
    class ExistingPullRequest
      UNUSABLE = "specification_pull_request_unusable"

      # Everything needed to decide, requested in one call so no two facts can be read at
      # different moments.
      FIELDS = "url,state,headRefName,baseRefName,isDraft,isCrossRepository"

      OPEN = "OPEN"

      Result = Struct.new(:url, :branch, :draft, :failure_class, :message, keyword_init: true) do
        def ok? = failure_class.nil?
        def draft? = draft ? true : false
      end

      def self.call(**kwargs) = new(**kwargs).call

      # +slug+ (`owner/repository`) and +base_branch+ are passed explicitly rather than read off
      # an assignment, because MVP-0028 decision D6 gave this class a SECOND caller: the same
      # validation runs at GENERATION time, against `specification_target`'s facts, and at
      # PUBLICATION time, against `publication`'s — two different sections of two different
      # assignment phases. The caller resolves which; this class only ever asks GitHub and
      # judges what comes back.
      def initialize(commands:, slug:, base_branch:, url:, io: $stdout)
        @commands = commands
        @slug = slug.to_s
        @base_branch = base_branch.to_s
        @url = url.to_s
        @io = io
      end

      def call
        result = commands.gh([ "pr", "view", url, "--repo", slug, "--json", FIELDS ])
        return unreadable(result) unless result.success?

        pull_request = parse(result.stdout)
        return failure("could not read GitHub's answer for #{url}") if pull_request.nil?

        validate(pull_request)
      end

      private

      attr_reader :commands, :slug, :base_branch, :url, :io

      # Every reason a pull request Jira points at may not be updated by this run, each with the
      # remedy that actually fixes it. A table rather than a chain of guards, because the list IS
      # the contract for criterion 4 and a reader asking "what makes a Spec PR unusable?" should
      # find one place that answers it.
      def validate(pull_request)
        state = pull_request["state"].to_s
        branch = pull_request["headRefName"].to_s
        base = pull_request["baseRefName"].to_s

        return failure(closed_message(state)) unless state == OPEN
        return failure(fork_message) if pull_request["isCrossRepository"] == true
        return failure(base_message(base)) unless base == base_branch
        return failure("GitHub reported no head branch for #{url}, so SpecRelay cannot tell which " \
                       "branch to add this specification to") if branch.empty?

        log("Updating the specification pull request this ticket already has: #{url} (branch #{branch}).")
        # The runner is Rails-free: no ActiveSupport, so `presence` is not available here and the
        # emptiness check is explicit. GitHub's own URL is preferred over the one Jira stored,
        # because a Jira field can hold a redirect or a shortened form of the same pull request.
        reported = pull_request["url"].to_s
        Result.new(url: reported.empty? ? url : reported, branch: branch,
                   draft: pull_request["isDraft"] == true)
      end

      # A closed or merged pull request no longer tracks its branch, so pushing to it would put a
      # specification somewhere nobody is reviewing while Jira still linked the old one. The
      # remedy is a Jira edit, not a GitHub one — which is why the message says so.
      def closed_message(state)
        "the specification pull request this ticket links (#{url}) is #{state.downcase}, not open, so " \
          "this specification cannot be added to it. Clear the Jira Spec PR field to start a new one, " \
          "or reopen that pull request, then retry publication"
      end

      def fork_message
        "the specification pull request this ticket links (#{url}) is opened from a fork, which " \
          "SpecRelay does not push to. Clear the Jira Spec PR field to start a new one, then retry " \
          "publication"
      end

      def base_message(base)
        "the specification pull request this ticket links (#{url}) targets #{base.empty? ? 'an unknown branch' : base} " \
          "but this project publishes specifications against #{base_branch}. Resolve that " \
          "in GitHub or clear the Jira Spec PR field, then retry publication"
      end

      # `gh pr view` failing is NOT "there is no pull request". A missing one, a permissions
      # problem and an unreachable API look alike from here, and guessing "none" would open the
      # duplicate this whole class exists to prevent.
      def unreadable(result)
        failure("SpecRelay could not read the specification pull request this ticket links (#{url}): " \
                "#{commands.failure_reason(result, 'gh pr view')}. Check that it exists and that this " \
                "runner's GitHub CLI can see it, then retry publication")
      end

      def parse(json)
        parsed = JSON.parse(json.to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      def failure(message) = Result.new(failure_class: UNUSABLE, message: Redaction.redact(message.to_s))
      def log(message) = io.puts(Redaction.redact(message.to_s))
    end
  end
end
