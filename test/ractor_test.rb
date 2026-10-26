# frozen_string_literal: true

require "test_helper"

# Smoke tests, not guarantees: a server has to answer from inside non-main Ractors,
# both when each Ractor builds its own and when one is built up front and shared
class RactorTest < Minitest::Test
  class Count < NanoMCP::Tool
    tool_name "count"

    def call
      3.times { |n| progress(n + 1, total: 3) }
      NanoMCP::Result.text("counted")
    end
  end

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

  def test_one_shareable_server_answers_from_several_ractors
    previous, Warning[:experimental] = Warning[:experimental], false

    # What a config.ru for a Ractor-based Rack server would do. The block may only refer
    # to shareable things, and the store is built per request because it holds a Mutex
    authenticate = nil.instance_eval do
      proc do |env, meta|
        next nil unless NanoMCP.token_matches?(NanoMCP.bearer_token(env), MCPRequests::TOKEN)
        WorkflowsMCP::Context.new(store: WorkflowsMCP::Store.seeded, base_url: "http://shared.example.com",
          identity: meta.dig("io.modelcontextprotocol/clientInfo", "name"), mutations_permitted: false)
      end
    end
    server = NanoMCP::Server.new(name: "shared", version: "1", tools: WorkflowsMCP::TOOLS, &authenticate)
    Ractor.make_shareable(server)
    assert Ractor.shareable?(server)

    ractors = 4.times.map do |index|
      Ractor.new(server, index, MCPRequests::TOKEN, NanoMCP::PROTOCOL_VERSION) do |server, index, token, version|
        params = {name: "get_server_status", _meta: {
          "io.modelcontextprotocol/protocolVersion" => version,
          "io.modelcontextprotocol/clientInfo" => {"name" => "client#{index}"}
        }}
        env = {
          "REQUEST_METHOD" => "POST",
          "rack.input" => StringIO.new(JSON.generate({jsonrpc: "2.0", id: index, method: "tools/call", params: params})),
          "HTTP_AUTHORIZATION" => "Bearer #{token}",
          "HTTP_MCP_PROTOCOL_VERSION" => version,
          "HTTP_MCP_METHOD" => "tools/call",
          "HTTP_MCP_NAME" => "get_server_status"
        }
        status, _, body = server.call(env)
        [status, JSON.parse(body.join)]
      end
    end

    ractors.each_with_index do |ractor, index|
      status, body = ractor.respond_to?(:value) ? ractor.value : ractor.take
      assert_equal 200, status
      assert_equal "client#{index}", body.dig("result", "structuredContent", "identity")
    end
  ensure
    Warning[:experimental] = previous
  end

  def test_one_shareable_server_streams_progress_from_several_ractors
    previous, Warning[:experimental] = Warning[:experimental], false

    authenticate = nil.instance_eval { proc { :anyone } }
    server = Ractor.make_shareable(NanoMCP::Server.new(name: "shared", version: "1", tools: [Count], &authenticate))

    ractors = 4.times.map do |index|
      Ractor.new(server, index) do |server, index|
        env = {
          "REQUEST_METHOD" => "POST",
          "rack.input" => StringIO.new(JSON.generate({jsonrpc: "2.0", id: index, method: "tools/call", params: {name: "count", _meta: {progressToken: "r#{index}"}}})),
          "HTTP_ACCEPT" => "text/event-stream"
        }
        status, headers, body = server.call(env)
        [status, headers["content-type"], body.each.to_a]
      end
    end

    ractors.each_with_index do |ractor, index|
      status, content_type, chunks = ractor.respond_to?(:value) ? ractor.value : ractor.take
      assert_equal 200, status
      assert_equal "text/event-stream", content_type
      messages = chunks.map { |chunk| JSON.parse(chunk.delete_prefix("event: message\ndata: ")) }
      assert_equal ["r#{index}"] * 3, messages[0..2].map { |m| m.dig("params", "progressToken") }
      assert_equal index, messages.last["id"]
    end
  ensure
    Warning[:experimental] = previous
  end

  def test_a_block_with_an_unshareable_self_says_so
    server = NanoMCP::Server.new(name: "x", version: "1", tools: []) { |env| env }
    error = assert_raises(Ractor::IsolationError) { Ractor.make_shareable(server) }
    assert_includes error.message, "self is not shareable"
  end
end
