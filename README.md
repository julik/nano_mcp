# nano_mcp

A (slightly unhinged) library for building small MCPs.

> [!IMPORTANT]
> **This gem is for my own private use.** It is public so that my other gems can depend on it,
> not because I am looking to support it for anyone else. It sits underneath several of my
> gems and apps at once - a diamond dependency - and that comes with **strict
> backwards-compatibility constraints**:
>
> - The public API is the short list under [Public API](#public-api), and nothing else.
> - Within a major version that list only ever grows. Nothing on it gets renamed, removed or
>   changes meaning.
> - Anything not on the list - private constants, the log line format, error message wording -
>   can change in any release.
> - Feature requests that grow the surface will most likely be declined. Bug reports are welcome.
>
> If you need something bigger, use [the official Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk).

## What it is

A Rack app that serves [MCP](https://modelcontextprotocol.io) tools over Streamable HTTP, written
against the **stateless** revision of the spec, [2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28).
It has:

- no sessions, no SSE, no GET stream - every request is one POST, and any process can serve it
- no runtime dependencies - not even Rack, only `json` and `openssl` from the standard library
- tools only - no resources, prompts, sampling or elicitation

Clients of revision 2025-11-25 and earlier open with `initialize` instead of putting the protocol
version in every request. They get answered the way they expect, from the same endpoint, but still
without a session.

## Installation

```ruby
gem "nano_mcp"
```

## Usage

A tool is a class with a name, a description, an input schema and a `#call`:

```ruby
class GetWorkflow < NanoMCP::Tool
  tool_name "get_workflow"
  title "Get workflow"
  description "One workflow by id, with its state and hero"
  input_schema properties: {id: {type: "integer", minimum: 1}}, required: ["id"]
  annotations readOnlyHint: true, openWorldHint: false

  def call(id:)
    workflow = context.store.find(id) or raise NanoMCP::ToolError, "No workflow with id #{id}"
    NanoMCP::Result.json(workflow.to_h)
  end
end
```

A server is a Rack app with a list of tools and a block that authenticates. The block gets the Rack
env and the request's `_meta`, and returns whatever your tools should see as `context`, or `nil` to
refuse with a 401:

```ruby
MCP_SERVER = NanoMCP::Server.new(
  name: "workflows",
  title: "Workflows on #{Rails.application.class.module_parent_name} (#{Rails.env})",
  version: MyGem::VERSION,
  instructions: "Read this before drawing conclusions: `paused` is not a crash...",
  tools: [GetWorkflow, SearchWorkflows],
  logger: Rails.logger
) do |env, meta|
  key = ApiToken.find_by(token: NanoMCP.bearer_token(env))
  next if key.nil? || key.expired?
  MyContext.new(user: key.user, client: meta.dig("io.modelcontextprotocol/clientInfo", "name"))
end
```

The context is how tools know who is calling: whatever the block returns is `context` in every tool
for that request, and nano_mcp never looks inside it. Copy into it anything from the request that
tools need. They don't see the Rack env themselves.

`_meta` is the hash as the client sent it, with string keys. A current client sends its name and
capabilities in it on every request. An older client sends them only once, in `initialize`, so for
its tool calls `_meta` is usually empty. A lambda taking only `env` works too.

Mount it:

```ruby
# config/routes.rb
mount MCP_SERVER => "/mcp"
```

or run it from a `config.ru`. See [examples/](examples) for a complete server, which the tests drive.

### Results

`#call` returns a `NanoMCP::Result`:

- `Result.text(string)` - prose
- `Result.json(value, summary: nil)` - structured data. A current client gets it as
  `structuredContent`, next to a text block holding `summary`, or a line like "12 workflows in
  structuredContent." if you gave none. An older client gets the JSON in the text block.

  The spec suggests repeating the data as JSON in the text block. We don't: a client on the
  current revision reads `structuredContent`, and a second copy of a large answer just fills the
  agent's context window.
- `Result.error(message)` - a refusal the agent should read. Raising `NanoMCP::ToolError` does the same.

Bad arguments come back as error results too, worded so an agent can fix its call. Any other
exception becomes a JSON-RPC internal error that names the exception class. The message stays in
your logs, since it may carry your data.

### Arguments

Arguments are checked against `input_schema` before `#call` sees them, and passed as keywords.
The checker handles the top level of the schema: `type`, `required`, `enum`, `minimum`, `maximum`,
`minLength`, `maxLength`, `minItems`, `maxItems`, `items` and `default`. Unknown arguments are
refused, and the schema sent to clients says `additionalProperties: false` to match. Integers sent
as strings are accepted, because agents do that. A number over `maximum` is clamped down to it rather than refused.

### Wrapping every tool

There are two hooks for house rules, both meant to be overridden in your own base class:

```ruby
class MyTool < NanoMCP::Tool
  # Every tool of ours unless it says otherwise - annotations are inherited
  annotations readOnlyHint: true, openWorldHint: false

  def self.mutating
    @mutating = true
    annotations readOnlyHint: false, destructiveHint: false, openWorldHint: false
  end

  def self.mutating? = !!@mutating

  # Around every call: permission gates, log tags, timeouts
  def invoke(arguments)
    if self.class.mutating? && !context.mutations_permitted?
      return NanoMCP::Result.error("Refused: mutations are disabled on this server")
    end
    Rails.logger.tagged("mcp_tool=#{self.class.tool_name}") { super }
  end

  # The tools/list entry, per caller
  def self.descriptor(context)
    entry = super
    entry[:description] += "\n\nDISABLED for you" if mutating? && !context.mutations_permitted?
    entry
  end
end

class PauseWorkflows < MyTool
  tool_name "pause_workflows"
  mutating
  # ...
end
```

### Ractors

A server works from non-main Ractors in two ways, and the test suite checks both.

**One server per Ractor.** Build it inside the Ractor, and anything goes: any block, any logger.

**One server shared by every Ractor**, which is what a Ractor-based Rack server loading a
`config.ru` would want. The server's own state is all frozen, so `Ractor.make_shareable` works on it
as long as the two things you hand it are shareable too:

- The block has to be a shareable proc. A block written in `config.ru` has the Rack builder as its
  `self`, which is not shareable, so create it with a `nil` self instead. It may only refer to
  shareable things, such as frozen constants.
- The logger has to be shareable or left out. A standard `Logger` is not, and freezing it breaks it.

```ruby
# Ruby 4.0
authenticate = Ractor.shareable_proc { |env, meta| ... }
# Ruby 3.2 and up
authenticate = nil.instance_eval { proc { |env, meta| ... } }

run Ractor.make_shareable(NanoMCP::Server.new(name: "workflows", version: "1", tools: TOOLS, &authenticate))
```

Tool classes store whatever you set on them as frozen copies, so they can be read from any Ractor.

### Things the server does not do for you

The server stays small by leaving these to the host:

- **Turning it off.** Wrap it: `->(env) { enabled? ? MCP_SERVER.call(env) : [404, {}, []] }`.
- **Pretending to be absent.** To answer 404 rather than 401 to a caller without a token, check the
  token in a wrapper like the one above.
- **Building the server from runtime settings.** Constructing one is cheap, so build it per request
  if its instructions or tools depend on configuration.
- **Logging arguments.** The log line per call has the tool, era, error flag, size and duration.
  Arguments are left out because they may carry secrets. For an audit trail, see `on_call` below.

### Auditing calls

Pass `on_call:` and it gets a frozen Hash after every tool call, including ones that raised:

```ruby
on_call: ->(event) do
  Rails.logger.info "mcp tool=#{event[:tool]} caller=#{event[:context].user.email} error=#{event[:error]}"
end
```

The keys are `tool`, `era` (`"modern"` or `"legacy"`), `context` (what your block returned),
`arguments` (as they came off the wire), `error`, `bytes` (of the response, nil if the tool
raised), `duration_ms` and `exception` (nil unless the tool raised). With an `on_call` the logger no longer gets a line per call, since yours replaces it.
An `on_call` that raises is logged and otherwise ignored. It runs after the tool, so it can't wrap the tool's own logging -
put log tags in `#invoke` for that.

## Public API

This is all of it. Everything else is private, whatever Ruby visibility it happens to have.

- `NanoMCP::VERSION`, `NanoMCP::PROTOCOL_VERSION`, `NanoMCP::MINIMUM_TOKEN_LENGTH`
- `NanoMCP.bearer_token(env)`, `NanoMCP.token_matches?(presented, configured)`
- `NanoMCP::Error`, `NanoMCP::ToolError`
- `NanoMCP::Tool`: class methods `tool_name`, `title`, `description`, `input_schema`, `annotations`,
  `descriptor(context)`. Instance methods `#initialize(context)`, `#context`, `#invoke(arguments)`, `#call(**)`
- `NanoMCP::Result`: `.text`, `.json`, `.error`, `#text`, `#structured`, `#error?`
- `NanoMCP::Server`: `.new(name:, version:, tools:, title:, instructions:, allowed_origins:, logger:, on_call:, &authenticate)` and `#call(env)`.
  The block is called with `(env, meta)`

## Protocol behaviour

| | 2026-07-28 (`_meta` in every request) | 2025-11-25 and earlier (`initialize`) |
|-|-|-|
| Handshake | `server/discover`, optional | `initialize`, answered and forgotten |
| Version | checked on every request, 400 + `-32022` if unsupported | negotiated in `initialize` |
| `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` | required, must match the body (400 + `-32020`) | ignored |
| Unknown method | 404 + `-32601` | 200 + `-32601` |
| `ping` | gone | `{}` |
| Results | `resultType: "complete"`, `ttlMs`/`cacheScope` on lists | plain |
| Structured results | `structuredContent` plus a text block | JSON in a text block |

In both eras:

- GET, DELETE and other verbs get a 405.
- No session id is ever issued.
- A notification gets an empty 202.
- Batches are refused.
- A request with an `Origin` header is refused with a 403 unless that origin is in
  `allowed_origins`. MCP clients don't send `Origin`, browsers do. Comparing it against the
  server's own host would not help: after a DNS rebind, the attacker's page sends its own name in both.
- Bodies over 1MB get a 413. Responses over 1MB are truncated, with a note saying so.

## Development

```
bundle install
bundle exec rake          # tests and standard
WORKFLOWS_MCP_TOKEN=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(32)') rackup examples/config.ru
```

## License

MIT
