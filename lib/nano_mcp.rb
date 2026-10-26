# frozen_string_literal: true

require "json"
require "openssl"
require "time"

# A Rack app serving MCP tools over stateless Streamable HTTP.
#
# The public API is what this file, NanoMCP::Tool, NanoMCP::Result and NanoMCP::Server
# document. Anything else - including any constant marked private - can change in any release.
module NanoMCP
  # The MCP revision this library is written against
  PROTOCOL_VERSION = "2026-07-28"

  # A configured token shorter than this never matches - see {.token_matches?}
  MINIMUM_TOKEN_LENGTH = 32

  class Error < StandardError
  end

  # Raise from a tool to refuse or fail in a way the agent can act on. It goes back
  # as a tool result with `isError` set and the message as its text, not as a JSON-RPC error.
  class ToolError < Error
  end

  # The bearer token from a Rack env, or nil when there is none.
  #
  # @param env [Hash] the Rack env
  # @return [String, nil]
  def self.bearer_token(env)
    token = env["HTTP_AUTHORIZATION"].to_s[/\ABearer +(.+)\z/i, 1].to_s.strip
    token.empty? ? nil : token
  end

  # Whether a presented token is the configured one. Both are hashed before comparing,
  # so the comparison takes the same time whatever they are. A configured token shorter
  # than MINIMUM_TOKEN_LENGTH matches nothing.
  #
  # @param presented [String, nil] what the caller sent
  # @param configured [String, nil] what you expect
  # @return [Boolean]
  def self.token_matches?(presented, configured)
    return false if presented.nil? || configured.nil?
    return false if configured.to_s.length < MINIMUM_TOKEN_LENGTH
    # Not OpenSSL::Digest::SHA256: its methods come from define_method, and those
    # cannot be called from a Ractor other than the one that loaded them
    OpenSSL.fixed_length_secure_compare(
      OpenSSL::Digest.digest("SHA256", presented.to_s),
      OpenSSL::Digest.digest("SHA256", configured.to_s)
    )
  end
end

require_relative "nano_mcp/version"
require_relative "nano_mcp/arguments"
require_relative "nano_mcp/result"
require_relative "nano_mcp/tool"
require_relative "nano_mcp/server"
