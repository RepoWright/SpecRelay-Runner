# frozen_string_literal: true

require "json"

module SpecrelayRunner
  # MAPIAI-97 — the ticket's CURRENT pull-request heads, resolved once at the start of a preview
  # claim and then reconstructed inside a freshly created task workspace.
  #
  # A narrow sibling of {PreviousAcceptedPackage}, and the difference is the whole point. That
  # class proves an ACCEPTED head is still the head, and refuses when the pull request has moved —
  # which is exactly right for continuing work someone approved. A preview is the opposite
  # question: show me what is on these pull requests NOW. So this reads the current branch and head
  # rather than comparing against a recorded one, and it must never be turned into a mode of the
  # other: a flag that let continuation accept a moved head would corrupt MAPIAI-87.
  #
  # It reuses that lane's primitives verbatim — the same bounded argv-only `gh` reader, the same
  # containment discovery, the same clean-checkout, fetch and exact-head placement — because those
  # are safety mechanics rather than continuation policy.
  #
  # It is ALL-OR-NOTHING and resolves before it places: one unreadable, closed, foreign, duplicated
  # or malformed entry refuses the whole attempt while nothing has been created, which is what lets
  # that refusal be a CLEAN failure the operator can simply retry.
  class PreviewSources
    # The publisher already bounds an accepted package at one hundred rows; the same bound is
    # restated here so a malformed assignment cannot make this walk unbounded.
    MAX_SOURCES = 100
    SHA = /\A[0-9a-f]{40}\z/
    PULL_REQUEST_URL = %r{\Ahttps://github\.com/([^/\s]+/[^/\s]+)/pull/\d+\z}
    OPEN = "OPEN"

    # The closed entry shape. Exactly these keys: an assignment carrying anything else is a
    # document this runner does not understand, and silently ignoring the extra field is how a
    # command, path or host would arrive unnoticed.
    REQUIRED_KEYS = %w[repository pull_request_url].freeze
    IDENTITY = %r{\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\z}
    MAX_IDENTITY_BYTES = 200
    MAX_URL_BYTES = 2048

    Result = Struct.new(:ok, :reason, :sources, keyword_init: true) do
      def ok? = ok

      # The bounded evidence document Platform stores. Only the four facts the attempt is built
      # from — never the raw `gh` payload, which carries fields no reader needs.
      def snapshot
        Array(sources).map do |source|
          { "repository" => source[:repository], "pull_request_url" => source[:url],
            "branch" => source[:branch], "head_commit" => source[:head] }
        end
      end
    end

    def self.resolve(entries:, root:, env: ENV, github: PreviousAcceptedPackage::GitHub)
      new(entries, root, env: env, github: github).resolve
    end

    def initialize(entries, root, env: ENV, github: PreviousAcceptedPackage::GitHub,
                   git: Review::Checkout::Git)
      @entries = entries
      @root = root
      @env = env
      @github = github
      @git = git
    end

    # Read every assigned pull request exactly once and return the exact heads, or the first fact
    # that refused. No worktree exists yet when this runs, which is deliberate: the complete source
    # set is accepted before anything is created.
    def resolve
      preflighted = preflight
      return refuse(preflighted) if preflighted.is_a?(String)

      observe(preflighted)
    end

    # Place every resolved head on the canonical task branch inside the workspace that was just
    # created. Verified in full before anything is moved, for the reason the sibling states: a
    # workspace with one repository placed and another refused is a half-built base.
    def materialize(task_root:, canonical_branch:, sources:)
      return refuse("this preview claim carries no canonical branch") if canonical_branch.to_s.empty?

      contained = ContainedRepositories.discover(task_root, git: git)
      return refuse(contained.error) unless contained.ok?

      plans = plan(sources, contained)
      return refuse(plans) if plans.is_a?(String)

      place(plans, canonical_branch)
    end

    private

    attr_reader :root, :env, :github, :git

    def refuse(reason) = Result.new(ok: false, reason: reason, sources: [])

    # F3 — pass one. The COMPLETE assignment judged from its own contents, before a single external
    # read. It returns the preflighted entries in stable assignment order, or the first fact that
    # refused. This is a whole pass rather than a per-entry check because a valid first entry must
    # not be able to buy a GitHub call for a document that was already unusable.
    def preflight
      return "this preview claim does not carry a list of pull requests" unless @entries.is_a?(Array)
      return "this preview claim names no pull request to rebuild" if @entries.empty?
      return "this preview claim names more than #{MAX_SOURCES} pull requests" if @entries.length > MAX_SOURCES

      identities = {}
      urls = {}
      preflighted = []
      @entries.each_with_index do |entry, index|
        checked = preflight_entry(entry, index, identities, urls)
        return checked if checked.is_a?(String)

        preflighted << checked
      end
      preflighted
    end

    # One entry judged locally. The order is deliberate: shape, then closed keys, then presence,
    # then bounds, then format, then agreement, then uniqueness — each step assuming only what the
    # step before it proved.
    def preflight_entry(entry, index, identities, urls)
      at = "pull request #{index + 1}"
      return "#{at} is not a pull-request entry" unless entry.is_a?(Hash)

      extra = entry.keys.map(&:to_s) - REQUIRED_KEYS
      return "#{at} carries the unexpected field #{quoted(extra.first)}" if extra.any?

      repository = entry["repository"]
      url = entry["pull_request_url"]
      missing = REQUIRED_KEYS.find { |key| entry[key].nil? || entry[key].to_s.strip.empty? }
      return "#{at} is missing #{quoted(missing)}" if missing

      bounded(at, repository.to_s, url.to_s) || agreed(at, repository.to_s, url.to_s, identities, urls)
    end

    def bounded(at, repository, url)
      return "#{at} names a repository that is longer than #{MAX_IDENTITY_BYTES} bytes" if
        repository.bytesize > MAX_IDENTITY_BYTES
      return "#{at} names a url that is longer than #{MAX_URL_BYTES} bytes" if url.bytesize > MAX_URL_BYTES
      return "#{at} names #{quoted(repository)}, which is not an owner/repository identity" unless
        IDENTITY.match?(repository)

      nil
    end

    # The url is matched against a fixed pattern and must name the repository the entry declares —
    # a foreign url never becomes a `--repo` argument. Uniqueness is case-insensitive on identity,
    # because GitHub treats `Owner/Repo` and `owner/repo` as one repository.
    def agreed(at, repository, url, identities, urls)
      slug = PULL_REQUEST_URL.match(url)&.captures&.first
      return "#{at} (#{quoted(repository)}) has no readable GitHub pull request url" if slug.nil?
      return "the pull request #{quoted(url)} does not belong to #{quoted(repository)}" unless
        slug.casecmp?(repository)

      identity = slug.downcase
      return "this preview claim names #{quoted(slug)} twice" if identities.key?(identity)
      return "this preview claim names the pull request #{quoted(url)} twice" if urls.key?(url)

      identities[identity] = true
      urls[url] = true
      { identity: identity, repository: slug, url: url }
    end

    # F3 — pass two. Exactly one GitHub read per preflighted entry, in stable assignment order.
    def observe(preflighted)
      sources = []
      preflighted.each do |entry|
        answer = observed(entry[:repository], entry[:url])
        return refuse(answer) if answer.is_a?(String)

        sources << entry.merge(branch: answer[:branch], head: answer[:head])
      end
      Result.new(ok: true, sources: sources)
    end

    # WHAT GITHUB SAYS NOW, read once. A preview of a closed pull request would be a preview of
    # work nobody can still review, and a cross-repository head is not this repository's code.
    # Returns the two resolved facts, or the reason this entry is unusable.
    def observed(slug, url)
      answer = github.pull_request(root: root, slug: slug, url: url, env: env)
      return "SpecRelay could not read the pull request of #{quoted(slug)}" if answer.nil?

      state = answer["state"].to_s
      return "the pull request of #{quoted(slug)} is #{state.downcase}, not open" unless state == OPEN
      return "the pull request of #{quoted(slug)} comes from a fork" if answer["isCrossRepository"]

      branch = answer["headRefName"].to_s
      head = answer["headRefOid"].to_s.downcase
      return "the pull request of #{quoted(slug)} names no branch" if branch.empty?
      return "the pull request of #{quoted(slug)} has no exact head commit" unless SHA.match?(head)

      { branch: branch, head: head }
    end

    def plan(sources, contained)
      plans = []
      sources.each do |source|
        path = contained.resolve(source[:identity])
        return "no repository in the prepared task workspace is #{quoted(source[:repository])}" if path == :missing
        return "the prepared task workspace holds two checkouts of #{quoted(source[:repository])}" if path == :duplicate

        refusal = verify(source, path)
        return refusal if refusal

        plans << source.merge(path: path)
      end
      plans
    end

    # Local facts first, so an unusable workspace is refused without a network call, then the
    # object itself. A freshly created workspace legitimately lacks the commit, so fetching is the
    # ordinary path rather than a repair.
    def verify(source, path)
      return "the checkout of #{quoted(source[:repository])} has uncommitted changes" unless clean?(path)
      return nil if git.commit?(path, source[:head])

      git.fetch(path)
      return nil if git.commit?(path, source[:head])

      "#{quoted(source[:repository])} does not contain head #{source[:head][0, 12]} after a fetch"
    end

    # `checkout -B` onto the canonical task branch, so the branch the application is built from IS
    # the pull request's current head.
    def place(plans, canonical_branch)
      plans.each do |plan|
        result = run(plan[:path], [ "checkout", "-B", canonical_branch, plan[:head] ])
        return refuse("could not place #{quoted(plan[:repository])} at head #{plan[:head][0, 12]}") unless
          result&.exit_code.to_i.zero?
      end
      Result.new(ok: true, sources: plans)
    end

    def clean?(path)
      result = run(path, %w[status --porcelain])
      result&.exit_code.to_i.zero? && result.stdout.to_s.strip.empty?
    end

    # Fixed argv, never a shell string: nothing here is interpolated into a command line.
    def run(path, arguments)
      CommandRunner.run([ "git", *arguments ], chdir: path, env: {}, timeout_seconds: 120)
    rescue SystemCallError
      nil
    end

    def quoted(value) = "\"#{value}\""
  end
end
