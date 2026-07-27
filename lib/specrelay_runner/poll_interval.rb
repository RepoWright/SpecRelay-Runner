# frozen_string_literal: true

module SpecrelayRunner
  # MVP-0018 — the validated polling interval for `specrelay-runner loop`.
  #
  # Two different kinds of bad input get two different answers, deliberately:
  #
  #   - a value that is not a whole number of seconds is REFUSED. `--poll-interval
  #     abc` almost certainly means the operator's intent was lost, and silently
  #     substituting a default would hide that.
  #   - a number outside [MINIMUM, MAXIMUM] is CLAMPED, and the clamp is announced
  #     on the terminal. The operator asked for a real interval; the runner honours
  #     the closest one it is willing to poll at and says so.
  #
  # The lower bound exists because this is a shared control plane: a one-second
  # poll from every connected machine is a load pattern nobody asked for. The upper
  # bound exists so a typo (`--poll-interval 86400`) cannot silently produce a
  # runner that looks alive and claims nothing for a day.
  class PollInterval
    MINIMUM = 5
    MAXIMUM = 3600
    DEFAULT = 60

    attr_reader :seconds, :notice, :error

    def self.resolve(raw) = new(raw)

    def initialize(raw)
      text = raw.to_s.strip
      @seconds = DEFAULT
      @notice = nil
      @error = nil
      text.empty? ? default! : parse(text)
    end

    def valid? = error.nil?

    private

    def default! = nil

    def parse(text)
      unless /\A\d+\z/.match?(text)
        @error = "--poll-interval must be a whole number of seconds " \
                 "(#{MINIMUM}-#{MAXIMUM}); got '#{text}'"
        return
      end

      clamp(text.to_i)
    end

    def clamp(value)
      if value < MINIMUM
        @seconds = MINIMUM
        @notice = "--poll-interval #{value}s is below the #{MINIMUM}s lower bound; polling every #{MINIMUM}s instead"
      elsif value > MAXIMUM
        @seconds = MAXIMUM
        @notice = "--poll-interval #{value}s is above the #{MAXIMUM}s upper bound; polling every #{MAXIMUM}s instead"
      else
        @seconds = value
      end
    end
  end
end
