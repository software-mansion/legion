defmodule Legion.Test.Support.MemoryStore do
  @moduledoc false
  @behaviour Legion.Store

  alias Legion.Store.Payload

  def start_link(_opts \\ []),
    do: Agent.start_link(fn -> %{rows: %{}, fail?: false} end, name: __MODULE__)

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def fail_saves(fail?), do: Agent.update(__MODULE__, &%{&1 | fail?: fail?})

  @impl true
  def get(agent_id), do: Agent.get(__MODULE__, &Map.fetch(&1.rows, agent_id))

  @impl true
  def list(limit), do: Agent.get(__MODULE__, &(&1.rows |> Map.values() |> Enum.take(limit)))

  # Payloads are partial updates: nil fields keep the stored value.
  @impl true
  def save(%Payload{} = payload) do
    Agent.get_and_update(__MODULE__, fn
      %{fail?: true} = state ->
        {:error, state}

      state ->
        given =
          payload |> Map.from_struct() |> Map.reject(fn {_field, value} -> is_nil(value) end)

        row = state.rows |> Map.get(payload.agent_id, payload) |> struct!(given)
        {:ok, put_in(state.rows[payload.agent_id], row)}
    end)
  end
end
