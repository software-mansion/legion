defmodule Legion.Store.PostgresTest do
  use ExUnit.Case, async: true

  alias Legion.Store.Payload

  defmodule FakeRepo do
    @moduledoc "Emulates the Ecto repository calls made by the generated store."

    def start_link, do: Agent.start_link(fn -> %{rows: %{}} end, name: __MODULE__)

    def get(_schema, agent_id) do
      Agent.get(__MODULE__, &Map.get(&1.rows, agent_id))
    end

    def all(_query), do: Agent.get(__MODULE__, &Map.values(&1.rows))

    def insert_all(_schema, [attrs], conflict_target: :agent_id, on_conflict: {:replace, columns}) do
      Agent.update(__MODULE__, fn state ->
        row =
          state.rows
          |> Map.get(attrs.agent_id, empty_row(attrs.agent_id))
          |> Map.merge(Map.take(attrs, [:agent_id | columns]))

        put_in(state.rows[attrs.agent_id], row)
      end)

      {1, nil}
    end

    def run(agent_id), do: Agent.get(__MODULE__, &Map.get(&1.rows, agent_id))

    defp empty_row(agent_id) do
      %{
        agent_id: agent_id,
        agent_module: nil,
        parent_agent_id: nil,
        status: "idle",
        started_at: nil,
        conversation_state: nil,
        usage: [],
        ratelimit_metadata: nil,
        inserted_at: nil,
        updated_at: nil
      }
    end
  end

  defmodule Store do
    use Legion.Store.Postgres, repo: Legion.Store.PostgresTest.FakeRepo
  end

  defmodule StepStore do
    use Legion.Store.Postgres,
      repo: Legion.Store.PostgresTest.FakeRepo,
      persistence_frequency: :step
  end

  setup do
    start_supervised!(%{id: FakeRepo, start: {FakeRepo, :start_link, []}})
    :ok
  end

  test "generated stores expose their configured persistence frequency" do
    assert Legion.Store.persistence_frequency(Store) == :turn
    assert Legion.Store.persistence_frequency(StepStore) == :step
  end

  test "save/1 round trips executor_state for a step checkpoint" do
    executor_state = %{phase: :awaiting_llm, iteration: 2, retries: 1}

    payload = %Payload{
      agent_id: "step-state",
      status: :running,
      conversation_state: %{
        messages: [%{role: "user", content: "result"}],
        bindings: [x: 42],
        executor_state: executor_state
      }
    }

    assert :ok = Store.save(payload)

    expected_payload = %{payload | usage: []}
    assert {:ok, ^expected_payload} = Store.get("step-state")
  end

  test "save/1 rejects unknown payload keys without inserting a row" do
    assert :error = Store.save(%{agent_id: "user_42", unexpected: "value"})
    assert FakeRepo.run("user_42") == nil
  end

  test "save/1 rejects a payload with non-string agent_id without inserting a row" do
    assert :error = Store.save(%Payload{agent_id: 42})
    assert FakeRepo.run(42) == nil
    assert :error = Store.save(%Payload{agent_id: <<0xFF>>})
    assert FakeRepo.run(<<0xFF>>) == nil
  end

  test "get/1 rejects a non-string agent_id" do
    assert :error = Store.get(42)
    assert :error = Store.get(<<0xFF>>)
  end
end
