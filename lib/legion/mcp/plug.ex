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

    require Logger

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
      server = Keyword.fetch!(opts, :server)
      warn_if_open(server)
      timeout = server.request_timeout()
      AnubisPlug.call(conn, AnubisPlug.init(Keyword.put_new(opts, :request_timeout, timeout)))
    end

    # Once per server: an HTTP endpoint with no `authorization:` runs code for
    # whoever reaches it.
    defp warn_if_open(server) do
      key = {__MODULE__, :open_warned, server}

      if is_nil(server.__authorization__()) and not :persistent_term.get(key, false) do
        :persistent_term.put(key, true)

        Logger.warning(
          "#{inspect(server)} serves MCP over HTTP without `authorization:`, so anyone " <>
            "who reaches it can call `repl`; pass `authorization:` to `use Legion.MCP.Server` " <>
            "before exposing it beyond localhost"
        )
      end
    end
  end
end
