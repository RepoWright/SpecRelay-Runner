# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "open3"
require "tmpdir"

module SpecrelayRunner
  # The uncommitted work a provider paused on, packaged so ANY eligible machine can continue it,
  # and the proof that a later session landed on exactly that work.
  #
  # Three operations, one rule each:
  #
  #   capture  — build the package from repositories the existing selection has already
  #              verified, reading only: the tree is written through a TEMPORARY git index, so
  #              the real index and working tree are exactly what they were;
  #   restore  — reproduce that work in a task workspace whose repositories are clean at the
  #              recorded base, importing git objects rather than applying text;
  #   verify   — remeasure and require exact agreement, which is what a provider start waits on
  #              whether the work was restored here or was already on this machine.
  #
  # WHY git objects rather than a diff. A patch cannot carry an empty file, and applying one
  # re-derives content that has to be byte-identical to be worth anything. A tree written from
  # the working copy records the exec bit, the symlink target, binary bytes and the empty blob
  # as git itself sees them, and the recorded change digest is measured by the SAME measurement
  # ({Workspace#capture_changes}) on both machines — so "the same work" is a fact rather than a
  # claim about a patch program.
  #
  # It fails CLOSED at every step, and every refusal names the term that failed. Nothing here
  # resets, cleans or overwrites a repository that is not exactly what was recorded: the whole
  # purpose is to continue real work, and destroying somebody else's is the outcome this exists
  # to prevent.
  module Checkpoint
    # The package's own name, checked before its bytes are believed.
    FORMAT = "specrelay-checkpoint-1"
    # The complete DECODED package, matching the bounded-package precedent Platform already
    # stores. A checkpoint over it is refused whole; nothing is ever truncated.
    MAX_BYTES = 4 * 1024 * 1024
    ENTRY_FIELDS = %w[base branch change_digest checkpoint_commit origin path].freeze
    PACKS = "packs"

    NO_REPOSITORY = "the executor reported no repository to checkpoint"
    COMMIT_MESSAGE = "Portable uncommitted-work checkpoint"

    # The checkpoint commit's identity, fixed so the same working tree always produces the same
    # commit id. It is a container for a tree and never an authored commit: it is created,
    # transported and read, and no branch ever points at it.
    COMMIT_IDENTITY = {
      "GIT_AUTHOR_NAME" => "SpecRelay", "GIT_AUTHOR_EMAIL" => "runner@specrelay.invalid",
      "GIT_AUTHOR_DATE" => "1970-01-01T00:00:00+0000",
      "GIT_COMMITTER_NAME" => "SpecRelay", "GIT_COMMITTER_EMAIL" => "runner@specrelay.invalid",
      "GIT_COMMITTER_DATE" => "1970-01-01T00:00:00+0000"
    }.freeze

    COMMIT_SHA = /\A[0-9a-f]{40}\z/
    DIGEST = /\A[0-9a-f]{64}\z/

    # The captured package, or the ONE reason nothing may be stored. A refusal reaches the
    # provider, which may correct its selection and ask again while its session is alive.
    Captured = Struct.new(:checkpoint, :error, keyword_init: true) do
      def ok? = error.nil?
    end

    Result = Struct.new(:ok, :reason, keyword_init: true) do
      def ok? = ok
    end

    # One located repository, or the reason it is not the recorded one. Two fields rather than a
    # string-or-string return: a path and a refusal are both text, and telling them apart by
    # inspecting the text is how a valid path becomes an error message.
    Located = Struct.new(:path, :reason, keyword_init: true) do
      def ok? = reason.nil?
    end

    module_function

    # The package for every repository the executor selected, in the order it selected them.
    #
    # `repositories` are {Workspace::Repository} values the existing selection has already
    # proven: inside the task workspace, a real git root, on the run's canonical branch, with a
    # supported and unique remote identity. Nothing here re-decides any of that — it measures
    # what those repositories hold and packages it.
    def capture(repositories:, workspace:)
      return refuse_capture(NO_REPOSITORY) if repositories.empty?

      entries = []
      packs = []
      repositories.each do |repository|
        built = package(repository, workspace)
        return built if built.is_a?(Captured)

        entries << built.first
        packs << built.last
      end
      seal(entries, packs)
    end

    # Reproduce the recorded work in `task_root`, then prove it.
    #
    # The payload is checked against the recorded size and checksum BEFORE any repository is
    # touched, and every target is proven clean at the recorded base before its objects are
    # imported — so a package that is not the recorded one, or a workspace that is not the
    # recorded base, never reaches a working tree at all.
    def restore(checkpoint, payload:, task_root:, workspace:)
      entries = recorded_entries(checkpoint)
      return refuse(entries) if entries.is_a?(String)

      packs = unseal(checkpoint, payload, entries.length)
      return refuse(packs) if packs.is_a?(String)

      entries.each_with_index do |entry, index|
        target = clean_target(entry, task_root)
        return refuse(target.reason) unless target.ok?

        failure = import(target.path, entry, packs[index])
        return refuse(failure) if failure
      end
      verify(checkpoint, task_root: task_root, workspace: workspace)
    end

    # Remeasure every recorded repository and require exact agreement. THE gate a provider start
    # waits on, whether this machine restored the work a moment ago or has held it all along.
    def verify(checkpoint, task_root:, workspace:)
      entries = recorded_entries(checkpoint)
      return refuse(entries) if entries.is_a?(String)

      entries.each do |entry|
        located = locate(entry, task_root)
        return refuse(located.reason) unless located.ok?

        changes = workspace.capture_changes(located.path)
        return refuse("could not measure #{quoted(entry['path'])}: #{changes.measurement_error}") unless changes.measured?
        next if Digest::SHA256.hexdigest(changes.diff.to_s) == entry["change_digest"]

        return refuse("the change_digest of #{quoted(entry['path'])} does not match the recorded checkpoint")
      end
      Result.new(ok: true)
    end

    def refuse_capture(reason) = Captured.new(checkpoint: nil, error: reason)
    def refuse(reason) = Result.new(ok: false, reason: reason)

    # ---------------------------------------------------------------- capture internals

    # One repository's entry and its git objects, or the refusal that stops the whole capture.
    def package(repository, workspace)
      changes = workspace.capture_changes(repository.path)
      return refuse_capture("could not measure #{quoted(repository.relative_path)}: #{changes.measurement_error}") unless changes.measured?

      base = changes.head_commit.to_s.downcase
      return refuse_capture("could not read the base commit of #{quoted(repository.relative_path)}") unless COMMIT_SHA.match?(base)

      commit = checkpoint_commit(repository.path, base)
      return refuse_capture("could not build a checkpoint of #{quoted(repository.relative_path)}") if commit.nil?

      pack = pack(repository.path, commit, base)
      return refuse_capture("could not package #{quoted(repository.relative_path)}") if pack.nil?

      [ entry(repository, base, commit, changes), Base64.strict_encode64(pack) ]
    end

    def entry(repository, base, commit, changes)
      { "path" => repository.relative_path, "origin" => repository.id,
        "branch" => repository.branch, "base" => base, "checkpoint_commit" => commit,
        "change_digest" => Digest::SHA256.hexdigest(changes.diff.to_s) }
    end

    # The bounded transport document: the metadata Platform validates and stores, and the opaque
    # package it never reads. The packs are POSITIONAL — pack N belongs to repository N — which
    # is the same ordering rule the answers already travel by.
    def seal(entries, packs)
      bytes = JSON.generate(PACKS => packs).b
      if bytes.bytesize > MAX_BYTES
        return refuse_capture("the checkpoint is too large (#{bytes.bytesize} bytes; the limit is #{MAX_BYTES})")
      end

      Captured.new(checkpoint: { "format" => FORMAT, "byte_size" => bytes.bytesize,
                                 "digest" => Digest::SHA256.hexdigest(bytes),
                                 "repositories" => entries,
                                 "payload" => Base64.strict_encode64(bytes) })
    end

    # The commit whose tree IS the current working tree, built in a temporary index.
    #
    # `read-tree` seeds that index from `HEAD` and `add --all` then stages the working tree over
    # it, so the tree records exactly what git can see — additions, deletions, renames, mode
    # changes, symlinks and binary content — and excludes exactly what git ignores. The real
    # index is never opened for writing, which is why capture cannot disturb the work it
    # describes.
    def checkpoint_commit(path, base)
      tree = Dir.mktmpdir("specrelay-checkpoint-index-") do |dir|
        index = { "GIT_INDEX_FILE" => File.join(dir, "index") }
        next nil unless git(path, %w[read-tree HEAD], env: index).first
        next nil unless git(path, %w[add --all], env: index).first

        staged = git(path, %w[write-tree], env: index)
        staged.first ? staged.last.strip : nil
      end
      return nil if tree.nil?

      built = git(path, [ "commit-tree", tree, "-p", base, "-m", COMMIT_MESSAGE ], env: COMMIT_IDENTITY)
      built.first ? built.last.strip : nil
    end

    # Only the objects the target does not already have: everything reachable from the checkpoint
    # commit that is not reachable from the base it was taken on top of.
    def pack(path, commit, base)
      ok, out = git(path, %w[pack-objects --revs --stdout -q], stdin: "#{commit}\n^#{base}\n")
      ok ? out : nil
    end

    # ---------------------------------------------------------------- restore internals

    # The recorded repositories, or the reason they cannot be acted on. Duplicates are refused
    # here because two entries for one path would restore twice and prove once.
    def recorded_entries(checkpoint)
      entries = checkpoint.to_h["repositories"]
      return "the recorded checkpoint names no repository" unless entries.is_a?(Array) && entries.any?

      paths = entries.map { |entry| entry.to_h["path"].to_s }
      return "the recorded checkpoint names the same repository twice" if paths.uniq.length != paths.length

      entries.map(&:to_h)
    end

    # The packages, or the reason these bytes are not the recorded ones. Checked before any
    # repository is opened: a payload that fails here has proven nothing and must change nothing.
    def unseal(checkpoint, payload, expected)
      recorded = checkpoint.to_h
      return "the recorded checkpoint is not a #{FORMAT} package" unless recorded["format"] == FORMAT

      bytes = decode(payload)
      return "the checkpoint payload is not readable" if bytes.nil?
      return "the checkpoint payload is too large (#{bytes.bytesize} bytes; the limit is #{MAX_BYTES})" if bytes.bytesize > MAX_BYTES
      return "the checkpoint payload is #{bytes.bytesize} bytes; #{recorded['byte_size']} were recorded" unless bytes.bytesize == recorded["byte_size"]
      return "the checkpoint payload does not match its recorded checksum" unless Digest::SHA256.hexdigest(bytes) == recorded["digest"]

      packs(bytes, expected)
    end

    def packs(bytes, expected)
      document = JSON.parse(bytes)
      return "the checkpoint payload is not readable" unless document.is_a?(Hash)

      encoded = document[PACKS]
      return "the checkpoint payload is not readable" unless encoded.is_a?(Array) && encoded.length == expected

      decoded = encoded.map { |pack| decode(pack) }
      decoded.include?(nil) ? "the checkpoint payload is not readable" : decoded
    rescue JSON::ParserError
      "the checkpoint payload is not readable"
    end

    def decode(value)
      Base64.strict_decode64(value.to_s).b
    rescue ArgumentError
      nil
    end

    # The repository this entry names, proven to be the one that was recorded, or the reason it
    # is not. Containment comes first, then git, then identity, then position — so a refusal
    # names the most specific cause rather than a consequence of it.
    def locate(entry, task_root)
      relative = entry["path"].to_s
      outside = "the recorded path #{quoted(relative)} is not inside the task workspace"
      return unlocated(outside) if rooted?(relative)

      # Lexically first, so a traversing entry is refused for what it IS rather than for the
      # directory it happens not to reach; then again on the resolved paths, which is what a
      # symlink pointing out of the workspace would otherwise defeat.
      expanded = File.expand_path(relative, task_root.to_s)
      return unlocated(outside) unless inside?(File.expand_path(task_root.to_s), expanded)

      root = real(task_root)
      resolved = real(expanded)
      return unlocated("no git repository at the recorded path #{quoted(relative)}") if resolved.nil? || root.nil?
      return unlocated(outside) unless inside?(root, resolved)

      toplevel = capture_git(resolved, %w[rev-parse --show-toplevel])
      return unlocated("no git repository at the recorded path #{quoted(relative)}") if toplevel.nil?
      return unlocated("the recorded path #{quoted(relative)} is not a git repository root") unless real(toplevel) == resolved

      reason = identified(entry, relative, resolved)
      reason ? unlocated(reason) : Located.new(path: resolved)
    end

    def unlocated(reason) = Located.new(reason: reason)

    # The identity and position terms, or the first one that failed.
    def identified(entry, relative, resolved)
      origin = GithubRemote.slug(capture_git(resolved, %w[remote get-url origin]))
      return "the origin of #{quoted(relative)} is not the recorded repository" unless origin.to_s.casecmp?(entry["origin"].to_s)
      return "the branch of #{quoted(relative)} is not the recorded #{quoted(entry['branch'])}" unless
        capture_git(resolved, %w[symbolic-ref --quiet --short HEAD]) == entry["branch"].to_s
      return "the base commit of #{quoted(relative)} is not the recorded one" unless
        capture_git(resolved, %w[rev-parse HEAD]).to_s.downcase == entry["base"].to_s

      nil
    end

    # The same repository, additionally proven to hold nothing of its own. Restoring into a
    # working tree somebody else is using would destroy their work, so an unclean target is a
    # refusal and never something to clean.
    def clean_target(entry, task_root)
      located = locate(entry, task_root)
      return located unless located.ok?

      status = git(located.path, %w[status --porcelain])
      return unlocated("the state of #{quoted(entry['path'])} could not be read") unless status.first
      return located if status.last.strip.empty?

      unlocated("#{quoted(entry['path'])} has uncommitted changes; the recorded work was not restored onto it")
    end

    # Import the objects, prove the commit is the recorded one taken on this exact base, and
    # materialize its tree as UNCOMMITTED work.
    #
    # The working tree is updated through a temporary index seeded from `HEAD`, so the
    # repository's own index still describes `HEAD` afterwards: the restored files are dirty
    # exactly as the machine that captured them had them, rather than staged.
    def import(path, entry, pack)
      relative = quoted(entry["path"])
      return "the recorded objects for #{relative} could not be imported" unless git(path, %w[unpack-objects -q], stdin: pack).first

      commit = entry["checkpoint_commit"].to_s
      return "the recorded checkpoint of #{relative} is missing from its package" unless
        git(path, [ "cat-file", "-e", "#{commit}^{commit}" ]).first
      return "the recorded checkpoint of #{relative} was not taken on its recorded base" unless
        capture_git(path, [ "rev-parse", "#{commit}^" ]).to_s.downcase == entry["base"].to_s

      materialize(path, commit) ? nil : "the recorded work could not be written into #{relative}"
    end

    def materialize(path, commit)
      Dir.mktmpdir("specrelay-checkpoint-index-") do |dir|
        index = { "GIT_INDEX_FILE" => File.join(dir, "index") }
        next false unless git(path, %w[read-tree HEAD], env: index).first

        git(path, [ "read-tree", "-u", "--reset", commit ], env: index).first
      end
    end

    # ---------------------------------------------------------------- git and paths

    # ONE binary-safe git call: an argv array, never a shell line, with an optional per-call
    # environment and optional standard input.
    #
    # Its own adapter rather than {Workspace}'s or {Review::Checkout::Git}'s because neither can
    # carry `GIT_INDEX_FILE` or return a pack: both bound their captured output for operator
    # text, and a truncated pack is a corrupt one.
    def git(path, args, env: {}, stdin: nil)
      out, _err, status = Open3.capture3(env, "git", "-C", path.to_s, *args,
                                         stdin_data: stdin.to_s, binmode: true)
      [ status.success?, out.b ]
    rescue SystemCallError
      [ false, "".b ]
    end

    # Trimmed output of a successful read-only query, or nil. A failed query is never an empty
    # answer: every caller turns nil into a refusal rather than into a default.
    def capture_git(path, args)
      ok, out = git(path, args)
      return nil unless ok

      value = out.to_s.strip
      value.empty? ? nil : value
    end

    def rooted?(relative) = relative.start_with?("/", "~") || File.absolute_path?(relative)

    def inside?(root, resolved) = resolved == root || resolved.start_with?("#{root}#{File::SEPARATOR}")

    def real(path)
      File.realpath(path.to_s)
    rescue SystemCallError
      nil
    end

    # Recorded paths reach an operator-facing reason, so they are quoted and redacted: a
    # checkpoint that recorded something unexpected is exactly where that text must stay safe.
    def quoted(value) = Redaction.redact(value.to_s).inspect
  end
end
