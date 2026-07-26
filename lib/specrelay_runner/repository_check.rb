# frozen_string_literal: true

module SpecrelayRunner
  # Validate that a local directory really is the checkout of the workspace Platform
  # assigned (MVP-0017 scope 2 item 3).
  #
  # This is the local half of the MAPIAI-35 fix. The remote failure was Platform routing
  # a Tiny Demo ticket into `development-workspace`; the local failure mode is the mirror
  # image — an operator pointing the runner at whichever repository happens to be open.
  # So the runner refuses BEFORE registration completes unless the directory is a Git
  # repository whose configured remote and default branch match the assignment.
  #
  # Remote comparison is normalized: the same repository is legitimately addressed as an
  # https URL by Platform and as an scp-like SSH remote by a developer's checkout, so
  # transport, userinfo, port, a `.git` suffix, and case are all dropped and only
  # `host/owner/repo` is compared. Refusing that difference would make the guided path
  # unusable while proving nothing about identity. The normalization mirrors Platform's
  # RunnerWorkspaceConnection.repository_identity exactly, because the two sides must
  # agree or a locally-accepted checkout would be rejected server-side.
  #
  # Nothing here reaches the network: `git remote get-url` and `git branch` read local
  # configuration only, so validation cannot be slow, cannot leak the operator's
  # credentials to a remote, and works offline.
  class RepositoryCheck
    # Stable failure classifications, matching Platform's
    # RunnerWorkspaceConnection::FAILURE_* vocabulary so the two never drift.
    MISSING = "repository_missing"
    MISMATCH = "repository_mismatch"

    # Local git config reads; a few seconds is generous.
    TIMEOUT_SECONDS = 30

    Result = Struct.new(:failure_class, :message, :remote_url, :default_branch, keyword_init: true) do
      def ok? = failure_class.nil?
    end

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(path:, repository_url:, default_branch:, remote: "origin", runner: CommandRunner)
      @path = path.to_s
      @repository_url = repository_url.to_s
      @default_branch = default_branch.to_s
      @remote = remote
      @runner = runner
    end

    def call
      return missing("that path does not exist or is not a directory") unless File.directory?(path)
      return missing("that directory is not a Git repository") unless git_repository?

      remote_url = configured_remote_url
      return missing("that repository has no '#{remote}' remote configured") if remote_url.nil?
      return mismatch(remote_url) unless identity_matches?(remote_url)
      return branch_mismatch(remote_url) unless branch_present?

      Result.new(failure_class: nil, message: nil, remote_url: remote_url, default_branch: default_branch)
    end

    # `host/owner/repo`, lowercased. Identity only: transport, userinfo (which can be a
    # credential), port, `.git`, and trailing slashes are dropped.
    def self.repository_identity(url)
      text = url.to_s.strip.sub(/\Agit\+/, "")
      text = text.sub(%r{\A[A-Za-z][A-Za-z0-9+.\-]*://}, "")
      text = text.sub(%r{\A[^/@\s]*@}, "")
      text = text.sub(%r{\A([^:/\s]+):(?!\d)}, '\1/')
      host, _, tail = text.partition("/")
      identity = [ host.sub(/:\d+\z/, ""), tail ].reject(&:empty?).join("/")
      identity.sub(/\.git\z/, "").chomp("/").downcase
    end

    private

    attr_reader :path, :repository_url, :default_branch, :remote, :runner

    def git_repository?
      result = git(%w[rev-parse --git-dir])
      result&.success? ? true : false
    end

    def configured_remote_url
      result = git([ "remote", "get-url", remote ])
      return nil unless result&.success?

      url = result.stdout.to_s.strip
      url.empty? ? nil : url
    end

    def identity_matches?(remote_url)
      self.class.repository_identity(remote_url) == self.class.repository_identity(repository_url)
    end

    # The assigned default branch must exist locally (as a local branch or as a remote
    # tracking ref). A checkout of the right repository that has never fetched the
    # assigned branch cannot create the task branch from it, so it is not ready.
    def branch_present?
      %W[refs/heads/#{default_branch} refs/remotes/#{remote}/#{default_branch}].any? do |ref|
        git([ "rev-parse", "--verify", "--quiet", ref ])&.success?
      end
    end

    def missing(reason)
      Result.new(failure_class: MISSING, message: reason, remote_url: nil, default_branch: nil)
    end

    # The operator sees BOTH identities so the difference is obvious. Both are repository
    # URLs the operator already knows; neither is a secret, and userinfo is stripped by
    # Redaction before display as defence in depth.
    def mismatch(remote_url)
      Result.new(
        failure_class: MISMATCH,
        message: "that checkout's '#{remote}' remote is #{Redaction.redact(remote_url)}, " \
                 "but this workspace is #{Redaction.redact(repository_url)}",
        remote_url: remote_url, default_branch: nil
      )
    end

    def branch_mismatch(remote_url)
      Result.new(
        failure_class: MISMATCH,
        message: "that checkout has no '#{default_branch}' branch (the branch this workspace builds from); " \
                 "fetch it, then run connect again",
        remote_url: remote_url, default_branch: nil
      )
    end

    def git(args)
      runner.run([ "git", "-C", path, *args ], chdir: path,
                 env: { "PATH" => ENV["PATH"].to_s }, timeout_seconds: TIMEOUT_SECONDS)
    rescue SystemCallError
      nil
    end
  end
end
