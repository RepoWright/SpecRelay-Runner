# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

# A real bare git remote plus a scriptable fake `gh` executable, so the runner's
# MVP-0014 publication path is exercised end to end (real commit, real push to a
# real remote, real argv into the CLI) without touching github.com.
#
# The fake `gh` records every invocation to a log file and answers `pr list` from a
# state file, so pull-request create/reuse and its idempotency are observable
# facts rather than stubbed return values.
module FakeGithub
  module_function

  # Create a bare remote and register it as `origin` on the repository root.
  #
  # MAPIAI-84 — the url is ALWAYS the GitHub one, because the runner now reads a repository's
  # identity from its own `origin` rather than from an assignment entry. A local bare path would
  # give the fixture no GitHub identity at all, so every publication test would fail closed on a
  # fact about the fixture rather than about the runner. The bytes still never leave the machine:
  # `serve_locally` keeps the transport real and answers it from the bare repository.
  def add_remote(root, name: "tiny-demo-workspace", url: nil, default_branch: "main")
    remote = Dir.mktmpdir("specrelay-runner-remote-")
    bare = File.join(remote, "#{name}.git")
    system("git", "init", "-q", "--bare", bare, exception: true)
    git(root, "remote", "remove", "origin") if remote?(root)
    git(root, "remote", "add", "origin", url || "git@github.com:SpecRelay/#{name}.git")
    git(root, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/#{default_branch}")
    serve_locally(root, bare)
    bare
  end

  def remote?(root)
    _out, status = Open3.capture2e("git", "-C", root, "remote", "get-url", "origin")
    status.success?
  end

  # Git runs `ssh <host> '<service> <path>'` for an ssh remote. Replacing ssh with a shim that
  # ignores both and serves the local bare repository keeps the transport, the protocol and every
  # object real while the url stays the one the assignment names — and reaches no network. It is
  # `core.sshCommand` rather than an env var because the runner spawns git itself.
  def serve_locally(root, bare)
    shim = File.join(File.dirname(bare), "ssh")
    File.write(shim, <<~RUBY)
      #!/usr/bin/env ruby
      service = ARGV.last.to_s.split(" ").first.to_s.sub(/\\Agit-/, "")
      exec("git", service, #{bare.inspect})
    RUBY
    FileUtils.chmod(0o755, shim)
    git(root, "config", "core.sshCommand", shim)
  end

  # Write a fake `gh` into its own bin dir and return [bin_dir, log_path, state_path].
  #
  #   mode: "ok"              — pr create succeeds and the PR is then reusable
  #         "unauthenticated" — `gh auth status` fails, as on a host without gh login
  #         "create_fails"    — auth works, listing works, creation fails
  #         "create_silent"   — creation succeeds but prints no URL, forcing the runner's
  #                             fallback lookup (the path that hid a stale call arity)
  #         "list_fails"      — auth works, `pr list` fails (a transient api error);
  #                             this is the review-001 finding-1 scenario
  #         "list_fails_once" — the FIRST `pr list` fails, later ones succeed, so a
  #                             retry after a transient error can be exercised
  #         "list_garbage"    — `pr list` exits 0 with unparseable stdout
  #         "view_fails"      — `pr view` fails (the pull request is gone, or the API is
  #                             unreachable); MVP-0028's "cannot be inspected safely" case
  #
  # `bare` lets the fake resolve REAL head shas from the bare remote, so `headRefOid`
  # is a fact rather than a fixture. `seed` pre-populates pull requests (each a hash of
  # url/state/headRefName/headRefOid) so a closed or merged pull request from an earlier
  # round can be represented — the review-001 finding-2 scenario.
  # MAPIAI-84 — `urls` gives one pull-request URL per `owner/repo`, and `bares` one bare
  # repository per `owner/repo`, so a run publishing several repositories gets distinct pull
  # requests resolved against the right remote. `fail_create_for` makes creation fail for exactly
  # one repository, which is what a PARTIAL publication failure is.
  def gh_bin(mode: "ok", pull_request_url: "https://github.com/SpecRelay/tiny-demo-workspace/pull/7",
             bare: nil, seed: [], urls: {}, bares: {}, fail_create_for: nil)
    dir = Dir.mktmpdir("specrelay-runner-gh-")
    log = File.join(dir, "gh.log")
    state = File.join(dir, "prs.json")
    File.write(state, JSON.generate(seed))
    path = File.join(dir, "gh")
    File.write(path, script(mode: mode, pull_request_url: pull_request_url, log: log, state: state,
                            bare: bare, counter: File.join(dir, "list.count"), urls: urls,
                            bares: bares, fail_create_for: fail_create_for))
    FileUtils.chmod(0o755, path)
    [ dir, log, state ]
  end

  # The fake honours `--head` and `--state` because those flags are exactly what the
  # reuse semantics depend on: ignoring them made the old tests approximate the
  # behaviour instead of exercising it (review-001 finding 7).
  def script(mode:, pull_request_url:, log:, state:, bare:, counter:, urls: {}, bares: {},
             fail_create_for: nil)
    <<~RUBY
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      require "json"
      LOG = #{log.inspect}
      STATE = #{state.inspect}
      MODE = #{mode.inspect}
      URL = #{pull_request_url.inspect}
      BARE = #{bare.inspect}
      COUNTER = #{counter.inspect}
      URLS = #{urls.inspect}
      BARES = #{bares.inspect}
      FAIL_CREATE_FOR = #{fail_create_for.inspect}
      File.open(LOG, "a") { |f| f.puts(ARGV.join(" ")) }

      def prs = JSON.parse(File.read(STATE))

      def flag(name)
        index = ARGV.index(name)
        index && ARGV[index + 1]
      end

      # Real sha for a branch in the bare remote of the repository being asked about, so
      # headRefOid matches what was pushed to THAT repository.
      def head_oid(branch, repo = nil)
        remote = BARES[repo.to_s] || BARE
        return "" if remote.nil? || branch.nil?

        out = IO.popen([ "git", "-C", remote, "rev-parse", "refs/heads/\#{branch}" ], err: :close, &:read).to_s.strip
        $?.success? ? out : ""
      end

      def bump_list_count
        n = (File.exist?(COUNTER) ? File.read(COUNTER).to_i : 0) + 1
        File.write(COUNTER, n.to_s)
        n
      end

      case ARGV.first
      when "auth"
        abort("gh: not logged in") if MODE == "unauthenticated"
        puts "Logged in to github.com"
        exit 0
      when "pr"
        case ARGV[1]
        when "list"
          attempt = bump_list_count
          # Hangs so a REAL CommandRunner timeout can be exercised end to end; the test
          # lowers the gh timeout and CommandRunner kills this process group.
          sleep 30 if MODE == "list_hangs"
          abort("gh: could not reach api.github.com (simulated transient failure)") if MODE == "list_fails"
          abort("gh: could not reach api.github.com (simulated transient failure)") if MODE == "list_fails_once" && attempt == 1
          if MODE == "list_garbage"
            puts "not json at all"
            exit 0
          end
          head = flag("--head")
          repo = flag("--repo")
          wanted = (flag("--state") || "open").downcase
          rows = prs
          rows = rows.select { |pr| pr["headRefName"].to_s == head } unless head.nil?
          rows = rows.select { |pr| pr["state"].to_s.downcase == wanted } unless wanted == "all"
          # `--repo` is honoured for the same reason `--head` and `--state` are: one task branch
          # exists in several independent repositories, so a fake that ignored it would let one
          # repository's pull request be reused as another's (MAPIAI-84 S08/S09).
          rows = rows.reject { |pr| pr.key?("repo") && pr["repo"].to_s != repo.to_s }
          # A live pull request tracks its branch; refresh its head from the remote.
          rows = rows.map do |pr|
            pr["headRefOid"].to_s == "live" ? pr.merge("headRefOid" => head_oid(pr["headRefName"], pr["repo"] || repo)) : pr
          end
          puts JSON.generate(rows)
          exit 0
        when "view"
          # MVP-0028: `gh pr view <url> --json ...`. Answered from the SAME state file `pr list`
          # reads, so a pull request seeded as closed, on the wrong base, or from a fork is one
          # fact rather than two that can disagree.
          abort("gh: could not resolve to a PullRequest (simulated)") if MODE == "view_fails"
          wanted = ARGV[2]
          row = prs.find { |pr| pr["url"].to_s == wanted }
          abort("gh: no pull request found for \#{wanted}") if row.nil?
          row = row.merge("headRefOid" => head_oid(row["headRefName"])) if row["headRefOid"].to_s == "live"
          puts JSON.generate({ "url" => row["url"], "state" => row["state"],
                               "headRefName" => row["headRefName"],
                               "baseRefName" => row.fetch("baseRefName", "main"),
                               "isDraft" => row.fetch("isDraft", true),
                               "isCrossRepository" => row.fetch("isCrossRepository", false) })
          exit 0
        when "create"
          abort("gh: pull request creation failed (simulated)") if MODE == "create_fails"
          head = flag("--head")
          repo = flag("--repo")
          abort("gh: pull request creation failed (simulated)") if FAIL_CREATE_FOR == repo
          # A second create for the same branch would be a duplicate; the runner is
          # expected to reuse instead, so record it and let the test assert on it.
          # `isDraft` mirrors what real `gh pr list --json isDraft` returns, and it is a FACT
          # about the invocation rather than a constant: MVP-0027 refuses to report a pull
          # request as this run's specification unless GitHub says it is a draft, so a fake that
          # always answered `true` would make that check untestable.
          created = URLS.fetch(repo.to_s, URL)
          File.write(STATE, JSON.generate(prs + [ { "url" => created, "state" => "OPEN",
                                                    "headRefName" => head, "repo" => repo,
                                                    "isDraft" => ARGV.include?("--draft"),
                                                    "headRefOid" => head_oid(head, repo) } ]))
          # "create_silent": creation succeeds but prints no URL, so the runner has to
          # fall back to a lookup. Real gh can be quiet under some output settings.
          puts created unless MODE == "create_silent"
          exit 0
        end
      end
      abort("gh: unexpected invocation \#{ARGV.join(' ')}")
    RUBY
  end

  def pr_lists(log) = invocations(log).count { |line| line.start_with?("pr list") }
  def pr_views(log) = invocations(log).count { |line| line.start_with?("pr view") }

  def invocations(log) = File.exist?(log) ? File.read(log).lines.map(&:strip).reject(&:empty?) : []
  def pr_creates(log) = invocations(log).count { |line| line.start_with?("pr create") }

  def remote_branches(bare)
    out, status = Open3.capture2e("git", "-C", bare, "for-each-ref", "--format=%(refname:short) %(objectname)", "refs/heads")
    raise out unless status.success?

    out.lines.map(&:strip).reject(&:empty?).to_h { |line| line.split(" ", 2) }
  end

  def git(root, *args)
    out, status = Open3.capture2e("git", "-C", root, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end
end
