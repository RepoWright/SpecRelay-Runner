# frozen_string_literal: true

module SpecrelayRunner
  # MAPIAI-97 — the closed boundary a `task_preview` assignment must pass before this runner does
  # anything at all.
  #
  # It is a DISCRIMINATED document, never an inferred one: the kind is read from
  # `assignment_kind`, so an implementation payload that happens to carry a `preview` block is not
  # a preview job. Inferring from field presence is how a runner ends up executing the wrong lane.
  #
  # Every block is closed. An unexpected key refuses the whole assignment rather than being
  # ignored, because the fields this lane does NOT accept are exactly the dangerous ones — a
  # command, an argv array, a local Platform path, a credential, a host or a port. There is no
  # allowlist of forbidden names to keep up to date; anything not named here is refused.
  #
  # It performs no network access and creates nothing. Its whole job is to decide whether the
  # document is worth acting on.
  class PreviewAssignment
    CONTRACT_VERSION = "mapiai-97"
    KIND = "task_preview"

    BLOCKS = %w[contract_version assignment_kind claim preview workspace sources].freeze
    CLAIM_KEYS = %w[execution_id claimed_at lease_expires_at].freeze
    CLAIM_REQUIRED = %w[execution_id].freeze
    PREVIEW_KEYS = %w[id ticket_key project_slug task_id canonical_branch].freeze
    WORKSPACE_KEYS = %w[key repository_url default_branch].freeze
    WORKSPACE_REQUIRED = %w[key].freeze

    MAX_VALUE_BYTES = 512
    # A task id names a worktree and a branch, so it is restricted to what both accept. This is
    # also what stops a task id from carrying a path segment or an option-looking argument.
    SAFE_TOKEN = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    Result = Struct.new(:ok, :reason, :execution_id, :preview_id, :task_id, :canonical_branch,
                        :ticket_key, :project_slug, :workspace_key, :sources, keyword_init: true) do
      def ok? = ok
    end

    # The DISPATCH question, answered from the discriminator alone: is this lane's job to read
    # this document at all? Everything about whether it may be acted on is {.read}'s answer.
    def self.preview?(payload) = payload.is_a?(Hash) && payload["assignment_kind"] == KIND

    # `payload` is the claim response. Returns a refusal for any document this lane may not act on,
    # including one that is simply not a preview.
    def self.read(payload)
      new(payload).read
    end

    def initialize(payload)
      @payload = payload
    end

    def read
      hash = @payload
      return refuse("this claim is not an assignment document") unless hash.is_a?(Hash)
      return refuse("this claim is not a task preview") unless hash["assignment_kind"] == KIND
      return refuse("this claim uses an unsupported contract version") unless
        hash["contract_version"] == CONTRACT_VERSION

      extra = hash.keys.map(&:to_s) - BLOCKS
      return refuse("this preview claim carries the unexpected block #{quoted(extra.first)}") if extra.any?

      build(hash)
    end

    private

    def refuse(reason) = Result.new(ok: false, reason: reason)

    def build(hash)
      claim = block_refusal(hash["claim"], "claim", CLAIM_KEYS, CLAIM_REQUIRED)
      return refuse(claim) if claim.is_a?(String)

      preview = block_refusal(hash["preview"], "preview", PREVIEW_KEYS, PREVIEW_KEYS)
      return refuse(preview) if preview.is_a?(String)

      workspace = block_refusal(hash["workspace"], "workspace", WORKSPACE_KEYS, WORKSPACE_REQUIRED)
      return refuse(workspace) if workspace.is_a?(String)

      token = token_refusal(preview)
      return refuse(token) if token

      accepted(claim, preview, workspace, hash["sources"])
    end

    # One closed block: an object, exactly the keys this lane knows, and every required value
    # present, scalar and inside its bound. A nested object or array where a string belongs is
    # refused rather than coerced — that is how a structured value smuggles itself into a field a
    # later step will interpolate.
    def block_refusal(block, name, allowed, required)
      return "the #{name} block is missing" if block.nil?
      return "the #{name} block is not an object" unless block.is_a?(Hash)

      extra = block.keys.map(&:to_s) - allowed
      return "the #{name} block carries the unexpected field #{quoted(extra.first)}" if extra.any?

      missing = required.find { |key| block[key].nil? || block[key].to_s.strip.empty? }
      return "the #{name} block is missing #{quoted(missing)}" if missing

      unscalar = allowed.find { |key| !block[key].nil? && !block[key].is_a?(String) }
      return "the #{name} block field #{quoted(unscalar)} is not a plain value" if unscalar

      oversized = allowed.find { |key| block[key].to_s.bytesize > MAX_VALUE_BYTES }
      return "the #{name} block field #{quoted(oversized)} is longer than #{MAX_VALUE_BYTES} bytes" if oversized

      block
    end

    # The two values that become command arguments. Both are restricted to a safe token so neither
    # can carry a path segment, an option or whitespace into an argv array.
    def token_refusal(preview)
      %w[task_id canonical_branch].each do |key|
        return "the preview #{key.tr('_', ' ')} #{quoted(preview[key])} is not a safe identifier" unless
          SAFE_TOKEN.match?(preview[key].to_s)
      end
      nil
    end

    # The source list is handed on unresolved: {PreviewSources} owns its complete preflight, and
    # restating those rules here would be a second contract parser for one document.
    def accepted(claim, preview, workspace, sources)
      Result.new(ok: true, execution_id: claim["execution_id"], preview_id: preview["id"],
                 task_id: preview["task_id"], canonical_branch: preview["canonical_branch"],
                 ticket_key: preview["ticket_key"], project_slug: preview["project_slug"],
                 workspace_key: workspace["key"], sources: sources)
    end

    def quoted(value) = "\"#{value}\""
  end
end
