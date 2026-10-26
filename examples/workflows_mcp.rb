# frozen_string_literal: true

# A small cousin of geneva_drive_admin's MCP server, over an in-memory store of
# workflows instead of a database. It exercises what the real ones need from nano_mcp:
# a token, a context per request, cursor pagination, prose and structured answers,
# mutations behind a gate that also changes what tools/list says, and progress.
#
# Run it with `rackup examples/config.ru` and point a client at http://localhost:9292/mcp
require "nano_mcp"

module WorkflowsMCP
  STATES = %w[ready performing paused finished canceled].freeze
  MAX_BATCH = 100

  Workflow = Struct.new(:id, :type, :state, :hero)

  class Store
    def initialize(workflows = [])
      @workflows = workflows.to_h { |workflow| [workflow.id, workflow] }
      @mutex = Mutex.new
    end

    def self.seeded
      types = %w[InvoiceWorkflow OnboardingWorkflow]
      new((1..250).map { |id| Workflow.new(id: id, type: types[id % 2], state: STATES[id % 4], hero: "Account/#{id * 7}") })
    end

    def find(id) = @workflows[id]

    def where(type: nil, state: nil, before: nil)
      @workflows.values
        .select { |w| (type.nil? || w.type == type) && (state.nil? || w.state == state) && (before.nil? || w.id < before) }
        .sort_by { |w| -w.id }
    end

    def counts
      @workflows.values.group_by(&:type).transform_values { |ws| ws.map(&:state).tally }
    end

    def update_state(id, state)
      @mutex.synchronize { @workflows[id]&.state = state }
    end
  end

  # What every tool sees for one request
  Context = Struct.new(:store, :identity, :mutations_permitted, :base_url) do
    def workflow_url(id) = "#{base_url}/admin/workflows/#{id}"
  end

  # The house base class, like GenevaDrive::Admin::MCP::Tool: the mutation gate lives
  # in one place, in #invoke, so no mutating tool can forget it
  class Tool < NanoMCP::Tool
    annotations readOnlyHint: true, openWorldHint: false

    def self.mutating(destructive: false)
      @mutating = true
      annotations(readOnlyHint: false, destructiveHint: destructive, idempotentHint: true, openWorldHint: false)
    end

    def self.mutating? = !!@mutating

    def self.descriptor(context)
      entry = super
      if mutating? && !context.mutations_permitted
        entry[:description] += "\n\nCURRENTLY DISABLED: mutations are turned off for you. Calling this will explain how to enable them."
      end
      entry
    end

    def invoke(arguments)
      if self.class.mutating? && !context.mutations_permitted
        return NanoMCP::Result.error("Refused: mutations are disabled on this server, so #{self.class.tool_name} did nothing. " \
          "An operator can enable them with WORKFLOWS_MCP_MUTATIONS=1.")
      end
      super
    end

    private

    def serialize(workflow)
      workflow.to_h.merge(admin_url: context.workflow_url(workflow.id))
    end

    def find!(id)
      context.store.find(id) || raise(NanoMCP::ToolError, "No workflow with id #{id}")
    end
  end

  module Tools
    class GetServerStatus < Tool
      tool_name "get_server_status"
      title "Server status"
      description "What this installation supports and whether you may mutate. Call this first."

      def call
        NanoMCP::Result.json({
          workflow_states: STATES,
          mutations_permitted: !!context.mutations_permitted,
          max_mutation_batch: MAX_BATCH,
          identity: context.identity
        })
      end
    end

    class GetWorkflowCounts < Tool
      tool_name "get_workflow_counts"
      title "Workflow counts"
      description "Workflow counts per type and state"

      def call
        NanoMCP::Result.json(context.store.counts, summary: "Counts per type and state in structuredContent.")
      end
    end

    class SearchWorkflows < Tool
      tool_name "search_workflows"
      title "Search workflows"
      description <<~TEXT
        Workflows newest first, filtered by type and state. Pass `next_cursor` back as
        `cursor` for the next page.
      TEXT
      input_schema(
        properties: {
          type: {type: "string", maxLength: 200, description: "Workflow class name"},
          state: {type: "string", enum: STATES},
          limit: {type: "integer", minimum: 1, maximum: 100, default: 20},
          cursor: {type: "string", maxLength: 64, description: "next_cursor from a previous page"}
        }
      )

      def call(limit:, type: nil, state: nil, cursor: nil)
        rows = context.store.where(type: type, state: state, before: decode_cursor(cursor))
        page = rows.first(limit)
        next_cursor = (rows.length > limit) ? [page.last.id.to_s].pack("m0") : nil
        NanoMCP::Result.json(
          {workflows: page.map { |w| serialize(w) }, next_cursor: next_cursor}.compact,
          summary: "#{page.length} workflows#{", more available (pass next_cursor)" if next_cursor}."
        )
      end

      private

      def decode_cursor(cursor)
        return nil if cursor.nil?
        decoded = cursor.unpack1("m0")
        raise ArgumentError unless /\A\d+\z/.match?(decoded)
        decoded.to_i
      rescue ArgumentError
        raise NanoMCP::ToolError, "Malformed cursor #{cursor.inspect}. Pass back next_cursor exactly, or omit it."
      end
    end

    class GetWorkflow < Tool
      tool_name "get_workflow"
      title "Get workflow"
      description "One workflow by id"
      input_schema properties: {id: {type: "integer", minimum: 1}}, required: ["id"]

      def call(id:)
        NanoMCP::Result.json(serialize(find!(id)))
      end
    end

    class WorkflowDocs < Tool
      tool_name "workflow_docs"
      title "Workflow concepts"
      description "Explains workflow states. Read this before drawing conclusions from a state."
      input_schema properties: {topic: {type: "string", enum: %w[states signals]}}, required: ["topic"]

      TOPICS = {
        "states" => "`paused` is a deliberate safety valve, not a crash. `ready` is idle between steps, and healthy.",
        "signals" => "A step waiting on a signal can sit in `waiting` indefinitely, and legitimately."
      }.freeze

      def call(topic:)
        NanoMCP::Result.text(TOPICS.fetch(topic))
      end
    end

    class PauseWorkflows < Tool
      tool_name "pause_workflows"
      title "Pause workflows"
      description "Pause workflows by id. Only `ready` and `performing` workflows can be paused."
      input_schema(
        properties: {
          workflow_ids: {type: "array", items: {type: "integer"}, minItems: 1, maxItems: MAX_BATCH},
          reason: {type: "string", maxLength: 500}
        },
        required: ["workflow_ids"]
      )
      mutating

      def call(workflow_ids:, reason: nil)
        ids = workflow_ids.uniq
        outcomes = ids.each_with_index.map do |id, index|
          progress(index, total: ids.length, message: "Pausing workflow #{id}")
          workflow = context.store.find(id)
          next {id: id, outcome: "not_found"} unless workflow
          next {id: id, outcome: "skipped", state: workflow.state} unless %w[ready performing].include?(workflow.state)
          context.store.update_state(id, "paused")
          {id: id, outcome: "paused", state: "paused"}
        end
        progress(ids.length, total: ids.length)
        paused = outcomes.count { |o| o[:outcome] == "paused" }
        NanoMCP::Result.json({paused: paused, outcomes: outcomes}, summary: "Paused #{paused} of #{outcomes.length}.")
      end
    end

    class Explode < Tool
      tool_name "explode"
      description "Always raises, for checking that internals stay out of the transcript"

      def call
        raise "secret row data"
      end
    end
  end

  INSTRUCTIONS = <<~TEXT
    This server exposes workflows. `paused` is a deliberate safety valve, not a crash.
    Call `get_server_status` first.
  TEXT

  TOOLS = [
    Tools::GetServerStatus,
    Tools::GetWorkflowCounts,
    Tools::SearchWorkflows,
    Tools::GetWorkflow,
    Tools::WorkflowDocs,
    Tools::PauseWorkflows,
    Tools::Explode
  ].freeze

  # Cheap enough to build per request, which is how a host that reads its settings
  # at runtime would do it
  def self.server(store:, token:, mutations_permitted: false, logger: nil, allowed_origins: [])
    NanoMCP::Server.new(
      name: "workflows",
      title: "Workflows example (#{ENV.fetch("RACK_ENV", "development")})",
      version: NanoMCP::VERSION,
      instructions: INSTRUCTIONS,
      tools: TOOLS,
      allowed_origins: allowed_origins,
      logger: logger
    ) do |env, meta|
      next nil unless NanoMCP.token_matches?(NanoMCP.bearer_token(env), token)
      scheme = env["HTTP_X_FORWARDED_PROTO"] || env["rack.url_scheme"]
      client = meta.dig("io.modelcontextprotocol/clientInfo", "name") || "unknown client"
      Context.new(store: store, identity: "token via #{client}", mutations_permitted: mutations_permitted, base_url: "#{scheme}://#{env["HTTP_HOST"] || env["SERVER_NAME"]}")
    end
  end
end
