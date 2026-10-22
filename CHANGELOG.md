# Changelog

## 0.1.0

Initial release, extracted from the MCP servers in geneva_drive_admin and Comptoir.

- `NanoMCP::Server`, a Rack app serving tools over stateless Streamable HTTP per MCP revision 2026-07-28,
  which also answers clients of 2025-11-25 and earlier
- `NanoMCP::Tool` and `NanoMCP::Result` for writing tools, with argument checking against the input schema
- `NanoMCP.bearer_token` and `NanoMCP.token_matches?` for token authentication
- Servers and tools work from non-main Ractors, and a server can be made shareable between them
