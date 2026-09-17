defmodule Legion.MCP.HTTPTest do
  # One Anubis server per module name, so tests of this server run one at a time.
  use ExUnit.Case, async: false

  alias Anubis.Client
  alias Legion.Test.Support.MathAgent

  defmodule HTTPMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "math-http", version: "1.0.0"
  end

  setup do
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

  test "sessions do not share variables", %{url: url} do
    first = connect(url, :first_client)
    second = connect(url, :second_client)

    {false, _} = repl(first, "x = 1")
    {false, text} = repl(second, "return x")

    assert text =~ "nil"
    refute text =~ "Available variables"
  end
end
