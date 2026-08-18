# frozen_string_literal: true

require "json"

module SpecrelayRunner
  # MAPIAI-84 — the executor's structured repository selection, read back from one bounded local
  # document.
  #
  # WHY a document. Which repositories an implementation needs to change is a SEMANTIC decision
  # that only the executor, holding the approved specification and the code, can make. Platform
  # therefore declares no eligible-repository list. But prose, terminal output and provider
  # reasoning are not evidence, so the decision has to arrive as a closed structure the runner
  # can read exactly once and refuse cleanly.
  #
  # WHY it grants nothing. This document records a CHOICE, not an authority. Every entry is
  # verified against the repositories on disk before any external write ({Workspace#select}), and
  # a path this parser accepted can still be refused there. The parser's whole job is to make sure
  # what reaches the verifier is a list of relative paths and nothing else.
  #
  # It lives in the attempt's STAGING directory, outside the task workspace, for the same reason
  # the question bridge does: a document inside the workspace would appear in the very diff it
  # describes.
  #
  # It fails CLOSED, including on absence. A missing document means the executor never answered,
  # which is not the same fact as "nothing changed" — the executor states that by writing an
  # empty list. Treating silence as "nothing" would let a run with a diff on disk report a clean
  # success.
  class RepositorySelection
    FILENAME = "changed-repositories.json"
    MAX_BYTES = 8192
    MAX_ENTRIES = 50
    KEY = "repositories"
    PATH = "path"

    Result = Struct.new(:paths, :error, keyword_init: true) do
      def ok? = error.nil?
    end

    def self.path(staging_dir) = File.join(staging_dir.to_s, FILENAME)

    def self.read(staging_dir) = new(staging_dir).read

    def initialize(staging_dir)
      @path = self.class.path(staging_dir)
    end

    # The reported relative paths in the order the executor listed them, or one refusal.
    #
    # No refusal quotes the document. A selection an executor got wrong is exactly the place an
    # unexpected token or private path would appear, and this reason travels into a report, a
    # Platform event and an operator's terminal.
    def read
      return refuse("the executor did not write #{FILENAME}; it must report every repository it changed") unless File.file?(path)

      size = File.size(path)
      return refuse("#{FILENAME} is too large (#{size} bytes; the limit is #{MAX_BYTES})") if size > MAX_BYTES

      document = parse
      return document if document.is_a?(Result)

      entries = document[KEY]
      return refuse("#{FILENAME} must be an object with a #{KEY.inspect} array") unless entries.is_a?(Array)
      return refuse("#{FILENAME} lists #{entries.length} repositories; at most #{MAX_ENTRIES} are accepted") if entries.length > MAX_ENTRIES

      collect(entries)
    end

    private

    attr_reader :path

    def parse
      parsed = JSON.parse(File.read(path))
      return refuse("#{FILENAME} could not be read as a JSON object") unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError, SystemCallError
      refuse("#{FILENAME} could not be read as a JSON object")
    end

    def collect(entries)
      paths = []
      entries.each_with_index do |entry, index|
        return refuse("#{FILENAME} entry #{index + 1} must be an object carrying only a #{PATH.inspect}") unless entry.is_a?(Hash)
        return refuse("#{FILENAME} entry #{index + 1} must carry only a #{PATH.inspect}") unless entry.keys == [ PATH ]

        value = entry[PATH]
        return refuse("#{FILENAME} entry #{index + 1} names no repository path") unless value.is_a?(String) && !value.strip.empty?

        paths << value.strip
      end
      Result.new(paths: paths)
    end

    def refuse(reason) = Result.new(paths: [], error: reason)
  end
end
