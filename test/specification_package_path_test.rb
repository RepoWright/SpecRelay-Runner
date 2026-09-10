# frozen_string_literal: true

require_relative "test_helper"

# MVP-0026 scope 2 — the package destination is deterministic, repository-relative, and
# contained.
#
# Unit-level, unlike the rest of this lane's tests, because the interesting inputs here are
# hostile strings rather than product flows: there is no way to route a URL-userinfo folder
# name or a control character through a real Jira ticket, and a test that could only use
# realistic inputs would leave the guards unexercised.
class SpecificationPackagePathTest < Minitest::Test
  PackagePath = SpecrelayRunner::Specification::PackagePath

  def setup
    @checkout = Dir.mktmpdir("specrelay-specs-")
  end

  def teardown
    FileUtils.remove_entry(@checkout) if File.directory?(@checkout)
    FileUtils.remove_entry(@outside) if @outside && File.directory?(@outside)
  end

  # ------------------------------------------------------------------- determinism

  def test_the_folder_name_is_the_issue_key_and_a_slugified_summary
    assert_equal "SR-700-add-an-export-button", build(summary: "Add an export button").folder_name
  end

  def test_the_same_inputs_always_produce_the_same_folder
    assert_equal build(summary: "Add an export button").folder_name,
                 build(summary: "Add an export button").folder_name
  end

  # Punctuation, casing, and runs of separators must not change the identity of a package —
  # otherwise an edited ticket title would produce a second folder rather than replacing one.
  def test_punctuation_and_casing_collapse_into_one_stable_slug
    assert_equal "SR-700-add-an-export-button", build(summary: "  Add   an EXPORT (button)!  ").folder_name
  end

  def test_a_long_summary_is_truncated_without_a_trailing_separator
    name = build(summary: "A very long ticket summary that goes on well past any reasonable " \
                          "directory component length limit").folder_name
    slug = name.delete_prefix("SR-700-")

    assert_operator slug.length, :<=, PackagePath::MAX_SLUG_LENGTH
    refute slug.end_with?("-")
  end

  # A summary with no Latin characters still has to produce a valid, deterministic component.
  def test_a_summary_that_slugifies_to_nothing_falls_back_to_a_stable_literal
    assert_equal "SR-700-specification", build(summary: "！！！").folder_name
    assert_equal "SR-700-specification", build(summary: "").folder_name
  end

  # ------------------------------------------------------------------- containment

  def test_the_relative_path_joins_the_configured_root
    assert_equal "specs/SR-700-add-an-export-button", build.relative_package_path
  end

  def test_an_empty_specification_root_puts_packages_at_the_repository_root
    assert_equal "SR-700-add-an-export-button", build(root: "").relative_package_path
  end

  def test_the_absolute_path_stays_inside_the_root_it_is_resolved_in
    path = build.absolute_in(@checkout)

    assert path.start_with?("#{File.realpath(@checkout)}/")
  end

  # MAPIAI-62 — the same identity resolves in whichever root the caller names, and each
  # resolution is contained in THAT root. This is the property that lets one validated package
  # identity serve a seed-validation read and a Runner-owned worktree write without either
  # being able to reach the other.
  def test_the_same_identity_resolves_independently_in_two_roots
    other = Dir.mktmpdir("specrelay-worktree-")
    package = build

    assert_equal File.join(File.realpath(@checkout), "specs/SR-700-add-an-export-button"),
                 package.absolute_in(@checkout)
    assert_equal File.join(File.realpath(other), "specs/SR-700-add-an-export-button"),
                 package.absolute_in(other)
  ensure
    FileUtils.remove_entry(other) if other && File.directory?(other)
  end

  # Each of these is refused rather than sanitized: a silently rewritten destination is one
  # the operator cannot predict, and "the runner wrote somewhere else" is the worse failure.
  {
    "a traversing root" => "../../etc",
    "a root that traverses in the middle" => "specs/../../etc",
    "an absolute root" => "/etc/specs",
    "a home-relative root" => "~/specs",
    "a Windows drive root" => "C:\\specs",
    "a root with a shell metacharacter" => "specs;rm -rf /",
    "a root with a command substitution" => "specs/$(whoami)",
    "a root with a backtick" => "specs/`id`",
    "a root with a newline" => "specs\n/etc",
    "a root with a control character" => "specs/\u0001evil",
    "a root that looks like URL userinfo" => "user:token@example.com"
  }.each do |description, root|
    define_method("test_#{description.tr(' ', '_')}_is_refused") do
      error = assert_raises(PackagePath::Unsafe) { build(root: root) }
      refute_empty error.message
    end
  end

  # The issue key is the one component the folder name is built from, so it is validated as a
  # closed shape rather than escaped. Anything else cannot become a path segment at all.
  {
    "a traversing key" => "../..",
    "a key with a slash" => "SR/700",
    "a lowercase key" => "sr-700",
    "a key with no number" => "SR-",
    "an empty key" => ""
  }.each do |description, key|
    define_method("test_#{description.tr(' ', '_')}_is_refused") do
      assert_raises(PackagePath::Unsafe) { build(issue_key: key) }
    end
  end

  # ------------------------------------------------------ real-path containment

  # The boundary is where the destination REALLY is, not how it is spelled. `File.expand_path`
  # resolves `..` textually and knows nothing about symbolic links, so a `specs` link pointing
  # out of the checkout produced a path that looked contained and would have been deleted,
  # copied into and written through — outside the root the caller named.
  def test_a_symlinked_ancestor_of_the_package_is_refused
    outside = link_specs_outside

    error = assert_raises(PackagePath::Unsafe) { build.absolute_in(@checkout) }
    assert_includes error.message, "specs"
    assert_equal "sentinel\n", File.read(File.join(outside, "sentinel.txt"))
  end

  # The package folder itself is an ancestor of every file the writer creates, so a link there
  # escapes exactly as completely as one higher up.
  def test_a_symlinked_package_folder_is_refused
    outside = Dir.mktmpdir("specrelay-outside-")
    FileUtils.mkdir_p(File.join(@checkout, "specs"))
    File.symlink(outside, File.join(@checkout, "specs", "SR-700-add-an-export-button"))

    assert_raises(PackagePath::Unsafe) { build.absolute_in(@checkout) }
  ensure
    FileUtils.remove_entry(outside) if outside && File.directory?(outside)
  end

  # A root an operator reaches through a link is an ordinary root, and refusing it would refuse
  # every checkout under a symlinked home or a macOS temporary directory. What is judged is
  # containment within what the root RESOLVES TO, never the spelling of the root itself.
  def test_a_root_reached_through_a_symlink_is_usable_and_resolves_to_its_real_location
    linked = File.join(Dir.mktmpdir("specrelay-link-"), "checkout")
    File.symlink(@checkout, linked)

    assert_equal File.join(File.realpath(@checkout), "specs/SR-700-add-an-export-button"),
                 build.absolute_in(linked)
  end

  # An unresolvable root is refused rather than assumed: this method's answer is a destination
  # something is about to be deleted at and written into.
  def test_a_root_that_cannot_be_resolved_is_refused
    assert_raises(PackagePath::Unsafe) { build.absolute_in(File.join(@checkout, "no-such-root")) }
  end

  # A directory OUTSIDE the checkout, reachable only through a `specs` symlink inside it, with a
  # sentinel file whose bytes prove nothing was written or deleted there.
  def link_specs_outside
    outside = Dir.mktmpdir("specrelay-outside-")
    File.write(File.join(outside, "sentinel.txt"), "sentinel\n")
    File.symlink(outside, File.join(@checkout, "specs"))
    @outside = outside
  end

  def test_a_trailing_slash_on_the_root_is_normalized_rather_than_doubling_the_separator
    assert_equal "specs/SR-700-add-an-export-button", build(root: "specs/").relative_package_path
    assert_equal "specs/SR-700-add-an-export-button", build(root: "./specs").relative_package_path
  end

  def build(root: "specs", issue_key: "SR-700", summary: "Add an export button")
    PackagePath.build(specification_root: root, issue_key: issue_key, summary: summary)
  end
end
