# frozen_string_literal: true

require "json"
require "tmpdir"

module SpecrelayRunner
  # Retires the remote pull requests and branches one ticket reset recorded, and reports one
  # classified row per planned resource.
  #
  # Platform decides what is OWNED — it recorded every resource in the plan — and whether this
  # report completes the reset. This side reads the live remote state and mutates only:
  #
  #   - an OPEN planned pull request, closed through {Review::Retirement}'s convergent close; and
  #   - a planned branch whose remote head still equals the recorded head, deleted with that head
  #     as the push lease, so a branch that moved in between is refused by the remote itself.
  #
  # A merged pull request, the default branch, a merged pull request's branch and a moved branch
  # are preserved; anything it cannot read is `unverifiable` and preserved. A retry re-reads the
  # live state, so a closed pull request or a deleted branch comes back `already_retired` and no
  # close or delete is repeated. A claim whose lease Platform no longer confirms stops before its
  # next mutation and reports nothing.
  class TicketReset
    ASSIGNMENT_KIND = "ticket_reset"
    MAX_ENTRIES = 100
    TIMEOUT_SECONDS = 120
    HEARTBEAT_SECONDS = 10

    RETIRED = "retired"
    ALREADY_RETIRED = "already_retired"
    MERGED = "merged"
    OPEN = "open"
    DEFAULT = "default"
    MOVED = "moved"
    UNVERIFIABLE = "unverifiable"

    SHA = /\A\h{40}\z/
    # A branch name that can only ever be a ref argument: no option, no whitespace, no lease or
    # refspec separator, no parent traversal.
    BRANCH = %r{\A(?!.*\.\.)[A-Za-z0-9][A-Za-z0-9._/-]*\z}

    Outcome = Struct.new(:message, :submitted, keyword_init: true) do
      def submitted? = submitted
    end

    def self.reset?(payload) = payload.is_a?(Hash) && payload["assignment_kind"] == ASSIGNMENT_KIND

    def initialize(payload:, client:, io:, env: ENV, heartbeat_seconds: HEARTBEAT_SECONDS)
      @payload = payload
      @client = client
      @io = io
      @env = env
      @heartbeat_seconds = heartbeat_seconds
    end

    def call
      return Outcome.new(message: "Refusing a reset assignment this runner cannot read.") unless readable?

      @beat = Heartbeater.new(client: client, claim: claim, interval_seconds: heartbeat_seconds, io: io).start
      # Confirmed once before anything is touched: a claim Platform already ended mutates nothing.
      @beat.renew
      rows = classify
      return stopped if rows.nil?

      body = client.submit_reset_result(claim: claim, result: rows)
      Outcome.new(message: "Reset of #{ticket_key} reported; Platform recorded it #{body['state']}.",
                  submitted: body["accepted"] == true)
    rescue PlatformClient::Error => e
      Outcome.new(message: "Reset of #{ticket_key} was not recorded: #{Redaction.redact(e.message)}")
    ensure
      @beat&.stop
    end

    private

    attr_reader :payload, :client, :io, :env, :heartbeat_seconds

    def claim = payload.dig("claim", "execution_id").to_s
    def ticket_key = payload.dig("reset", "ticket_key").to_s
    def pull_requests = payload["pull_requests"]
    def branches = payload["branches"]

    def readable?
      !claim.empty? && bounded?(pull_requests) { |url| url.is_a?(String) } &&
        bounded?(branches) { |row| row.is_a?(Hash) }
    end

    def bounded?(list, &) = list.is_a?(Array) && list.size <= MAX_ENTRIES && list.all?(&)

    # One row per planned resource, in plan order, or nil once the claim must stop. The lease is
    # checked before every resource, because every resource may be a mutation.
    def classify
      result = { "pull_requests" => [], "branches" => [] }
      pull_requests.each do |url|
        return nil if @beat.stop_reason

        result["pull_requests"] << { "url" => url, "classification" => pull_request(url) }
      end
      branches.each do |row|
        return nil if @beat.stop_reason

        result["branches"] << row.slice("repository_url", "branch").merge("classification" => branch(row))
      end
      result
    end

    def stopped = Outcome.new(message: "Reset of #{ticket_key} stopped: #{@beat.stop_reason}; nothing was reported.")

    def pull_request(url)
      repository = GithubRemote.pull_request_slug(url)
      return UNVERIFIABLE if repository.nil?

      retirement = Review::Retirement.new(
        plan: { "digest" => ASSIGNMENT_KIND, "pull_requests" => [ { "repository" => repository, "pull_request_url" => url } ] },
        chdir: Dir.tmpdir, env: env, timeout_seconds: TIMEOUT_SECONDS, io: io
      )
      live = retirement.state_of(repository: repository, url: url)
      return UNVERIFIABLE if live.error
      return MERGED if live.merged
      return ALREADY_RETIRED if live.state == Review::Retirement::CLOSED
      return UNVERIFIABLE unless live.state == Review::Retirement::OPEN

      closed = retirement.call
      return RETIRED if closed.ok?

      closed.failure_kind == Review::Retirement::PRODUCT_DECISION ? MERGED : OPEN
    end

    def branch(row)
      url, name, recorded = row.values_at("repository_url", "branch", "head_commit").map(&:to_s)
      slug = GithubRemote.slug(url)
      return UNVERIFIABLE if slug.nil? || !BRANCH.match?(name) || !SHA.match?(recorded)

      default = default_branch(url)
      return UNVERIFIABLE if default.nil?
      return DEFAULT if name == default

      head = remote_head(url, name)
      return UNVERIFIABLE if head == :unreadable
      return ALREADY_RETIRED if head.nil?

      merged = merged_head?(slug, name)
      return UNVERIFIABLE if merged.nil?
      return MERGED if merged
      return MOVED unless head == recorded

      delete(url, name, recorded) ? RETIRED : after_refused_delete(url, name, recorded)
    end

    # The remote refused the guarded delete; the live head says why.
    def after_refused_delete(url, name, recorded)
      head = remote_head(url, name)
      return ALREADY_RETIRED if head.nil?
      return MOVED if head != :unreadable && head != recorded

      UNVERIFIABLE
    end

    def default_branch(url)
      result = git("ls-remote", "--symref", url, "HEAD")
      return nil unless result.success?

      result.stdout[%r{^ref: refs/heads/(\S+)\tHEAD$}, 1]
    end

    # The branch's current remote head, nil when the branch is absent, or :unreadable.
    def remote_head(url, name)
      ref = "refs/heads/#{name}"
      result = git("ls-remote", url, ref)
      return :unreadable unless result.success?

      result.stdout.each_line.map { |line| line.chomp.split("\t", 2) }.find { |_sha, found| found == ref }&.first
    end

    # Whether a merged pull request's head is this branch, or nil when GitHub could not be read.
    def merged_head?(slug, name)
      result = run([ "gh", "pr", "list", "--repo", slug, "--head", name, "--state", "merged", "--json", "url",
                     "--limit", "1" ], Dir.tmpdir)
      return nil unless result.success?

      parsed = JSON.parse(result.stdout.to_s)
      parsed.is_a?(Array) ? parsed.any? : nil
    rescue JSON::ParserError
      nil
    end

    # The recorded head is the lease: the remote deletes the branch only while it still points
    # there. `git push` needs a repository to run in, and an empty one carries nothing of its own.
    def delete(url, name, recorded)
      ref = "refs/heads/#{name}"
      Dir.mktmpdir("specrelay-reset-") do |dir|
        git("init", "-q", chdir: dir).success? &&
          git("push", "--porcelain", "--force-with-lease=#{ref}:#{recorded}", url, "--delete", ref, chdir: dir).success?
      end
    end

    def git(*args, chdir: Dir.tmpdir) = run([ "git", *args ], chdir)

    # Only the operator's git/gh session variables, through the allowlist every authenticated
    # GitHub call in this runner uses, and never an interactive credential prompt.
    def run(argv, chdir)
      CommandRunner.run(argv, chdir: chdir, env: command_env, timeout_seconds: TIMEOUT_SECONDS)
    rescue SystemCallError => e
      CommandRunner::Result.new(exit_code: 127, stdout: "", stderr: e.message.to_s, duration_seconds: 0.0,
                                timed_out: false)
    end

    def command_env
      @command_env ||= Publication::FORWARDED_ENV.each_with_object({ "GIT_TERMINAL_PROMPT" => "0" }) do |name, acc|
        acc[name] = env[name].to_s unless env[name].nil?
      end
    end
  end
end
