defmodule Legion.RateLimiter.Postgres do
  @moduledoc """
  A Postgres-backed `Legion.RateLimiter` extending `Legion.Store.Postgres`.

  This adapter depends on an existing `Legion.Store.Postgres` configuration.
  It stores rate-limit metadata in that store's table and reads persisted usage from it.
  Configure the store first, then define a rate limiter using the same Ecto repo and table:

      defmodule MyApp.AgentStore do
        use Legion.Store.Postgres, repo: MyApp.Repo
      end

      defmodule MyApp.RateLimiter do
        use Legion.RateLimiter.Postgres, repo: MyApp.Repo
      end

  The Store migration creates the rate-limit metadata column and its GIN index.
  No separate rate-limiter migration is required:

      defmodule MyApp.Repo.Migrations.AddLegionAgents do
        use Ecto.Migration

        def up, do: Legion.Store.Postgres.Migration.up()
        def down, do: Legion.Store.Postgres.Migration.down()
      end

  Call the generated limiter before running work, passing every rule that
  applies to the agent:

      policy = %Legion.RateLimiter.Policy{
        window_ms: :timer.minutes(1),
        max_agents: 10,
        max_tokens: 100_000
      }

      :ok =
        MyApp.RateLimiter.enforce!(agent_id, [
          %Legion.RateLimiter.Rule{identity: %{"ip" => "203.0.113.42"}, policy: policy}
        ])

  All rules are evaluated inside one transaction: the adapter locks every
  distinct identity (in a global order, so agents naming the same identities
  in different orders cannot deadlock), records the agent, then checks the
  rules in the order given. The first violated rule raises and rolls the whole
  call back, leaving metadata only for allowed calls.

  Limits are evaluated when a turn starts; a turn that is already running is
  never interrupted, so one turn can carry the recorded total past
  `:max_tokens` before the next call is denied.

  ## Identity matching

  An agent's rule identities are merged into one JSON metadata document and
  matched with Postgres JSON containment. Each rule is evaluated against the
  agents whose metadata contains its identity, so an agent recorded under
  `%{"ip" => "203.0.113.42"}` and `%{"email" => "someone@example.com"}` counts
  towards both groups, and a broader identity such as
  `%{"ip" => "203.0.113.42"}` also matches an agent recorded with a `"tenant"`
  field. Rules passed directly to `enforce!/2` must agree on shared fields;
  `Legion.start_link/2` validates this, and the adapter does not. Calling
  `enforce!/2` again for the same agent replaces its stored metadata while
  retaining its original start time, and marks it `running` when a rule
  limits running agents.

  ## Limit evaluation

  The adapter includes the agent being checked when it evaluates
  `:max_agents`, so it raises only when that call would make the matching count
  exceed the configured maximum. Agents are counted by `started_at`.

  `:max_running_agents` counts the matching agents mid-turn: rows whose stored
  status is `running`, changed inside the window, and whose agent process is
  alive. A turn interrupted by a crash never writes `idle` back, so a dead
  process does not hold a slot. When a rule sets this limit, the adapter marks
  the caller `running` in the same transaction, before it counts, so
  concurrent starts see each other; the caller's own row is included, as with
  `:max_agents`.

  `:max_tokens` is evaluated from recorded `"total_tokens"` usage whose `"at"`
  timestamp falls inside the policy's window; once that total reaches the
  configured maximum, later calls raise.

  Token limits require Legion usage tracking, which is enabled by default. If
  your application configures `config :legion, :track_usage, false`, leave
  `:max_tokens` as `nil`; agent limits do not require usage tracking.

  ## Options

    * `:repo` (required) - the Ecto repo used by the configured store.
    * `:table` - the shared Store table name, defaulting to `"legion_agents"`.
      It must also be passed to the Store migration.
  """

  alias Legion.RateLimiter.ExceededError
  alias Legion.RateLimiter.Rule

  @doc false
  def enforce!(repo, record, agent_id, rules) when is_binary(agent_id) and is_list(rules) do
    metadata = Enum.reduce(rules, %{}, &Map.merge(&2, &1.identity))
    mark_running? = Enum.any?(rules, &(&1.policy.max_running_agents != nil))

    {:ok, :ok} =
      repo.transaction(fn ->
        rules
        |> Enum.map(&Jason.encode!(&1.identity))
        |> Enum.sort()
        |> Enum.uniq()
        |> Enum.each(&lock_identity(repo, &1))

        upsert_metadata(repo, record, agent_id, metadata, mark_running?)

        Enum.each(rules, fn %Rule{identity: identity, policy: policy} ->
          usage = fetch_usage(repo, record, identity, policy)
          violations = find_violations(usage, policy)

          violations == [] ||
            raise ExceededError,
              agent_id: agent_id,
              identity: identity,
              policy: policy,
              usage: usage,
              violations: violations
        end)

        :ok
      end)

    :ok
  end

  def enforce!(_repo, _record, agent_id, other) do
    raise ArgumentError,
          "invalid rate-limit arguments: " <>
            "#{inspect(agent_id)}, #{inspect(other)}"
  end

  # Serializes concurrent calls for the same identity so `:max_agents` counts
  # every in-flight transaction, not only those already committed.
  defp lock_identity(repo, encoded_identity) do
    repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [encoded_identity])
    :ok
  end

  # A running limit needs the caller's turn visible to the counts that follow
  # in this transaction, so the row is marked before the lock is released.
  # Without one the row is only touched when its identity changed.
  defp upsert_metadata(repo, record, agent_id, metadata_identity, mark_running?) do
    import Ecto.Query

    now = NaiveDateTime.utc_now()
    row = %{agent_id: agent_id, ratelimit_metadata: metadata_identity, started_at: now}

    {row, on_conflict} =
      if mark_running? do
        {Map.merge(row, %{status: "running", updated_at: now}),
         from(agent in record,
           update: [
             set: [ratelimit_metadata: ^metadata_identity, status: "running", updated_at: ^now]
           ]
         )}
      else
        {row,
         from(agent in record,
           update: [set: [ratelimit_metadata: ^metadata_identity]],
           where:
             fragment(
               "? IS DISTINCT FROM ?",
               agent.ratelimit_metadata,
               type(^metadata_identity, :map)
             )
         )}
      end

    {_count, _} =
      repo.insert_all(record, [row], conflict_target: :agent_id, on_conflict: on_conflict)

    :ok
  end

  defp fetch_usage(repo, record, metadata_identity, policy) do
    now = DateTime.utc_now()

    %{
      agents: count_agents(repo, record, metadata_identity, policy, now),
      running: count_running(repo, record, metadata_identity, policy, now),
      tokens: sum_tokens(repo, record, metadata_identity, policy, now)
    }
  end

  defp count_agents(_repo, _record, _metadata_identity, %{max_agents: nil}, _now), do: nil

  defp count_agents(repo, record, metadata_identity, policy, now) do
    import Ecto.Query

    from(agent in record,
      where:
        fragment(
          "? @> ?::jsonb",
          agent.ratelimit_metadata,
          type(^metadata_identity, :map)
        ),
      where: agent.started_at >= ^naive_cutoff(now, policy),
      select: count(agent.agent_id)
    )
    |> repo.one()
  end

  defp count_running(_repo, _record, _metadata_identity, %{max_running_agents: nil}, _now),
    do: nil

  # The stored status is a hint: an agent killed mid-turn never writes `idle`
  # back, so only rows whose process is still alive count.
  defp count_running(repo, record, metadata_identity, policy, now) do
    import Ecto.Query

    from(agent in record,
      where:
        fragment(
          "? @> ?::jsonb",
          agent.ratelimit_metadata,
          type(^metadata_identity, :map)
        ),
      where: agent.status == "running",
      where: agent.updated_at >= ^naive_cutoff(now, policy),
      select: agent.agent_id
    )
    |> repo.all()
    |> Enum.count(&live?/1)
  end

  defp live?(agent_id) do
    case Legion.lookup(agent_id) do
      {:ok, pid} -> Legion.running?(pid)
      :error -> false
    end
  end

  defp sum_tokens(_repo, _record, _metadata_identity, %{max_tokens: nil}, _now), do: nil

  defp sum_tokens(repo, record, metadata_identity, policy, now) do
    import Ecto.Query

    cutoff = DateTime.to_unix(now, :millisecond) - policy.window_ms

    from(agent in record,
      inner_lateral_join: entry in fragment("SELECT unnest(?) AS value", agent.usage),
      on: true,
      where:
        fragment(
          "? @> ?::jsonb",
          agent.ratelimit_metadata,
          type(^metadata_identity, :map)
        ),
      where: fragment("(?->>'at')::bigint >= ?", field(entry, :value), ^cutoff),
      where: agent.updated_at >= ^naive_cutoff(now, policy),
      select:
        fragment(
          "coalesce(sum((?->>'total_tokens')::bigint), 0)::bigint",
          field(entry, :value)
        )
    )
    |> repo.one()
  end

  defp naive_cutoff(now, policy) do
    now
    |> DateTime.add(-policy.window_ms, :millisecond)
    |> DateTime.to_naive()
  end

  # The agent counts include the caller's own row, hence `>`; tokens are
  # consumed before this check, hence `>=`.
  defp find_violations(usage, policy) do
    for {name, true} <- %{
          max_agents: usage.agents != nil and usage.agents > policy.max_agents,
          max_running_agents: usage.running != nil and usage.running > policy.max_running_agents,
          max_tokens: usage.tokens != nil and usage.tokens >= policy.max_tokens
        },
        do: name
  end

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.get(opts, :table, "legion_agents")

    quote do
      @behaviour Legion.RateLimiter

      alias Legion.RateLimiter

      defmodule Record do
        @moduledoc false

        use Ecto.Schema

        @primary_key {:agent_id, :string, autogenerate: false}

        schema unquote(table) do
          field :status, :string
          field :started_at, :naive_datetime_usec
          field :usage, {:array, :map}
          field :updated_at, :naive_datetime_usec
          field :ratelimit_metadata, :map
        end
      end

      @impl Legion.RateLimiter
      def enforce!(agent_id, rules) do
        RateLimiter.Postgres.enforce!(
          unquote(repo),
          Record,
          agent_id,
          rules
        )
      end
    end
  end
end
