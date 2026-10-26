# Changelog

## 0.3.0

- `Tool#progress` sends `notifications/progress` while a tool runs. A `tools/call` carrying a
  `progressToken` from a client that accepts `text/event-stream` is answered as an event stream:
  the progress, then the response. Anything else is answered exactly as before, and `#progress`
  does nothing.

## 0.2.0

- `Result.json` without a `summary:` now puts a line like "12 workflows in structuredContent."
  in the text block for current clients, rather than the data again as JSON. This changes what
  an existing call sends, which the compatibility rules in the README say we don't do - but both
  apps using nano_mcp were working around the old behaviour, so it changes now rather than never.
- `Server.new` takes `on_call:`, which hears about every tool call, for audit logging.
- `Tool.annotations` set on a base class apply to its subclasses.

## 0.1.0

Initial release, extracted from the MCP servers in geneva_drive_admin and Comptoir.

- `NanoMCP::Server`, a Rack app serving tools over stateless Streamable HTTP per MCP revision 2026-07-28,
  which also answers clients of 2025-11-25 and earlier
- `NanoMCP::Tool` and `NanoMCP::Result` for writing tools, with argument checking against the input schema
- `NanoMCP.bearer_token` and `NanoMCP.token_matches?` for token authentication
- Servers and tools work from non-main Ractors, and a server can be made shareable between them
