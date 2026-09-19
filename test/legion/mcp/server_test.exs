defmodule Legion.MCP.ServerTest do
  # Agents the server starts share one named supervisor.
  use ExUnit.Case, async: false

  alias Anubis.Server.{Context, Frame, Handlers}
  alias Legion.MCP.Server
  alias Legion.RateLimiter.{ExceededError, Policy, Rule}
  alias Legion.Store.Payload
  alias Legion.Test.Support.{MathAgent, MathTool, MemoryStore, VaultTool}

  defmodule MathMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "math", version: "1.2.3"
  end

  defmodule ConfiguredAgent do
    @moduledoc "Agent with a short sandbox timeout and per-call variables."
    use Legion.Agent

    def tools, do: [MathTool]
    def config, do: %{sandbox_timeout: 1_000, binding_scope: :iteration}
  end

  defmodule ConfiguredMCP do
    use Legion.MCP.Server, agent: ConfiguredAgent, name: "configured", version: "0.1.0"
  end

  defmodule CustomPromptAgent do
    @moduledoc "Agent with a hand-written prompt."
    use Legion.Agent

    def system_prompt, do: "Do exactly as I say."
  end

  defmodule CustomPromptMCP do
    use Legion.MCP.Server, agent: CustomPromptAgent, name: "custom", version: "0.1.0"
  end

  defmodule VaultAgent do
    @moduledoc "Agent whose tool reports what its process was seeded with."
    use Legion.Agent

    def tools, do: [VaultTool]
  end

  defmodule DenyingLimiter do
    @moduledoc "Denies every call whose rule names the user `denied`."
    @behaviour Legion.RateLimiter

    @impl Legion.RateLimiter
    def enforce!(agent_id, [%Rule{identity: %{"user" => "denied"}} = rule]) do
      raise ExceededError,
        agent_id: agent_id,
        identity: rule.identity,
        policy: rule.policy,
        usage: %{agents: 1, tokens: nil, evals: 30},
        violations: [:max_evals]
    end

    def enforce!(_agent_id, _rules), do: :ok
  end

  defmodule UserMCP do
    use Legion.MCP.Server, agent: VaultAgent, name: "users", version: "0.1.0"

    # The bearer token's subject is the user; the session id plays no part.
    def session(frame) do
      user = frame.context.auth.sub
      rule = %Rule{identity: %{"user" => user}, policy: %Policy{window_ms: 1_000, max_evals: 30}}

      [
        store: MemoryStore,
        agent_id: "mcp:user:" <> user,
        vault: [current_user: user, token: frame.context.auth[:token]],
        rate_limit: [limiter: DenyingLimiter, rules: [rule]]
      ]
    end
  end

  defmodule ShortLivedMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "short", version: "0.1.0"

    def session(_frame), do: [store: MemoryStore, agent_id: "mcp:user:short", idle_timeout: 50]
  end

  setup do
    start_supervised!(MemoryStore)
    start_supervised!({DynamicSupervisor, name: Legion.AgentSupervisor, strategy: :one_for_one})
    :ok
  end

  defp frame(session_id \\ "session-1", auth \\ nil) do
    context = %Context{session_id: session_id, client_info: %{"name" => "host"}, auth: auth}
    %Frame{context: context}
  end

  defp initialized(server, frame) do
    {:ok, frame} = server.init(%{}, frame)
    frame
  end

  defp repl(server, frame, code) do
    request = %{
      "method" => "tools/call",
      "params" => %{"name" => "repl", "arguments" => %{"code" => code}}
    }

    {:reply, %{"content" => [%{"text" => text}], "isError" => error?}, %Frame{} = frame} =
      Handlers.handle(request, server, frame)

    {error?, text, frame}
  end

  describe "generated server" do
    test "exposes exactly one tool, repl, taking the code to run" do
      assert [tool] = MathMCP.__components__(:tool)
      assert tool.name == "repl"
      assert tool.input_schema["required"] == ["code"]
      assert tool.description =~ "sandbox"
    end

    test "reports the given name and version" do
      assert MathMCP.server_info() == %{"name" => "math", "version" => "1.2.3"}
    end

    test "requires an agent" do
      assert_raise KeyError, fn ->
        Code.compile_string("""
        defmodule AgentlessMCP do
          use Legion.MCP.Server, name: "x", version: "1"
        end
        """)
      end
    end
  end

  describe "server_instructions/0" do
    test "describes the agent, its tools, the language and the repl tool" do
      instructions = MathMCP.server_instructions()

      assert instructions =~ "An agent that does math."
      assert instructions =~ "MathTool"
      assert instructions =~ "Lua"
      assert instructions =~ "`repl`"
    end

    test "tells the model how long variables live" do
      assert MathMCP.server_instructions() =~ "Variables persist"
      assert ConfiguredMCP.server_instructions() =~ "Variables do not persist"
    end

    test "an agent's own system_prompt/0 wins" do
      assert CustomPromptMCP.server_instructions() == "Do exactly as I say."
    end
  end

  describe "child_spec/1" do
    test "gives the transport call five seconds more than the sandbox" do
      %{start: {_, _, [_, opts]}} = ConfiguredMCP.child_spec(transport: :stdio)
      assert opts[:request_timeout] == 6_000
      assert opts[:transport] == :stdio
    end

    test "keeps an explicit request_timeout" do
      %{start: {_, _, [_, opts]}} =
        ConfiguredMCP.child_spec(transport: :stdio, request_timeout: 10)

      assert opts[:request_timeout] == 10
    end
  end

  describe "anonymous sessions" do
    test "a session's first call starts its agent, later calls keep its variables" do
      frame = initialized(MathMCP, frame())

      assert {false, _text, frame} = repl(MathMCP, frame, "x = MathTool.random_add(1, 0)")
      assert {false, text, frame} = repl(MathMCP, frame, "return x + 1")

      assert text =~ "984"
      assert text =~ "Available variables: `x`"
      assert Process.alive?(frame.assigns.legion_mcp_agent)
    end

    test "sessions do not share variables" do
      first = initialized(MathMCP, frame("first"))
      second = initialized(MathMCP, frame("second"))

      assert {false, _text, _first} = repl(MathMCP, first, "x = 1")
      assert {false, text, _second} = repl(MathMCP, second, "return x")
      assert text =~ "nil"
    end

    test "a sandbox error is a tool error" do
      frame = initialized(MathMCP, frame())

      assert {true, text, _frame} = repl(MathMCP, frame, "return (")
      assert text != ""
    end

    test "the agent stops with the session" do
      frame = initialized(MathMCP, frame())
      {false, _text, frame} = repl(MathMCP, frame, "return 1")
      pid = frame.assigns.legion_mcp_agent

      MathMCP.terminate(:shutdown, frame)

      refute Process.alive?(pid)
    end

    test "every call is a span naming the session and the agent it ran in" do
      ref = attach([[:legion, :mcp, :call, :start], [:legion, :mcp, :call, :stop]])
      frame = initialized(MathMCP, frame("session-7"))

      {false, _text, frame} = repl(MathMCP, frame, "return 1")
      {true, error, _frame} = repl(MathMCP, frame, "return (")
      agent_id = Legion.get_agent_id(frame.assigns.legion_mcp_agent)

      assert_received {^ref, [:legion, :mcp, :call, :start],
                       %{
                         agent: MathAgent,
                         agent_id: ^agent_id,
                         session_id: "session-7",
                         code: "return 1"
                       }}

      assert_received {^ref, [:legion, :mcp, :call, :stop], %{success: true, code: "return 1"}}
      assert_received {^ref, [:legion, :mcp, :call, :stop], %{success: false, error: ^error}}
    end

    test "a call before the handshake is a tool error" do
      assert {true, "Session is not initialized" <> _, _frame} =
               repl(MathMCP, frame(), "return 1")
    end
  end

  describe "named sessions" do
    test "session/1 picks the agent from the call's auth, whatever the session id" do
      alice = initialized(UserMCP, frame("first-host", %{sub: "alice"}))
      alice_again = initialized(UserMCP, frame("second-host", %{sub: "alice"}))
      bob = initialized(UserMCP, frame("third-host", %{sub: "bob"}))

      assert {false, _text, _frame} = repl(UserMCP, alice, "x = 40")
      assert {false, text, _frame} = repl(UserMCP, alice_again, "return x + 2")
      assert text =~ "42"

      assert {false, text, _frame} = repl(UserMCP, bob, "return x")
      assert text =~ "nil"

      assert {:ok, alice_pid} = Legion.lookup("mcp:user:alice")
      assert {:ok, bob_pid} = Legion.lookup("mcp:user:bob")
      assert alice_pid != bob_pid
    end

    test "every call is saved as a step of the user's conversation" do
      frame = initialized(UserMCP, frame("host", %{sub: "carol"}))

      {false, result, _frame} = repl(UserMCP, frame, "return 1 + 1")
      {true, error, _frame} = repl(UserMCP, frame, "return (")

      assert {:ok,
              %Payload{
                conversation_state: %{
                  messages: [first_action, saved_result, _second, saved_error]
                },
                usage: [%{"evals" => 1}, %{"evals" => 1}]
              }} = MemoryStore.get("mcp:user:carol")

      assert %{type: :assistant, content: content} = first_action
      assert Jason.decode!(content)["code"] == "return 1 + 1"
      assert %{type: :eval_result, content: ^result} = saved_result
      assert %{type: :error, content: ^error} = saved_error
    end

    test "tools read what session/1 put in the vault" do
      frame = initialized(UserMCP, frame("host", %{sub: "dave"}))

      assert {false, text, _frame} = repl(UserMCP, frame, "return VaultTool.current_user()")
      assert text =~ "dave"
    end

    test "a rate-limited call is a tool error and runs nothing" do
      frame = initialized(UserMCP, frame("host", %{sub: "denied"}))

      assert {true, "Rate limit exceeded (max_evals)." <> _, _frame} =
               repl(UserMCP, frame, "x = 1")

      assert {:ok, %Payload{conversation_state: nil}} = MemoryStore.get("mcp:user:denied")
    end

    test "the vault follows every call, the rest of session/1 is read once" do
      first = initialized(UserMCP, frame("host", %{sub: "frank", token: "morning"}))
      second = initialized(UserMCP, frame("host", %{sub: "frank", token: "evening"}))

      assert {false, text, _frame} = repl(UserMCP, first, "return VaultTool.token()")
      assert text =~ "morning"
      assert {false, text, _frame} = repl(UserMCP, second, "return VaultTool.token()")
      assert text =~ "evening"
    end

    test "concurrent sessions on one agent serialise, and every step is kept" do
      frames = for host <- 1..4, do: initialized(UserMCP, frame("host-#{host}", %{sub: "grace"}))

      results =
        frames
        |> Task.async_stream(fn frame -> repl(UserMCP, frame, "x = (x or 0) + 1 return x") end)
        |> Enum.map(fn {:ok, {error?, text, _frame}} -> {error?, text} end)

      assert Enum.all?(results, &match?({false, _text}, &1))

      assert {:ok, %Payload{conversation_state: %{messages: messages, bindings: bindings}}} =
               MemoryStore.get("mcp:user:grace")

      assert length(messages) == 8
      assert List.keyfind(bindings, "x", 0) == {"x", 4}
    end

    test "an agent stopped for idleness continues from the store on the next call" do
      frame = initialized(ShortLivedMCP, frame())

      assert {false, _text, _frame} = repl(ShortLivedMCP, frame, "x = 41")
      {:ok, pid} = Legion.lookup("mcp:user:short")
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500

      assert {false, text, _frame} = repl(ShortLivedMCP, frame, "return x + 1")
      assert text =~ "42"
      assert {:ok, restarted} = Legion.lookup("mcp:user:short")
      assert restarted != pid
    end

    test "a step that cannot be saved is a tool error and is forgotten" do
      frame = initialized(UserMCP, frame("host", %{sub: "heidi"}))
      {false, _text, _frame} = repl(UserMCP, frame, "x = 1")

      MemoryStore.fail_saves(true)

      assert {true, "The code ran, but the step could not be saved." <> _, _frame} =
               repl(UserMCP, frame, "x = 2")

      MemoryStore.fail_saves(false)
      assert {false, text, _frame} = repl(UserMCP, frame, "return x")
      assert text =~ "1"
    end

    test "nothing is left in the frame to stop with the session" do
      frame = initialized(UserMCP, frame("host", %{sub: "erin"}))
      {false, _text, frame} = repl(UserMCP, frame, "return 1")

      assert :ok = UserMCP.terminate(:shutdown, frame)
      assert {:ok, _pid} = Legion.lookup("mcp:user:erin")
    end
  end

  defp attach(events) do
    ref = make_ref()
    test_pid = self()
    id = "server-test-#{inspect(ref)}"

    :telemetry.attach_many(
      id,
      events,
      fn event, _measurements, metadata, _ -> send(test_pid, {ref, event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    ref
  end

  describe "agent/2" do
    test "starts the agent under Legion.AgentSupervisor and finds it again by its id" do
      opts = [store: MemoryStore, agent_id: "mcp-shared"]
      pid = Server.agent(MathAgent, opts)

      assert Server.agent(MathAgent, opts) == pid
      assert {:ok, ^pid} = Legion.lookup("mcp-shared")

      children = DynamicSupervisor.which_children(Legion.AgentSupervisor)
      assert Enum.any?(children, &match?({_id, ^pid, :worker, _modules}, &1))
    end
  end
end
