# frozen_string_literal: true

module SpecrelayRunner
  # Every git repository CONTAINED in one prepared task workspace, mapped by normalized GitHub
  # identity (MAPIAI-87 design 5).
  #
  # It exists because Platform declares no repository list and no path map: the accepted package
  # names `owner/repository`, and only this machine can say where — or whether — that repository
  # is checked out inside the task workspace it just built. Discovery answers that by asking the
  # repositories themselves, so no layout convention and no registry is needed, and a project
  # whose task environment is several independent repositories is handled by the same code as one
  # that is a single checkout.
  #
  # It is bounded and containment-checked. A task workspace is an ordinary directory tree that may
  # hold vendored trees, caches and symlinks, so the walk stops at a fixed depth and a fixed
  # number of entries, never follows a link out of the task root, and never treats a directory
  # outside it as contained.
  #
  # It resolves nothing on its own: identity collisions are reported to the caller rather than
  # silently deduplicated, because "two checkouts of one accepted repository" is a workspace a
  # runner must refuse rather than choose between.
  module ContainedRepositories
    MAX_DEPTH = 3
    MAX_DIRECTORIES = 2_000
    MAX_REPOSITORIES = 100

    # Directories a task workspace legitimately contains and a repository never lives in. Skipping
    # them is a bound, not a policy: a vendored dependency tree can hold thousands of directories
    # and none of them is a repository this run may publish.
    SKIPPED = %w[node_modules vendor tmp log .bundle .runs].freeze

    Result = Struct.new(:paths_by_identity, :error, keyword_init: true) do
      def ok? = error.nil?

      # The single contained checkout with this identity. `:missing` and `:duplicate` are
      # returned rather than raised so the caller can name the accepted repository in its refusal.
      def resolve(identity)
        found = paths_by_identity[identity.to_s.downcase]
        return :missing if found.nil?

        found.length == 1 ? found.first : :duplicate
      end
    end

    module_function

    def discover(task_root, git: Review::Checkout::Git)
      root = real(task_root)
      return Result.new(error: "the prepared task workspace could not be resolved") if root.nil?

      roots = walk(root, root, 0, [])
      return Result.new(error: "the prepared task workspace holds more than #{MAX_REPOSITORIES} " \
                               "git repositories") if roots.length > MAX_REPOSITORIES

      Result.new(paths_by_identity: identify(roots, git))
    end

    # Depth-first, bounded twice, and containment-checked at every step. A repository root is
    # RECORDED and still descended into: SpecRelay's own task workspace is a git worktree whose
    # component repositories are its direct children, so stopping at the first `.git` would find
    # exactly one repository in the layout this exists to support.
    def walk(root, directory, depth, found)
      found << directory if File.exist?(File.join(directory, ".git"))
      return found if depth >= MAX_DEPTH || found.length > MAX_REPOSITORIES

      children(directory).each do |child|
        break if found.length > MAX_REPOSITORIES

        resolved = real(child)
        next if resolved.nil? || !inside?(root, resolved)

        walk(root, resolved, depth + 1, found)
      end
      found
    end

    # One directory's own children, bounded and alphabetical so discovery is deterministic.
    def children(directory)
      Dir.children(directory).sort.first(MAX_DIRECTORIES).filter_map do |name|
        next if SKIPPED.include?(name) || name.start_with?(".")

        path = File.join(directory, name)
        path if File.directory?(path) && !File.symlink?(path)
      end
    rescue SystemCallError
      []
    end

    # The GitHub identity each contained repository declares for itself, normalized the one way
    # this runner normalizes one ({GithubRemote}), so an https remote and its scp-like ssh
    # spelling are one repository. A repository with no supported `origin` is not an accepted
    # target and is simply absent from the map.
    def identify(roots, git)
      roots.each_with_object({}) do |path, acc|
        slug = GithubRemote.slug(git.remote_url(path))
        next if slug.nil?

        (acc[slug.downcase] ||= []) << path
      end
    end

    def inside?(root, path) = path == root || path.start_with?("#{root}#{File::SEPARATOR}")

    def real(path)
      File.realpath(path.to_s)
    rescue SystemCallError
      nil
    end
  end
end
