# frozen_string_literal: true

require "test_helper"

class ProgressTest < Minitest::Test
  include MCPRequests

  class Count < NanoMCP::Tool
    tool_name "count"

    def call
      progress(1, total: 3, message: "one")
      progress(2, total: 3)
      progress(2, total: 3, message: "two again")
      progress(1.5)
      progress(3, total: 3, message: "done")
      NanoMCP::Result.text("counted")
    end
  end

  class Halfway < NanoMCP::Tool
    tool_name "halfway"

    def call
      progress(1, total: 2)
      raise "secret row data"
    end
  end

  class Watched < NanoMCP::Tool
    tool_name "watched"

    def call
      progress(1)
      context << :tool_went_on
      NanoMCP::Result.text("done")
    end
  end

  STREAM = {"HTTP_ACCEPT" => "application/json, text/event-stream"}.freeze

  def app
    @app ||= NanoMCP::Server.new(name: "p", version: "1", tools: [Count, Halfway], logger: Logger.new(@log), **server_options) do |env, _meta|
      :anyone if NanoMCP.token_matches?(NanoMCP.bearer_token(env), TOKEN)
    end
  end

  def streaming_call(name, token: "tok-1", headers: STREAM)
    modern("tools/call", {name: name, arguments: {}}, headers: headers, meta: {"progressToken" => token})
  end

  def test_streams_the_notifications_then_the_response
    assert_equal 200, streaming_call("count")
    assert_equal "text/event-stream", @headers["content-type"]
    assert_equal "no-cache", @headers["cache-control"]
    assert_equal "no", @headers["x-accel-buffering"]
    refute @headers.key?("content-length")

    *notifications, response = events
    assert_equal [
      {"progressToken" => "tok-1", "progress" => 1, "total" => 3, "message" => "one"},
      {"progressToken" => "tok-1", "progress" => 2, "total" => 3},
      {"progressToken" => "tok-1", "progress" => 3, "total" => 3, "message" => "done"}
    ], notifications.map { |n| n["params"] }, "Progress that does not increase must be dropped"
    assert(notifications.all? { |n| n["method"] == "notifications/progress" && !n.key?("id") })

    assert_equal 1, response["id"]
    assert_equal "complete", response.dig("result", "resultType")
    assert_equal "counted", response.dig("result", "content", 0, "text")
  end

  def test_notifications_go_out_while_the_tool_runs
    trail = []
    @app = NanoMCP::Server.new(name: "p", version: "1", tools: [Watched]) { trail }
    env = Rack::MockRequest.env_for("http://mcp.example.com/mcp", :method => "POST", "HTTP_ACCEPT" => "text/event-stream",
      :input => JSON.generate({jsonrpc: "2.0", id: 1, method: "tools/call", params: {name: "watched", _meta: {progressToken: 1}}}))
    _, _, body = app.call(env)
    assert_empty trail, "The tool runs when the body is iterated, not before"
    body.each { |chunk| trail << chunk[/"method":"([^"]+)"/, 1] }
    assert_equal ["notifications/progress", :tool_went_on, nil], trail
  end

  def test_integer_progress_token_comes_back_as_is
    streaming_call("count", token: 42)
    assert_equal 42, events.first.dig("params", "progressToken")
  end

  def test_without_a_progress_token_it_is_plain_json
    assert_equal 200, modern("tools/call", {name: "count", arguments: {}}, headers: STREAM)
    assert_equal "application/json", @headers["content-type"]
    assert_equal "counted", result.dig("content", 0, "text")

    # Not a string or an integer, so not a token
    streaming_call("count", token: {"nope" => 1})
    assert_equal "application/json", @headers["content-type"]
  end

  def test_without_accepting_a_stream_it_is_plain_json
    [{}, {"HTTP_ACCEPT" => "application/json"}].each do |headers|
      assert_equal 200, streaming_call("count", headers: headers)
      assert_equal "application/json", @headers["content-type"]
      assert_equal "counted", result.dig("content", 0, "text")
    end
  end

  def test_progress_does_nothing_when_not_streaming
    assert_nil Count.new(:anyone).progress(1, total: 2, message: "hi")
    assert_equal "counted", Count.new(:anyone).call.text
  end

  def test_progress_must_be_a_number
    assert_raises(ArgumentError) { Count.new(nil).progress("1") }
    assert_raises(ArgumentError) { Count.new(nil).progress(1, total: "2") }
  end

  def test_refusals_keep_their_status_and_stay_json
    assert_equal 401, streaming_call("count", headers: STREAM.merge("HTTP_AUTHORIZATION" => nil))
    assert_equal "application/json", @headers["content-type"]
    assert_equal(-32001, error["code"])

    assert_equal 400, streaming_call("count", headers: STREAM.merge("HTTP_MCP_NAME" => "halfway"))
    assert_equal "application/json", @headers["content-type"]

    assert_equal 200, streaming_call("nope")
    assert_equal "application/json", @headers["content-type"]
    assert_equal(-32602, error["code"])
  end

  def test_tool_raising_midway_ends_the_stream_with_an_internal_error
    assert_equal 200, streaming_call("halfway")
    notification, response = events
    assert_equal 1, notification.dig("params", "progress")
    assert_equal(-32603, response.dig("error", "code"))
    assert_equal 1, response["id"]
    refute_includes @body, "secret row data"
    assert_includes @log.string, "secret row data"
    assert_match(/tool=halfway era=modern error=true bytes=- /, @log.string)
  end

  def test_on_call_hears_about_streamed_calls
    calls = []
    @app = NanoMCP::Server.new(name: "p", version: "1", tools: [Count, Halfway], on_call: ->(event) { calls << event }) { :anyone }
    streaming_call("count")
    final_result = events.last["result"].except("resultType")
    streaming_call("halfway")

    counted, exploded = calls
    assert_equal "count", counted[:tool]
    refute counted[:error]
    assert_equal JSON.generate(final_result).bytesize, counted[:bytes], "Counts the result, not the notifications before it"
    assert exploded[:error]
    assert_equal "secret row data", exploded[:exception].message
  end

  def test_legacy_clients_get_a_stream_too
    post({jsonrpc: "2.0", id: 7, method: "tools/call", params: {name: "count", _meta: {progressToken: "old"}}}, STREAM)
    assert_equal "text/event-stream", @headers["content-type"]
    *notifications, response = events
    assert_equal [1, 2, 3], notifications.map { |n| n.dig("params", "progress") }
    assert_equal 7, response["id"]
    refute response["result"].key?("resultType")
  end

  def test_the_example_reports_progress_while_pausing
    @app = WorkflowsMCP.server(store: @store, token: TOKEN, mutations_permitted: true)
    modern("tools/call", {name: "pause_workflows", arguments: {workflow_ids: [1, 4, 9999]}}, headers: STREAM, meta: {"progressToken" => "p"})
    *notifications, response = events
    assert_equal [0, 1, 2, 3], notifications.map { |n| n.dig("params", "progress") }
    assert_equal "Pausing workflow 4", notifications[1].dig("params", "message")
    assert_equal 2, response.dig("result", "structuredContent", "paused")
  end
end
