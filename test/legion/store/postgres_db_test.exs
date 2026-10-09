defmodule Legion.Store.PostgresDbTest do
  @moduledoc "Exercises the generated Postgres store against a real database."
  use ExUnit.Case, async: true

  alias Ecto.UUID
  alias Legion.RateLimiter.Policy
  alias Legion.RateLimiter.Rule
  alias Legion.Store.Payload
  alias Legion.Test.Support.PostgresRepo, as: Repo

  defmodule Store do
    use Legion.Store.Postgres, repo: Legion.Test.Support.PostgresRepo
  end

  defmodule RateLimiter do
    use Legion.RateLimiter.Postgres, repo: Legion.Test.Support.PostgresRepo
  end

  # The table is shared with concurrent tests and keeps rows from earlier runs,
  # so every test writes its own random agent ids.
  setup do
    %{agent_id: "agent-#{UUID.generate()}"}
  end

  test "stores usage as a jsonb array", %{agent_id: agent_id} do
    payload = %Payload{
      agent_id: agent_id,
      usage: [
        %{
          input_tokens: 12,
          output_tokens: 5,
          turn_usage: 17,
          tool_usage: %{web_search: 1},
          at: 1_786_000_000_000
        },
        %{input_tokens: 7, output_tokens: 3, turn_usage: 10}
      ]
    }

    assert :ok = Store.save(payload)

    assert {:ok,
            %Payload{
              usage: [
                %{
                  "input_tokens" => 12,
                  "output_tokens" => 5,
                  "turn_usage" => 17,
                  "tool_usage" => %{"web_search" => 1},
                  "at" => 1_786_000_000_000
                },
                %{"input_tokens" => 7, "output_tokens" => 3, "turn_usage" => 10}
              ]
            }} = Store.get(agent_id)

    assert %{rows: [["jsonb[]"]]} =
             Repo.query!("SELECT pg_typeof(usage)::text FROM legion_agents WHERE agent_id = $1", [
               agent_id
             ])
  end

  test "exposes the rate limiter's metadata and keeps it across partial saves",
       %{agent_id: agent_id} do
    identity = %{"ip" => "203.0.113.42", "tenant" => "acme"}
    unlimited = "unlimited-#{agent_id}"

    assert :ok =
             RateLimiter.enforce!(agent_id, [
               %Rule{identity: identity, policy: %Policy{window_ms: 60_000}}
             ])

    assert {:ok, %Payload{ratelimit_metadata: ^identity}} = Store.get(agent_id)

    assert :ok = Store.save(%Payload{agent_id: agent_id, status: :running})
    assert {:ok, %Payload{status: :running, ratelimit_metadata: ^identity}} = Store.get(agent_id)

    assert :ok = Store.save(%Payload{agent_id: unlimited, status: :idle})
    assert {:ok, %Payload{ratelimit_metadata: nil}} = Store.get(unlimited)
  end

  test "save/1 fully inserts every payload field", %{agent_id: agent_id} do
    payload = %Payload{
      agent_id: agent_id,
      agent_module: Legion.Test.Support.MathAgent,
      parent_agent_id: "parent-1",
      status: :idle,
      started_at: ~N[2026-01-01 00:00:00.000000],
      conversation_state: %{
        messages: [%{role: "user", content: "hi"}],
        bindings: [x: 42],
        executor_state: :nonexistent
      },
      usage: [%{turn_usage: 100}],
      ratelimit_metadata: %{"ip" => "203.0.113.42", "tenant" => "acme"}
    }

    expected_payload = %{payload | usage: [%{"turn_usage" => 100}]}

    assert :ok = Store.save(payload)
    assert {:ok, ^expected_payload} = Store.get(agent_id)
  end

  test "save/1 partially inserts only the supplied payload fields", %{agent_id: agent_id} do
    payload = %Payload{
      agent_id: agent_id,
      conversation_state: %{
        messages: [%{role: "user", content: "hi"}],
        bindings: [],
        executor_state: :nonexistent
      }
    }

    assert :ok = Store.save(payload)
    assert {:ok, stored} = Store.get(agent_id)
    assert stored == %{payload | status: :idle, usage: []}
  end

  test "save/1 partial upsert preserves omitted fields and advances updated_at",
       %{agent_id: agent_id} do
    initial = %Payload{
      agent_id: agent_id,
      agent_module: Legion.Test.Support.MathAgent,
      parent_agent_id: "parent-1",
      status: :running,
      started_at: ~N[2026-01-01 00:00:00.000000],
      conversation_state: %{
        messages: [%{role: "user", content: "hi"}],
        bindings: [x: 42],
        executor_state: :nonexistent
      },
      usage: [%{turn_usage: 100}],
      ratelimit_metadata: %{"ip" => "203.0.113.42"}
    }

    assert :ok = Store.save(initial)

    previous_updated_at = ~N[2026-01-01 00:00:00.000000]

    Repo.query!("UPDATE legion_agents SET updated_at = $2 WHERE agent_id = $1", [
      agent_id,
      previous_updated_at
    ])

    assert :ok = Store.save(%Payload{agent_id: agent_id, status: :idle})

    assert {:ok,
            %Payload{
              agent_module: Legion.Test.Support.MathAgent,
              parent_agent_id: "parent-1",
              status: :idle,
              started_at: ~N[2026-01-01 00:00:00.000000],
              conversation_state: %{
                messages: [%{role: "user", content: "hi"}],
                bindings: [x: 42],
                executor_state: :nonexistent
              },
              usage: [%{"turn_usage" => 100}],
              ratelimit_metadata: %{"ip" => "203.0.113.42"}
            }} = Store.get(agent_id)

    %{rows: [[updated_at]]} =
      Repo.query!("SELECT updated_at FROM legion_agents WHERE agent_id = $1", [agent_id])

    assert NaiveDateTime.compare(updated_at, previous_updated_at) == :gt
  end
end
