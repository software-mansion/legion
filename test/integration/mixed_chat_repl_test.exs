defmodule Legion.Integration.MixedChatReplTest do
  @moduledoc """
  Integration test: one agent driven both by `Legion.call/2` (a real model)
  and by an MCP host's `repl` calls over HTTP, in the order chat -> repl ->
  chat. The second chat turn reads a history holding an `eval_and_continue`
  step with no `return` after it, and must carry on from it.

  Skipped by default to avoid external API calls and LLM costs.
  Run with:

      mix test test/integration/mixed_chat_repl_test.exs --include integration
  """
  # One Anubis server per module name, and one agent supervisor, so tests run one at a time.
  use ExUnit.Case, async: false

  alias Anubis.Client
  alias Legion.Store.Payload
  alias Legion.Test.Support.{MathTool, MemoryStore}

  @moduletag :integration
  @moduletag timeout: 120_000

  defmodule MixedAgent do
    @moduledoc "A math agent whose variables outlive a turn."
    use Legion.Agent

    def tools, do: [MathTool]
    def config, do: %{binding_scope: :conversation}
  end

  defmodule MixedMCP do
    use Legion.MCP.Server, agent: MixedAgent, name: "mixed-http", version: "1.0.0"

    def agent_id, do: "mixed-chat-repl-integration"

    def session(_frame), do: [store: MemoryStore, agent_id: agent_id()]
  end

  setup do
    unless System.get_env("OPENAI_API_KEY"), do: raise("OPENAI_API_KEY not set")

    start_supervised!(MemoryStore)
    start_supervised!({DynamicSupervisor, name: Legion.AgentSupervisor, strategy: :one_for_one})
    start_supervised!({Registry, keys: :duplicate, name: Legion.MCP.Sessions})
    start_supervised!({MixedMCP, transport: :streamable_http})

    bandit =
      start_supervised!(
        {Bandit, plug: {Legion.MCP.Plug, server: MixedMCP}, ip: :loopback, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    start_supervised!({Finch, name: Anubis.Finch})

    {:ok, client: connect("http://127.0.0.1:#{port}", :mixed_client)}
  end

  test "a chat turn after an MCP repl call continues the same conversation", %{client: client} do
    {:ok, pid} = Legion.start_link(MixedAgent, store: MemoryStore, agent_id: MixedMCP.agent_id())

    set_x = "Set x = 40 and return \"Done\"."
    assert {:ok, first} = Legion.call(pid, set_x)
    assert inspect(first) =~ ~r/done/i
    before_repl = Legion.get_messages(pid)
    assert Enum.any?(before_repl, &(&1.type == :eval_result)), "turn 1 ran no code"

    code = "x = x + 2\nreturn x"
    {:ok, response} = Client.call_tool(client, "repl", %{"code" => code})
    assert %{"content" => [%{"text" => text}], "isError" => false} = response.result
    assert text =~ "42"
    assert Legion.lookup(MixedMCP.agent_id()) == {:ok, pid}

    after_repl = Legion.get_messages(pid)
    assert Enum.take(after_repl, length(before_repl)) == before_repl
    assert [action, result] = Enum.drop(after_repl, length(before_repl))
    assert action.type == :assistant

    assert Jason.decode!(action.content) == %{
             "action" => "eval_and_continue",
             "code" => code
           }

    assert result.type == :eval_result

    ask_x = "What is the current value of x? Return only the number."
    assert {:ok, second} = Legion.call(pid, ask_x)
    assert inspect(second) =~ "42"

    [%{role: "system"} | messages] = Legion.get_messages(pid)

    assert messages |> Enum.filter(&(&1.type == :user)) |> Enum.map(& &1.content) == [
             set_x,
             ask_x
           ]

    assert {:ok, %Payload{conversation_state: %{messages: ^messages, bindings: bindings}}} =
             MemoryStore.get(MixedMCP.agent_id())

    assert {"x", 42} in bindings
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
end
