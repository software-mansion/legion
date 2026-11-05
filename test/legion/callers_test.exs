defmodule Legion.CallersTest.ConnectionTool do
  @moduledoc "Reports which database connection its process was given."
  use Legion.Tool

  alias Legion.Test.Support.SandboxRepo

  def backend_pid do
    %{rows: [[backend_pid]]} = SandboxRepo.query!("SELECT pg_backend_pid()")
    backend_pid
  end
end

defmodule Legion.CallersTest do
  @moduledoc """
  Agents inherit `$callers`, so an async test's Ecto sandbox connection and stubs
  reach them, unless a supervisor from outside the test starts them.
  """
  use ExUnit.Case, async: true
  use Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias Legion.CallersTest.ConnectionTool
  alias Legion.Sandbox.Lua
  alias Legion.Store.Payload
  alias Legion.Test.Support.SandboxRepo
  alias Legion.Tools.AgentTool

  defmodule Store do
    use Legion.Store.Postgres, repo: Legion.Test.Support.SandboxRepo
  end

  defmodule ConnectionAgent do
    @moduledoc "Agent that asks for its database connection."
    use Legion.Agent

    def tools, do: [ConnectionTool]
  end

  defmodule OwnerAgent do
    @moduledoc "Agent that delegates to a sub-agent."
    use Legion.Agent

    def tools, do: [AgentTool]
    def tool_config(AgentTool), do: [agents: [ConnectionAgent]]
  end

  @ask_connection "return ConnectionTool.backend_pid()"
  @return_done %{"action" => "return", "code" => "", "result" => "done"}

  setup :set_mimic_private

  @moduletag capture_log: true

  setup do
    owner = Sandbox.start_owner!(SandboxRepo)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    {:ok, backend_pid: ConnectionTool.backend_pid()}
  end

  defp eval(code), do: %{"action" => "eval_and_continue", "code" => code, "result" => ""}

  # Answers each LLM request with the next object and reports what the model was just told.
  defp script_llm(objects) do
    test_pid = self()
    {:ok, script} = Agent.start_link(fn -> objects end)

    stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
      send(test_pid, {:model_told, List.last(messages)[:content]})
      object = Agent.get_and_update(script, fn [next | rest] -> {next, rest} end)

      {:ok,
       %ReqLLM.Response{
         id: "test",
         model: "test",
         context: nil,
         object: object,
         usage: %{turn_usage: 0}
       }}
    end)
  end

  defp script_connection_turn, do: script_llm([eval(@ask_connection), @return_done])

  # A tool's failure goes to the model as text while the turn succeeds, so the
  # result of the call proves nothing - only what the model was told does.
  defp assert_model_got(backend_pid) do
    told = "Code executed successfully. Result:\n```\n#{backend_pid}\n```\n"
    assert_received {:model_told, ^told}
  end

  test "an eval uses the connection of the process that ran it", %{backend_pid: backend_pid} do
    assert {:ok, {^backend_pid, []}} = Lua.execute(@ask_connection, 5_000, [ConnectionTool])
  end

  test "an agent from Legion.start_link/2 uses the test's connection", %{backend_pid: backend_pid} do
    script_connection_turn()

    {:ok, pid} = Legion.start_link(ConnectionAgent)

    assert {:ok, "done"} = Legion.call(pid, "go")
    assert_model_got(backend_pid)
  end

  test "an agent from Legion.execute/2 uses the test's connection", %{backend_pid: backend_pid} do
    script_connection_turn()

    assert {:ok, "done"} = Legion.execute(ConnectionAgent, "go")
    assert_model_got(backend_pid)
  end

  test "an agent from start_supervised!/1 uses the test's connection", %{backend_pid: backend_pid} do
    script_connection_turn()

    pid = start_supervised!({ConnectionAgent, []})

    assert {:ok, "done"} = Legion.call(pid, "go")
    assert_model_got(backend_pid)
  end

  test "an agent under a supervisor the test started uses the test's connection", %{
    backend_pid: backend_pid
  } do
    script_connection_turn()
    supervisor = start_supervised!(DynamicSupervisor)

    {:ok, pid} = DynamicSupervisor.start_child(supervisor, {ConnectionAgent, []})

    assert {:ok, "done"} = Legion.call(pid, "go")
    assert_model_got(backend_pid)
  end

  test "a test with a registered name stays in the chain", %{backend_pid: backend_pid} do
    script_connection_turn()
    Process.register(self(), :callers_test_named_process)
    supervisor = start_supervised!(DynamicSupervisor)

    {:ok, pid} = DynamicSupervisor.start_child(supervisor, {ConnectionAgent, []})

    assert {:ok, "done"} = Legion.call(pid, "go")
    assert_model_got(backend_pid)
  end

  test "a Postgres store shares the test's connection", %{backend_pid: backend_pid} do
    script_connection_turn()

    {:ok, pid} = Legion.start_link(ConnectionAgent, store: Store)

    assert {:ok, "done"} = Legion.call(pid, "go")
    assert_model_got(backend_pid)

    # Uncommitted, so only the same connection can see it.
    assert {:ok, %Payload{status: :idle}} = Store.get(Legion.get_agent_id(pid))
  end

  test "a sub-agent uses the test's connection", %{backend_pid: backend_pid} do
    script_llm([
      eval("return AgentTool.call(ConnectionAgent, 'go')"),
      eval(@ask_connection),
      @return_done,
      @return_done
    ])

    assert {:ok, "done"} = Legion.execute(OwnerAgent, "go")
    assert_model_got(backend_pid)
  end

  # What a LiveView under test looks like: its own `$callers`, and a supervision
  # tree that has nothing to do with the test.
  test "an agent inherits the callers of the process that started it", %{backend_pid: backend_pid} do
    script_connection_turn()
    test_pid = self()

    spawn_link(fn ->
      Process.put(:"$callers", [test_pid])
      send(test_pid, {:result, Legion.execute(ConnectionAgent, "go")})
    end)

    assert_receive {:result, {:ok, "done"}}, 5_000
    assert_model_got(backend_pid)
  end
end
