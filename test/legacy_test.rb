# frozen_string_literal: true

require "test_helper"

# Clients of 2025-11-25 and earlier, which open with `initialize` and never send _meta
class LegacyTest < Minitest::Test
  include MCPRequests

  def test_initialize_negotiates_a_version
    legacy("initialize", {protocolVersion: "2025-06-18", capabilities: {}, clientInfo: {name: "Old", version: "1"}})
    assert_equal "2025-06-18", result["protocolVersion"]
    assert_equal "workflows", result.dig("serverInfo", "name")
    assert_includes result["instructions"], "safety valve"
    refute result.key?("resultType")
  end

  def test_initialize_with_an_unknown_version_offers_the_newest_legacy_one
    legacy("initialize", {protocolVersion: "2019-01-01"})
    assert_equal "2025-11-25", result["protocolVersion"]
  end

  def test_initialized_notification_and_ping
    post({jsonrpc: "2.0", method: "notifications/initialized"})
    assert_equal 202, @status
    legacy("ping")
    assert_equal({}, result)
  end

  def test_no_session_id_comes_back
    legacy("initialize", {protocolVersion: "2025-06-18"})
    refute @headers.keys.any? { |key| key.casecmp?("mcp-session-id") }
  end

  def test_tools_list_has_no_modern_fields
    legacy("tools/list")
    assert_equal WorkflowsMCP::TOOLS.size, result["tools"].size
    refute result.key?("ttlMs")
    refute result.key?("resultType")
  end

  def test_structured_answers_go_out_as_json_text
    legacy("tools/call", {name: "get_workflow", arguments: {id: 2}})
    refute result.key?("structuredContent")
    assert_equal 2, JSON.parse(result["content"].first["text"])["id"]
  end

  def test_unknown_method_is_a_200_with_an_error
    assert_equal 200, legacy("resources/list")
    assert_equal(-32601, error["code"])
  end

  def test_legacy_version_header_is_fine_without_meta
    assert_equal 200, legacy("tools/list", headers: {"HTTP_MCP_PROTOCOL_VERSION" => "2025-06-18"})
  end
end
