# frozen_string_literal: true

require "json"
require "uri"

module SpecrelayRunner
  # Reconstructs the ticket's PREVIOUS ACCEPTED implementation inside a task workspace this run
  # just created (MAPIAI-87 design 5).
  #
  # A sibling of {ContinuedTarget}, never a widening of it. That class proves ONE recorded target
  # of THIS run — a reviewed pull request or a replacement's own published head — and its whole
  # value is that a claim with such a target may not deviate from it. This one carries a
  # DIFFERENT authority: several repositories, accepted by an EARLIER run, which are context for
  # the new work rather than the work itself. Mixing the two would let same-run authority be
  # overwritten by an older package, which is exactly the mistake the precedence rule forbids.
  #
  # It VERIFIES for every workspace and PLACES differently for two. A newly created one is put at
  # the exact accepted heads. A reused one may already hold this run's own partial publication,
  # rework, restart or answered-resume state, so it is reconciled rather than reset — proved to
  # contain the accepted commit, moved forward only when that is an unambiguous fast-forward, and
  # never rewound.
  #
  # It fails CLOSED, and it verifies EVERY target before it mutates any of them. Current GitHub
  # state is the safety authority: a package is Platform's record of what was accepted, and a
  # pull request that has since closed, moved or been re-pointed means this machine must not
  # start work it cannot honestly continue.
  #
  # Its nested {Input} owns the assignment field itself, for BOTH lanes — see there for why
  # absence and an explicit null are different documents.
  class PreviousAcceptedPackage
    Result = Struct.new(:ok, :reason, :repositories, keyword_init: true) do
      def ok? = ok
    end

    # What a claim says about continuation, read ONCE through {Input}. `package` is nil for the
    # explicit null of a first run; `ok?` is false when the field is absent or is not the closed
    # block the contract defines, and then `reason` says which fact failed.
    Claim = Struct.new(:ok, :reason, :package, keyword_init: true) do
      def ok? = ok
    end

    OPEN = "OPEN"

    # The one authoritative reading of the required, nullable continuation field. Both lanes call
    # it — the implementation lane here, the specification lane through {Input} — so neither can
    # invent its own idea of what the field may contain.
    def self.read(payload, env: ENV, github: GitHub, git: Review::Checkout::Git)
      reason = Input.refusal(payload)
      return Claim.new(ok: false, reason: reason) if reason

      hash = payload.to_h
      block = hash["previous_accepted_package"]
      return Claim.new(ok: true) if block.nil?

      Claim.new(ok: true, package: new(block, hash.dig("run", "canonical_branch"),
                                       env: env, github: github, git: git))
    end

    def initialize(block, canonical_branch, env: ENV, github: GitHub, git: Review::Checkout::Git)
      @block = block
      @canonical_branch = canonical_branch.to_s
      @env = env
      @github = github
      @git = git
    end
    # {read} is the only way in: every method below assumes {Input} already proved the shape.
    private_class_method :new

    # Put every accepted repository of the task workspace on the canonical branch at its verified
    # head, or refuse. A package that changed nothing succeeds without touching git.
    def materialize(task_root:) = act(task_root) { |plans| place(plans) }

    # PROVE a workspace this run did not build already contains the accepted implementation,
    # without resetting it. Same targets, same verification, different placement — see {advance}.
    def reconcile(task_root:) = act(task_root) { |plans| advance(plans) }

    private

    # Everything the two entry points share: read the targets, find them in the workspace, and
    # prove every one of them before any of them is touched.
    def act(task_root)
      targets = read_targets
      return refuse(targets) if targets.is_a?(String)
      return Result.new(ok: true, repositories: []) if targets.empty?

      contained = ContainedRepositories.discover(task_root, git: git)
      return refuse(contained.error) unless contained.ok?

      plans = plan(targets, contained)
      return refuse(plans) if plans.is_a?(String)

      yield(plans)
    end

    attr_reader :block, :canonical_branch, :env, :github, :git

    # The accepted targets as a SET, or the first fact about them that failed. {Input} already
    # proved the shape, the formats and the bounds; what is left is the agreement between fields
    # that only this lane cares about.
    def read_targets
      return "this claim carries no canonical branch to place the accepted heads on" if canonical_branch.empty?

      collect(block["implementation_pull_requests"])
    end

    def collect(entries)
      seen = {}
      targets = []
      entries.each do |entry|
        target = readable(entry)
        return target if target.is_a?(String)

        identity = target[:identity]
        return "the previous accepted package names #{identity} twice" if seen.key?(identity)

        seen[identity] = true
        targets << target
      end
      targets
    end

    # One accepted entry, or the reason it is unusable: the identity is normalized the one way
    # this runner normalizes one and must be the repository the entry names, and the pull request
    # must belong to that repository — a foreign url never reaches `gh`.
    def readable(entry)
      repository = entry["repository"]
      slug = GithubRemote.slug(entry["clone_url"])
      return "the accepted repository #{quoted(repository)} has no supported GitHub remote" if
        slug.nil? || !slug.casecmp?(repository)
      return "the accepted pull request of #{quoted(repository)} does not belong to it" unless
        pull_request_url?(slug, entry["pull_request_url"])

      { identity: slug.downcase, repository: slug, branch: entry["branch"],
        head: entry["head_commit"], url: entry["pull_request_url"] }
    end

    # Every target resolved and PROVED before any of them is moved. All-or-nothing: a workspace
    # with one repository placed and another refused is a half-reconstructed base no executor may
    # start from.
    def plan(targets, contained)
      plans = []
      targets.each do |target|
        path = contained.resolve(target[:identity])
        return "no repository in the prepared task workspace is #{quoted(target[:repository])}" if path == :missing
        return "the prepared task workspace holds two checkouts of #{quoted(target[:repository])}" if path == :duplicate

        refusal = verify(target, path)
        return refusal if refusal

        plans << target.merge(path: path)
      end
      plans
    end

    # The order is deliberate: the local facts first, so an unusable or dirty workspace is refused
    # without a network call, then GitHub's own answer, then the object itself.
    def verify(target, path)
      return "the checkout of #{quoted(target[:repository])} has uncommitted changes; " \
             "release the task workspace before retrying" unless clean?(path)

      pull_request_refusal(target, path) || fetch_head(target, path)
    end

    # WHAT GITHUB SAYS NOW. The package records what was accepted; only the live pull request can
    # say whether that is still the head a new round may build on, so a closed, moved, re-branched
    # or unreadable one refuses rather than being reconstructed from a stale record.
    def pull_request_refusal(target, path)
      observed = github.pull_request(root: path, slug: target[:repository], url: target[:url], env: env)
      return "SpecRelay could not read the accepted pull request of #{quoted(target[:repository])}; " \
             "refusing to continue from a head it cannot confirm" if observed.nil?

      state = observed["state"].to_s
      return "the accepted pull request of #{quoted(target[:repository])} is #{state.downcase}, not open" unless
        state == OPEN
      return "the accepted pull request of #{quoted(target[:repository])} is on branch " \
             "#{quoted(observed['headRefName'].to_s)}, not #{quoted(target[:branch])}" unless
        observed["headRefName"].to_s == target[:branch]
      return "the accepted head of #{quoted(target[:repository])} moved from " \
             "#{target[:head][0, 12]} to #{observed['headRefOid'].to_s[0, 12]}" unless
        observed["headRefOid"].to_s.casecmp?(target[:head])

      nil
    end

    # One read-only fetch, then the object itself. The accepted commit legitimately does not exist
    # in a workspace that was just created, so fetching is the ordinary path rather than a repair.
    def fetch_head(target, path)
      return nil if git.commit?(path, target[:head])

      git.fetch(path)
      return nil if git.commit?(path, target[:head])

      "#{quoted(target[:repository])} does not contain the accepted head " \
        "#{target[:head][0, 12]} after a fetch"
    end

    # `checkout -B` onto the canonical task branch, so the branch the executor works on — and that
    # publication pushes from — IS the accepted head. A detached checkout would leave publication
    # unable to find the branch, and a merge would invent a commit nobody accepted.
    def place(plans)
      plans.each do |plan|
        result = run(plan[:path], [ "checkout", "-B", canonical_branch, plan[:head] ])
        return refuse("could not place #{quoted(plan[:repository])} on #{quoted(canonical_branch)} " \
                      "at its accepted head") unless result&.exit_code.to_i.zero?
      end
      Result.new(ok: true, repositories: plans.map { |plan| plan[:repository] })
    end

    # A reused workspace proved to CONTAIN the accepted head, and moved forward only when that
    # is unambiguous.
    #
    # Newer work is preserved: a workspace that carries a descendant of the accepted commit
    # already contains the accepted implementation, and rewinding it would delete the round that
    # produced it. A workspace that is merely behind is fast-forwarded, which invents no commit.
    # Divergence refuses — this reconstructs a base, it does not resolve one — and so does a
    # workspace whose checkout is not on the canonical branch at all, because the branch the
    # accepted head must be reachable from is the one the ticket works on.
    def advance(plans)
      plans.each do |plan|
        refusal = advance_one(plan)
        return refuse(refusal) if refusal
      end
      Result.new(ok: true, repositories: plans.map { |plan| plan[:repository] })
    end

    def advance_one(plan)
      branch = value(plan[:path], %w[symbolic-ref --quiet --short HEAD])
      return "the checkout of #{quoted(plan[:repository])} is not on the canonical branch " \
             "#{quoted(canonical_branch)}" unless branch == canonical_branch

      local = value(plan[:path], %w[rev-parse HEAD])
      return "SpecRelay could not read the current head of #{quoted(plan[:repository])}" if local.nil?
      return nil if local == plan[:head] || ancestor?(plan[:path], plan[:head], local)
      return fast_forward(plan) if ancestor?(plan[:path], local, plan[:head])

      "the checkout of #{quoted(plan[:repository])} has diverged from the accepted head " \
        "#{plan[:head][0, 12]}; preserve or release the task workspace before retrying"
    end

    def fast_forward(plan)
      result = run(plan[:path], [ "merge", "--ff-only", plan[:head] ])
      return nil if result && result.exit_code.to_i.zero?

      "#{quoted(plan[:repository])} could not be advanced to its accepted head #{plan[:head][0, 12]}"
    end

    def ancestor?(path, ancestor, descendant)
      result = run(path, [ "merge-base", "--is-ancestor", ancestor, descendant ])
      !result.nil? && result.exit_code.to_i.zero?
    end

    # Trimmed stdout of a successful read-only query, or nil. A failed query is never an answer.
    def value(path, args)
      result = run(path, args)
      result && result.exit_code.to_i.zero? ? result.stdout.to_s.strip : nil
    end

    def clean?(path)
      result = run(path, %w[status --porcelain])
      !result.nil? && result.exit_code.to_i.zero? && result.stdout.to_s.strip.empty?
    end

    def pull_request_url?(slug, url)
      %r{\Ahttps://github\.com/#{Regexp.escape(slug)}/pull/\d+\z}i.match?(url)
    end

    # Every reason reaches an operator, so an assignment string that was not what we expected is
    # exactly the case where the text must stay safe.
    def quoted(value) = Redaction.redact(value.to_s).inspect

    def run(path, args)
      CommandRunner.run([ "git", "-C", path, *args ], chdir: path,
                        timeout_seconds: Review::Checkout::Git::TIMEOUT_SECONDS)
    rescue SystemCallError
      nil
    end

    def refuse(reason) = Result.new(ok: false, reason: reason)

    # The closed nullable continuation block, as INPUT.
    #
    # The contract makes `previous_accepted_package` required and nullable so that absence and
    # "this ticket has no accepted implementation" are different documents. Both lanes read the
    # field through here, because both would otherwise have to decide what a missing, scalar,
    # partial or unknown-keyed value means — and the only safe answer is that it means the
    # assignment is not the one Platform builds.
    #
    # It is CLOSED on purpose: an unknown key is a newer or foreign document, and reading the
    # parts this build recognises would be exactly the guess the contract exists to prevent.
    module Input
      KEY = "previous_accepted_package"
      MAX_PULL_REQUESTS = 100
      MAX_STRING = 500

      SHA256 = /\A[0-9a-f]{64}\z/
      COMMIT = /\A[0-9a-f]{40}\z/

      KINDS = { text: "bounded non-empty string", url: "credential-free https url",
                sha256: "sha256 digest", commit: "40-character commit sha",
                object: "object", list: "list" }.freeze

      BLOCK = { "package_id" => :text, "checksum" => :sha256, "source_run_id" => :text,
                "approved_specification" => :object, "implementation_pull_requests" => :list }.freeze
      SPECIFICATION = { "reference" => :url, "digest" => :sha256 }.freeze
      PULL_REQUEST = { "repository" => :text, "clone_url" => :url, "branch" => :text,
                       "head_commit" => :commit, "pull_request_url" => :url }.freeze

      module_function

      # nil when the field is present and usable — an explicit null, or the exact closed block.
      # Otherwise the operator-facing reason, which names fields and never echoes their values.
      def refusal(payload)
        hash = payload.to_h
        unless hash.key?(KEY)
          return "the assignment carries no #{KEY}; the contract requires the field on every " \
                 "claim, and an explicit null when the ticket has no accepted implementation"
        end

        value = hash[KEY]
        return nil if value.nil?
        return "#{KEY} is a #{value.class} rather than an object or null" unless value.is_a?(Hash)

        closed(KEY, value, BLOCK) ||
          closed("#{KEY}.approved_specification", value["approved_specification"], SPECIFICATION) ||
          pull_requests(value["implementation_pull_requests"])
      end

      def closed(where, record, fields)
        # The path, and the FACT — never the keys. An unknown key is attacker-controlled text, and
        # this reason travels into operator logs and, on the specification lane, into the refusal
        # payload Platform stores durably. Naming the keys would make a JSON key a channel for
        # carrying a credential across that boundary.
        return "#{where} carries fields this build does not recognise" if (record.keys - fields.keys).any?

        missing = fields.keys - record.keys
        return "#{where} is missing #{missing.sort.join(', ')}" if missing.any?

        fields.filter_map { |name, kind| malformed(where, name, record[name], kind) }.first
      end

      def malformed(where, name, value, kind)
        return nil if valid?(value, kind)

        "#{where}.#{name} is not a #{KINDS.fetch(kind)}"
      end

      def valid?(value, kind)
        case kind
        when :text then value.is_a?(String) && !value.strip.empty? && value.length <= MAX_STRING
        when :url then value.is_a?(String) && value.length <= MAX_STRING && https_url?(value)
        when :sha256 then value.is_a?(String) && SHA256.match?(value)
        when :commit then value.is_a?(String) && COMMIT.match?(value)
        when :object then value.is_a?(Hash)
        when :list then value.is_a?(Array)
        end
      end

      # A URL, not an https-SHAPED string. `https:///no-host` passes every pattern test and names
      # nothing to reach, and a credential in userinfo must never travel on to `gh` or a packet —
      # so the string is parsed and asked what it actually is. One predicate for every `:url`
      # field, because a per-lane version is how the two lanes come to disagree.
      def https_url?(value)
        parsed = URI.parse(value)
        parsed.is_a?(URI::HTTPS) && !parsed.host.to_s.empty? && parsed.userinfo.nil?
      rescue URI::InvalidURIError
        false
      end

      # The bound is a refusal rather than a trim: a shortened list is a document that claims to
      # be the whole accepted implementation and is not.
      def pull_requests(entries)
        return "#{KEY} names #{entries.length} accepted pull requests; at most " \
               "#{MAX_PULL_REQUESTS} are accepted" if entries.length > MAX_PULL_REQUESTS

        entries.each_with_index do |entry, index|
          where = "#{KEY}.implementation_pull_requests[#{index}]"
          return "#{where} is a #{entry.class} rather than an object" unless entry.is_a?(Hash)

          reason = closed(where, entry, PULL_REQUEST)
          return reason if reason
        end
        nil
      end
    end

    # The injected GitHub seam. One bounded, read-only question — "what does GitHub show for this
    # pull request?" — asked with argv and answered with a Hash or nil. Nothing here interpolates
    # assignment data into a command line, and a missing or unauthenticated `gh` is nil rather
    # than a crash, which the caller turns into a refusal.
    module GitHub
      TIMEOUT_SECONDS = 120
      FIELDS = "url,state,headRefName,headRefOid,isCrossRepository"

      module_function

      def pull_request(root:, slug:, url:, env: ENV)
        result = run(root, [ "pr", "view", url, "--repo", slug, "--json", FIELDS ], env)
        return nil if result.nil? || !result.exit_code.to_i.zero?

        parsed = JSON.parse(result.stdout.to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      # The same forwarded set this lane's publication uses, reached for rather than restated:
      # both are this runner reaching GitHub for this run's repositories, so a change to what a
      # `gh` process may see must apply to both at once.
      def run(root, args, env)
        forwarded = Publication::FORWARDED_ENV.each_with_object({}) do |name, acc|
          value = env[name]
          acc[name] = value.to_s unless value.nil?
        end
        CommandRunner.run([ "gh", *args ], chdir: root, env: forwarded, timeout_seconds: TIMEOUT_SECONDS)
      rescue SystemCallError
        nil
      end
    end
  end
end
