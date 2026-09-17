defmodule Legion.MCP.HTTPTest do
  # One Anubis server per module name, so tests of this server run one at a time.
  use ExUnit.Case, async: false

  alias Anubis.Client
  alias Legion.RateLimiter.{Policy, Rule}
  alias Legion.Test.Support.{MathAgent, MemoryStore, PostgresRepo}

  defmodule HTTPMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "math-http", version: "1.0.0"
  end

  defmodule PgStore do
    use Legion.Store.Postgres, repo: Legion.Test.Support.PostgresRepo
  end

  defmodule PgLimiter do
    use Legion.RateLimiter.Postgres, repo: Legion.Test.Support.PostgresRepo
  end

  defmodule LimitedMCP do
    use Legion.MCP.Server,
      agent: MathAgent,
      name: "math-limited",
      version: "1.0.0",
      store: PgStore

    def rate_limit_rules(frame) do
      ip = frame.context.remote_ip |> :inet.ntoa() |> to_string()
      [%Rule{identity: %{"ip" => ip}, policy: %Policy{window_ms: 60_000, max_evals: 2}}]
    end
  end

  setup do
    start_supervised!({Finch, name: Anubis.Finch})

    {:ok, url: serve(HTTPMCP)}
  end

  defp serve(server) do
    start_supervised!({server, transport: :streamable_http})

    bandit =
      start_supervised!(
        {Bandit,
         plug: {Anubis.Server.Transport.StreamableHTTP.Plug, server: server},
         ip: :loopback,
         port: 0},
        id: {Bandit, server}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    "http://127.0.0.1:#{port}"
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

  test "a client that skips notifications/initialized gets a tool error until it sends it",
       %{url: url} do
    post = fn body, headers ->
      Req.post!(url,
        json: Map.put(body, "jsonrpc", "2.0"),
        headers: [accept: "application/json"] ++ headers
      )
    end

    initialize = %{
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "skipper", "version" => "1"}
      }
    }

    call = %{
      "id" => 2,
      "method" => "tools/call",
      "params" => %{"name" => "repl", "arguments" => %{"code" => "return 1 + 1"}}
    }

    [session_id] = initialize |> post.([]) |> Req.Response.get_header("mcp-session-id")
    session = [{"mcp-session-id", session_id}]

    %{body: %{"result" => result}} = post.(call, session)
    assert result["isError"]
    assert [%{"text" => "Session is not initialized" <> _}] = result["content"]

    post.(%{"method" => "notifications/initialized"}, session)

    %{body: %{"result" => result}} = post.(call, session)
    refute result["isError"]
    assert [%{"text" => text}] = result["content"]
    assert text =~ "2"
  end

  test "a session is recorded in the configured store", %{url: url} do
    start_supervised!(MemoryStore)
    Application.put_env(:legion, :store, MemoryStore)
    on_exit(fn -> Application.delete_env(:legion, :store) end)

    client = connect(url, :stored_client)
    {false, _} = repl(client, "x = 1")
    {false, _} = repl(client, "return x + 1")

    assert [%{agent_id: "mcp:" <> _, conversation_state: %{messages: messages}}] =
             MemoryStore.list(10)

    assert length(messages) == 4
  end

  test "rules built from the request deny the call after the limit, across sessions" do
    PostgresRepo.query!("TRUNCATE legion_agents", [])
    Application.put_env(:legion, :rate_limit, limiter: PgLimiter)
    on_exit(fn -> Application.delete_env(:legion, :rate_limit) end)

    url = serve(LimitedMCP)

    first = connect(url, :limited_first)
    {false, _} = repl(first, "return 1")
    {false, _} = repl(first, "return 2")

    second = connect(url, :limited_second)
    {error?, text} = repl(second, "return 3")

    assert error?
    assert text == "Rate limited: max_evals (2 per 60s). Try again later."
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
