# frozen_string_literal: true

require "test_helper"

class TransportTest < Minitest::Test
  include MCPRequests

  def test_get_and_delete_are_405
    %w[GET DELETE PUT].each do |verb|
      status, headers, _ = app.call(Rack::MockRequest.env_for("http://mcp.example.com/mcp", method: verb))
      assert_equal 405, status
      assert_equal "POST", headers["allow"]
    end
  end

  def test_missing_or_wrong_token_is_401
    assert_equal 401, post({jsonrpc: "2.0", id: 1, method: "tools/list"}, {"HTTP_AUTHORIZATION" => nil})
    assert_equal %(Bearer realm="workflows"), @headers["www-authenticate"]
    assert_equal 401, post({jsonrpc: "2.0", id: 1, method: "tools/list"}, {"HTTP_AUTHORIZATION" => "Bearer nope"})
  end

  def test_authentication_that_raises_refuses
    @app = NanoMCP::Server.new(name: "x", version: "1", tools: [], logger: Logger.new(@log)) { raise "db down" }
    assert_equal 401, legacy("tools/list")
    assert_includes @log.string, "db down"
  end

  def test_server_without_authentication_block_is_refused
    assert_raises(ArgumentError) { NanoMCP::Server.new(name: "x", version: "1", tools: []) }
  end

  def test_tool_list_is_checked_at_construction
    assert_raises(ArgumentError) { NanoMCP::Server.new(name: "x", version: "1", tools: [String]) { true } }
    assert_raises(ArgumentError) { NanoMCP::Server.new(name: "x", version: "1", tools: [Class.new(NanoMCP::Tool)]) { true } }
    dupe = WorkflowsMCP::Tools::GetWorkflow
    assert_raises(ArgumentError) { NanoMCP::Server.new(name: "x", version: "1", tools: [dupe, dupe]) { true } }
  end

  def test_foreign_origin_is_403
    assert_equal 403, modern("tools/list", headers: {"HTTP_ORIGIN" => "https://evil.example"})
    assert_equal 403, modern("tools/list", headers: {"HTTP_ORIGIN" => "null"})
  end

  def test_only_listed_origins_are_fine
    # Even our own: after a DNS rebind the attacker's page has "our own" origin too
    assert_equal 403, modern("tools/list", headers: {"HTTP_ORIGIN" => "http://mcp.example.com"})

    @app = WorkflowsMCP.server(store: @store, token: TOKEN, allowed_origins: ["https://console.internal"])
    assert_equal 200, modern("tools/list", headers: {"HTTP_ORIGIN" => "https://console.internal"})
  end

  def test_garbage_bodies
    assert_equal 400, post("{nope")
    assert_equal(-32700, error["code"])
    assert_equal 400, post("")
    assert_equal 400, post("[]")
    assert_includes error["message"], "Batches"
    assert_equal 400, post("42")
    assert_equal 400, post({jsonrpc: "2.0", id: 1})
    assert_equal 400, post({jsonrpc: "2.0", id: 1, method: "tools/list", params: [1]})
  end

  def test_oversized_body_is_413
    assert_equal 413, post(JSON.generate({jsonrpc: "2.0", id: 1, method: "x", params: {pad: "x" * 1_000_001}}))
  end

  def test_body_already_read_by_a_framework_is_rewound
    env = Rack::MockRequest.env_for("http://mcp.example.com/mcp", :method => "POST",
      :input => JSON.generate({jsonrpc: "2.0", id: 1, method: "tools/list"}), "HTTP_AUTHORIZATION" => "Bearer #{TOKEN}")
    env["rack.input"].read
    status, _, _ = app.call(env)
    assert_equal 200, status
  end
end
