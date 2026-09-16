defmodule Legion.MCP.ServerTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.{Context, Frame, Handlers}
  alias Legion.MCP.Server
  alias Legion.Test.Support.{MathAgent, MathTool}

  defmodule MathMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "math", version: "1.2.3"
  end

  defmodule ConfiguredAgent do
    @moduledoc "Agent with a short sandbox timeout, per-call variables and a configured tool."
    use Legion.Agent

    def tools, do: [MathTool]
    def tool_config(MathTool), do: [precision: 2]
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

  defp frame(session_id \\ "session-1") do
    %Frame{context: %Context{session_id: session_id, client_info: %{"name" => "host"}}}
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

    test "an unlimited sandbox means an unlimited transport call" do
      assert Server.request_timeout(%{sandbox_timeout: :infinity}) == :infinity
    end
  end

  describe "init/2" do
    test "makes the session id the agent id and seeds the tool configs for the session process" do
      assert {:ok, %Frame{}} = ConfiguredMCP.init(%{}, frame("session-42"))

      assert Vault.get(:agent_id) == "session-42"
      assert Vault.get(MathTool) == [precision: 2]
    end

    test "emits a session started event" do
      ref = attach([[:legion, :mcp, :session, :started]])

      ConfiguredMCP.init(%{}, frame("session-42"))

      assert_received {^ref, [:legion, :mcp, :session, :started],
                       %{
                         agent: ConfiguredAgent,
                         session_id: "session-42",
                         client_info: %{"name" => "host"}
                       }}
    end

    test "the session is ready to run code" do
      {:ok, frame} = MathMCP.init(%{}, frame())

      request = %{
        "method" => "tools/call",
        "params" => %{"name" => "repl", "arguments" => %{"code" => "return 1 + 1"}}
      }

      assert {:reply, %{"content" => [%{"text" => text}], "isError" => false}, %Frame{}} =
               Handlers.handle(request, MathMCP, frame)

      assert text =~ "2"
    end
  end

  describe "terminate/2" do
    test "emits a session stopped event" do
      ref = attach([[:legion, :mcp, :session, :stopped]])

      MathMCP.terminate(:shutdown, frame("session-9"))

      assert_received {^ref, [:legion, :mcp, :session, :stopped],
                       %{agent: MathAgent, session_id: "session-9", reason: :shutdown}}
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
end
