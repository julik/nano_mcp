# frozen_string_literal: true

module NanoMCP
  # Base class for tools. A tool is a name, a description an agent picks it by,
  # an input schema, and a #call returning a Result.
  #
  #   class GetWorkflow < NanoMCP::Tool
  #     tool_name "get_workflow"
  #     description "One workflow by id"
  #     input_schema properties: {id: {type: "integer"}}, required: ["id"]
  #     annotations readOnlyHint: true
  #
  #     def call(id:)
  #       NanoMCP::Result.json(context.store.find(id))
  #     end
  #   end
  #
  # A tool is instantiated once per call, with whatever the server's authentication
  # block returned as its context.
  class Tool
    class << self
      # @param value [String] the name agents call the tool by, `[A-Za-z0-9_.-]{1,128}`
      def tool_name(value = nil)
        @tool_name = value.to_s if value
        @tool_name
      end

      # @param value [String] a human-readable name for client UIs
      def title(value = nil)
        @title = value.to_s if value
        @title
      end

      # @param value [String] what the tool does, written for the agent choosing it
      def description(value = nil)
        @description = value.to_s.strip if value
        @description
      end

      # JSON Schema for the arguments, keys as symbols or strings. Only the top-level
      # `properties` and `required` are given meaning by the validator, and arguments
      # not in `properties` are always refused - `additionalProperties` is forced to
      # false to say so.
      #
      # @param value [Hash]
      def input_schema(value = nil)
        if value
          @input_schema = value
          @json_schema = nil
        end
        @input_schema || {}
      end

      # Behaviour hints for the client, passed through verbatim. Use the spec's names:
      # `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`.
      #
      # @param value [Hash]
      def annotations(value = nil)
        @annotations = value if value
        @annotations
      end

      # The `tools/list` entry for this tool. Override it (calling super) to vary the
      # entry with the caller, for example to say a tool is disabled for them.
      #
      # @param context [Object] what the server's authentication block returned
      # @return [Hash]
      def descriptor(context)
        {
          name: tool_name,
          title: title,
          description: description.to_s,
          inputSchema: json_schema,
          annotations: annotations
        }.compact
      end

      # @api private
      def json_schema
        @json_schema ||= begin
          schema = JSON.parse(JSON.generate(input_schema))
          schema["type"] = "object"
          schema["properties"] ||= {}
          schema["additionalProperties"] = false
          schema.freeze
        end
      end
    end

    # @return [Object] what the server's authentication block returned
    attr_reader :context

    def initialize(context)
      @context = context
    end

    # Validates the arguments and calls #call with them as keywords. This is the
    # seam for wrapping every tool of yours at once - a permission check, log tags,
    # a timeout: override it in your own base class and call super.
    #
    # @param arguments [Hash, nil] as they came off the wire
    # @return [Result]
    def invoke(arguments)
      call(**Arguments.validate!(arguments, self.class.json_schema))
    end

    # Implement this. Receives the validated arguments as keywords; ones the caller
    # left out and that have no `default` are not passed at all.
    #
    # @return [Result]
    def call(**)
      raise NotImplementedError, "#{self.class} must implement #call"
    end
  end
end
