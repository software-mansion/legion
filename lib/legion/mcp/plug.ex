if Code.ensure_loaded?(Anubis.Server) and Code.ensure_loaded?(Plug) do
  defmodule Legion.MCP.Plug do
    @moduledoc """
    Mounts an MCP server over Streamable HTTP with the server's request timeout.

        forward "/mcp", Legion.MCP.Plug, server: MyApp.MCP

    A wrapper for `Anubis.Server.Transport.StreamableHTTP.Plug`, which speaks
    the transport: the session header, SSE streams, OAuth bearer checks. It
    takes that plug's options unchanged, `:session_header` and
    `:subscriber_metadata` included. It differs in three ways.

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

    It caps the sessions and event streams a server holds. Anubis starts a
    session for every `initialize` it receives and keeps a GET event stream
    open for as long as the client stays, limiting neither, so whoever
    reaches the endpoint could otherwise open them until the node runs out
    of memory. A new one over a cap is refused: with 503 when the server is
    full, with 429 when the client is.

      - `:max_sessions` - live sessions of the server, 10,000 by default
      - `:max_streams` - open event streams of the server, 10,000 by default
      - `:max_sessions_per_client`, `:max_streams_per_client` - the same for
        one client, unlimited by default
      - `:client_key` - a function from the `Plug.Conn` to who the client is,
        `conn.remote_ip` by default. Behind a proxy that is the proxy's
        address for everyone, so give a function that reads the client's own
        before setting a per-client cap. Pass a remote capture,
        `&MyAppWeb.ClientIP.key/1`, since a Phoenix `forward` keeps its
        options from compile time.

        forward "/mcp", Legion.MCP.Plug,
          server: MyApp.MCP,
          client_key: &MyAppWeb.ClientIP.key/1,
          max_sessions_per_client: 20,
          max_streams_per_client: 20

    A session counts from its `initialize` until Anubis ends it, on `DELETE`
    or after `:session_idle_timeout` without a request. Its id is issued
    here, from `:crypto.strong_rand_bytes/1`, and one a client sends with
    `initialize` is ignored. A stream counts until it closes, and it is
    closed when its session ends or a newer stream takes the session: Anubis
    stops writing to it then, but would leave it open. A GET stream needs
    the `mcp-session-id` of a live session; without one it is answered with
    400, and with an unknown one with 404.
    """

    @behaviour Plug

    require Logger

    alias Anubis.Server.Transport.StreamableHTTP.Plug, as: AnubisPlug
    alias Legion.MCP.Admission

    @limits [
      max_sessions: 10_000,
      max_streams: 10_000,
      max_sessions_per_client: :infinity,
      max_streams_per_client: :infinity
    ]

    # Anubis's default, which `:session_header` overrides.
    @session_header "mcp-session-id"

    @impl Plug
    def init(opts) do
      _ = Keyword.fetch!(opts, :server)

      for {key, limit} <- Keyword.take(opts, Keyword.keys(@limits)),
          not (limit == :infinity or (is_integer(limit) and limit > 0)) do
        raise ArgumentError,
              "#{inspect(key)} must be a positive integer or :infinity, got: #{inspect(limit)}"
      end

      case Keyword.fetch(opts, :client_key) do
        {:ok, client_key} when not is_function(client_key, 1) ->
          raise ArgumentError,
                ":client_key must be a function of one argument, got: #{inspect(client_key)}"

        _other ->
          :ok
      end

      opts
    end

    @local_hosts ~w(localhost 127.0.0.1 ::1)

    # The timeout is read per request, not in init/1: a Plug.Router forward
    # runs init/1 at compile time, before the agent's config exists.
    @impl Plug
    def call(conn, opts) do
      {gate, opts} = Keyword.split(opts, [:allowed_origins, :client_key | Keyword.keys(@limits)])
      allowed_origins = Keyword.get(gate, :allowed_origins, [])

      case Plug.Conn.get_req_header(conn, "origin") do
        [origin | _] ->
          if allowed_origin?(origin, allowed_origins),
            do: admit(conn, gate, opts),
            else: refuse(conn, origin)

        [] ->
          admit(conn, gate, opts)
      end
    end

    defp admit(conn, gate, opts) do
      server = Keyword.fetch!(opts, :server)
      header = Keyword.get(opts, :session_header, @session_header)
      session_id = conn |> Plug.Conn.get_req_header(header) |> List.first()

      cond do
        conn.method == "POST" and not Admission.live_session?(server, session_id) ->
          start_session(conn, server, header, gate, opts)

        conn.method == "GET" and event_stream?(conn) ->
          open_stream(conn, server, session_id, gate, opts)

        true ->
          serve(conn, opts)
      end
    end

    # A POST outside a live session may be an `initialize`, so it runs under
    # an id issued for the session it would start; anything else is answered
    # 404 by Anubis, as it would have been under the client's id.
    defp start_session(conn, server, header, gate, opts) do
      start = fn session_id ->
        conn
        |> Plug.Conn.put_req_header(header, session_id)
        |> Plug.Conn.register_before_send(&name_session(&1, server, header, session_id))
        |> serve(opts)
      end

      case Admission.with_session(server, client(conn, gate), limits(gate), start) do
        {:ok, conn} -> conn
        {:error, scope} -> too_many(conn, "sessions", scope)
      end
    end

    # Anubis names the session in its response only when the request did not.
    defp name_session(conn, server, header, session_id) do
      if Admission.live_session?(server, session_id),
        do: Plug.Conn.put_resp_header(conn, header, session_id),
        else: conn
    end

    defp open_stream(conn, _server, nil, _gate, _opts),
      do: send_text(conn, 400, "Session ID required")

    defp open_stream(conn, server, session_id, gate, opts) do
      stream = fn -> serve(conn, opts) end

      case Admission.with_stream(server, session_id, client(conn, gate), limits(gate), stream) do
        {:ok, conn} -> conn
        {:error, :unknown_session} -> send_text(conn, 404, "Session not found")
        {:error, scope} -> too_many(conn, "event streams", scope)
      end
    end

    # What Anubis takes for a request to open the session's event stream.
    defp event_stream?(conn) do
      conn
      |> Plug.Conn.get_req_header("accept")
      |> List.first("")
      |> String.contains?("text/event-stream")
    end

    defp client(conn, gate) do
      case Keyword.fetch(gate, :client_key) do
        {:ok, client_key} -> client_key.(conn)
        :error -> conn.remote_ip
      end
    end

    defp limits(gate), do: Keyword.merge(@limits, Keyword.take(gate, Keyword.keys(@limits)))

    defp too_many(conn, what, :server),
      do: send_text(conn, 503, "This server holds too many MCP #{what}; try again later")

    defp too_many(conn, what, :client),
      do: send_text(conn, 429, "Too many MCP #{what} from this client; close some or try later")

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
      send_text(
        conn,
        403,
        "Origin #{origin} is not allowed; list it in :allowed_origins of Legion.MCP.Plug"
      )
    end

    defp send_text(conn, status, text) do
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(status, text)
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
