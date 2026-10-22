# frozen_string_literal: true

require "test_helper"

# A smoke test, not a guarantee: a server built inside a non-main Ractor has to be able
# to answer from there. A server cannot be shared between Ractors (its block and logger
# are not shareable), so each Ractor builds its own
class RactorTest < Minitest::Test
  def test_servers_answer_from_inside_ractors
    previous, Warning[:experimental] = Warning[:experimental], false

    ractors = 4.times.map do |index|
      Ractor.new(index, MCPRequests::TOKEN, NanoMCP::PROTOCOL_VERSION) do |index, token, version|
        log = StringIO.new
        server = WorkflowsMCP.server(store: WorkflowsMCP::Store.seeded, token: token,
          mutations_permitted: true, logger: Logger.new(log))

        request = lambda do |method, params = {}, legacy: false|
          headers = {}
          unless legacy
            params = params.merge("_meta" => {"io.modelcontextprotocol/protocolVersion" => version})
            headers = {"HTTP_MCP_PROTOCOL_VERSION" => version, "HTTP_MCP_METHOD" => method}
            headers["HTTP_MCP_NAME"] = params[:name] if params[:name]
          end
          env = {
            "REQUEST_METHOD" => "POST",
            "SERVER_NAME" => "ractor#{index}.example.com",
            "rack.url_scheme" => "http",
            "rack.input" => StringIO.new(JSON.generate({jsonrpc: "2.0", id: index, method: method, params: params})),
            "HTTP_AUTHORIZATION" => "Bearer #{token}"
          }.merge(headers)
          status, _, body = server.call(env)
          [status, JSON.parse(body.join)]
        end

        {
          discover: request.call("server/discover"),
          list: request.call("tools/list"),
          search: request.call("tools/call", {name: "search_workflows", arguments: {state: "ready", limit: "3"}}),
          pause: request.call("tools/call", {name: "pause_workflows", arguments: {workflow_ids: [4, 8]}}),
          refused: request.call("tools/call", {name: "get_workflow", arguments: {id: "nope"}}),
          legacy: request.call("initialize", {protocolVersion: "2025-06-18"}, legacy: true),
          log: log.string
        }
      end
    end

    ractors.each_with_index do |ractor, index|
      out = ractor.respond_to?(:value) ? ractor.value : ractor.take

      status, body = out[:discover]
      assert_equal 200, status
      assert_equal "workflows", body.dig("result", "_meta", "io.modelcontextprotocol/serverInfo", "name")

      assert_equal WorkflowsMCP::TOOLS.size, out[:list][1].dig("result", "tools").size

      workflows = out[:search][1].dig("result", "structuredContent", "workflows")
      assert_equal 3, workflows.size
      assert_equal "http://ractor#{index}.example.com/admin/workflows/#{workflows.first["id"]}", workflows.first["admin_url"]

      assert_equal 2, out[:pause][1].dig("result", "structuredContent", "paused")
      assert out[:refused][1].dig("result", "isError")
      assert_equal "2025-06-18", out[:legacy][1].dig("result", "protocolVersion")
      assert_includes out[:log], "tool=pause_workflows era=modern error=false"
    end
  ensure
    Warning[:experimental] = previous
  end
end
