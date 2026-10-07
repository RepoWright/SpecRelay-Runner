# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

# Scenario evidence: the executor's own record of the acceptance scenarios it checked, written into
# the attempt's staging directory and declared in a local index. Only declared, safe files reach the
# uploaded report, through the manifest collections Platform already imports; anything else becomes
# a stated limitation in the round README rather than a silent omission.
class ScenarioEvidenceTest < Minitest::Test
  TASK = "DEMO-0001"
  PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
  SCENARIO = <<~MD
    # Sign-in validation

    - Criterion: AC2 — an empty password is refused.
    - Target: http://127.0.0.1:3000/session/new at 1440x900
    - Result: PASS

    1. Submitted the form with an empty password. Observed "Password can't be blank".
  MD

  def setup
    @dir = Dir.mktmpdir("scenario-evidence-")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    FileUtils.remove_entry(@outside) if @outside && File.exist?(@outside)
  end

  def test_a_declared_scenario_and_its_screenshot_reach_the_report_with_their_exact_metadata
    write("scenarios/01-sign-in.md", SCENARIO)
    write("screenshots/01-sign-in-error.png", PNG)
    write_index(evidence: [ { "path" => "scenarios/01-sign-in.md", "description" => "Sign-in validation" } ],
                screenshots: [ shot("screenshots/01-sign-in-error.png") ])

    report = bundle

    assert_equal SCENARIO.b, uploaded(report)["scenarios/01-sign-in.md"]
    assert_equal PNG, uploaded(report)["screenshots/01-sign-in-error.png"]
    assert_includes manifest(report)["evidence_files"],
                    { "path" => "scenarios/01-sign-in.md", "kind" => "markdown", "description" => "Sign-in validation" }
    assert_equal [ shot("screenshots/01-sign-in-error.png") ], manifest(report)["screenshots"]
    assert_includes readme(report), "- Scenario evidence: 1 scenario(s), 1 screenshot(s)"
    refute_includes readme(report), "limitation"
    refute uploaded(report).key?("index.json"), "the local index is not evidence and is never uploaded"
  end

  def test_a_scenario_without_ui_uploads_no_screenshot
    write("scenarios/01-import.md", "# Import\n\n- Result: PASS\n- Browser check: NOT_APPLICABLE (no UI change)\n")
    write_index(evidence: [ { "path" => "scenarios/01-import.md" } ])

    report = bundle

    assert_includes uploaded(report)["scenarios/01-import.md"], "Browser check: NOT_APPLICABLE"
    assert_empty manifest(report)["screenshots"]
    assert_includes manifest(report)["evidence_files"], { "path" => "scenarios/01-import.md", "kind" => "markdown" }
    assert_includes readme(report), "- Scenario evidence: 1 scenario(s), 0 screenshot(s)"
  end

  # Each refusal names the index entry by position, never by its declared value: a declaration an
  # executor got wrong is exactly where a private path or a token would appear.
  def test_unsafe_or_unprovable_declarations_are_refused_and_stated
    @outside = Dir.mktmpdir("outside-")
    File.write(File.join(@outside, "secret.md"), "outside the staging directory")
    write("scenarios/01-kept.md", SCENARIO)
    FileUtils.mkdir_p(File.join(@dir, "scenarios"))
    File.symlink(File.join(@outside, "secret.md"), File.join(@dir, "scenarios", "02-link.md"))
    write("scenarios/03-page.html", "<p>not markdown</p>")
    write("screenshots/fake.png", "plain text pretending to be an image")
    write("screenshots/orphan.png", PNG)
    write_index(
      evidence: [ { "path" => "scenarios/01-kept.md" }, { "path" => "../#{File.basename(@outside)}/secret.md" },
                  { "path" => "scenarios/02-link.md" }, { "path" => "scenarios/03-page.html" },
                  { "path" => "scenarios/04-missing.md" }, { "path" => "/etc/hosts" } ],
      screenshots: [ shot("screenshots/fake.png", scenario: "01-kept"), shot("screenshots/orphan.png", scenario: "09-none"),
                     shot("screenshots/absent.png", scenario: "01-kept"),
                     { "path" => "screenshots/orphan.png", "scenario" => "01-kept" } ]
    )

    report = bundle

    scenario_files = uploaded(report).keys.grep(%r{\A(scenarios|screenshots)/})
    assert_equal [ "scenarios/01-kept.md" ], scenario_files
    assert_empty manifest(report)["screenshots"]
    refute_includes uploaded(report).values.join, "outside the staging directory"
    text = readme(report)
    assert_includes text, "- Scenario evidence: 1 scenario(s), 0 screenshot(s)"
    (1..5).each { |index| assert_match(/Scenario evidence limitation: evidence_files\[#{index}\] /, text) }
    (0..3).each { |index| assert_match(/Scenario evidence limitation: screenshots\[#{index}\] /, text) }
    refute_includes text, @outside
    refute_includes text, "/etc/hosts"
  end

  def test_secret_like_text_in_scenario_evidence_is_redacted_before_upload
    write("scenarios/01-token.md", "Signed in with api_key=live-value-0123456789 and sk-live-DO-NOT-LEAK-0123456789\n")
    write_index(evidence: [ { "path" => "scenarios/01-token.md", "description" => "token: abc123secret" } ])

    report = bundle
    scenario = uploaded(report)["scenarios/01-token.md"]

    refute_includes scenario, "live-value-0123456789"
    refute_includes scenario, "sk-live-DO-NOT-LEAK"
    assert_includes scenario, SpecrelayRunner::Redaction::REDACTION
    refute_includes uploaded(report)["manifest.yml"], "abc123secret"
  end

  def test_a_scenario_that_is_not_utf8_text_is_refused_without_breaking_the_report
    write("scenarios/01-binary.md", "\xFF\xFE\x00broken".b)
    write_index(evidence: [ { "path" => "scenarios/01-binary.md" } ])

    report = bundle

    refute uploaded(report).key?("scenarios/01-binary.md")
    assert_match(/Scenario evidence limitation: evidence_files\[0\] /, readme(report))
  end

  def test_a_missing_index_is_a_stated_limitation_rather_than_silence
    write("scenarios/01-sign-in.md", SCENARIO)

    report = bundle

    refute uploaded(report).key?("scenarios/01-sign-in.md"), "an undeclared file is never collected"
    assert_includes readme(report), "- Scenario evidence limitation: the executor wrote no index.json"
  end

  def test_a_malformed_index_collects_nothing_and_says_why
    write("scenarios/01-sign-in.md", SCENARIO)
    [ "{ not json", "[]", JSON.generate("evidence_files" => "scenarios/01-sign-in.md", "screenshots" => []),
      JSON.generate("evidence_files" => [], "screenshots" => [], "padding" => "x" * 40_000) ].each do |document|
      write("index.json", document)

      report = bundle

      refute uploaded(report).key?("scenarios/01-sign-in.md"), document[0, 40]
      assert_match(/Scenario evidence limitation: index\.json /, readme(report), document[0, 40])
    end
  end

  # The scenario record describes what the executor checked; the measured status remains the
  # runner's own. A PASS in prose cannot make a failed attempt a success.
  def test_scenario_prose_cannot_change_the_measured_outcome
    write("scenarios/01-sign-in.md", SCENARIO)
    write_index(evidence: [ { "path" => "scenarios/01-sign-in.md" } ])

    report = bundle(status: SpecrelayRunner::ReportBundle::STATUS_FAILED)

    assert_equal "failed", manifest(report)["execution_status"]
    assert_equal false, manifest(report)["final_jira_update_ready"]
    assert_includes readme(report), "Execution status: **failed**"
    assert_includes uploaded(report)["scenarios/01-sign-in.md"], "Result: PASS"
  end

  # A report built before any executor ran (a refused package, for example) has no scenario
  # directory to read, so it says nothing about scenario evidence at all.
  def test_a_report_with_no_scenario_directory_is_unchanged
    report = bundle(dir: nil)

    refute_includes readme(report), "Scenario evidence"
    assert_empty manifest(report)["screenshots"]
    assert_empty uploaded(report).keys.grep(%r{\A(scenarios|screenshots)/})
  end

  # ---- through the real runner ----------------------------------------------------------------

  def test_an_executor_authored_scenario_and_screenshot_reach_the_uploaded_report
    root, = DemoWorkspace.build
    prompt_path = File.join(@dir, "captured-prompt.md")
    executor = write_scenario_executor(root, prompt_path)
    platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK, root: root)).start
    io = StringIO.new

    exit_code = SpecrelayRunner::CLI.run(%W[claim-once --config #{runner_config(platform, root)}], out: io, err: io,
                                         env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN,
                                                "PATH" => fixture_path(executor) })

    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, io.string
    files = platform.last_report[:body].dig("report", "files")
                    .to_h { |file| [ file["relative_path"], Base64.strict_decode64(file["content_base64"]) ] }
    manifest = YAML.safe_load(files.fetch("manifest.yml"))
    assert_includes files.fetch("scenarios/01-heading.md"), "Result: PASS"
    # The placement line reaches Platform exactly as written; Platform alone decides where it renders.
    assert_includes files.fetch("scenarios/01-heading.md"), "1. Opened the page.\n![Success](screenshots/01-heading-success.png)\n"
    assert_equal PNG, files.fetch("screenshots/01-heading-success.png")
    assert_equal [ { "path" => "screenshots/01-heading-success.png", "viewport" => "1440x900",
                     "scenario" => "01-heading", "result" => "Success" } ], manifest["screenshots"]
    assert_includes manifest["evidence_files"],
                    { "path" => "scenarios/01-heading.md", "kind" => "markdown", "description" => "Heading text" }
    # The evidence lived outside the task workspace, so it is neither a changed file nor in the diff.
    assert_equal [ "demo-app/index.html" ], manifest.dig("git", "changed_files")
    refute_includes files.fetch("evidence/diff.txt"), "scenario"
  ensure
    platform&.stop
    FileUtils.remove_entry(root) if root && File.directory?(root)
  end

  # A screenshot is placed by a line of its own directly after the step it shows; the instruction
  # still forbids an invented screenshot or pass, and secrets.
  def test_the_executor_is_told_to_place_each_screenshot_after_the_step_it_shows
    root, = DemoWorkspace.build
    prompt_path = File.join(@dir, "captured-prompt.md")
    executor = write_scenario_executor(root, prompt_path)
    platform = FakePlatform.new(claim_payload: claim_payload_for(task_id: TASK, root: root)).start
    io = StringIO.new

    SpecrelayRunner::CLI.run(%W[claim-once --config #{runner_config(platform, root)}], out: io, err: io,
                             env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => fixture_path(executor) })

    prompt = File.read(prompt_path).gsub(/\s+/, " ")
    assert_includes prompt, "a line containing only `![<short state>](screenshots/<name>.png)` directly after the " \
                            "action or observation it shows"
    refute_includes prompt, "Do not link images"
    assert_includes prompt, "Never invent a screenshot or a pass."
    assert_includes prompt, "Never include credentials, tokens or private reasoning."
  ensure
    platform&.stop
    FileUtils.remove_entry(root) if root && File.directory?(root)
  end

  private

  def write(relative, bytes)
    path = File.join(@dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
  end

  def write_index(evidence: [], screenshots: [])
    write("index.json", JSON.generate("evidence_files" => evidence, "screenshots" => screenshots))
  end

  def shot(path, scenario: "01-sign-in")
    { "path" => path, "viewport" => "1440x900", "scenario" => scenario, "result" => "Validation error" }
  end

  def bundle(dir: @dir, status: SpecrelayRunner::ReportBundle::STATUS_SUCCEEDED)
    failed = status == SpecrelayRunner::ReportBundle::STATUS_FAILED
    SpecrelayRunner::ReportBundle.build(
      payload: claim_payload_for(task_id: TASK), status: status,
      executor: SpecrelayRunner::Executor::Result.new(exit_code: 0, stdout: "", stderr: "", duration_seconds: 1,
                                                      timed_out: false, argv: [ "fake" ]),
      verifications: [],
      changes: SpecrelayRunner::Workspace::Changes.new(changed_files: [], diff: "", head_commit: "b" * 40),
      base_commit: "a" * 40, worktree_path: "/work/#{TASK}", failure_details: ("verification failed" if failed),
      scenario_evidence_dir: dir
    )
  end

  def uploaded(report)
    report.fetch("files").to_h { |file| [ file["relative_path"], Base64.strict_decode64(file["content_base64"]) ] }
  end

  def manifest(report) = YAML.safe_load(uploaded(report).fetch("manifest.yml"))
  def readme(report) = uploaded(report).fetch("README.md")

  def runner_config(platform, root)
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: test-runner
        display_name: Test Runner
        claim_policy:
          mode: all_eligible
      workspace_roots:
        tiny-demo-workspace: #{root}
    YAML
    path
  end

  # A fake executor that does the demo edit, then records one checked scenario and one screenshot
  # exactly where the prompt names the scenario evidence directory, as a real executor must.
  def write_scenario_executor(root, prompt_path)
    path = File.join(root, "bin", "scenario-executor")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      require "base64"
      require "fileutils"
      require "json"
      prompt = File.read(ARGV.last.to_s)
      File.write(#{prompt_path.inspect}, prompt)
      dir = prompt[%r{`([^`]*/scenario-evidence)`}, 1]
      abort "the prompt named no scenario evidence directory" if dir.nil?
      file = "demo-app/index.html"
      content = File.read(file)
      changed = content.include?("Hello Demo")
      File.write(file, content.gsub("Hello Demo", "Hello SpecRelay Demo")) if changed
      FileUtils.mkdir_p(File.join(dir, "scenarios"))
      FileUtils.mkdir_p(File.join(dir, "screenshots"))
      File.write(File.join(dir, "scenarios", "01-heading.md"), "# Heading\\n\\n- Result: PASS\\n\\n1. Opened the page.\\n![Success](screenshots/01-heading-success.png)\\n")
      File.binwrite(File.join(dir, "screenshots", "01-heading-success.png"), Base64.decode64(#{Base64.strict_encode64(PNG).inspect}))
      File.write(File.join(dir, "index.json"), JSON.generate(
        "evidence_files" => [ { "path" => "scenarios/01-heading.md", "description" => "Heading text" } ],
        "screenshots" => [ { "path" => "screenshots/01-heading-success.png", "viewport" => "1440x900",
                             "scenario" => "01-heading", "result" => "Success" } ]
      ))
      #{DemoWorkspace.selection_snippet(changed: 'changed')}
      exit 0
    RUBY
    FileUtils.chmod(0o755, path)
    path
  end
end
