defmodule Legion.MCP.ServerTest do
  # Agents the server starts share one named supervisor.
  use ExUnit.Case, async: false

  alias Anubis.Server.{Component, Context, Frame, Handlers}
  alias Legion.MCP.Server
  alias Legion.RateLimiter.{ExceededError, Policy, Rule}
  alias Legion.Sandbox.Lua
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

  defmodule EndlessAgent do
    @moduledoc "Agent whose evals never time out."
    use Legion.Agent

    def config, do: %{sandbox_timeout: :infinity}
  end

  defmodule EndlessMCP do
    use Legion.MCP.Server, agent: EndlessAgent, name: "endless", version: "0.1.0"
  end

  defmodule PatientMCP do
    use Legion.MCP.Server, agent: ConfiguredAgent, name: "patient", version: "0.1.0"

    def request_timeout, do: 10
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

  defmodule ElixirAgent do
    @moduledoc "Agent that delegates work from the Elixir sandbox."
    use Legion.Agent

    def tools, do: [Legion.Tools.AgentTool]
    def config, do: %{sandbox: Legion.Sandbox.Elixir}
  end

  defmodule ElixirMCP do
    use Legion.MCP.Server, agent: ElixirAgent, name: "elixir", version: "0.1.0"
  end

  defmodule PresetMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "preset", version: "0.1.0"

    def session(_frame), do: [store: MemoryStore, agent_id: "mcp:user:preset"]
  end

  defmodule ElixirSessionMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "elixir-session", version: "0.1.0"

    def session(_frame), do: [sandbox: Legion.Sandbox.Elixir]
  end

  defmodule AgentToolAgent do
    @moduledoc "Agent that delegates work."
    use Legion.Agent

    def tools, do: [Legion.Tools.AgentTool]
  end

  defmodule AgentToolMCP do
    use Legion.MCP.Server, agent: AgentToolAgent, name: "agent-tool", version: "0.1.0"
  end

  defmodule FullDocsAgent do
    @moduledoc "Agent that wants its tools embedded in full."
    use Legion.Agent

    def tools, do: [MathTool]
    def config, do: %{tool_docs: :inline}
  end

  defmodule FullDocsMCP do
    use Legion.MCP.Server, agent: FullDocsAgent, name: "full", version: "0.1.0"
  end

  defmodule WordySandbox do
    @moduledoc "Lua sandbox whose rules run past any host's tool description cap."
    @behaviour Legion.Sandbox

    @impl true
    defdelegate check(code, allowed), to: Lua
    @impl true
    defdelegate execute(code, timeout, allowed, bindings, limits), to: Lua
    @impl true
    defdelegate binding_names(bindings), to: Lua

    @impl true
    def prompt_info do
      %{Lua.prompt_info() | constraints: String.duplicate("- Rule. ", 400)}
    end
  end

  defmodule WordyAgent do
    @moduledoc "Agent on a sandbox with too many rules."
    use Legion.Agent

    def config, do: %{sandbox: WordySandbox}
  end

  defmodule WordyMCP do
    use Legion.MCP.Server, agent: WordyAgent, name: "wordy", version: "0.1.0"
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

  defp help(server, frame, arguments) do
    request = %{
      "method" => "tools/call",
      "params" => %{"name" => "help", "arguments" => arguments}
    }

    {:reply, %{"content" => [%{"text" => text}], "isError" => error?}, %Frame{} = frame} =
      Handlers.handle(request, server, frame)

    {error?, text, frame}
  end

  describe "generated server" do
    test "exposes repl and help" do
      tools = MathMCP.__components__(:tool)
      assert tools |> Enum.map(& &1.name) |> Enum.sort() == ["help", "repl"]

      repl = Enum.find(tools, &(&1.name == "repl"))
      assert repl.input_schema["required"] == ["code"]

      help = Enum.find(tools, &(&1.name == "help"))
      assert help.input_schema["required"] in [nil, []]
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
      assert instructions =~ "- `MathTool` - This is math tool moduledoc."
      assert instructions =~ "Lua"
      assert instructions =~ "`repl`"
      assert instructions =~ "`help`"
      refute instructions =~ "performs math operations"
    end

    test "tool_docs: :inline in the agent config embeds the tools" do
      instructions = FullDocsMCP.server_instructions()

      assert instructions =~ "### MathTool"
      assert instructions =~ "performs math operations"
    end

    test "tells the model how long variables live" do
      assert MathMCP.server_instructions() =~ "Variables persist"
      assert ConfiguredMCP.server_instructions() =~ "Variables do not persist"
    end

    test "an agent's own system_prompt/0 is not used for MCP instructions" do
      instructions = CustomPromptMCP.server_instructions()

      assert instructions =~ "Agent with a hand-written prompt."
      assert instructions =~ "`repl`"
    end
  end

  describe "request_timeout/0" do
    test "is the sandbox timeout plus thirty seconds" do
      assert ConfiguredMCP.request_timeout() == 31_000
    end

    test "has no default for a sandbox without a timeout" do
      assert_raise ArgumentError, ~r/request_timeout\/0/, fn ->
        EndlessMCP.request_timeout()
      end
    end
  end

  defmodule VerboseAgent do
    @moduledoc "An agent whose purpose statement runs long. " <>
                 String.duplicate("It does math, and it says so at length. ", 60)
    use Legion.Agent
    def tools, do: [MathTool]
  end

  defmodule VerboseMCP do
    use Legion.MCP.Server, agent: VerboseAgent, name: "verbose", version: "0.1.0"
  end

  defmodule UncheckedMCP do
    use Legion.MCP.Server,
      agent: VerboseAgent,
      name: "unchecked",
      version: "0.1.0",
      instructions_budget: :infinity
  end

  defmodule RoomyMCP do
    use Legion.MCP.Server,
      agent: VerboseAgent,
      name: "roomy",
      version: "0.1.0",
      instructions_budget: 100_000
  end

  describe "instructions_budget" do
    import ExUnit.CaptureLog

    test "warns at child_spec time when the instructions exceed the budget" do
      log = capture_log(fn -> VerboseMCP.child_spec(transport: :stdio) end)

      assert log =~ "VerboseMCP: server instructions are"
      assert log =~ "cap them at 2048"
      assert log =~ "stop reading after"
      assert log =~ "drops the sections: Available Tools"
      assert log =~ "instructions_budget:"
    end

    test "warns when the repl tool description exceeds the budget" do
      # Not through child_spec: WordySandbox is not Legion.Sandbox.Lua, so that refuses first.
      log = capture_log(fn -> Server.check_instructions(WordyMCP, 2048) end)

      assert log =~ "WordyMCP: repl tool description is"
      assert log =~ "cap them at 2048"
    end

    test "is quiet with a budget the instructions fit, or :infinity" do
      assert capture_log(fn -> RoomyMCP.child_spec(transport: :stdio) end) == ""
      assert capture_log(fn -> UncheckedMCP.child_spec(transport: :stdio) end) == ""
    end
  end

  describe "repl tool description" do
    test "carries the sandbox language and its rules" do
      description = Component.get_description(MathMCP.Repl)

      assert description =~ "Lua"
      assert description =~ String.trim(Lua.prompt_info().constraints)
    end

    test "names the Lua sandbox" do
      assert Component.get_description(MathMCP.Repl) =~ "Run Lua code"
    end

    test "says whether variables persist" do
      assert Component.get_description(MathMCP.Repl) =~ "Variables persist"

      assert Component.get_description(ConfiguredMCP.Repl) =~
               "Variables do not persist"
    end
  end

  describe "help tool" do
    test "with no tool lists every tool with a summary" do
      frame = initialized(MathMCP, frame())

      assert {false, text, _frame} = help(MathMCP, frame, %{})
      assert text =~ "- `MathTool` - This is math tool moduledoc."
      assert text =~ "- `Help` -"
    end

    test "with a tool name returns its full reference" do
      frame = initialized(MathMCP, frame())

      assert {false, text, _frame} = help(MathMCP, frame, %{"tool" => "MathTool"})
      assert text =~ "### MathTool"
      assert text =~ "performs math operations"
    end

    test "with an unknown name returns the list instead" do
      frame = initialized(MathMCP, frame())

      assert {false, text, _frame} = help(MathMCP, frame, %{"tool" => "Nope"})
      assert text =~ "No tool named"
      assert text =~ "- `MathTool` -"
    end

    test "rejects a name that is not a bare word without running anything" do
      frame = initialized(MathMCP, frame())

      assert {true, text, frame} = help(MathMCP, frame, %{"tool" => ~s|x") os.exit(|})
      assert text =~ "Tools:"
      assert text =~ "- `MathTool` -"
      refute Map.has_key?(frame.assigns, :legion_mcp_agent)
    end

    test "is a step of the session's conversation" do
      frame = initialized(MathMCP, frame())

      assert {false, _text, %Frame{assigns: %{legion_mcp_agent: pid}}} =
               help(MathMCP, frame, %{"tool" => "MathTool"})

      [%{type: :assistant, content: code}, %{type: :eval_result, content: result}] =
        pid |> Legion.get_messages() |> Enum.take(-2)

      assert Jason.decode!(code)["code"] == ~s|return Help.help("MathTool")|
      assert result =~ "### MathTool"
    end

    test "is rate limited like repl" do
      frame = initialized(UserMCP, frame("host", %{sub: "denied"}))

      assert {true, "Rate limit exceeded (max_evals)." <> _, _frame} =
               help(UserMCP, frame, %{})
    end

    test "refuses before the session is initialized" do
      assert {true, text, _frame} = help(MathMCP, frame(), %{})
      assert text =~ "not initialized"
    end
  end

  describe "session tool_docs" do
    test "over MCP Help is in the sandbox whatever the agent's tool_docs" do
      frame = initialized(FullDocsMCP, frame())

      assert {false, text, frame} = repl(FullDocsMCP, frame, "return Help == nil")
      assert text =~ "false"

      assert {false, text, _frame} = help(FullDocsMCP, frame, %{"tool" => "MathTool"})
      assert text =~ "### MathTool"
    end
  end

  describe "child_spec/1" do
    test "gives the transport the server's request_timeout" do
      %{start: {_, _, [_, opts]}} = ConfiguredMCP.child_spec(transport: :stdio)
      assert opts[:request_timeout] == 31_000
      assert opts[:transport] == :stdio
    end

    test "refuses to start for an agent that is not on the Lua sandbox" do
      %{start: {module, function, arguments}} = ElixirMCP.child_spec(transport: :stdio)

      assert {:error, message} = apply(module, function, arguments)
      assert message =~ "Legion.Sandbox.Lua agents only"
      assert message =~ "ElixirAgent runs Legion.Sandbox.Elixir"
    end

    test "refuses to start for an agent that lists AgentTool" do
      %{start: {module, function, arguments}} = AgentToolMCP.child_spec(transport: :stdio)

      assert {:error, message} = apply(module, function, arguments)
      assert message =~ "does not serve agents with Legion.Tools.AgentTool"
      assert message =~ "AgentToolAgent lists"
    end
  end

  describe "session/1 naming a sandbox" do
    test "answers the call with a tool error unless it is Lua" do
      frame = initialized(ElixirSessionMCP, frame())

      assert {true, text, _frame} = repl(ElixirSessionMCP, frame, "return 1")
      assert text =~ "Legion.Sandbox.Lua agents only"
    end

    test "refuses a named agent already running another sandbox" do
      {:ok, _pid} =
        Legion.start_link(MathAgent,
          store: MemoryStore,
          agent_id: "mcp:user:preset",
          sandbox: Legion.Sandbox.Elixir
        )

      frame = initialized(PresetMCP, frame())

      assert {true, text, _frame} = repl(PresetMCP, frame, "1 + 1")
      assert text =~ "requires Legion.Sandbox.Lua"
    end

    test "refuses a named agent already running with AgentTool" do
      {:ok, _pid} =
        Legion.start_link(AgentToolAgent, store: MemoryStore, agent_id: "mcp:user:preset")

      frame = initialized(PresetMCP, frame())

      assert {true, text, _frame} = repl(PresetMCP, frame, "return 1")
      assert text =~ "refuses agents with Legion.Tools.AgentTool"
    end

    test "uses an overridden request_timeout/0" do
      %{start: {_, _, [_, opts]}} = PatientMCP.child_spec(transport: :stdio)
      assert opts[:request_timeout] == 10
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

    test "the vault follows every call" do
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
