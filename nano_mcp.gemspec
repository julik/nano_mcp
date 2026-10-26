# frozen_string_literal: true

require_relative "lib/nano_mcp/version"

Gem::Specification.new do |spec|
  spec.name = "nano_mcp"
  spec.version = NanoMCP::VERSION
  spec.authors = ["Julik Tarkhanov"]
  spec.email = ["me@julik.nl"]
  spec.license = "MIT"
  spec.summary = "A (slightly unhinged) library for building small MCPs"
  spec.description = "A Rack app serving MCP tools over stateless Streamable HTTP, per MCP revision 2026-07-28. No sessions, no GET stream, no dependencies."
  spec.homepage = "https://github.com/julik/nano_mcp"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  # No runtime dependencies, on purpose: this gem sits underneath other gems
  spec.add_development_dependency "logger", "~> 1.6"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rack", ">= 2.2", "< 4"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "standard", "~> 1.50"
end
