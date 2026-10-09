if Code.ensure_loaded?(Anubis.Server) and Code.ensure_loaded?(Plug) do
  defmodule Legion.MCP.Plug do
    @moduledoc """
    Mounts an MCP server over Streamable HTTP with the server's request timeout.

        forward "/mcp", Legion.MCP.Plug, server: MyApp.MCP

    A wrapper for `Anubis.Server.Transport.StreamableHTTP.Plug`, which speaks
    the transport: the session header, SSE streams, OAuth bearer checks. It
    takes that plug's options unchanged, `:session_header` and
    `:subscriber_metadata` included. It differs in two ways.

    `:request_timeout`, unless given, is the server's `request_timeout/0`,
    read when a request arrives, so it is the same bound stdio gets from the
    child spec. See "Request timeout" in `Legion.MCP.Server`.

    It checks the `Origin` header, as the MCP specification asks of servers
    and Anubis does not. A browser sends it, and a web page the developer
    has open could otherwise reach a server on `localhost` through DNS
    rebinding and call `repl` with the application's tools. A request with
    no `Origin`, as CLI and desktop hosts send them, is served, and so is one
    from `localhost`, `127.0.0.1` or `[::1]` on any port, such as the MCP
    Inspector. Any other origin is answered with 403 unless it is listed:

        forward "/mcp", Legion.MCP.Plug,
          server: MyApp.MCP,
          allowed_origins: ["https://app.example.com"]

    Entries are whole origins, scheme and port included. The request's own
    `Host` is not trusted for this: under DNS rebinding it is the attacker's
    name too. `allowed_origins: :any` turns the check off.
    """

    @behaviour Plug

    require Logger

    alias Anubis.Server.Transport.StreamableHTTP.Plug, as: AnubisPlug

    @impl Plug
    def init(opts) do
      _ = Keyword.fetch!(opts, :server)
      opts
    end

    @local_hosts ~w(localhost 127.0.0.1 ::1)

    # The timeout is read per request, not in init/1: a Plug.Router forward
    # runs init/1 at compile time, before the agent's config exists.
    @impl Plug
    def call(conn, opts) do
      {allowed_origins, opts} = Keyword.pop(opts, :allowed_origins, [])

      case Plug.Conn.get_req_header(conn, "origin") do
        [origin | _] ->
          if allowed_origin?(origin, allowed_origins),
            do: serve(conn, opts),
            else: refuse(conn, origin)

        [] ->
          serve(conn, opts)
      end
    end

    defp serve(conn, opts) do
      server = Keyword.fetch!(opts, :server)
      warn_if_open(server)
      timeout = server.request_timeout()
      AnubisPlug.call(conn, AnubisPlug.init(Keyword.put_new(opts, :request_timeout, timeout)))
    end

    defp allowed_origin?(_origin, :any), do: true

    defp allowed_origin?(origin, allowed_origins) do
      URI.parse(origin).host in @local_hosts or origin in allowed_origins
    end

    defp refuse(conn, origin) do
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(
        403,
        "Origin #{origin} is not allowed; list it in :allowed_origins of Legion.MCP.Plug"
      )
      |> Plug.Conn.halt()
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
