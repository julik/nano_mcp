# frozen_string_literal: true

require "test_helper"

class ModernTest < Minitest::Test
  include MCPRequests

  def test_discover_describes_the_server
    assert_equal 200, modern("server/discover")
    assert_equal "complete", result["resultType"]
    assert_equal [VERSION], result["supportedVersions"]
    assert_equal({"tools" => {"listChanged" => false}}, result["capabilities"])
    assert_equal "workflows", result.dig("_meta", "io.modelcontextprotocol/serverInfo", "name")
    assert_equal NanoMCP::VERSION, result.dig("_meta", "io.modelcontextprotocol/serverInfo", "version")
    assert_includes result["instructions"], "safety valve"
    assert result["ttlMs"].positive?
    assert_equal "private", result["cacheScope"]
    assert_equal "application/json", @headers["content-type"]
  end

  def test_never_mints_a_session
    modern("server/discover", headers: {"HTTP_MCP_SESSION_ID" => "pretend-i-have-one"})
    assert_equal 200, @status
    refute @headers.keys.any? { |key| key.casecmp?("mcp-session-id") }
  end

  def test_ping_is_gone_and_unknown_methods_are_404
    assert_equal 404, modern("ping")
    assert_equal(-32601, error["code"])
    assert_equal 404, modern("resources/list")
    assert_equal 1, json["id"]
  end

  def test_unsupported_version_lists_what_we_do_speak
    assert_equal 400, modern("tools/list", version: "1999-01-01")
    assert_equal(-32022, error["code"])
    assert_includes error.dig("data", "supported"), VERSION
    assert_includes error.dig("data", "supported"), "2025-11-25"
    assert_equal "1999-01-01", error.dig("data", "requested")
  end

  def test_version_header_must_agree_with_body
    assert_equal 400, modern("tools/list", headers: {"HTTP_MCP_PROTOCOL_VERSION" => "2025-06-18"})
    assert_equal(-32020, error["code"])
    assert_includes error["message"], "MCP-Protocol-Version"
  end

  def test_modern_header_without_meta_is_refused
    post({jsonrpc: "2.0", id: 1, method: "tools/list", params: {}},
      {"HTTP_MCP_PROTOCOL_VERSION" => VERSION, "HTTP_MCP_METHOD" => "tools/list"})
    assert_equal 400, @status
    assert_equal(-32020, error["code"])
  end

  def test_required_headers_must_be_present
    assert_equal 400, modern("tools/list", headers: {"HTTP_MCP_METHOD" => nil})
    assert_includes error["message"], "Mcp-Method header is required"

    assert_equal 400, modern("tools/call", {name: "get_server_status"}, headers: {"HTTP_MCP_NAME" => nil})
    assert_includes error["message"], "Mcp-Name header is required"
  end

  def test_method_and_name_headers_must_agree_with_body
    assert_equal 400, modern("tools/list", headers: {"HTTP_MCP_METHOD" => "tools/call"})
    assert_equal(-32020, error["code"])

    # A router sending this to the read-only pool while we pause things would be bad
    assert_equal 400, modern("tools/call", {name: "pause_workflows", arguments: {workflow_ids: [1]}},
      headers: {"HTTP_MCP_NAME" => "get_server_status"})
    assert_equal(-32020, error["code"])
  end

  def test_base64_wrapped_name_is_decoded
    wrapped = "=?base64?#{["get_server_status"].pack("m0")}?="
    assert_equal 200, modern("tools/call", {name: "get_server_status"}, headers: {"HTTP_MCP_NAME" => wrapped})
    refute result["isError"]

    assert_equal 400, modern("tools/call", {name: "get_server_status"}, headers: {"HTTP_MCP_NAME" => "=?base64?!!!?="})
    assert_equal(-32020, error["code"])
  end

  def test_tools_list_carries_caching_hints_in_order
    modern("tools/list")
    assert_equal "complete", result["resultType"]
    assert_equal WorkflowsMCP::TOOLS.map(&:tool_name), result["tools"].map { |t| t["name"] }
    assert_equal 300_000, result["ttlMs"]
    assert_equal "private", result["cacheScope"]
  end

  def test_structured_answer_comes_back_once_with_summary
    call_tool("search_workflows", {state: "paused", limit: 5})
    assert_equal "complete", result["resultType"]
    assert_equal false, result["isError"]
    assert_equal 5, result.dig("structuredContent", "workflows").length
    assert(result.dig("structuredContent", "workflows").all? { |w| w["state"] == "paused" })
    assert_equal "5 workflows, more available (pass next_cursor).", result["content"].first["text"]
  end

  def test_structured_answer_without_summary_serializes_into_text
    call_tool("get_workflow", {id: 3})
    assert_equal 3, result.dig("structuredContent", "id")
    assert_equal result["structuredContent"], JSON.parse(result["content"].first["text"])
    assert_equal "http://mcp.example.com/admin/workflows/3", result.dig("structuredContent", "admin_url")
  end

  def test_cursor_pagination_walks_everything
    seen = []
    cursor = nil
    loop do
      call_tool("search_workflows", {type: "InvoiceWorkflow", limit: 40, cursor: cursor}.compact)
      seen.concat(result.dig("structuredContent", "workflows").map { |w| w["id"] })
      cursor = result.dig("structuredContent", "next_cursor")
      break unless cursor
    end
    assert_equal 125, seen.length
    assert_equal seen.sort.reverse, seen
  end

  def test_prose_stays_prose
    call_tool("workflow_docs", {topic: "states"})
    refute result.key?("structuredContent")
    assert_includes result["content"].first["text"], "safety valve"
  end

  def test_tool_errors_are_results_not_protocol_errors
    assert_equal 200, call_tool("get_workflow", {id: 9999})
    assert result["isError"]
    assert_equal "No workflow with id 9999", result["content"].first["text"]
  end

  def test_unknown_tool_is_a_protocol_error
    assert_equal 200, call_tool("nope")
    assert_equal(-32602, error["code"])
    assert_includes error["message"], "Unknown tool: nope"
  end

  def test_internal_errors_keep_their_message_in_the_log
    assert_equal 200, call_tool("explode")
    assert_equal(-32603, error["code"])
    assert_includes error["message"], "RuntimeError"
    refute_includes @body, "secret row data"
    assert_includes @log.string, "secret row data"
  end

  def test_every_call_is_logged
    call_tool("get_server_status")
    assert_match(/\[nano_mcp\] server=workflows tool=get_server_status era=modern error=false bytes=\d+ duration_ms=[\d.]+/, @log.string)
  end

  def test_notifications_get_an_empty_202
    post({jsonrpc: "2.0", method: "notifications/whatever", params: {}})
    assert_equal 202, @status
    assert_equal "", @body
  end

  def test_initialize_selects_legacy_even_with_modern_headers
    legacy("initialize", {protocolVersion: VERSION}, headers: {"HTTP_MCP_PROTOCOL_VERSION" => VERSION})
    assert_equal "2025-11-25", result["protocolVersion"]
    refute result.key?("resultType")
  end
end
