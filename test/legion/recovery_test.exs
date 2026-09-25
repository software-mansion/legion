defmodule Legion.RecoveryTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Legion.Store.Payload

  defmodule RecoveryAgent do
    @moduledoc "Agent used to exercise startup recovery."
    use Legion.Agent
  end

  defmodule StoreState do
    use Agent

    def start_link(test_pid) do
      Agent.start_link(fn -> %{stores: %{}, test_pid: test_pid} end, name: __MODULE__)
    end

    def put(store, payloads) do
      Agent.update(__MODULE__, fn state ->
        payloads = Map.new(payloads, &{&1.agent_id, &1})
        put_in(state, [:stores, store], payloads)
      end)
    end

    def get(store, agent_id) do
      {test_pid, result} =
        Agent.get(__MODULE__, fn state ->
          result =
            case get_in(state, [:stores, store, agent_id]) do
              nil -> :error
              payload -> {:ok, payload}
            end

          {state.test_pid, result}
        end)

      send(test_pid, {:looked_up, store, agent_id})
      result
    end

    def list(store, limit) do
      {test_pid, payloads} =
        Agent.get(__MODULE__, fn state ->
          {state.test_pid, state.stores |> Map.fetch!(store) |> Map.values() |> Enum.take(limit)}
        end)

      send(test_pid, {:listed, store, limit})
      payloads
    end

    def save(store, %Payload{} = payload) do
      Agent.update(__MODULE__, fn state ->
        existing = get_in(state, [:stores, store, payload.agent_id])

        merged =
          Enum.reduce(Map.from_struct(payload), existing, fn
            {:agent_id, _agent_id}, stored -> stored
            {_field, nil}, stored -> stored
            {field, value}, stored -> Map.put(stored, field, value)
          end)

        put_in(state, [:stores, store, payload.agent_id], merged)
      end)

      :ok
    end
  end

  defmodule RecoveryStoreOne do
    @behaviour Legion.Store

    @impl Legion.Store
    def get(agent_id), do: StoreState.get(__MODULE__, agent_id)

    @impl Legion.Store
    def list(limit), do: StoreState.list(__MODULE__, limit)

    @impl Legion.Store
    def save(payload), do: StoreState.save(__MODULE__, payload)
  end

  defmodule RecoveryStoreTwo do
    @behaviour Legion.Store

    @impl Legion.Store
    def get(agent_id), do: StoreState.get(__MODULE__, agent_id)

    @impl Legion.Store
    def list(limit), do: StoreState.list(__MODULE__, limit)

    @impl Legion.Store
    def save(payload), do: StoreState.save(__MODULE__, payload)
  end

  setup :set_mimic_global

  setup do
    start_supervised!({StoreState, self()})
    :ok
  end

  @moduletag capture_log: true

  test "does not start when recovery config is absent" do
    assert :ignore = Legion.Recovery.start_link(:error)
  end

  test "uses separate store scan and concurrent request limits" do
    stores = [RecoveryStoreOne, RecoveryStoreTwo]

    Enum.each(stores, fn store ->
      StoreState.put(store, [
        interrupted_payload("#{store}-one"),
        interrupted_payload("#{store}-two")
      ])
    end)

    test_pid = self()

    stub(ReqLLM, :generate_object, fn _model, _messages, _schema, _opts ->
      send(test_pid, {:recovering, self()})

      receive do
        :complete_recovery -> llm_response("recovered")
      end
    end)

    assert {:ok, worker} =
             Legion.Recovery.start_link(
               {:ok, stores: stores, store_scan_limit: 2, concurrent_request_limit: 1}
             )

    monitor_ref = Process.monitor(worker)

    assert_receive {:listed, RecoveryStoreOne, 2}
    assert_receive {:listed, RecoveryStoreTwo, 2}

    assert_receive {:recovering, first}
    refute_receive {:recovering, _}, 50

    send(first, :complete_recovery)

    assert_receive {:recovering, second}
    refute_receive {:recovering, _}, 50

    send(second, :complete_recovery)

    assert_receive {:recovering, third}
    refute_receive {:recovering, _}, 50

    send(third, :complete_recovery)

    assert_receive {:recovering, fourth}
    refute_receive {:recovering, _}, 50

    send(fourth, :complete_recovery)

    assert_receive {:DOWN, ^monitor_ref, :process, ^worker, :normal}

    for store <- stores,
        suffix <- ["one", "two"] do
      assert {:ok, %Payload{status: :idle}} = StoreState.get(store, "#{store}-#{suffix}")
    end
  end

  test "defaults the concurrent request limit to three" do
    StoreState.put(RecoveryStoreOne, [
      interrupted_payload("one"),
      interrupted_payload("two"),
      interrupted_payload("three"),
      interrupted_payload("four")
    ])

    test_pid = self()

    stub(ReqLLM, :generate_object, fn _model, _messages, _schema, _opts ->
      send(test_pid, {:recovering, self()})

      receive do
        :complete_recovery -> llm_response("recovered")
      end
    end)

    assert {:ok, worker} =
             Legion.Recovery.start_link({:ok, stores: [RecoveryStoreOne], store_scan_limit: 4})

    monitor_ref = Process.monitor(worker)

    assert_receive {:recovering, first}
    assert_receive {:recovering, second}
    assert_receive {:recovering, third}
    refute_receive {:recovering, _}, 50

    send(first, :complete_recovery)

    assert_receive {:recovering, fourth}

    send(second, :complete_recovery)
    send(third, :complete_recovery)
    send(fourth, :complete_recovery)

    assert_receive {:DOWN, ^monitor_ref, :process, ^worker, :normal}
  end

  test "filters out idle and child runs before recovering" do
    eligible = interrupted_payload("eligible")
    idle_root = %{interrupted_payload("idle-root") | status: :idle}
    running_child = %{interrupted_payload("running-child") | parent_agent_id: "parent"}

    StoreState.put(RecoveryStoreOne, [eligible, idle_root, running_child])

    test_pid = self()

    stub(ReqLLM, :generate_object, fn _model, _messages, _schema, _opts ->
      send(test_pid, {:recovering, self()})

      receive do
        :complete_recovery -> llm_response("recovered")
      end
    end)

    assert {:ok, worker} =
             Legion.Recovery.start_link(
               {:ok, stores: [RecoveryStoreOne], store_scan_limit: 3, concurrent_request_limit: 3}
             )

    monitor_ref = Process.monitor(worker)

    assert_receive {:listed, RecoveryStoreOne, 3}
    assert_receive {:recovering, recovery_pid}
    refute_receive {:looked_up, RecoveryStoreOne, "idle-root"}, 50
    refute_receive {:looked_up, RecoveryStoreOne, "running-child"}, 50

    send(recovery_pid, :complete_recovery)

    assert_receive {:DOWN, ^monitor_ref, :process, ^worker, :normal}
  end

  defp interrupted_payload(agent_id) do
    %Payload{
      agent_id: agent_id,
      parent_agent_id: nil,
      agent_module: RecoveryAgent,
      status: :running,
      usage: [],
      conversation_state: %{
        messages: [%{role: "user", type: :user, content: "recover me"}],
        bindings: [],
        executor_state: %{phase: :awaiting_llm, iteration: 1, retries: 0}
      }
    }
  end

  defp llm_response(result) do
    {:ok,
     %ReqLLM.Response{
       id: "test",
       model: "test",
       context: nil,
       object: %{"action" => "return", "code" => "", "result" => result},
       usage: %{turn_usage: 0}
     }}
  end
end
