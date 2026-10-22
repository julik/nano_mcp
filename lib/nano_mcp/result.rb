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

    # Structured data. A current client gets it as `structuredContent`, with `summary`
    # in the text block next to it - or, without one, a line like "12 workflows in
    # structuredContent.". An older client gets the data serialized into the text block.
    #
    # @param value [Hash, Array, String, Numeric, true, false] anything JSON can represent
    # @param summary [String, nil] a line saying what came back
    # @return [Result]
    def self.json(value, summary: nil)
      raise ArgumentError, "Result.json needs a value, use Result.text for an empty answer" if value.nil?
      new((summary || summarize(value)).to_s, value, false)
    end

    # A refusal or failure the agent should read and act on. Same as raising ToolError.
    #
    # @param message [String]
    # @return [Result]
    def self.error(message)
      new(message.to_s, nil, true)
    end

    # The spec suggests repeating the data as JSON in the text block, but a client
    # asking for the current revision reads structuredContent, and a second copy of a
    # large answer just fills the agent's context window
    def self.summarize(value)
      count, noun = case value
      when Array then [value.length, "items"]
      when Hash then value.select { |_key, member| member.is_a?(Array) }.max_by { |_key, member| member.length }&.then { |key, member| [member.length, key] }
      end
      count ? "#{count} #{noun} in structuredContent." : "See structuredContent."
    end

    private_class_method :new, :summarize

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
