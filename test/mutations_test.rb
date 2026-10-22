# frozen_string_literal: true

require "test_helper"

# The gate the example puts in its own base class, through the two seams nano_mcp
# offers for it: Tool.descriptor and Tool#invoke
class MutationsTest < Minitest::Test
  include MCPRequests

  def test_disabled_mutation_says_so_in_the_list_and_refuses
    modern("tools/list")
    pause = result["tools"].find { |t| t["name"] == "pause_workflows" }
    assert_includes pause["description"], "CURRENTLY DISABLED"
    assert_equal false, pause.dig("annotations", "readOnlyHint")
    assert_equal true, result["tools"].find { |t| t["name"] == "get_workflow" }.dig("annotations", "readOnlyHint")

    call_tool("pause_workflows", {workflow_ids: [1]})
    assert result["isError"]
    assert_includes result["content"].first["text"], "WORKFLOWS_MCP_MUTATIONS"
    assert_equal "performing", @store.find(1).state
  end

  def test_permitted_mutation_reports_per_id
    @app = WorkflowsMCP.server(store: @store, token: TOKEN, mutations_permitted: true)
    modern("tools/list")
    refute_includes result["tools"].find { |t| t["name"] == "pause_workflows" }["description"], "DISABLED"

    call_tool("pause_workflows", {workflow_ids: [1, 2, 4, 9999]})
    outcomes = result.dig("structuredContent", "outcomes").to_h { |o| [o["id"], o["outcome"]] }
    assert_equal({1 => "paused", 2 => "skipped", 4 => "paused", 9999 => "not_found"}, outcomes)
    assert_equal "Paused 2 of 4.", result["content"].first["text"]
    assert_equal "paused", @store.find(1).state
  end
end
