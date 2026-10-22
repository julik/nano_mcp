# frozen_string_literal: true

require "test_helper"

class ToolTest < Minitest::Test
  include MCPRequests

  class Echo < NanoMCP::Tool
    tool_name "echo"
    input_schema(
      properties: {
        "text" => {type: "string", minLength: 1, maxLength: 5},
        :count => {type: "integer", minimum: 1, maximum: 3, default: 1},
        :ratio => {type: "number"},
        :loud => {type: "boolean"},
        :tags => {type: "array", items: {type: "string", enum: %w[a b]}, maxItems: 2},
        :opts => {type: "object"}
      },
      required: [:text]
    )

    def call(text:, count:, **rest)
      NanoMCP::Result.json({text: text, count: count, **rest})
    end
  end

  class Bare < NanoMCP::Tool
    tool_name "bare"

    def call = NanoMCP::Result.text("ok")
  end

  class WrongReturn < NanoMCP::Tool
    tool_name "wrong_return"

    def call = "a string"
  end

  def app
    @app ||= NanoMCP::Server.new(name: "t", version: "1", tools: [Echo, Bare, WrongReturn], logger: Logger.new(@log)) { :anyone }
  end

  def test_descriptor_has_a_strict_string_keyed_schema
    entry = Bare.descriptor(nil)
    assert_equal({name: "bare", description: "", inputSchema: {"type" => "object", "properties" => {}, "additionalProperties" => false}}, entry)

    schema = Echo.descriptor(nil)[:inputSchema]
    assert_equal ["text"], schema["required"]
    assert_equal %w[text count ratio loud tags opts], schema["properties"].keys
    assert_equal 1, schema.dig("properties", "count", "default")
  end

  def test_arguments_are_coerced_and_defaulted
    echo(text: "hi", ratio: "0.5", loud: "true")
    assert_equal({"text" => "hi", "count" => 1, "ratio" => 0.5, "loud" => true}, result["structuredContent"])
    echo(text: "hi", count: "3")
    assert_equal 3, result.dig("structuredContent", "count")
  end

  def test_maximum_clamps_rather_than_refuses
    echo(text: "hi", count: 50)
    assert_equal 3, result.dig("structuredContent", "count")
  end

  def test_validation_failures_are_tool_errors_the_agent_can_read
    {
      {} => "Missing required argument(s): text",
      {text: "hi", colour: "red"} => "Unknown argument(s): colour. This tool accepts: text, count",
      {text: 5} => "text must be a string, got integer",
      {text: ""} => "text must be at least 1 characters",
      {text: "toolong"} => "text must be at most 5 characters",
      {text: "hi", count: 0} => "count must be at least 1",
      {text: "hi", count: "many"} => "count must be an integer",
      {text: "hi", loud: "yes"} => "loud must be a boolean",
      {text: "hi", tags: %w[a b a]} => "tags accepts at most 2 items",
      {text: "hi", tags: ["c"]} => "tags[0] must be one of: a, b",
      {text: "hi", opts: []} => "opts must be an object, got array"
    }.each do |arguments, message|
      echo(**arguments)
      assert result["isError"], "expected #{arguments.inspect} to be refused"
      assert_includes result["content"].first["text"], message
    end
  end

  def test_arguments_must_be_an_object
    modern("tools/call", {name: "bare", arguments: [1]})
    assert result["isError"]
    assert_includes result["content"].first["text"], "Arguments must be an object"
    modern("tools/call", {name: "bare"})
    refute result["isError"]
  end

  def test_returning_something_other_than_a_result_is_an_internal_error
    modern("tools/call", {name: "wrong_return"})
    assert_equal(-32603, error["code"])
    assert_includes @log.string, "not a NanoMCP::Result"
  end

  def test_json_results_summarize_themselves
    assert_equal "3 items in structuredContent.", NanoMCP::Result.json([1, 2, 3]).text
    assert_equal "2 rows in structuredContent.", NanoMCP::Result.json({total: 2, rows: [1, 2]}).text
    assert_equal "3 rows in structuredContent.", NanoMCP::Result.json({columns: %w[a b], rows: [1, 2, 3]}).text
    assert_equal "See structuredContent.", NanoMCP::Result.json({id: 1}).text
    assert_equal "Mine.", NanoMCP::Result.json({id: 1}, summary: "Mine.").text
  end

  def test_annotations_are_inherited_until_overridden
    base = Class.new(NanoMCP::Tool) { annotations readOnlyHint: true }
    plain = Class.new(base)
    own = Class.new(base) { annotations readOnlyHint: false }
    assert_equal({readOnlyHint: true}, plain.annotations)
    assert_equal({readOnlyHint: false}, own.annotations)
    assert_nil Bare.annotations
  end

  def test_results_cannot_be_built_by_hand
    assert_raises(NoMethodError) { NanoMCP::Result.new("x", nil, false) }
    assert_raises(ArgumentError) { NanoMCP::Result.json(nil) }
    assert NanoMCP::Result.error("no").error?
    assert NanoMCP::Result.text("x").frozen?
  end

  def test_private_constants_stay_private
    assert_raises(NameError) { NanoMCP::Arguments }
    assert_raises(NameError) { NanoMCP::Server::MODERN_VERSIONS }
  end

  def test_token_helpers
    assert_equal "abc", NanoMCP.bearer_token("HTTP_AUTHORIZATION" => "Bearer   abc ")
    assert_equal "abc", NanoMCP.bearer_token("HTTP_AUTHORIZATION" => "bearer abc")
    assert_nil NanoMCP.bearer_token("HTTP_AUTHORIZATION" => "Basic abc")
    assert_nil NanoMCP.bearer_token({})

    assert NanoMCP.token_matches?(TOKEN, TOKEN)
    refute NanoMCP.token_matches?(TOKEN + "x", TOKEN)
    refute NanoMCP.token_matches?(nil, TOKEN)
    refute NanoMCP.token_matches?("short", "short") # too short to be trusted
  end

  private

  def echo(**arguments)
    modern("tools/call", {name: "echo", arguments: arguments})
  end
end
