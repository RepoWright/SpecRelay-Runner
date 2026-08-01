# frozen_string_literal: true

require "fileutils"
require "json"

# A throwaway pair of checkouts for the specification lane's tests (MVP-0026).
#
# The lane spans TWO repositories on the operator's disk and they are not the same one: the
# SOURCE checkout is the code a specification is written about, and the SPECIFICATION checkout
# is where the generated package lands. Most of the interesting failures — a package escaping
# its folder, a host path leaking into generated Markdown, an atomic replace — are only
# observable when the two are genuinely separate directories, so this builds them that way
# rather than pointing both at one fixture.
#
# The source checkout also gets executable `bin/graph-check` and `bin/graph-query` stubs,
# because Graphify usability is a real preflight gate and a test that skipped it would only
# ever exercise the substitute path.
module SpecificationWorkspace
  module_function

  # Returns [source_root, specification_root]. Both are real directories under one temp root
  # so a single `remove_entry` cleans up.
  def build(graph: :fresh)
    root = Dir.mktmpdir("specrelay-spec-lane-")
    source = File.join(root, "tiny-demo-runs")
    specs = File.join(root, "SpecRelay-Specs")
    build_source(source, graph: graph)
    build_specs(specs)
    [ source, specs, root ]
  end

  def build_source(source, graph:)
    FileUtils.mkdir_p(File.join(source, "app", "services"))
    FileUtils.mkdir_p(File.join(source, "bin"))
    File.write(File.join(source, "app", "services", "export_report.rb"),
               "class ExportReport\n  def call = :exported\nend\n")
    File.write(File.join(source, "app", "services", "report_row.rb"),
               "class ReportRow\n  def to_csv = \"row\"\nend\n")
    write_graph_wrappers(source, graph) unless graph == :missing
  end

  # `fresh` exits 0 and prints a plausible check/query result; `stale` exits 3, which the
  # runner must treat as "not evidence" rather than querying anyway.
  #
  # Both wrappers print ABSOLUTE paths, exactly as the real ones do (`bin/graph-check` prints
  # its workspace root and graph path; `bin/graph-query` prints absolute source locations).
  # The first version of these stubs printed only relative paths, and that omission is why the
  # unit suite passed while the live pass failed on a host path reaching a generated file.
  # A stub that is politer than the tool it stands in for tests nothing.
  def write_graph_wrappers(source, graph)
    exit_code = graph == :stale ? 3 : 0
    freshness = graph == :stale ? "STALE" : "FRESH"
    write_executable(File.join(source, "bin", "graph-check"), <<~SH)
      #!/bin/sh
      echo "graphify version:  graphify 0.9.28"
      echo "workspace root:    #{source}"
      echo "graph path:        #{source}/graphify-out/graph.json"
      echo "freshness:         #{freshness}"
      exit #{exit_code}
    SH
    write_executable(File.join(source, "bin", "graph-query"), <<~SH)
      #!/bin/sh
      echo "NODE ExportReport [src=#{source}/app/services/export_report.rb loc=L1]"
      echo "NODE ReportRow [src=#{source}/app/services/report_row.rb loc=L1]"
      exit 0
    SH
  end

  def write_executable(path, body)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end

  # The specification repository checkout, with the configured folder already present. A real
  # specs repository has one; creating it here keeps the "folder is unwritable" and "folder is
  # missing" cases distinct rather than conflating them.
  def build_specs(specs)
    FileUtils.mkdir_p(File.join(specs, "specs"))
    File.write(File.join(specs, "README.md"), "# SpecRelay specifications\n")
  end

  # A provider command that returns whatever `files` describes, as JSON on stdout. Used to
  # exercise the Command provider without a model: the boundary is what is under test, not
  # the writer behind it.
  def write_provider(path, files:, exit_code: 0, stdout: nil)
    body = stdout || JSON.generate(files)
    write_executable(path, <<~SH)
      #!/bin/sh
      cat > /dev/null
      cat <<'SPECRELAY_PROVIDER_EOF'
      #{body}
      SPECRELAY_PROVIDER_EOF
      exit #{exit_code}
    SH
    path
  end

  # A provider that records the packet it was handed, so a test can assert what actually
  # crossed the boundary rather than what the Packet class says it builds.
  def write_recording_provider(path, capture_to:, files:)
    write_executable(path, <<~SH)
      #!/bin/sh
      cat > "#{capture_to}"
      cat <<'SPECRELAY_PROVIDER_EOF'
      #{JSON.generate(files)}
      SPECRELAY_PROVIDER_EOF
    SH
    path
  end
end
