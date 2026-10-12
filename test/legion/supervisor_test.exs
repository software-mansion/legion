defmodule Legion.SupervisorTest do
  # Starts the globally named Legion supervisor and sets :recovery app env.
  use ExUnit.Case, async: false

  defmodule FakeRepo do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl GenServer
    def init(:ok), do: {:ok, :ready}
  end

  defmodule RecoveryStore do
    def list(limit) do
      send(
        Process.whereis(:legion_supervisor_test),
        {:recovery_scanned, limit, Process.whereis(FakeRepo)}
      )

      []
    end
  end

  setup do
    previous = Application.fetch_env(:legion, :recovery)

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

  test "starts the agent supervisor, and recovery with its configured options after a client repo" do
    Process.register(self(), :legion_supervisor_test)
    Application.put_env(:legion, :recovery, stores: [RecoveryStore], store_scan_limit: 3)

    start_supervised!(%{
      id: :client_supervisor,
      start: {Supervisor, :start_link, [[FakeRepo, {Legion, []}], [strategy: :one_for_one]]}
    })

    assert_receive {:recovery_scanned, 3, repo_pid}
    assert is_pid(repo_pid)
    assert is_pid(Process.whereis(Legion.AgentSupervisor))
  end
end
