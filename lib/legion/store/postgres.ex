defmodule Legion.Store.Postgres do
  @moduledoc """
  A ready-made `Legion.Store` backed by Postgres, through your existing Ecto repo.

  The generated store uses Ecto for its schema, reads, and partial upserts.
  Legion depends on `ecto_sql` and `postgrex`, so this adapter needs nothing
  extra in your `mix.exs` - only an `Ecto.Repo` backed by
  `Ecto.Adapters.Postgres`.

  ## Usage

  Define a Postgres-backed Ecto repo and a store module that uses it:

      defmodule MyApp.AgentStore do
        use Legion.Store.Postgres, repo: MyApp.Repo
      end

  Create the table in a migration with `Legion.Store.Postgres.Migration`:

      defmodule MyApp.Repo.Migrations.AddLegionAgents do
        use Ecto.Migration

        def up, do: Legion.Store.Postgres.Migration.up()
        def down, do: Legion.Store.Postgres.Migration.down()
      end

  The Store migration also creates the `ratelimit_metadata` column and GIN index used
  by `Legion.RateLimiter.Postgres`; no additional migration is needed.

  Then start agents with it:

      {:ok, pid} = Legion.start_link(AssistantAgent, store: MyApp.AgentStore, agent_id: "user_42")

  ## Options

    - `:repo` (required) - your Ecto repo module
    - `:table` - the table name, defaults to `"legion_agents"`
    - `:persistence_frequency` - `:turn` (default) or `:step`

  To persist intermediate eval results and recoverable errors:

      defmodule MyApp.AgentStore do
        use Legion.Store.Postgres,
          repo: MyApp.Repo,
          persistence_frequency: :step
      end

  Agent ids must be valid UTF-8 strings. Snapshots are stored as compressed
  `:erlang.term_to_binary/2` blobs - readable only from Elixir, one row
  per conversation, upserted on every save. Step snapshots therefore require
  no additional migration.

  `save/1` performs partial upserts, so a row carries the conversation state
  and identity. Omitted payload fields preserve their existing values. The
  `updated_at` timestamp is automatically set to the current UTC time on every save.
  Only `agent_id` and `inserted_at` are never updated.

  The row's `status` flips to `'running'` when a turn starts and back to
  `'idle'` when it completes. Step writes update only the conversation state,
  leaving the running status unchanged.

  Usage is stored as a `jsonb[]`: each element contains one complete,
  string-keyed usage map.

  `list/1` and `get/1` read persisted conversations back from the same table.

  The migration also installs a trigger that `pg_notify`s the table's channel
  (the table name) with the `agent_id` on every insert or update, so
  consumers can follow store changes live without polling.
  """

  alias Legion.Store.Payload

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.get(opts, :table, "legion_agents")
    persistence_frequency = Keyword.get(opts, :persistence_frequency, :turn)

    quote do
      @behaviour Legion.Store

      import Ecto.Query, only: [from: 2]

      alias Legion.Store.Payload
      alias Legion.Store.Postgres

      defmodule Record do
        use Ecto.Schema

        @primary_key {:agent_id, :string, autogenerate: false}

        schema unquote(table) do
          field :agent_module, :string
          field :parent_agent_id, :string
          field :status, :string
          field :started_at, :naive_datetime_usec
          field :conversation_state, :binary
          field :usage, {:array, :map}
          field :inserted_at, :naive_datetime_usec
          field :updated_at, :naive_datetime_usec
          field :ratelimit_metadata, :map
        end
      end

      @impl Legion.Store
      def persistence_frequency, do: unquote(persistence_frequency)

      @impl Legion.Store
      def get(agent_id) when not is_binary(agent_id), do: :error

      @impl Legion.Store
      def get(agent_id) do
        if String.valid?(agent_id) do
          do_get(agent_id)
        else
          :error
        end
      end

      defp do_get(agent_id) do
        case unquote(repo).get(Record, agent_id) do
          nil -> :error
          record -> {:ok, Postgres.decode_record(record)}
        end
      end

      @impl Legion.Store
      def list(limit) when is_integer(limit) and limit > 0 do
        from(record in Record, order_by: [desc: record.updated_at], limit: ^limit)
        |> unquote(repo).all()
        |> Enum.map(&Postgres.decode_record/1)
      end

      def save(map) when is_map(map) and not is_struct(map), do: :error

      @impl Legion.Store
      def save(%Payload{agent_id: agent_id}) when not is_binary(agent_id), do: :error

      @impl Legion.Store
      def save(%Payload{agent_id: agent_id} = payload) do
        if String.valid?(agent_id) do
          do_save(payload)
        else
          :error
        end
      end

      defp do_save(payload) do
        attrs =
          payload
          |> Postgres.encode_data()
          |> Map.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.put(:updated_at, NaiveDateTime.utc_now())

        update_columns = attrs |> Map.delete(:agent_id) |> Map.keys()

        case unquote(repo).insert_all(
               Record,
               [attrs],
               conflict_target: :agent_id,
               on_conflict: {:replace, update_columns}
             ) do
          {1, _} -> :ok
          _ -> :error
        end
      end

      @doc false
      def __repo__, do: unquote(repo)

      @doc false
      def __table__, do: unquote(table)
    end
  end

  def encode_data(%Payload{} = payload) do
    payload
    |> Map.from_struct()
    |> Map.update(:conversation_state, nil, fn state ->
      # Snapshots are large, repetitive terms (message text, bindings)
      # that compress several-fold. Old uncompressed rows still decode fine.
      if not is_nil(state), do: :erlang.term_to_binary(state, compressed: 6)
    end)
    |> Map.update(:agent_module, nil, fn module ->
      if not is_nil(module), do: inspect(module)
    end)
    |> Map.update(:status, nil, fn status ->
      if not is_nil(status), do: Atom.to_string(status)
    end)
  end

  @doc false
  def decode_record(record) do
    %Payload{
      agent_id: record.agent_id,
      agent_module: record.agent_module && Module.concat([record.agent_module]),
      parent_agent_id: record.parent_agent_id,
      status: decode_status(record.status),
      started_at: record.started_at,
      conversation_state: decode_conversation_state(record.conversation_state),
      usage: record.usage,
      ratelimit_metadata: record.ratelimit_metadata
    }
  end

  defp decode_conversation_state(nil), do: nil

  # sobelow_skip ["Misc.BinToTerm"]
  defp decode_conversation_state(binary) when is_binary(binary) do
    state = :erlang.binary_to_term(binary)

    %{
      messages: Map.get(state, :messages, []),
      bindings: Map.get(state, :bindings, []),
      executor_state: Map.get(state, :executor_state, :nonexistent)
    }
  end

  defp decode_status("running"), do: :running
  defp decode_status("idle"), do: :idle
end
