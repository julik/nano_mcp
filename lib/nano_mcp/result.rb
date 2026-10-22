# frozen_string_literal: true

module NanoMCP
  # What a tool returns from #call. Build one with {.text}, {.json} or {.error};
  # the server shapes it for whichever protocol revision the caller speaks.
  class Result
    # Prose for the agent to read.
    #
    # @param string [String]
    # @return [Result]
    def self.text(string)
      new(string.to_s, nil, false)
    end

    # Structured data. A current client gets it as `structuredContent`, an older one
    # gets it serialized into a text block. The text block a current client gets next
    # to the data is `summary` when given, and the data as JSON when not - pass a summary
    # to avoid sending a large answer twice.
    #
    # @param value [Hash, Array, String, Numeric, true, false] anything JSON can represent
    # @param summary [String, nil] a line saying what came back
    # @return [Result]
    def self.json(value, summary: nil)
      raise ArgumentError, "Result.json needs a value, use Result.text for an empty answer" if value.nil?
      new(summary&.to_s, value, false)
    end

    # A refusal or failure the agent should read and act on. Same as raising ToolError.
    #
    # @param message [String]
    # @return [Result]
    def self.error(message)
      new(message.to_s, nil, true)
    end

    private_class_method :new

    # @return [String, nil] the text, or the summary of a structured result
    attr_reader :text

    # @return [Object, nil] the structured value, nil for text and error results
    attr_reader :structured

    def initialize(text, structured, error)
      @text = text
      @structured = structured
      @error = error
      freeze
    end

    # @return [Boolean]
    def error?
      @error
    end
  end
end
