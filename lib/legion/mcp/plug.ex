if Code.ensure_loaded?(Anubis.Server.Transport.StreamableHTTP.Plug) do
  defmodule Legion.MCP.Plug do
    @moduledoc """
    Mounts an MCP server over Streamable HTTP with the server's request timeout.

        forward "/mcp", to: Legion.MCP.Plug, server: MyApp.MCP

    A wrapper for `Anubis.Server.Transport.StreamableHTTP.Plug`, which does
    everything: the session header, SSE streams, OAuth bearer checks. It takes
    that plug's options unchanged, `:session_header` and `:subscriber_metadata`
    included. The one difference is `:request_timeout`: unless given, it is
    the server's `request_timeout/0`, read when a request arrives, so it is
    the same bound stdio gets from the child spec. See "Request timeout" in
    `Legion.MCP.Server`.
    """

    @behaviour Plug

    alias Anubis.Server.Transport.StreamableHTTP.Plug, as: AnubisPlug

    @impl Plug
    def init(opts) do
      _ = Keyword.fetch!(opts, :server)
      opts
    end

    # The timeout is read per request, not in init/1: a Plug.Router forward
    # runs init/1 at compile time, before the agent's config exists.
    @impl Plug
    def call(conn, opts) do
      timeout = Keyword.fetch!(opts, :server).request_timeout()
      AnubisPlug.call(conn, AnubisPlug.init(Keyword.put_new(opts, :request_timeout, timeout)))
    end
  end
end
