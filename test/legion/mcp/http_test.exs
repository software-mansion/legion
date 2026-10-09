defmodule Legion.MCP.HTTPTest do
  # One Anubis server per module name, and one agent supervisor, so tests run one at a time.
  use ExUnit.Case, async: false

  alias Anubis.Client
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
