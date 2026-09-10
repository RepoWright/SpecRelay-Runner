# frozen_string_literal: true

require_relative "test_helper"

# Where the generated package is allowed to land, proved at the two destinations that are
# actually written to.
#
# {PackagePath} owns the containment rule and its own unit test proves the rule; this proves the
# WRITER obeys it at both roots it is handed. The distinction matters because the two roots are
# prepared by different owners — the ticket's task workspace by the project's own command, the
# publication snapshot by this runner — and a symbolic link on the way to either one is enough
# to make the delete, the copy and the rename land outside the tree the run is allowed to touch.
#
# Each case keeps a SENTINEL file in the outside directory and asserts its bytes afterwards. A
# refusal that still deleted or overwrote something outside would pass an "it raised" assertion
# and fail the one this file exists to make.
class SpecificationPackageContainmentTest < Minitest::Test
  PackageWriter = SpecrelayRunner::Specification::PackageWriter
  PackagePath = SpecrelayRunner::Specification::PackagePath
  DocumentSet = SpecrelayRunner::Specification::DocumentSet

  ISSUE = "SR-700"
  FOLDER = "SR-700-add-an-export-button"

  Tool = Struct.new(:name, :usable, :contributed, :summary, keyword_init: true) do
    def usable? = usable
    def contributed? = contributed
  end

  Source = Struct.new(:root, :repository_name, :entry_point_paths, :graphify, :context_plus,
                      :warnings, keyword_init: true)
  Inputs = Struct.new(:inputs, :readable_inputs, :warnings, keyword_init: true)
  ProviderDouble = Struct.new(:kind, :description, keyword_init: true) do
    def describe = description
  end

  def setup
    @temp = Dir.mktmpdir("specrelay-containment-")
    @task = File.join(@temp, "task")
    @snapshot = File.join(@temp, "snapshot")
    [ @task, @snapshot ].each { |root| FileUtils.mkdir_p(root) }
    @outside = File.join(@temp, "outside")
    FileUtils.mkdir_p(@outside)
    File.write(File.join(@outside, "sentinel.txt"), "sentinel\n")
  end

  def teardown
    FileUtils.remove_entry(@temp) if @temp && File.directory?(@temp)
  end

  # The control. With both roots ordinary directories the package lands in both, so the refusals
  # below are the containment rule firing rather than the fixture being unusable.
  def test_an_ordinary_pair_of_roots_receives_the_package
    written = write!

    assert_path_exists File.join(@task, "specs", FOLDER, "spec.md")
    assert_path_exists File.join(@snapshot, "specs", FOLDER, "spec.md")
    assert_equal "specs/#{FOLDER}", written.relative_package_path
  end

  # The TASK destination. `specs` is a link out of the task workspace, so the staging directory,
  # the rename and the replaced package all resolve outside it.
  def test_a_symlinked_ancestor_in_the_task_workspace_is_refused_without_touching_the_outside
    File.symlink(@outside, File.join(@task, "specs"))

    assert_raises(PackagePath::Unsafe, PackageWriter::Error) { write! }
    assert_outside_untouched
  end

  # The SNAPSHOT destination. It is refused for the same reason and by the same authority; a
  # package that reached the retained workspace through a link would be published from outside
  # the directory this runner owns.
  def test_a_symlinked_ancestor_in_the_snapshot_workspace_is_refused_without_touching_the_outside
    File.symlink(@outside, File.join(@snapshot, "specs"))

    assert_raises(PackagePath::Unsafe, PackageWriter::Error) { write! }
    assert_outside_untouched
  end

  # The package folder itself is an ancestor of every file written, so a link there escapes as
  # completely as one higher up.
  def test_a_symlinked_package_folder_in_the_task_workspace_is_refused
    FileUtils.mkdir_p(File.join(@task, "specs"))
    File.symlink(@outside, File.join(@task, "specs", FOLDER))

    assert_raises(PackagePath::Unsafe, PackageWriter::Error) { write! }
    assert_outside_untouched
  end

  private

  # Nothing outside the two roots was created, changed or removed.
  def assert_outside_untouched
    assert_equal "sentinel\n", File.read(File.join(@outside, "sentinel.txt"))
    assert_equal [ "sentinel.txt" ], Dir.children(@outside).sort
  end

  def write!
    PackageWriter.call(package_path: package_path, destination_root: @task,
                       snapshot_root: @snapshot, workspace_root: @temp,
                       documents: documents, assignment: assignment, provider: provider,
                       source: source, inputs: inputs)
  end

  def package_path
    PackagePath.build(specification_root: "specs", issue_key: ISSUE, summary: "Add an export button")
  end

  def documents
    DocumentSet.validate!(minimal_package, issue_key: ISSUE)
  end

  def assignment
    SpecrelayRunner::Specification::Assignment.parse(spec_creation_payload_for(issue_key: ISSUE))
  end

  def provider = ProviderDouble.new(kind: "command", description: "a configured command")

  def source
    Source.new(root: @task, repository_name: "SpecRelay-Specs", entry_point_paths: [],
               graphify: Tool.new(name: "graphify", usable: true, contributed: true, summary: "FRESH"),
               context_plus: Tool.new(name: "context_plus", usable: true, contributed: false,
                                      summary: "no semantic query was performed"),
               warnings: [])
  end

  def inputs = Inputs.new(inputs: [], readable_inputs: [], warnings: [])

  def minimal_package
    { "spec.md" => document("#{ISSUE}: add an export button",
                            DocumentSet::REQUIRED_SECTIONS.fetch("spec.md")),
      "analysis/input-evidence.md" => document("#{ISSUE} input evidence", [ "Recorded inputs" ]),
      "analysis/business.md" => document("#{ISSUE} business analysis",
                                         DocumentSet::REQUIRED_SECTIONS.fetch("analysis/business.md")),
      "analysis/technical.md" => document("#{ISSUE} technical analysis",
                                          DocumentSet::REQUIRED_SECTIONS.fetch("analysis/technical.md")) }
  end

  def document(title, sections)
    body = sections.map do |name|
      "## #{name}\n\nThis section records the substantive detail a reviewer needs here, at " \
        "length enough to be real content rather than a heading.\n"
    end
    "# #{title}\n\n#{body.join("\n")}"
  end
end
