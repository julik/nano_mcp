# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "nano_mcp"
require "rack/mock"
require "logger"
require "stringio"
require "minitest/autorun"
require_relative "../examples/workflows_mcp"

module MCPRequests
  TOKEN = "0123456789abcdef0123456789abcdef0123456789abcdef"
  VERSION = NanoMCP::PROTOCOL_VERSION

  def setup
    @log = StringIO.new
    @store = WorkflowsMCP::Store.seeded
  end

  def app
    @app ||= WorkflowsMCP.server(store: @store, token: TOKEN, logger: Logger.new(@log), **server_options)
  end

  def server_options = {}

  # A 2026-07-28 request, with all the headers a conforming client sends
  def modern(method, params = {}, version: VERSION, headers: {}, meta: {})
    body_params = params.merge("_meta" => {
      "io.modelcontextprotocol/protocolVersion" => version,
      "io.modelcontextprotocol/clientInfo" => {"name" => "TestClient", "version" => "1.0"},
      "io.modelcontextprotocol/clientCapabilities" => {}
    }.merge(meta))
    standard = {"HTTP_MCP_PROTOCOL_VERSION" => version, "HTTP_MCP_METHOD" => method}
    name = params[:name] || params["name"]
    standard["HTTP_MCP_NAME"] = name if name
    post({jsonrpc: "2.0", id: 1, method: method, params: body_params}, standard.merge(headers))
  end

  # A request from a client of 2025-11-25 or earlier, which never sends _meta
  def legacy(method, params = {}, headers: {})
    post({jsonrpc: "2.0", id: 1, method: method, params: params}, headers)
  end

  def post(body, headers = {})
    raw = body.is_a?(String) ? body : JSON.generate(body)
    env = Rack::MockRequest.env_for("http://mcp.example.com/mcp",
      {:method => "POST", :input => raw, "CONTENT_TYPE" => "application/json",
       "HTTP_AUTHORIZATION" => "Bearer #{TOKEN}"}.merge(headers))
    @status, @headers, chunks = app.call(env)
    @body = chunks.each.to_a.join
    @status
  end

  def json = JSON.parse(@body)

  def result = json.fetch("result")

  def error = json.fetch("error")

  # The messages of an event stream body, in order
  def events
    @body.split("\n\n").map do |event|
      assert event.start_with?("event: message\ndata: "), "Not an SSE message event: #{event.inspect}"
      JSON.parse(event.delete_prefix("event: message\ndata: "))
    end
  end

  def call_tool(name, arguments = {})
    modern("tools/call", {name: name, arguments: arguments})
  end
end
