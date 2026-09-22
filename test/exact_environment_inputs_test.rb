# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# The approved specification and the accepted code have to be visible in the prepared environment
# TOGETHER, and they have to agree.
#
# Two failures this closes. The delivered copy of the package used to be the only correct one: a
# provider could read six correct documents in staging while the checkout beside it held an older
# round's specification, and nothing in the run disagreed. And when one repository carries both the
# specification and the accepted code, something has to decide which commit the environment opens
# at — there is no commit that is "both", only commits that already satisfy both.
#
# Real git repositories throughout, because every claim here is about history: what a commit
# contains, what is an ancestor of what, and which paths differ between two of them. A double that
# answered those questions would be testing itself.
class ExactEnvironmentInputsTest < Minitest::Test
  BRANCH = "DEMO-0007"
  PACKAGE = "specs/DEMO-0007"
  SPEC_DOCUMENTS = [
    [ "specification", "spec.md", "# Approved\nDo the thing.\n" ],
    [ "generation_manifest", "generation-manifest.json", "{\"round\":1}\n" ]
  ].freeze

  def setup
    @task_root = Dir.mktmpdir("exact-inputs-")
    @repo = File.join(@task_root, "product")
    FileUtils.mkdir_p(@repo)
    git("init", "-b", "main")
    git("config", "user.email", "fixture@example.test")
    git("config", "user.name", "Fixture")
    git("config", "commit.gpgsign", "false")
    git("remote", "add", "origin", "git@github.com:SpecRelay/product.git")
    write("app/main.rb", "puts :one\n")
    commit("base")
    @base = head
  end

  def teardown
    FileUtils.remove_entry(@task_root) if File.directory?(@task_root)
  end

  # --- fixture ---------------------------------------------------------------

  def git(*args, dir: @repo)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  def head = git("rev-parse", "HEAD").strip
  def write(path, content)
    absolute = File.join(@repo, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.write(absolute, content)
  end

  def commit(message)
    git("add", "-A")
    git("commit", "--quiet", "-m", message)
    head
  end

  # The approved package, committed where the assignment says it lives.
  def commit_package(message: "approved package")
    SPEC_DOCUMENTS.each { |_role, path, content| write(File.join(PACKAGE, path), content) }
    commit(message)
  end

  def specification(head_sha, package_path: PACKAGE)
    { repository: "SpecRelay/product", path: @repo, head: head_sha, package_path: package_path }
  end

  # An accepted target whose pull request is open at exactly the head under test. Only the GitHub
  # answer is stubbed; the repository, its history and every ancestry question are real.
  def accepted(head_sha)
    block = {
      "package_id" => "art_previous123", "checksum" => "c" * 64, "source_run_id" => "run_previous",
      "approved_specification" => { "reference" => "https://github.com/SpecRelay/product/pull/2",
                                    "digest" => "d" * 64 },
      "implementation_pull_requests" => [
        { "repository" => "SpecRelay/product", "clone_url" => "https://github.com/SpecRelay/product",
          "branch" => BRANCH, "head_commit" => head_sha,
          "pull_request_url" => "https://github.com/SpecRelay/product/pull/3" }
      ]
    }
    claim = SpecrelayRunner::PreviousAcceptedPackage.read(
      { "previous_accepted_package" => block, "run" => { "canonical_branch" => BRANCH } },
      env: { "PATH" => ENV["PATH"].to_s }, github: OpenPullRequest.new(head_sha, BRANCH)
    )
    raise claim.reason unless claim.ok?

    claim.package
  end

  def specification_only
    SpecrelayRunner::PreviousAcceptedPackage.for_specification(
      BRANCH, env: { "PATH" => ENV["PATH"].to_s }
    )
  end

  OpenPullRequest = Struct.new(:head, :branch) do
    def pull_request(root:, slug:, url:, env:)
      { "state" => "OPEN", "headRefName" => branch, "headRefOid" => head }
    end
  end

  def placed_head = git("rev-parse", "HEAD").strip
  def placed_branch = git("symbolic-ref", "--quiet", "--short", "HEAD").strip

  # --- the compatibility matrix ----------------------------------------------

  def test_without_accepted_code_the_specification_head_is_placed
    spec_head = commit_package

    result = specification_only.materialize(task_root: @task_root,
                                            specification: specification(spec_head))

    assert result.ok?, result.reason
    assert_equal spec_head, placed_head
    assert_equal BRANCH, placed_branch
    assert_path_exists File.join(@repo, PACKAGE, "spec.md")
  end

  def test_the_accepted_head_is_kept_when_it_already_carries_the_package
    spec_head = commit_package
    write("app/main.rb", "puts :two\n")
    accepted_head = commit("accepted implementation on top of the package")

    result = accepted(accepted_head).materialize(task_root: @task_root,
                                                 specification: specification(spec_head))

    assert result.ok?, result.reason
    assert_equal accepted_head, placed_head, "the accepted work must not be rewound"
    assert_equal "puts :two\n", File.read(File.join(@repo, "app/main.rb"))
    assert_path_exists File.join(@repo, PACKAGE, "spec.md")
  end

  def test_the_specification_head_is_taken_when_it_only_adds_the_package
    write("app/main.rb", "puts :two\n")
    accepted_head = commit("accepted implementation")
    spec_head = commit_package

    result = accepted(accepted_head).materialize(task_root: @task_root,
                                                 specification: specification(spec_head))

    assert result.ok?, result.reason
    assert_equal spec_head, placed_head
    assert_equal "puts :two\n", File.read(File.join(@repo, "app/main.rb")),
                 "taking the specification head must not lose the accepted code"
  end

  def test_one_head_satisfying_both_needs_no_choice
    both = commit_package

    result = accepted(both).materialize(task_root: @task_root, specification: specification(both))

    assert result.ok?, result.reason
    assert_equal both, placed_head
  end

  def test_a_specification_head_that_also_changes_code_refuses_before_placement
    write("app/main.rb", "puts :two\n")
    accepted_head = commit("accepted implementation")
    write("app/main.rb", "puts :three\n")
    spec_head = commit_package(message: "package plus an unrelated code change")
    before = placed_head

    result = accepted(accepted_head).materialize(task_root: @task_root,
                                                 specification: specification(spec_head))

    refute result.ok?, "a head carrying unreviewed code changes is not a compatible input"
    assert_match(/no existing history carries both/, result.reason)
    assert_equal before, placed_head, "nothing may be placed once the inputs disagree"
  end

  def test_an_accepted_head_that_changed_the_package_refuses_before_placement
    spec_head = commit_package
    write(File.join(PACKAGE, "spec.md"), "# Approved\nEdited after acceptance.\n")
    accepted_head = commit("the package was edited on the accepted branch")
    before = placed_head

    result = accepted(accepted_head).materialize(task_root: @task_root,
                                                 specification: specification(spec_head))

    refute result.ok?, "the visible package must still be the approved one"
    assert_match(/no existing history carries both/, result.reason)
    assert_equal before, placed_head
  end

  def test_diverged_histories_refuse_rather_than_inventing_a_third
    spec_head = commit_package
    git("switch", "--quiet", "--create", "other", @base)
    write("app/main.rb", "puts :divergent\n")
    accepted_head = commit("a divergent accepted branch")
    git("switch", "--quiet", "--detach", spec_head)
    before = placed_head

    result = accepted(accepted_head).materialize(task_root: @task_root,
                                                 specification: specification(spec_head))

    refute result.ok?
    assert_match(/no existing history carries both/, result.reason)
    assert_equal before, placed_head
    refute_equal BRANCH, git("symbolic-ref", "--quiet", "--short", "HEAD", dir: @repo).strip rescue nil
  end

  # --- measurements that did not happen ---------------------------------------

  # The rule that keeps the accepted head asks whether the package tree is the SAME at both
  # commits. An unanswered question is not a yes: when both measurements fail, they are equally
  # absent, and reading that as equality grants the accepted head — with the wrong specification
  # visible — on the strength of two failures.
  def test_two_failed_package_measurements_are_not_a_match
    spec_head = commit_package
    write(File.join(PACKAGE, "spec.md"), "# A DIFFERENT specification\n")
    accepted_head = commit("the accepted head changed the package")
    placer = accepted(accepted_head)
    break_package_measurement(placer)

    result = placer.materialize(task_root: @task_root, specification: specification(spec_head))

    refute result.ok?, "two unanswered measurements must not read as equal package trees"
    assert_equal "# A DIFFERENT specification\n",
                 File.read(File.join(@repo, PACKAGE, "spec.md")),
                 "and nothing may be placed on the strength of them"
  end

  # The control: with the SAME injection, a repository whose package genuinely is unchanged at the
  # accepted head must still be refused rather than accepted — because the proof was not obtained.
  # Without this the test above would pass for a version that simply never keeps an accepted head.
  def test_an_unmeasurable_but_genuinely_equal_package_is_still_refused
    spec_head = commit_package
    write("app/main.rb", "puts :two\n")
    accepted_head = commit("accepted code on top of the package")
    placer = accepted(accepted_head)

    assert placer.materialize(task_root: @task_root,
                              specification: specification(spec_head)).ok?,
           "control: this case is compatible when the measurement succeeds"

    git("checkout", "--quiet", "--detach", spec_head)
    broken = accepted(accepted_head)
    break_package_measurement(broken)

    refute broken.materialize(task_root: @task_root, specification: specification(spec_head)).ok?
  end

  # Fails exactly the two package-tree reads, and nothing else, so every other question the
  # decision asks is still answered by real git.
  def break_package_measurement(placer)
    original = placer.method(:run)
    failure = Struct.new(:exit_code, :stdout, :stderr).new(1, "", "injected query error")
    placer.define_singleton_method(:run) do |path, args|
      args[0] == "rev-parse" && args.last.to_s.include?(":#{PACKAGE}") ? failure
                                                                      : original.call(path, args)
    end
  end

  # --- the specification's own repository -------------------------------------

  # The plan owner resolves WHERE the specification repository is, rather than being told. A run
  # whose environment does not contain it has nowhere to make the approved documents visible, and
  # neither a clone nor writing the files into some other repository is that place.
  def test_a_specification_repository_the_environment_does_not_hold_refuses
    spec_head = commit_package
    elsewhere = specification(spec_head).merge(repository: "SpecRelay/not-here")

    result = specification_only.materialize(task_root: @task_root, specification: elsewhere)

    refute result.ok?
    assert_match(/no repository in the prepared task workspace is/, result.reason)
  end

  def test_two_checkouts_of_the_specification_repository_refuse_rather_than_choosing
    spec_head = commit_package
    FileUtils.cp_r(@repo, File.join(@task_root, "product-again"))

    result = specification_only.materialize(task_root: @task_root,
                                            specification: specification(spec_head))

    refute result.ok?
    assert_match(/two checkouts/, result.reason)
  end

  # A pinned commit the contained checkout cannot produce, even after a fetch, is refused as such
  # — not as a divergence, which would send an operator to the wrong place.
  def test_a_specification_commit_the_checkout_cannot_obtain_refuses
    commit_package
    absent = specification("0" * 40)

    result = specification_only.materialize(task_root: @task_root, specification: absent)

    refute result.ok?
    assert_match(/does not contain the approved specification head/, result.reason)
  end
end

# The approved package must be attributable to a commit in a repository the environment actually
# holds. Every refusal below happens before a provider is launched and before anything is
# published, because a run that cannot show the specification it was given has nothing to hand a
# provider that would be honest.
class VisibleSpecificationPackageTest < Minitest::Test
  PACKAGE = "specs/DEMO-0009"
  DOCUMENTS = [
    [ "spec.md", "# Approved\nBuild it.\n" ],
    [ "analysis/technical.md", "# Technical\n" ]
  ].freeze

  def setup
    @task_root = Dir.mktmpdir("visible-package-")
    @staging = Dir.mktmpdir("visible-staging-")
    @repo = init_repository("product", "SpecRelay/product")
    @head = commit_documents(@repo)
  end

  def teardown
    [ @task_root, @staging ].each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  # --- fixture ---------------------------------------------------------------

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  def init_repository(directory, slug)
    path = File.join(@task_root, directory)
    FileUtils.mkdir_p(path)
    git(path, "init", "-b", "main")
    git(path, "config", "user.email", "fixture@example.test")
    git(path, "config", "user.name", "Fixture")
    git(path, "config", "commit.gpgsign", "false")
    git(path, "remote", "add", "origin", "git@github.com:#{slug}.git")
    path
  end

  def commit_documents(path, documents: DOCUMENTS)
    documents.each do |relative, content|
      absolute = File.join(path, PACKAGE, relative)
      FileUtils.mkdir_p(File.dirname(absolute))
      File.write(absolute, content)
    end
    git(path, "add", "-A")
    git(path, "commit", "--quiet", "-m", "approved package")
    git(path, "rev-parse", "HEAD").strip
  end

  def payload(slug: "SpecRelay/product", head: nil, package_path: PACKAGE, documents: DOCUMENTS)
    { "specification_package" => {
      "repository_slug" => slug, "head_sha" => head || @head, "package_path" => package_path,
      "documents" => documents.map do |path, content|
        { "role" => "specification", "path" => path,
          "digest" => Digest::SHA256.hexdigest(content), "byte_size" => content.bytesize,
          "content" => content }
      end
    } }
  end

  def deliver(**overrides)
    SpecrelayRunner::SpecificationPackage.call(payload: payload(**overrides),
                                               staging_dir: @staging, task_root: @task_root)
  end

  # --- the visible package ----------------------------------------------------

  def test_a_package_that_matches_the_pinned_commit_is_delivered_and_anchored
    result = deliver

    assert result.ok?, result.failure
    assert_equal "SpecRelay/product", result.anchor[:repository]
    assert_equal @head, result.anchor[:head]
    assert_equal PACKAGE, result.anchor[:package_path]
    assert_equal File.read(File.join(@repo, PACKAGE, "spec.md")),
                 File.read(File.join(result.root, "spec.md")),
                 "the delivered copy and the visible checkout must be the same bytes"
  end

  def test_a_repository_the_environment_does_not_hold_refuses_rather_than_overlaying_it
    result = deliver(slug: "SpecRelay/somewhere-else")

    refute result.ok?
    assert_match(/no repository in the prepared task workspace is/, result.failure)
    refute File.exist?(File.join(@staging, SpecrelayRunner::SpecificationPackage::DIRECTORY)),
           "nothing may be delivered for a package that could not be attributed"
  end

  def test_two_checkouts_of_the_pinned_repository_refuse_rather_than_choosing
    second = init_repository("product-again", "SpecRelay/product")
    commit_documents(second)

    result = deliver

    refute result.ok?
    assert_match(/two checkouts/, result.failure)
  end

  def test_a_commit_this_environment_cannot_obtain_refuses
    result = deliver(head: "0" * 40)

    refute result.ok?
    assert_match(/does not contain the pinned specification commit/, result.failure)
  end

  def test_a_visible_package_that_differs_from_the_delivered_bytes_refuses
    result = deliver(documents: [ [ "spec.md", "# Approved\nSomething else entirely.\n" ] ])

    refute result.ok?
    assert_match(/does not match the delivered package/, result.failure)
  end

  def test_a_document_missing_from_the_pinned_commit_refuses
    result = deliver(documents: DOCUMENTS + [ [ "absent.md", "# Never committed\n" ] ])

    refute result.ok?
    assert_match(/is missing from the pinned specification commit/, result.failure)
  end

  # A link is not the file the package pinned; following it would make "the bytes matched" a
  # statement about whatever it points at.
  # --- the package as the provider will READ it --------------------------------
  #
  # Anchoring proves the pinned COMMIT carries the approved bytes, which is a statement about an
  # object in the database. An environment this run reused, or continued from its own recorded
  # target, can stand on a later commit whose package says something else entirely while the
  # pinned object sits in its history, intact and beside the point.

  def test_the_visible_package_is_accepted_when_the_checkout_matches_the_delivery
    assert_nil SpecrelayRunner::SpecificationPackage.visible_failure(deliver)
  end

  def test_a_checkout_committed_past_the_pinned_package_refuses_without_being_reset
    result = deliver
    visible = File.join(@repo, PACKAGE, "spec.md")
    File.write(visible, "# A LATER round's specification\n")
    git(@repo, "add", "-A")
    git(@repo, "commit", "--quiet", "-m", "a later round replaced the package")

    failure = SpecrelayRunner::SpecificationPackage.visible_failure(result)

    assert_match(/is not the approved specification this run was assigned/, failure.to_s)
    assert_equal "# A LATER round's specification\n", File.read(visible),
                 "the environment's own work may not be reset to make the check pass"
  end

  def test_a_package_file_missing_from_the_checkout_refuses
    result = deliver
    FileUtils.rm(File.join(@repo, PACKAGE, "spec.md"))

    assert_match(/is not a regular file in the prepared task workspace/,
                 SpecrelayRunner::SpecificationPackage.visible_failure(result).to_s)
  end

  def test_a_package_file_replaced_by_a_link_refuses_rather_than_being_followed
    result = deliver
    visible = File.join(@repo, PACKAGE, "spec.md")
    decoy = File.join(@task_root, "decoy.md")
    File.write(decoy, File.read(visible))
    FileUtils.rm(visible)
    File.symlink(decoy, visible)

    # Matching bytes read through a link are a fact about the wrong file.
    assert_match(/is not a regular file in the prepared task workspace/,
                 SpecrelayRunner::SpecificationPackage.visible_failure(result).to_s)
  end

  def test_a_symlinked_document_refuses_rather_than_being_followed
    target = File.join(@repo, "elsewhere.md")
    File.write(target, "# Approved\nBuild it.\n")
    link = File.join(@repo, PACKAGE, "linked.md")
    File.symlink("../../elsewhere.md", link)
    git(@repo, "add", "-A")
    git(@repo, "commit", "--quiet", "-m", "a linked document")
    linked_head = git(@repo, "rev-parse", "HEAD").strip

    result = deliver(head: linked_head,
                     documents: [ [ "linked.md", "# Approved\nBuild it.\n" ] ])

    refute result.ok?
    assert_match(/is not a regular file in the pinned specification commit/, result.failure)
  end
end

# The analysis a run relies on has to describe the tree as it FINALLY stands.
#
# Inputs are placed in stages, so a graph built while the environment was still being assembled
# answers questions about code that has since been replaced — which is worse than having no graph,
# because it looks like an answer. Preparation therefore happens after every placement, rebuilds a
# stale graph, and verifies the rebuild rather than trusting its exit code.
class AnalysisPreparationTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("analysis-prep-")
    @log = File.join(@root, "calls.log")
  end

  def teardown
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  # `check` answers with whatever sequence of exit codes the test scripts, one per invocation, so
  # "stale, then fresh after a build" is expressible without a stub object standing in for the
  # wrapper contract.
  def install(check_codes:, build_code: 0)
    FileUtils.mkdir_p(File.join(@root, "bin"))
    File.write(File.join(@root, "bin", "graph-check"), <<~SH)
      #!/bin/sh
      printf 'check\\n' >> "#{@log}"
      n=$(grep -c '^check$' "#{@log}")
      set -- #{check_codes.join(' ')}
      eval "code=\\${$n:-#{check_codes.last}}"
      exit "$code"
    SH
    File.write(File.join(@root, "bin", "graph-build"), <<~SH)
      #!/bin/sh
      printf 'build\\n' >> "#{@log}"
      exit #{build_code}
    SH
    [ "graph-check", "graph-build" ].each { |n| FileUtils.chmod(0o755, File.join(@root, "bin", n)) }
    File.write(File.join(@root, "bin", "graph-query"), "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, File.join(@root, "bin", "graph-query"))
  end

  # nil, or the reason preparation could not be completed.
  def prepare
    SpecrelayRunner::Specification::SourceEvidence.prepare(
      root: @root, env: { "PATH" => ENV["PATH"].to_s }
    )
  end

  def calls = File.exist?(@log) ? File.read(@log).split("\n") : []

  def test_a_checkout_without_the_wrappers_is_not_a_failure
    assert_nil prepare
    assert_empty calls, "there is nothing to ask"
  end

  def test_a_fresh_graph_is_left_alone
    install(check_codes: [ 0 ])

    assert_nil prepare
    assert_equal %w[check], calls, "a fresh graph needs no rebuild"
  end

  def test_a_stale_graph_is_rebuilt_and_then_verified
    install(check_codes: [ 3, 0 ])

    assert_nil prepare
    assert_equal %w[check build check], calls, "the rebuild must be verified, not assumed"
  end

  def test_a_rebuild_that_leaves_the_graph_stale_refuses
    install(check_codes: [ 3, 3 ])

    assert_match(/still does not report a fresh graph/, prepare.to_s)
  end

  def test_a_failed_rebuild_stops_rather_than_reusing_earlier_evidence
    install(check_codes: [ 3 ], build_code: 1)

    assert_match(/failed for this checkout/, prepare.to_s)
  end
end
