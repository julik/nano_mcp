# frozen_string_literal: true

# rackup examples/config.ru, with WORKFLOWS_MCP_TOKEN set to 32 characters or more
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require_relative "workflows_mcp"
require "logger"

store = WorkflowsMCP::Store.seeded
server = WorkflowsMCP.server(
  store: store,
  token: ENV.fetch("WORKFLOWS_MCP_TOKEN"),
  mutations_permitted: ENV["WORKFLOWS_MCP_MUTATIONS"] == "1",
  logger: Logger.new($stderr)
)

map("/mcp") { run server }
