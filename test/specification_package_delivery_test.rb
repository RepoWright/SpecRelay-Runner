# frozen_string_literal: true

require_relative "test_helper"

# MVP-0034 contract 4 and S22/S23: the pinned package reaches the Executor as files it can read,
# and one altered document stops the attempt before a provider starts.
class SpecificationPackageDeliveryTest < Minitest::Test
  TASK = "DEMO-0001"

  def setup
    @staging = Dir.mktmpdir("package-delivery-")
    # A real contained repository holding the approved package, because delivery is not allowed to
    # be the only place the package exists. The document checks below still run first and still
    # refuse first; this is what they refuse INSTEAD of.
    @root, = DemoWorkspace.build
  end

  def teardown
    [ @staging, @root ].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  # The approved block, pinned to what this fixture actually committed.
  def approved(**overrides) = specification_package_block(TASK, root: @root, **overrides)

  def deliver(block)
    SpecrelayRunner::SpecificationPackage.call(payload: { "specification_package" => block },
                                               staging_dir: @staging, task_root: @root)
  end

  def test_writes_every_document_read_only_under_the_staging_root
    result = deliver(approved)

    assert result.ok?, result.failure
    assert_equal %w[spec.md analysis/input-evidence.md analysis/business.md analysis/technical.md
                    generation-manifest.json].sort,
                 result.paths.sort
    result.paths.each do |path|
      absolute = File.join(result.root, path)

      assert File.file?(absolute), "#{path} was not written"
      # Read-only on disk, so an executor cannot edit its own authority by accident.
      assert_equal "100444", format("%o", File.stat(absolute).mode)
    end
    assert_equal "# Approved spec for DEMO-0001\nImplement it.\n",
                 File.read(File.join(result.root, "spec.md"))
  end

  # S23 — ONE changed byte, with the length left intact so the digest is the only check that can
  # catch it. A tamper that also changed the size would prove the cheaper comparison instead.
  def test_refuses_a_document_whose_bytes_do_not_reproduce_the_pinned_digest
    block = approved
    block["documents"][2]["content"] = "# Business analysix\n"

    result = deliver(block)

    refute result.ok?
    assert_includes result.failure, "analysis/business.md"
    assert_includes result.failure, "digest"
    refute File.exist?(File.join(@staging, SpecrelayRunner::SpecificationPackage::DIRECTORY, "spec.md")),
           "nothing may be written once the package is refused"
  end

  def test_refuses_a_document_whose_byte_size_does_not_match
    block = approved
    block["documents"][0]["byte_size"] = 99_999

    result = deliver(block)

    refute result.ok?
    assert_includes result.failure, "byte size"
  end

  def test_refuses_a_duplicated_document
    block = approved
    block["documents"] << block["documents"].first.dup

    result = deliver(block)

    refute result.ok?
    assert_includes result.failure, "appears twice"
  end

  # S11 — a path that escapes the package folder never becomes a filesystem write.
  def test_refuses_a_traversing_or_absolute_path
    [ "../escape.md", "/etc/passwd", "analysis/../../escape.md" ].each do |path|
      block = approved
      block["documents"][0]["path"] = path

      result = deliver(block)

      refute result.ok?, "#{path} was accepted"
      assert_includes result.failure, "safe package-relative path"
    end
    refute File.directory?(File.join(@staging, SpecrelayRunner::SpecificationPackage::DIRECTORY))
  end

  def test_refuses_a_document_larger_than_the_bound
    oversized = "x" * (SpecrelayRunner::SpecificationPackage::MAX_FILE_BYTES + 1)
    block = approved(
                                         documents: [ [ "specification", "spec.md", oversized ] ])

    result = deliver(block)

    refute result.ok?
    assert_includes result.failure, "larger than this runner will deliver"
  end

  # An assignment with no documents is a contract violation, not an empty package: Platform
  # authorizes execution only after pinning one.
  def test_refuses_an_assignment_that_carries_no_documents
    result = deliver(approved.merge("documents" => []))

    refute result.ok?
    assert_includes result.failure, "no specification documents"
  end
end

# The same two properties over the REAL claim → execute → report path, because the unit test above
# cannot show that the delivery happens before the provider starts (MVP-0034 S22, S23, and the
# deterministic half of S28).
class SpecificationPackageDeliveryFlowTest < Minitest::Test
  # The one directory on the child PATH that provides the approved fixture name.
  def fixture_dir = @fixture_dir ||= fixture_bin
  TASK = "DEMO-0001"

  def setup
    @root, @executor = DemoWorkspace.build
    use_fixture(fixture_dir, @executor)
    @payload = claim_payload_for(task_id: TASK, root: @root)
    @platform = nil
  end

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def start
    @platform = FakePlatform.new(claim_payload: @payload).start
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{@platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: test-runner
        display_name: Test Runner
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{@root}
    YAML
    @io = StringIO.new
    SpecrelayRunner::CLI.run(%W[claim-once --config #{path}], out: @io, err: @io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => "#{fixture_dir}:#{ENV['PATH']}" })
  end

  # S22 / S28 — every document, not only `spec.md`, is readable by the executor while it runs.
  def test_the_executor_can_read_every_pinned_document_while_it_runs
    exit_code = start

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
    stdout_log = uploaded("evidence/stdout.log")
    %w[spec.md analysis/input-evidence.md analysis/business.md analysis/technical.md
       generation-manifest.json].each do |document|
      assert_includes stdout_log, "package document readable: #{document}"
    end
    refute_includes stdout_log, "MISSING"
  end

  # S23 — one altered document, and the provider is never started. The alteration keeps the
  # document's length, so only the digest comparison can catch it.
  def test_an_altered_document_refuses_before_the_executor_runs
    @payload["specification_package"]["documents"][0]["content"] =
      "# Approved spec for #{TASK}\nImplement it!\n"

    exit_code = start

    assert_equal SpecrelayRunner::CLI::RUN_FAILED, exit_code, @io.string
    # The worktree was untouched: nothing implemented anything from an unverified package. Read
    # from the change set measured into the report, because the recorded failure then releases
    # the environment.
    refute_includes uploaded("evidence/diff.txt"), "Hello SpecRelay Demo"

    terminal = @platform.last_terminal_result
    assert_equal "failed", terminal["outcome"]
    assert_equal SpecrelayRunner::SpecificationPackage::REFUSED,
                 terminal.dig("core", "error_classification")
    assert_nil terminal.dig("core", "exit_code"), "no provider ran, so there is no exit code"
    assert(terminal.fetch("repositories").none? { |repo| repo["pull_request_url"] })
  end

  def uploaded(relative)
    entry = @platform.last_report[:body].dig("report", "files").find { |f| f["relative_path"] == relative }
    Base64.strict_decode64(entry.fetch("content_base64"))
  end
end
