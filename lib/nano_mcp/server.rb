# frozen_string_literal: true

module NanoMCP
  # The MCP endpoint, as a Rack app. Mount it wherever you like:
  #
  #   SERVER = NanoMCP::Server.new(name: "comptoir", version: "1", tools: [ListSnapshots]) do |env|
  #     Context.new(...) if NanoMCP.token_matches?(NanoMCP.bearer_token(env), ENV["MCP_TOKEN"])
  #   end
  #   mount SERVER => "/mcp"
  #
  # Stateless all the way down: no sessions, no GET stream, nothing remembered between
  # requests, so any process can answer any request. It speaks revision 2026-07-28,
  # where every request carries its own protocol version in `_meta`. A client of
  # 2025-11-25 or earlier opens with `initialize` instead, and gets answered the way
  # those revisions expect - minus the session, which they never strictly needed.
  #
  # The block authenticates. It receives the Rack env and the request's `_meta`, and
  # returns the context every tool in this request gets, or nil/false to refuse the
  # request with a 401. A block that raises refuses too.
  #
  # `_meta` is the hash as the client sent it, string keys and all. A current client
  # puts its identity there on every request, under "io.modelcontextprotocol/clientInfo".
  # An older one sends it only once, in `initialize`, so for its tool calls `_meta`
  # is usually empty.
  class Server
    MODERN_VERSIONS = [PROTOCOL_VERSION].freeze
    LEGACY_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"].freeze

    META_PROTOCOL_VERSION = "io.modelcontextprotocol/protocolVersion"
    META_SERVER_INFO = "io.modelcontextprotocol/serverInfo"

    PARSE_ERROR = -32700
    INVALID_REQUEST = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS = -32602
    INTERNAL_ERROR = -32603
    UNAUTHORIZED = -32001
    HEADER_MISMATCH = -32020
    UNSUPPORTED_PROTOCOL_VERSION = -32022

    # How long a client may cache the tool list. It only changes on a deploy, and
    # "private" because it may vary with the caller
    TOOL_LIST_TTL_MS = 300_000
    CACHE_SCOPE = "private"

    MAX_REQUEST_BYTES = 1_000_000
    MAX_RESPONSE_BYTES = 1_000_000

    BASE64_SENTINEL = /\A=\?base64\?(.*)\?=\z/m

    # Methods whose `Mcp-Name` header mirrors a body param
    NAMED_METHODS = {"tools/call" => "name", "prompts/get" => "name", "resources/read" => "uri"}.freeze

    # The body has no `to_ary`, so Rack::ContentLength and Rack 3's Rack::ETag leave it alone,
    # and the server sends it as it comes. `last-modified` gets added per response
    STREAM_HEADERS = {
      "content-type" => "text/event-stream",
      # no-transform makes Rack::Deflater and compressing proxies leave us be. `content-encoding:
      # identity` does not, Deflater gzips those just the same
      "cache-control" => "no-cache, no-store, no-transform",
      "x-accel-buffering" => "no" # nginx and the Google load balancer
    }.freeze

    private_constant(*constants)

    class ProtocolError < StandardError
      attr_reader :code, :status, :data

      def initialize(message, code:, status: 200, data: nil)
        super(message)
        @code = code
        @status = status
        @data = data
      end
    end
    private_constant :ProtocolError

    # The body of a tools/call answered as an event stream: the progress notifications
    # as the tool sends them, then the response, then the end. Still stateless - no event
    # ids, nothing to resume. The tool runs inside #each, on the thread the Rack server
    # iterates the body on, so it holds what one call needs and nothing outlives it
    class ProgressStream
      def initialize(token, &respond)
        @token = token
        @respond = respond
      end

      def each(&write)
        return enum_for(:each) unless block_given?
        @write = write
        response = @respond.call(self)
        write.call(event(response))
      ensure
        @write = nil
      end

      def progress(progress, total, message)
        return unless @write
        return if @last_progress && progress <= @last_progress
        @last_progress = progress
        params = {progressToken: @token, progress: progress, total: total, message: message}.compact
        @write.call(event({jsonrpc: "2.0", method: "notifications/progress", params: params}))
      end

      private

      # JSON.generate escapes newlines, so the payload always fits on one data line
      def event(message)
        "event: message\ndata: #{JSON.generate(message)}\n\n"
      end
    end
    private_constant :ProgressStream

    # @param name [String] `serverInfo.name`, which clients key on - keep it fixed
    # @param version [String] `serverInfo.version`
    # @param tools [Array<Class>] NanoMCP::Tool subclasses, listed in this order
    # @param title [String, nil] `serverInfo.title` - say which app and environment this is
    # @param instructions [String, nil] handed to the client up front, usually ends up in the system prompt
    # @param allowed_origins [Array<String>] browser origins allowed to call, none by default
    # @param logger [Logger, nil] gets every internal error, and a line per tool call unless there is an `on_call`
    # @param on_call [#call, nil] receives a frozen Hash after every tool call - see the README
    # @yieldparam env [Hash] the Rack env
    # @yieldparam meta [Hash] the request's `params._meta`, empty when there is none
    # @yieldreturn [Object, nil] the tool context, or nil/false to refuse with a 401
    def initialize(name:, version:, tools:, title: nil, instructions: nil, allowed_origins: [], logger: nil, on_call: nil, &authenticate)
      raise ArgumentError, "Pass a block which authenticates the request and returns the tool context, or nil to refuse" unless authenticate

      @name = name.to_s
      @version = version.to_s
      @title = title&.to_s
      @instructions = instructions&.to_s
      @allowed_origins = Array(allowed_origins).map(&:to_s)
      @logger = logger
      @on_call = on_call
      @authenticate = authenticate
      @tools = tools.each_with_object({}) do |tool, by_name|
        raise ArgumentError, "#{tool.inspect} is not a NanoMCP::Tool subclass" unless tool.is_a?(Class) && tool < Tool
        tool_name = tool.tool_name.to_s
        raise ArgumentError, "#{tool} has no tool_name" if tool_name.empty?
        raise ArgumentError, "Two tools are named #{tool_name}" if by_name.key?(tool_name)
        by_name[tool_name] = tool
      end.freeze
    end

    # @param env [Hash] the Rack env
    # @return [Array] a Rack response
    def call(env)
      # GET opened a stream and DELETE ended a session in older revisions. The current
      # one tells a server with neither to answer exactly this
      unless env["REQUEST_METHOD"] == "POST"
        return respond(405, error_body(nil, METHOD_NOT_FOUND, "This MCP server is stateless and POST-only. POST JSON-RPC requests to this same URL."), "allow" => "POST")
      end

      # Required by the transport to defeat DNS rebinding. MCP clients send no Origin
      unless origin_permitted?(env["HTTP_ORIGIN"])
        return respond(403, error_body(nil, INVALID_REQUEST, "Origin not allowed"))
      end

      # Read before authenticating, since the block gets the request's _meta - but
      # answered after, so a caller without a token learns nothing from its body
      body = read_body(env)
      request = begin
        body && JSON.parse(body)
      rescue JSON::ParserError
        :unparseable
      end

      context = authenticate(env, request_meta(request))
      unless context
        return respond(401, error_body(nil, UNAUTHORIZED, "Unauthorized: send a valid bearer token in the Authorization header"),
          "www-authenticate" => %(Bearer realm="#{@name}"))
      end

      return respond(413, error_body(nil, INVALID_REQUEST, "Request body over #{MAX_REQUEST_BYTES} bytes")) unless body
      return respond(400, error_body(nil, PARSE_ERROR, "Parse error: body is not valid JSON")) if request == :unparseable

      status, payload = handle(request, env, context)
      case payload
      when nil then [status, {}, []]
      # Rack 2's Rack::ETag buffers any body to hash it, unless there already is a last-modified
      when ProgressStream then [status, STREAM_HEADERS.merge("last-modified" => Time.now.httpdate), payload]
      else respond(status, payload)
      end
    end

    private

    def handle(request, env, context)
      return [400, error_body(nil, INVALID_REQUEST, "Batches are not supported, send one JSON-RPC request per POST")] if request.is_a?(Array)
      return [400, error_body(nil, INVALID_REQUEST, "Request must be a JSON object")] unless request.is_a?(Hash)

      id = request["id"]
      method = request["method"]
      params = request.fetch("params", nil) || {}
      return [400, error_body(id, INVALID_REQUEST, "Request has no method")] unless method.is_a?(String)
      return [400, error_body(id, INVALID_REQUEST, "params must be an object")] unless params.is_a?(Hash)

      # A notification. None of them need anything from us
      return [202, nil] unless request.key?("id")

      modern = modern?(method, params, env)
      validate_modern_request!(method, params, env) if modern

      # Everything that can be refused with a real status has been by now, and the
      # tool lookup goes first too. Past this point we owe the client a 200 stream
      if method == "tools/call" && (token = progress_token(params)) && accepts_event_stream?(env)
        tool = find_tool!(params)
        stream = ProgressStream.new(token) do |progress_stream|
          success_body(id, call_tool(tool, params, context, modern, progress_stream), modern)
        rescue => e
          internal_error_body(id, method, e)
        end
        return [200, stream]
      end

      [200, success_body(id, dispatch(method, params, context, modern), modern)]
    rescue ProtocolError => e
      [e.status, error_body(id, e.code, e.message, e.data)]
    rescue => e
      [200, internal_error_body(id, method, e)]
    end

    def success_body(id, result, modern)
      result[:resultType] = "complete" if modern
      {jsonrpc: "2.0", id: id, result: result}
    end

    def internal_error_body(id, method, e)
      log(:error) { "#{method} raised #{e.class}: #{e.message}\n#{Array(e.backtrace).first(10).join("\n")}" }
      # The message may carry the host's data, so it stays in the host's logs
      error_body(id, INTERNAL_ERROR, "Internal error (#{e.class}). See the server logs.")
    end

    # Both eras send it in `_meta`, and the spec allows a string or an integer
    def progress_token(params)
      meta = params["_meta"]
      token = meta.is_a?(Hash) ? meta["progressToken"] : nil
      (token.is_a?(String) || token.is_a?(Integer)) ? token : nil
    end

    def accepts_event_stream?(env)
      env["HTTP_ACCEPT"].to_s.split(",").any? { |type| type.split(";").first.to_s.strip.casecmp?("text/event-stream") }
    end

    # The spec's rule for serving both eras: `initialize` always selects the old one,
    # and per-request `_meta` the new one. A modern header with no `_meta` is a broken
    # modern request rather than an old one, and gets told so
    def modern?(method, params, env)
      return false if method == "initialize"
      !meta_version(params).nil? || MODERN_VERSIONS.include?(env["HTTP_MCP_PROTOCOL_VERSION"])
    end

    def request_meta(request)
      params = request.is_a?(Hash) ? request["params"] : nil
      meta = params.is_a?(Hash) ? params["_meta"] : nil
      meta.is_a?(Hash) ? meta.freeze : {}.freeze
    end

    def meta_version(params)
      meta = params["_meta"]
      meta.is_a?(Hash) ? meta[META_PROTOCOL_VERSION] : nil
    end

    # The headers mirror the body so a load balancer can route without parsing it.
    # That only holds if both say the same, so anything that disagrees is refused
    def validate_modern_request!(method, params, env)
      version = meta_version(params)
      if version.nil?
        raise ProtocolError.new("Header mismatch: request has no _meta[#{META_PROTOCOL_VERSION}]", code: HEADER_MISMATCH, status: 400)
      end
      unless MODERN_VERSIONS.include?(version)
        raise ProtocolError.new("Unsupported protocol version: #{version}",
          code: UNSUPPORTED_PROTOCOL_VERSION, status: 400,
          data: {supported: MODERN_VERSIONS + LEGACY_VERSIONS, requested: version})
      end

      header_matches!("MCP-Protocol-Version", env["HTTP_MCP_PROTOCOL_VERSION"], version)
      header_matches!("Mcp-Method", env["HTTP_MCP_METHOD"], method)
      if (param = NAMED_METHODS[method]) && params.key?(param)
        header_matches!("Mcp-Name", decode_header(env["HTTP_MCP_NAME"]), params[param].to_s)
      end
    end

    def header_matches!(header_name, header_value, body_value)
      if header_value.nil?
        raise ProtocolError.new("Header mismatch: #{header_name} header is required", code: HEADER_MISMATCH, status: 400)
      end
      return if header_value == body_value
      raise ProtocolError.new("Header mismatch: #{header_name} header value #{header_value.inspect} does not match body value #{body_value.inspect}",
        code: HEADER_MISMATCH, status: 400)
    end

    def decode_header(value)
      match = BASE64_SENTINEL.match(value.to_s)
      return value unless match
      match[1].unpack1("m0").force_encoding(Encoding::UTF_8)
    rescue ArgumentError
      raise ProtocolError.new("Header mismatch: malformed base64 in Mcp-Name", code: HEADER_MISMATCH, status: 400)
    end

    def dispatch(method, params, context, modern)
      case [method, modern]
      in ["server/discover", true] then discover_result
      in ["initialize", false] then initialize_result(params)
      in ["ping", false] then {}
      in ["tools/list", _] then tools_list_result(context, modern)
      in ["tools/call", _] then call_tool(find_tool!(params), params, context, modern)
      else
        # In the current revision the 404 is how a client tells "no such method"
        # apart from "not an MCP endpoint at all"
        raise ProtocolError.new("Method not found: #{method}", code: METHOD_NOT_FOUND, status: modern ? 404 : 200)
      end
    end

    def discover_result
      {
        supportedVersions: MODERN_VERSIONS,
        capabilities: {tools: {listChanged: false}},
        instructions: @instructions,
        ttlMs: TOOL_LIST_TTL_MS,
        cacheScope: CACHE_SCOPE,
        _meta: {META_SERVER_INFO => server_info}
      }.compact
    end

    def initialize_result(params)
      requested = params["protocolVersion"]
      {
        protocolVersion: LEGACY_VERSIONS.include?(requested) ? requested : LEGACY_VERSIONS.first,
        capabilities: {tools: {listChanged: false}},
        serverInfo: server_info,
        instructions: @instructions
      }.compact
    end

    def server_info
      {name: @name, title: @title, version: @version}.compact
    end

    def tools_list_result(context, modern)
      result = {tools: @tools.values.map { |tool| tool.descriptor(context) }}
      modern ? result.merge(ttlMs: TOOL_LIST_TTL_MS, cacheScope: CACHE_SCOPE) : result
    end

    def find_tool!(params)
      name = params["name"]
      raise ProtocolError.new("tools/call needs a tool name", code: INVALID_PARAMS) unless name.is_a?(String)
      @tools.fetch(name) { raise ProtocolError.new("Unknown tool: #{name}. Call tools/list to see what this server offers.", code: INVALID_PARAMS) }
    end

    def call_tool(tool, params, context, modern, progress_stream = nil)
      name = params["name"]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      era = modern ? "modern" : "legacy"
      begin
        result = begin
          instance = tool.new(context)
          instance.send(:stream_progress_to, progress_stream) if progress_stream
          instance.invoke(params["arguments"])
        rescue ToolError => e
          Result.error(e.message)
        end
        raise TypeError, "#{tool}#call returned #{result.class}, not a NanoMCP::Result" unless result.is_a?(Result)
        shaped = shape(result, modern)
        bytes = JSON.generate(shaped).bytesize
      rescue => e
        exception = e
        raise
      ensure
        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
        error = exception ? true : result.error?
        log(:info) { "tool=#{name} era=#{era} error=#{error} bytes=#{bytes || "-"} duration_ms=#{elapsed_ms}" } unless @on_call
        report_call(tool: name, era: era, context: context, arguments: params["arguments"], error: error,
          bytes: bytes, duration_ms: elapsed_ms, exception: exception)
      end
      shaped
    end

    def report_call(event)
      @on_call&.call(event.freeze)
    rescue => e
      log(:error) { "on_call raised #{e.class}: #{e.message}" }
    end

    # A client of an older revision may not read `structuredContent`, so it gets the
    # data as JSON in prose. A current one gets the data once, plus the summary. An answer over the size cap goes out as truncated text: a clipped
    # structure would be a lie about its own shape
    def shape(result, modern)
      return {content: [text_block(result.text)], isError: result.error?} if result.structured.nil?

      unless modern
        return {content: [text_block(JSON.pretty_generate(result.structured))], isError: false}
      end

      json = JSON.generate(result.structured)
      if json.bytesize > MAX_RESPONSE_BYTES
        return {content: [text_block(JSON.pretty_generate(result.structured))], isError: false}
      end
      {content: [text_block(result.text)], structuredContent: result.structured, isError: false}
    end

    def text_block(string)
      string = string.to_s
      if string.bytesize > MAX_RESPONSE_BYTES
        string = string.byteslice(0, MAX_RESPONSE_BYTES).scrub("") + "\n\n[truncated: response exceeded #{MAX_RESPONSE_BYTES} bytes]"
      end
      {type: "text", text: string}
    end

    def authenticate(env, meta)
      # A lambda taking just the env would raise on a second argument, a block would not
      if @authenticate.lambda? && @authenticate.arity == 1
        @authenticate.call(env)
      else
        @authenticate.call(env, meta)
      end
    rescue => e
      log(:error) { "authentication raised #{e.class}: #{e.message} - refusing" }
      nil
    end

    # Absent is fine, since MCP clients are not browsers. A present one has to be listed:
    # comparing it to our own Host proves nothing after a rebind, because the browser
    # then sends the attacker's name in both
    def origin_permitted?(origin)
      return true if origin.nil? || origin.empty?
      @allowed_origins.any? { |allowed| origin.casecmp?(allowed) }
    end

    def read_body(env)
      input = env["rack.input"]
      return "" unless input
      input.rewind if input.respond_to?(:rewind)
      body = input.read(MAX_REQUEST_BYTES + 1).to_s
      input.rewind if input.respond_to?(:rewind)
      (body.bytesize > MAX_REQUEST_BYTES) ? nil : body
    end

    def respond(status, payload, headers = {})
      [status, {"content-type" => "application/json"}.merge(headers), [JSON.generate(payload)]]
    end

    def error_body(id, code, message, data = nil)
      error = {code: code, message: message}
      error[:data] = data if data
      {jsonrpc: "2.0", id: id, error: error}
    end

    def log(level, &message)
      @logger&.public_send(level) { "[nano_mcp] server=#{@name} #{message.call}" }
    end
  end
end
