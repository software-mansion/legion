defmodule Legion.SupervisorTest do
  use ExUnit.Case, async: false

  defmodule FakeRepo do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl GenServer
    def init(:ok), do: {:ok, :ready}
  end

  defmodule RecoveryStore do
    def list(_limit) do
      send(
        Process.whereis(:legion_supervisor_test),
        {:recovery_scanned, Process.whereis(FakeRepo)}
      )

      []
    end
  end

  defmodule TestAgent do
    @moduledoc "Agent used to verify Legion's public startup function."
    use Legion.Agent
  end

  setup do
    previous = Application.fetch_env(:legion, :recovery)
    Process.register(self(), :legion_supervisor_test)

    on_exit(fn ->
      case previous do
        {:ok, config} -> Application.put_env(:legion, :recovery, config)
        :error -> Application.delete_env(:legion, :recovery)
      end
    end)
  end

  test "does not auto-start a Legion supervisor" do
    assert [] = Application.spec(:legion, :mod)
  end

  test "uses start_link when embedded as a child" do
    assert %{id: Legion, start: {Legion, :start_link, [[]]}, type: :supervisor} =
             Legion.child_spec([])
  end

  test "starts an agent when start_link receives an agent module" do
    assert {:ok, pid} = Legion.start_link(TestAgent)
    assert is_binary(Legion.get_agent_id(pid))
  end

  test "adds recovery worker with configured options" do
    config = [stores: [RecoveryStore], store_scan_limit: 3, concurrent_request_limit: 2]
    Application.put_env(:legion, :recovery, config)

    assert {:ok,
            {_supervisor_flags,
             [
               %{id: Legion.Recovery, start: {Legion.Recovery, :start_link, [{:ok, ^config}]}},
               %{id: Legion.AgentSupervisor, start: {DynamicSupervisor, :start_link, [sup_opts]}}
             ]}} =
             Legion.init([])

    assert sup_opts[:name] == Legion.AgentSupervisor
  end

  test "starts recovery after a client repo" do
    Application.put_env(:legion, :recovery, stores: [RecoveryStore], store_scan_limit: 1)

    start_supervised!(%{
      id: :client_supervisor,
      start: {Supervisor, :start_link, [[FakeRepo, {Legion, []}], [strategy: :one_for_one]]}
    })

    assert_receive {:recovery_scanned, repo_pid}
    assert is_pid(repo_pid)
  end
end
