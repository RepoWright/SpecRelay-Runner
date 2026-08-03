# frozen_string_literal: true

require_relative "test_helper"

# MVP-0026 CR-001 must-fix 1 — the generated package must RENDER.
#
# Round 001 shipped a `spec.md` in which six of the nine required sections were inside an
# unterminated fenced code block. Every existing assertion passed: the sections were present in
# the text, the digests described the bytes on disk, and `DocumentSet.validate!` returned
# PASSED. Nothing in the suite asked the one question a reader would — does this render?
#
# So these tests assert a RENDERING property rather than a text property, and they do it with
# an INDEPENDENT fence scanner (see #unterminated_fence_at below) rather than with the module
# that produces the documents. Verifying `Markdown` with `Markdown` would restate the
# implementation; the point here is to check it from the outside, the way a Markdown renderer
# does.
class SpecificationMarkdownTest < Minitest::Test
  ISSUE = "SR-700"
  PACKAGE = "specs/SR-700-add-an-export-button"

  REQUIRED_SPEC_SECTIONS = [
    "Problem", "Outcome", "Input summary", "Proposed behavior", "Non-goals",
    "Acceptance criteria", "Validation expectations",
    "Dependencies and assumptions", "Analysis"
  ].freeze

  def teardown
    @platform&.stop
    FileUtils.remove_entry(@temp) if @temp && File.directory?(@temp)
  end

  # ----------------------------------------------------- the generated package, rendered

  # AC 1: the ordinary case, over a bundle produced by the REAL Jira::SpecCreation::Markdown.
  def test_the_generated_specification_renders_with_balanced_fences_and_visible_headings
    generate(variant: :plain)
    spec = read_package("spec.md")

    assert_nil unterminated_fence_at(spec),
               "spec.md leaves a fenced block open at line #{unterminated_fence_at(spec)}"
    assert_equal REQUIRED_SPEC_SECTIONS, headings_outside_fences(spec) & REQUIRED_SPEC_SECTIONS,
                 "sections swallowed by a code block: " \
                 "#{REQUIRED_SPEC_SECTIONS - headings_outside_fences(spec)}"
  end

  # AC 2: the same, over a description that carries its OWN fenced block — which the real
  # renderer wraps in a FOUR-backtick fence. This is the case that broke round 001, and a
  # three-backtick composer fence cannot survive it.
  def test_a_bundle_whose_description_contains_a_fenced_block_still_renders
    generate(variant: :backticked)
    spec = read_package("spec.md")

    assert_includes spec, "````", "the real renderer's four-backtick fence must reach the document"
    assert_nil unterminated_fence_at(spec)
    assert_empty REQUIRED_SPEC_SECTIONS - headings_outside_fences(spec)
  end

  def test_every_generated_document_renders_with_balanced_fences
    generate(variant: :backticked)

    %w[spec.md analysis/business.md analysis/technical.md].each do |name|
      assert_nil unterminated_fence_at(read_package(name)), "#{name} leaves a fenced block open"
    end
  end

  # AC 5: `graph-check` prints one fact per line. Unfenced, they collapsed into a single
  # run-together paragraph — the freshness verdict, which is the whole point of quoting it,
  # became invisible.
  def test_the_graph_check_evidence_is_fenced
    generate(variant: :plain)
    technical = read_package("analysis/technical.md")

    block = technical[/`bin\/graph-check`:\n\n(```+text\n.*?\n```+)/m, 1]
    assert block, "the graph-check output must be inside a fenced block\n#{technical}"
    assert_includes block, "freshness:"
  end

  # ------------------------------------------------------------- DocumentSet's own gates

  # AC 3: an unterminated fence is rejected BEFORE anything is written. A provider — a language
  # model, most plausibly — can return exactly this, and the previous validator could not see it.
  def test_validate_rejects_a_document_with_an_unterminated_fence
    error = assert_raises(SpecrelayRunner::Specification::DocumentSet::Invalid) do
      SpecrelayRunner::Specification::DocumentSet.validate!(document_set(spec: broken_fence_spec))
    end

    assert_includes error.message, "spec.md"
    assert_includes error.message, "never closed"
  end

  # AC 4: a heading that exists only inside a code block is not a heading. This is the exact
  # shape of the shipped defect — the sections were "there", in the sense that the raw text
  # contained the characters.
  def test_validate_rejects_a_required_heading_that_appears_only_inside_a_code_block
    error = assert_raises(SpecrelayRunner::Specification::DocumentSet::Invalid) do
      SpecrelayRunner::Specification::DocumentSet.validate!(document_set(spec: fenced_headings_spec))
    end

    assert_includes error.message, "## #{spec_sections[6]}", "the FIRST hidden section must be named"
    assert_includes error.message, "missing"
  end

  def test_validate_accepts_a_document_whose_fenced_block_contains_heading_like_lines
    documents = document_set(spec: spec_with_fenced_bundle)

    assert SpecrelayRunner::Specification::DocumentSet.validate!(documents)
  end

  # ------------------------------------------------------------------------- helpers

  def generate(variant:)
    @source, @specs, @temp = SpecificationWorkspace.build
    payload = spec_creation_payload_for(issue_key: ISSUE,
                                        content: spec_bundle_markdown(ISSUE, variant: variant))
    @platform = FakePlatform.new(claim_payload: payload).start
    @io = StringIO.new
    config = write_config
    exit_code = SpecrelayRunner::CLI.run(
      %W[claim-once --config #{config.source_path}], out: @io, err: @io,
      env: { "TEST_TOKEN" => FakePlatform::EXPECTED_TOKEN, "PATH" => ENV["PATH"] }
    )
    assert_equal SpecrelayRunner::CLI::SUCCESS, exit_code, @io.string
  end

  def read_package(name) = File.read(File.join(@specs, PACKAGE, name))

  def write_config
    path = File.join(Dir.mktmpdir("cfg"), "runner.yml")
    File.write(path, <<~YAML)
      platform:
        base_url: #{@platform.base_url}
        token_env: TEST_TOKEN
      runner:
        id: test-runner
        display_name: Test Runner
        specification:
          provider:
            kind: composed
          repository_roots:
            "SpecRelay/SpecRelay-Specs": #{@specs}
          context_plus:
            available: true
      workspace_roots:
        tiny-demo-workspace: #{@source}
    YAML
    SpecrelayRunner::Config.load(path)
  end

  # An INDEPENDENT CommonMark-ish fence scanner. Deliberately not the production one: a test
  # that asserts a renderability property with the code that produces the document would have
  # agreed with the defect.
  #
  # Returns the 1-based line number of an opening fence with no closing fence, or nil.
  def unterminated_fence_at(content)
    open = nil
    open_at = nil
    content.lines.each_with_index do |line, index|
      match = /\A {0,3}(`{3,}|~{3,})[ \t]*(.*?)[ \t]*\z/.match(line.chomp)
      marker = match && match[1]
      info = match ? match[2].to_s : ""
      if open.nil?
        next if marker.nil? || (marker.start_with?("`") && info.include?("`"))

        open = marker
        open_at = index + 1
      elsif marker && marker[0] == open[0] && marker.length >= open.length && info.empty?
        open = open_at = nil
      end
    end
    open_at
  end

  # The `##` headings a renderer would show, in document order.
  def headings_outside_fences(content)
    inside = false
    open = nil
    content.lines.filter_map do |line|
      match = /\A {0,3}(`{3,}|~{3,})[ \t]*(.*?)[ \t]*\z/.match(line.chomp)
      marker = match && match[1]
      if inside
        inside = false if marker && marker[0] == open[0] && marker.length >= open.length &&
                          match[2].to_s.empty?
        next
      end
      if marker && !(marker.start_with?("`") && match[2].to_s.include?("`"))
        open = marker
        inside = true
        next
      end
      line.chomp[/\A##[ \t]+(.+?)[ \t]*\z/, 1]
    end
  end

  # ------------------------------------------------------------------ document fixtures

  BODY = "Enough prose under this heading to clear the minimum body length that DocumentSet " \
         "enforces for every required section of a generated document.\n"

  def document_set(spec:)
    {
      "spec.md" => spec,
      "analysis/input-evidence.md" => "# Input evidence\n\nNo supporting input beyond the Jira ticket " \
                                       "was recorded.\n",
      "analysis/business.md" => document(required_sections("analysis/business.md")),
      "analysis/technical.md" => document(required_sections("analysis/technical.md"))
    }
  end

  def required_sections(name)
    SpecrelayRunner::Specification::DocumentSet::REQUIRED_SECTIONS.fetch(name)
  end

  def document(sections, title: "# Generated document\n\n")
    title + sections.map { |section| "## #{section}\n\n#{BODY}\n" }.join
  end

  def spec_sections = required_sections("spec.md")

  def broken_fence_spec = "#{document(spec_sections)}\n```text\nan opening fence with no partner\n"

  # Every required heading present in the raw text, but the last three only inside a code
  # block. Exactly the shape round 001 shipped.
  def fenced_headings_spec
    visible = spec_sections.first(6)
    hidden = spec_sections.drop(6)
    "#{document(visible)}\n```markdown\n" \
      "#{hidden.map { |section| "## #{section}\n\n#{BODY}" }.join("\n")}\n```\n"
  end

  # The legitimate case the fence-aware scan must NOT reject: a real section body that embeds
  # the input bundle, headings and all, inside a properly closed fence.
  def spec_with_fenced_bundle
    bundle = spec_bundle_markdown(ISSUE)
    sections = spec_sections.map do |section|
      body = section == "Input summary" ? "#{BODY}\n````markdown\n#{bundle}\n````\n" : BODY
      "## #{section}\n\n#{body}\n"
    end
    "# Generated document\n\n#{sections.join}"
  end
end
