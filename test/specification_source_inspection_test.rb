# frozen_string_literal: true

require_relative "test_helper"

# MVP-0026 CR-002 must-fix 2 — a generation that inspected no source must not report success
# silently.
#
# The failure this exists to prevent, exactly as it happened: `INTERESTING` was a
# twelve-extension allowlist that omitted `.mjs`, `.html` and `.json`, so the real Tiny Demo
# app — `server.mjs`, `index.html`, `homepage.test.mjs`, `package.json` — returned ZERO entry
# points. The manifest recorded `entry_points_inspected: 0` and `warnings: []`, the run page
# showed nothing, and the run reported `generated` while `spec.md` asserted source grounding
# three times.
#
# Every generation test before this one ran against a Ruby checkout, which is why an allowlist
# missing every non-Ruby extension survived two rounds.
class SpecificationSourceInspectionTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("specrelay-source-inspection-")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # The CR's criterion 1, against the real Tiny Demo shape.
  def test_a_node_esm_checkout_is_inspected
    write("demo-app/server.mjs", "import { createServer } from \"node:http\";\n")
    write("demo-app/index.html", "<!doctype html>\n<h1>Tiny Demo App</h1>\n")
    write("demo-app/package.json", "{ \"name\": \"tiny-demo-app\", \"type\": \"module\" }\n")
    write("demo-app/test/homepage.test.mjs", "import test from \"node:test\";\n")

    assert_equal %w[demo-app/index.html demo-app/package.json demo-app/server.mjs
                    demo-app/test/homepage.test.mjs], gather.entry_points.sort
  end

  # The point of inverting the rule: a language this runner has never met must still be
  # sampled, because an allowlist fails closed for exactly the set that matters.
  def test_a_language_the_allowlist_never_had_is_still_inspected
    write("src/main.zig", "pub fn main() void {}\n")
    write("src/build.gradle.kts", "plugins { kotlin(\"jvm\") }\n")
    write("Dockerfile", "FROM ruby:3.4\n")

    assert_equal %w[Dockerfile src/build.gradle.kts src/main.zig], gather.entry_points.sort
  end

  def test_binary_and_oversized_files_are_not_sampled
    write("app/logo.png", "\x89PNG\r\n\x1a\n binary")
    write("app/blob.dat", "head\x00tail")
    write("app/huge.txt", "x" * (SpecrelayRunner::Specification::SourceEvidence::MAX_ENTRY_POINT_BYTES + 1))
    write("app/real.rb", "class Real; end\n")

    assert_equal %w[app/real.rb], gather.entry_points
  end

  # Prose is sampled — it is readable and it is in the checkout — but it must never crowd out
  # code, or a repository of forty specification documents would report those as its source.
  def test_documentation_is_ranked_after_code
    20.times { |index| write("specs/DEMO-#{index.to_s.rjust(4, '0')}/spec.md", "# spec #{index}\n") }
    write("demo-app/server.mjs", "import http from \"node:http\";\n")

    assert_equal "demo-app/server.mjs", gather.entry_points.first
  end

  # ------------------------------------------------------- a zero-file inspection is loud

  # The CR's criterion 2.
  def test_an_empty_checkout_produces_a_warning_rather_than_silence
    result = gather

    assert_empty result.entry_points
    refute result.inspected?
    assert_equal 3, result.warnings.length
    assert result.warnings.any? { |warning| warning.include?("Graphify is not installed") }
    assert result.warnings.any? { |warning| warning.include?("Context+ is not available") }
    source_warning = result.warnings.find { |warning| warning.include?("No source file could be read") }
    assert_includes source_warning, "grounded in the Jira ticket alone"
  end

  def test_a_checkout_with_source_carries_only_the_missing_tool_warnings
    write("app/real.rb", "class Real; end\n")

    result = gather
    assert_equal [
      "Graphify is not installed for this checkout; direct source inspection was used instead.",
      "Context+ is not available on this runner; direct source inspection was used without semantic " \
      "Context+ evidence."
    ], result.warnings
    assert result.inspected?
  end

  # The refuse-or-warn decision, named so a reviewer can see it was made rather than
  # defaulted into. WARN: the checkout resolved, so this is not scope §8's unresolvable
  # workspace, and a specification written from a complete ticket is still useful provided it
  # says what it is missing. Documented in the runner README and docs/runner-setup.md.
  def test_the_documented_choice_is_to_warn_and_generate_not_to_refuse
    result = gather

    refute_empty result.warnings, "an empty inspection must warn"
    assert_kind_of SpecrelayRunner::Specification::SourceEvidence::Result, result,
                   "an empty inspection must still return a usable result, not raise"
  end

  def gather
    SpecrelayRunner::Specification::SourceEvidence.gather(
      root: @root, settings: SpecrelayRunner::Specification::Settings.new({}, env: {}), env: ENV
    )
  end

  def write(relative, content)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
