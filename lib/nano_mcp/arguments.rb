# frozen_string_literal: true

module NanoMCP
  # The slice of JSON Schema tool arguments get checked against, by hand. Deliberately
  # not a general implementation - a tool that needs more than this is asking for too much.
  #
  # Checked: `type`, `required`, `enum`, `minimum`, `maximum`, `minLength`, `maxLength`,
  # `minItems`, `maxItems` and `items`, plus `default`. Nested object properties are
  # not descended into. Unknown arguments are refused rather than ignored, so a misspelled
  # filter is heard about instead of silently returning everything.
  module Arguments
    module_function

    # @param arguments [Hash, nil] as they came off the wire
    # @param schema [Hash] the input schema with string keys
    # @return [Hash] symbol-keyed, coerced, with defaults filled in
    def validate!(arguments, schema)
      arguments = {} if arguments.nil?
      raise ToolError, "Arguments must be an object, got #{json_type(arguments)}" unless arguments.is_a?(Hash)

      properties = schema.fetch("properties", {})
      unknown = arguments.keys.map(&:to_s) - properties.keys
      if unknown.any?
        accepted = properties.empty? ? "no arguments" : properties.keys.join(", ")
        raise ToolError, "Unknown argument(s): #{unknown.join(", ")}. This tool accepts: #{accepted}"
      end

      missing = Array(schema["required"]) - arguments.keys.map(&:to_s)
      raise ToolError, "Missing required argument(s): #{missing.join(", ")}" if missing.any?

      properties.each_with_object({}) do |(name, property), validated|
        value = arguments.fetch(name) { arguments[name.to_sym] }
        if !value.nil?
          validated[name.to_sym] = coerce(value, property, name)
        elsif property.key?("default")
          validated[name.to_sym] = property["default"]
        end
      end
    end

    def coerce(value, property, name)
      value = coerce_type(value, property["type"], name)

      if (enum = property["enum"]) && !enum.include?(value)
        raise ToolError, "#{name} must be one of: #{enum.join(", ")} (got #{value.inspect})"
      end

      case value
      when Numeric
        if property["minimum"] && value < property["minimum"]
          raise ToolError, "#{name} must be at least #{property["minimum"]}"
        end
        # Clamped rather than refused: an agent asking for more rows than we serve
        # wants as many as it can get, and an error just costs it a round trip
        value = property["maximum"] if property["maximum"] && value > property["maximum"]
      when String
        if property["minLength"] && value.length < property["minLength"]
          raise ToolError, "#{name} must be at least #{property["minLength"]} characters"
        end
        if property["maxLength"] && value.length > property["maxLength"]
          raise ToolError, "#{name} must be at most #{property["maxLength"]} characters"
        end
      when Array
        if property["minItems"] && value.length < property["minItems"]
          raise ToolError, "#{name} needs at least #{property["minItems"]} items, got #{value.length}"
        end
        if property["maxItems"] && value.length > property["maxItems"]
          raise ToolError, "#{name} accepts at most #{property["maxItems"]} items, got #{value.length}"
        end
        if (items = property["items"]).is_a?(Hash)
          value = value.each_with_index.map { |item, index| coerce(item, items, "#{name}[#{index}]") }
        end
      end

      value
    end

    def coerce_type(value, type, name)
      case type
      when "string"
        raise ToolError, "#{name} must be a string, got #{json_type(value)}" unless value.is_a?(String)
        value
      when "integer"
        # Agents routinely send ids as strings, and refusing those just buys a retry
        return value if value.is_a?(Integer)
        return value.to_i if value.is_a?(Float) && value == value.floor
        return value.to_i if value.is_a?(String) && /\A-?\d+\z/.match?(value)
        raise ToolError, "#{name} must be an integer, got #{value.inspect}"
      when "number"
        return value if value.is_a?(Numeric)
        return Float(value) if value.is_a?(String) && /\A-?\d+(\.\d+)?\z/.match?(value)
        raise ToolError, "#{name} must be a number, got #{value.inspect}"
      when "boolean"
        return value if value == true || value == false
        return value == "true" if value == "true" || value == "false"
        raise ToolError, "#{name} must be a boolean, got #{json_type(value)}"
      when "array"
        raise ToolError, "#{name} must be an array, got #{json_type(value)}" unless value.is_a?(Array)
        value
      when "object"
        raise ToolError, "#{name} must be an object, got #{json_type(value)}" unless value.is_a?(Hash)
        value
      else
        value
      end
    end

    def json_type(value)
      case value
      when nil then "null"
      when true, false then "boolean"
      when Integer then "integer"
      when Numeric then "number"
      when String then "string"
      when Array then "array"
      when Hash then "object"
      else value.class.name
      end
    end
  end
  private_constant :Arguments
end
