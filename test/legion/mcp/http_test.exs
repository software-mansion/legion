defmodule Legion.MCP.HTTPTest do
  # One Anubis server per module name, and one agent supervisor, so tests run one at a time.
  use ExUnit.Case, async: false

  alias Anubis.Client
  alias Legion.Test.Support.{MathAgent, VaultTool}

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

  setup do
    start_supervised!({DynamicSupervisor, name: Legion.AgentSupervisor, strategy: :one_for_one})
    start_supervised!({HTTPMCP, transport: :streamable_http})

    bandit =
      start_supervised!(
        {Bandit,
         plug: {Anubis.Server.Transport.StreamableHTTP.Plug, server: HTTPMCP},
         ip: :loopback,
         port: 0}
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

  test "lists exactly one tool, repl", %{url: url} do
    client = connect(url, :list_client)

    {:ok, response} = Client.list_tools(client)
    assert Enum.map(response.result["tools"], & &1["name"]) == ["repl"]
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
        {Bandit,
         plug: {Anubis.Server.Transport.StreamableHTTP.Plug, server: VaultMCP},
         ip: :loopback,
         port: 0},
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

  test "sessions do not share variables", %{url: url} do
    first = connect(url, :first_client)
    second = connect(url, :second_client)

    {false, _} = repl(first, "x = 1")
    {false, text} = repl(second, "return x")

    assert text =~ "nil"
    refute text =~ "Available variables"
  end
end
