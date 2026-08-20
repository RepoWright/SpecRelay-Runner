# frozen_string_literal: true

require "json"

module SpecrelayRunner
  # MAPIAI-84/MAPIAI-93 — the executor's structured repository selection, read back from one
  # bounded local document.
  #
  # WHY a document. Which repositories an implementation needs to change, and which verification
  # is relevant to what it changed, are SEMANTIC decisions that only the executor, holding the
  # approved specification and the code, can make. Platform therefore declares no eligible-
  # repository list and no test command. But prose, terminal output and provider reasoning are
  # not evidence, so the decision has to arrive as a closed structure the runner can read exactly
  # once and refuse cleanly.
  #
  # WHY it grants nothing. This document records a CHOICE, not an authority. Every path is
  # verified against the repositories on disk before any external write ({Workspace#select}), and
  # every command is RE-RUN by {RepositoryVerification} before publication. A claimed exit code
  # or a claimed status is therefore not merely unnecessary here, it is refused: the runner's own
  # execution is the only thing that decides an outcome.
  #
  # It lives in the attempt's STAGING directory, outside the task workspace, for the same reason
  # the question bridge does: a document inside the workspace would appear in the very diff it
  # describes.
  #
  # It fails CLOSED, including on absence. A missing document means the executor never answered,
  # which is not the same fact as "nothing changed" — the executor states that by writing an
  # empty list. Treating silence as "nothing" would let a run with a diff on disk report a clean
  # success. An empty COMMAND list is the same distinction one level down: it is the executor
  # saying it found no applicable verification, which is a valid answer and never a failure.
  class RepositorySelection
    FILENAME = "changed-repositories.json"
    # Large enough for the bounds below at their worst realistic shape, and still far too small
    # for a transcript, a diff or a pasted log to arrive disguised as a selection.
    MAX_BYTES = 32_768
    MAX_ENTRIES = 50
    MAX_COMMANDS = 10
    MAX_ARGUMENTS = 20
    MAX_ARGUMENT_LENGTH = 200
    KEY = "repositories"
    PATH = "path"
    COMMANDS = "commands"
    ENTRY_KEYS = [ COMMANDS, PATH ].freeze

    # One changed repository: where it is, and the ordered verification the executor selected for
    # it. An empty `commands` means no applicable verification was found.
    Entry = Struct.new(:path, :commands, keyword_init: true)

    Result = Struct.new(:entries, :error, keyword_init: true) do
      def ok? = error.nil?
    end

    def self.path(staging_dir) = File.join(staging_dir.to_s, FILENAME)

    def self.read(staging_dir) = new(staging_dir).read

    def initialize(staging_dir)
      @path = self.class.path(staging_dir)
    end

    # The reported entries in the order the executor listed them, or one refusal.
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
      collected = []
      entries.each_with_index do |entry, index|
        position = index + 1
        return refuse("#{FILENAME} entry #{position} must be an object carrying only a #{PATH.inspect} and #{COMMANDS.inspect}") unless entry.is_a?(Hash)
        return refuse("#{FILENAME} entry #{position} must carry only a #{PATH.inspect} and #{COMMANDS.inspect}") unless entry.keys.sort == ENTRY_KEYS

        value = entry[PATH]
        return refuse("#{FILENAME} entry #{position} names no repository path") unless value.is_a?(String) && !value.strip.empty?

        commands = read_commands(entry[COMMANDS], position)
        return commands if commands.is_a?(Result)

        collected << Entry.new(path: value.strip, commands: commands)
      end
      Result.new(entries: collected)
    end

    # An ordered list of argv arrays, or one refusal. A string is refused rather than split:
    # splitting it would be this runner inventing a shell nobody asked for, and the whole point
    # of the argv contract is that no argument is ever interpreted.
    def read_commands(value, position)
      return refuse("#{FILENAME} entry #{position} must carry a list of commands") unless value.is_a?(Array)
      return refuse("#{FILENAME} entry #{position} lists #{value.length} commands; at most #{MAX_COMMANDS} are accepted") if value.length > MAX_COMMANDS

      value.each_with_index do |argv, index|
        error = argv_error(argv, position, index + 1)
        return refuse(error) if error
      end
      value.map { |argv| argv.map(&:strip) }
    end

    def argv_error(argv, position, command)
      where = "#{FILENAME} entry #{position} command #{command}"
      return "#{where} must be an argv array, not a shell string" unless argv.is_a?(Array)
      return "#{where} names no program" if argv.empty?
      return "#{where} lists #{argv.length} arguments; at most #{MAX_ARGUMENTS} are accepted" if argv.length > MAX_ARGUMENTS

      argv.each_with_index do |element, index|
        return "#{where} argument #{index + 1} must be a non-empty string" unless element.is_a?(String) && !element.strip.empty?
        return "#{where} argument #{index + 1} is too long (the limit is #{MAX_ARGUMENT_LENGTH})" if element.length > MAX_ARGUMENT_LENGTH
      end
      nil
    end

    def refuse(reason) = Result.new(entries: [], error: reason)
  end
end
