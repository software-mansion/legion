defmodule Legion.MCP.HTTPTest do
  # One Anubis server per module name, and one agent supervisor, so tests run one at a time.
  use ExUnit.Case, async: false

  alias Anubis.Client
  alias Legion.MCP.Plug, as: MCPPlug
  alias Legion.Test.Support.{MathAgent, SlowTool, VaultTool}

  defmodule HTTPMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "math-http", version: "1.0.0"
  end

  defmodule VaultAgent do
    @moduledoc "Agent whose tool reports what its process was seeded with."
    use Legion.Agent

    def tools, do: [VaultTool]
  end

  defmodule VaultMCP do
    use Legion.MCP.Server, agent: VaultAgent, name: "vault-http", version: "1.0.0"

    def session(frame), do: [vault: [current_user: frame.context.headers["x-user"]]]
  end

  defmodule SlowAgent do
    @moduledoc "Agent whose tool can outlast the transport."
    use Legion.Agent

    def tools, do: [SlowTool]
  end

  defmodule ImpatientMCP do
    use Legion.MCP.Server, agent: SlowAgent, name: "impatient", version: "1.0.0"

    def request_timeout, do: 200
  end

  setup do
    start_supervised!({DynamicSupervisor, name: Legion.AgentSupervisor, strategy: :one_for_one})
    start_supervised!({Registry, keys: :duplicate, name: Legion.MCP.Sessions})
    start_supervised!(Legion.MCP.Admission)
    start_supervised!({HTTPMCP, transport: :streamable_http})

    bandit =
      start_supervised!(
        {Bandit, plug: {Legion.MCP.Plug, server: HTTPMCP}, ip: :loopback, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    start_supervised!({Finch, name: Anubis.Finch})

    {:ok, url: "http://127.0.0.1:#{port}"}
  end

  # Anubis keeps a per-client-name cache, so each client needs its own name.
  defp connect(url, name) do
    start_supervised!(
      {Client,
       name: name,
       transport: {:streamable_http, base_url: url, mcp_path: "/"},
       client_info: %{"name" => Atom.to_string(name), "version" => "1"},
       capabilities: %{}}
    )

    :ok = Client.await_ready(name, timeout: 5_000)
    name
  end

  defp repl(client, code) do
    {:ok, response} = Client.call_tool(client, "repl", %{"code" => code})
    %{"content" => [%{"text" => text}], "isError" => error?} = response.result
    {error?, text}
  end

  test "initialize returns the server info and the agent's instructions", %{url: url} do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "raw", "version" => "1"}
      }
    }

    %{status: 200, body: %{"result" => result}} =
      Req.post!(url, json: body, headers: [accept: "application/json"])

    assert result["serverInfo"] == %{"name" => "math-http", "version" => "1.0.0"}
    assert result["instructions"] =~ "An agent that does math."
    assert result["instructions"] =~ "`repl`"
  end

  describe "Origin" do
    defp initialize(url, headers) do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "raw", "version" => "1"}
        }
      }

      Req.post!(url, json: body, headers: [accept: "application/json"] ++ headers, retry: false)
    end

    defp start_plug(id, opts) do
      bandit =
        start_supervised!(
          {Bandit, plug: {Legion.MCP.Plug, [server: HTTPMCP] ++ opts}, ip: :loopback, port: 0},
          id: id
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
      "http://127.0.0.1:#{port}"
    end

    test "a page on another site is refused, as under DNS rebinding", %{url: url} do
      response = initialize(url, origin: "http://evil.example:4000")

      assert response.status == 403
      assert response.body =~ "http://evil.example:4000 is not allowed"
    end

    test "localhost on any port is served, as the MCP Inspector is", %{url: url} do
      for origin <- ["http://localhost:6274", "http://127.0.0.1:3000", "http://[::1]:8080"] do
        assert %{status: 200} = initialize(url, origin: origin)
      end
    end

    test "a listed origin is served, and :any serves every one" do
      listed = start_plug(:listed_bandit, allowed_origins: ["https://app.example.com"])
      assert %{status: 200} = initialize(listed, origin: "https://app.example.com")
      assert %{status: 403} = initialize(listed, origin: "https://app.example.com:8443")

      open = start_plug(:open_bandit, allowed_origins: :any)
      assert %{status: 200} = initialize(open, origin: "http://evil.example")
    end
  end

  describe "sessions and streams" do
    def client(conn), do: conn |> Plug.Conn.get_req_header("x-client") |> List.first()

    defp start_capped_plug(id, opts) do
      bandit =
        start_supervised!(
          {Bandit,
           plug: {Legion.MCP.Plug, [server: HTTPMCP, client_key: &__MODULE__.client/1] ++ opts},
           ip: :loopback,
           port: 0},
          id: id
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
      port
    end

    defp session(port, client) do
      response = initialize("http://127.0.0.1:#{port}", [{"x-client", client}])
      {response.status, List.first(response.headers["mcp-session-id"] || [])}
    end

    # Over a raw socket, so the test sees exactly when the server ends the
    # stream: `connection: close` makes the end of the response close it.
    defp open_stream(port, session_id, client) do
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      :ok =
        :gen_tcp.send(
          socket,
          "GET / HTTP/1.1\r\nhost: localhost\r\naccept: text/event-stream\r\n" <>
            "connection: close\r\nx-client: #{client}\r\n" <>
            if(session_id, do: "mcp-session-id: #{session_id}\r\n", else: "") <> "\r\n"
        )

      {:ok, "HTTP/1.1 " <> <<status::binary-size(3)>> <> _rest} = :gen_tcp.recv(socket, 0, 5_000)
      {String.to_integer(status), socket}
    end

    defp closed?(socket, timeout \\ 2_000) do
      case :gen_tcp.recv(socket, 0, timeout) do
        {:ok, _data} -> closed?(socket, timeout)
        {:error, :closed} -> true
        {:error, :timeout} -> false
      end
    end

    test "a client over its session cap gets 429, and another client is still served" do
      port = start_capped_plug(:client_cap_bandit, max_sessions_per_client: 2)

      assert {200, _id} = session(port, "ann")
      assert {200, _id} = session(port, "ann")
      assert {429, nil} = session(port, "ann")
      assert {200, _id} = session(port, "bob")
    end

    test "a server over its session cap gets 503 until a session ends" do
      port = start_capped_plug(:server_cap_bandit, max_sessions: 1)

      assert {200, session_id} = session(port, "ann")
      assert {503, nil} = session(port, "bob")

      assert %{status: 200} =
               Req.delete!("http://127.0.0.1:#{port}", headers: [{"mcp-session-id", session_id}])

      assert {200, _id} = session(port, "bob")
    end

    test "the server issues the session id, not the client" do
      port = start_capped_plug(:issued_id_bandit, [])

      response =
        initialize("http://127.0.0.1:#{port}", [{"x-client", "ann"}, {"mcp-session-id", "mine"}])

      assert [session_id] = response.headers["mcp-session-id"]
      assert session_id != "mine"
      assert byte_size(session_id) == 32
    end

    test "a stream needs a live session" do
      port = start_capped_plug(:stream_session_bandit, [])

      assert {400, _socket} = open_stream(port, nil, "ann")
      assert {404, _socket} = open_stream(port, "made-up", "ann")
    end

    test "a newer stream closes the one it replaces, and the end of the session closes it" do
      port = start_capped_plug(:stream_close_bandit, max_streams_per_client: 1)
      {200, session_id} = session(port, "ann")

      {200, first} = open_stream(port, session_id, "ann")
      refute closed?(first, 200)

      # The replaced stream does not count against the cap of one.
      {200, second} = open_stream(port, session_id, "ann")
      assert closed?(first)
      refute closed?(second, 200)

      Req.delete!("http://127.0.0.1:#{port}", headers: [{"mcp-session-id", session_id}])
      assert closed?(second)
    end

    test "a client over its stream cap gets 429, and another client is still served" do
      port = start_capped_plug(:stream_cap_bandit, max_streams_per_client: 1)
      {200, first_session} = session(port, "ann")
      {200, second_session} = session(port, "ann")

      assert {200, _socket} = open_stream(port, first_session, "ann")
      assert {429, _socket} = open_stream(port, second_session, "ann")
      assert {200, _socket} = open_stream(port, second_session, "bob")
    end

    test "limits and :client_key are checked when the plug is built" do
      assert_raise ArgumentError, ~r/:max_sessions must be/, fn ->
        MCPPlug.init(server: HTTPMCP, max_sessions: 0)
      end

      assert_raise ArgumentError, ~r/:client_key must be/, fn ->
        MCPPlug.init(server: HTTPMCP, client_key: :remote_ip)
      end
    end
  end

  test "lists the repl and help tools", %{url: url} do
    client = connect(url, :list_client)

    {:ok, response} = Client.list_tools(client)
    assert response.result["tools"] |> Enum.map(& &1["name"]) |> Enum.sort() == ["help", "repl"]
  end

  test "keeps variables between calls in one session", %{url: url} do
    client = connect(url, :bindings_client)

    {false, _} = repl(client, "x = MathTool.random_add(1, 0)")
    {false, text} = repl(client, "return x + 1")

    assert text =~ "984"
    assert text =~ "Available variables: `x`"
  end

  test "a sandbox error comes back as a tool error", %{url: url} do
    client = connect(url, :error_client)

    {error?, text} = repl(client, "return (")

    assert error?
    assert text != ""
  end

  test "tools read what session/1 put in the vault, through the real transport" do
    start_supervised!({VaultMCP, transport: :streamable_http})

    bandit =
      start_supervised!(
        {Bandit, plug: {Legion.MCP.Plug, server: VaultMCP}, ip: :loopback, port: 0},
        id: :vault_bandit
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    _client =
      start_supervised!(
        {Client,
         name: :vault_client,
         transport:
           {:streamable_http,
            base_url: "http://127.0.0.1:#{port}", mcp_path: "/", headers: %{"x-user" => "ivan"}},
         client_info: %{"name" => "vault", "version" => "1"},
         capabilities: %{}}
      )

    :ok = Client.await_ready(:vault_client, timeout: 5_000)

    assert {false, text} = repl(:vault_client, "return VaultTool.current_user()")
    assert text =~ "ivan"
  end

  test "the plug gives up on a call after the server's request_timeout/0" do
    start_supervised!({ImpatientMCP, transport: :streamable_http})

    bandit =
      start_supervised!(
        {Bandit, plug: {Legion.MCP.Plug, server: ImpatientMCP}, ip: :loopback, port: 0},
        id: :impatient_bandit
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    start_supervised!(
      {Client,
       name: :impatient_client,
       transport: {:streamable_http, base_url: "http://127.0.0.1:#{port}", mcp_path: "/"},
       client_info: %{"name" => "impatient", "version" => "1"},
       capabilities: %{}}
    )

    :ok = Client.await_ready(:impatient_client, timeout: 5_000)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, _} =
                 Client.call_tool(:impatient_client, "repl", %{"code" => "SlowTool.wait(1000)"})
      end)

    assert log =~ "timeout"
  end

  test "sessions do not share variables", %{url: url} do
    first = connect(url, :first_client)
    second = connect(url, :second_client)

    {false, _} = repl(first, "x = 1")
    {false, text} = repl(second, "return x")

    assert text =~ "nil"
    refute text =~ "Available variables"
  end
end
