defmodule Legion.RateLimiter.PostgresDbTest do
  use ExUnit.Case, async: true

  alias Ecto.UUID
  alias Legion.RateLimiter.ExceededError
  alias Legion.RateLimiter.Policy
  alias Legion.RateLimiter.Rule
  alias Legion.Test.Support.MathAgent
  alias Legion.Test.Support.MemoryStore
  alias Legion.Test.Support.PostgresRepo, as: Repo

  # Every policy uses a one-minute window; rows timestamped this long ago fall
  # outside it however slowly the test runs.
  @outside_window_ms 120_000

  defmodule RateLimiter do
    use Legion.RateLimiter.Postgres, repo: Legion.Test.Support.PostgresRepo
  end

  defmodule Store do
    use Legion.Store.Postgres, repo: Legion.Test.Support.PostgresRepo
  end

  defmodule OtherTableStore do
    use Legion.Store.Postgres, repo: Legion.Test.Support.PostgresRepo, table: "other_agents"
  end

  # The table is shared with concurrent tests and keeps rows from earlier runs,
  # so every test counts only its own random identities and agent ids.
  setup do
    unique = UUID.generate()
    ip = %{"ip" => "203.0.113.42-#{unique}"}

    %{
      ip: ip,
      other_ip: %{"ip" => "198.51.100.7-#{unique}"},
      tenant_ip: Map.put(ip, "tenant", "acme"),
      email: %{"email" => "someone-#{unique}@example.com"}
    }
  end

  test "allows exactly max_agents matching agents and rejects the next", %{ip: ip} do
    rules = [rule(ip, policy(max_agents: 2))]

    assert :ok = RateLimiter.enforce!(agent_id(), rules)
    assert :ok = RateLimiter.enforce!(agent_id(), rules)

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!(agent_id(), rules)
    end
  end

  test "counts a broader identity's agents with more specific metadata", context do
    policy = policy(max_agents: 1)

    assert :ok = RateLimiter.enforce!(agent_id(), [rule(context.tenant_ip, policy)])

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!(agent_id(), [rule(context.ip, policy)])
    end
  end

  test "does not count agents whose starts predate the agent window", %{ip: ip} do
    insert_agent(agent_id(), ip, started_at: outside_window())

    assert :ok = RateLimiter.enforce!(agent_id(), [rule(ip, policy(max_agents: 1))])
  end

  test "counts timestamped token usage from agents started before the window", %{ip: ip} do
    insert_agent(agent_id(), ip, started_at: outside_window(), usage: [usage(total_tokens: 10)])

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!(agent_id(), [rule(ip, policy(max_tokens: 10))])
    end
  end

  test "does not count token usage outside the token window", %{ip: ip} do
    insert_agent(agent_id(), ip, usage: [usage(total_tokens: 10, at: outside_window_timestamp())])

    assert :ok = RateLimiter.enforce!(agent_id(), [rule(ip, policy(max_tokens: 10))])
  end

  # Usage is only ever appended by a store save, and every save bumps
  # updated_at, so a row untouched since before the window cannot hold usage
  # inside it. Skipping those rows keeps the token sum proportional to the
  # window rather than to the whole history of the group.
  test "ignores rows untouched since before the token window", %{ip: ip} do
    insert_agent(agent_id(), ip, usage: [usage(total_tokens: 10)], updated_at: outside_window())

    assert :ok = RateLimiter.enforce!(agent_id(), [rule(ip, policy(max_tokens: 10))])
  end

  test "rejects when recorded tokens reach max_tokens", %{ip: ip} do
    insert_agent(agent_id(), ip, usage: [usage(total_tokens: 10)])

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!(agent_id(), [rule(ip, policy(max_tokens: 10))])
    end
  end

  test "allows calls while recorded evals stay below max_evals", %{ip: ip} do
    session = agent_id()
    insert_agent(session, ip, usage: evals(2))

    assert :ok = RateLimiter.enforce!(session, [rule(ip, policy(max_evals: 3))])
  end

  test "rejects when recorded evals reach max_evals, reporting the count", %{ip: ip} do
    session = agent_id()
    insert_agent(session, ip, usage: evals(3))

    error =
      assert_raise ExceededError, fn ->
        RateLimiter.enforce!(session, [rule(ip, policy(max_evals: 3))])
      end

    assert error.violations == [:max_evals]
    assert error.usage.evals == 3
  end

  test "counts evals across every row of the identity", %{ip: ip} do
    insert_agent(agent_id(), ip, usage: evals(2))
    insert_agent(agent_id(), ip, usage: evals(1))

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!(agent_id(), [rule(ip, policy(max_evals: 3))])
    end
  end

  test "does not count evals outside the window", %{ip: ip} do
    session = agent_id()
    insert_agent(session, ip, usage: evals(3, at: outside_window_timestamp()))

    assert :ok = RateLimiter.enforce!(session, [rule(ip, policy(max_evals: 3))])
  end

  test "does not count another identity's evals", context do
    insert_agent(agent_id(), context.other_ip, usage: evals(3))

    assert :ok = RateLimiter.enforce!(agent_id(), [rule(context.ip, policy(max_evals: 3))])
  end

  test "evals are not tokens and tokens are not evals", %{ip: ip} do
    insert_agent(agent_id(), ip, usage: [usage(total_tokens: 10) | evals(1)])

    assert :ok =
             RateLimiter.enforce!(agent_id(), [rule(ip, policy(max_tokens: 11, max_evals: 2))])
  end

  test "reports every active violation of a rule without requiring an order", %{ip: ip} do
    insert_agent(agent_id(), ip, usage: [usage(total_tokens: 10)])

    error =
      assert_raise ExceededError, fn ->
        RateLimiter.enforce!(agent_id(), [rule(ip, policy(max_agents: 1, max_tokens: 10))])
      end

    assert MapSet.new(error.violations) == MapSet.new([:max_agents, :max_tokens])
  end

  test "zero limits allow none", context do
    assert_raise ExceededError, fn ->
      RateLimiter.enforce!(agent_id(), [rule(context.ip, policy(max_agents: 0))])
    end

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!(agent_id(), [rule(context.other_ip, policy(max_tokens: 0))])
    end

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!(agent_id(), [rule(context.email, policy(max_evals: 0))])
    end
  end

  test "allows an unrestricted policy", %{ip: ip} do
    assert :ok = RateLimiter.enforce!(agent_id(), [rule(ip, policy())])
  end

  test "rejects arguments that are not an agent id and a list of rules", %{ip: ip} do
    assert_raise ArgumentError, ~r/invalid rate-limit arguments/, fn ->
      RateLimiter.enforce!(agent_id(), rule(ip, policy()))
    end
  end

  describe "several rules" do
    test "records the merged identities of every rule", context do
      agent = agent_id()

      assert :ok =
               RateLimiter.enforce!(agent, [
                 rule(context.ip, policy()),
                 rule(context.email, policy())
               ])

      assert %{rows: [[metadata]]} =
               Repo.query!("SELECT ratelimit_metadata FROM legion_agents WHERE agent_id = $1", [
                 agent
               ])

      assert metadata == Map.merge(context.ip, context.email)
    end

    test "counts an agent under each of its rules' groups", context do
      assert :ok =
               RateLimiter.enforce!(agent_id(), [
                 rule(context.ip, policy()),
                 rule(context.email, policy())
               ])

      assert_raise ExceededError, fn ->
        RateLimiter.enforce!(agent_id(), [rule(context.ip, policy(max_agents: 1))])
      end

      assert_raise ExceededError, fn ->
        RateLimiter.enforce!(agent_id(), [rule(context.email, policy(max_agents: 1))])
      end
    end

    test "rejects the agent when any rule is violated and records nothing", context do
      insert_agent(agent_id(), context.email)
      rejected = agent_id()

      error =
        assert_raise ExceededError, fn ->
          RateLimiter.enforce!(rejected, [
            rule(context.ip, policy(max_agents: 5)),
            rule(context.email, policy(max_agents: 1))
          ])
        end

      assert error.identity == context.email
      assert error.violations == [:max_agents]

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM legion_agents WHERE agent_id = $1", [rejected])
    end

    test "reports the first violated rule in list order", context do
      insert_agent(agent_id(), Map.merge(context.ip, context.email))
      ip_rule = rule(context.ip, policy(max_agents: 1))
      email_rule = rule(context.email, policy(max_agents: 1))

      error =
        assert_raise ExceededError, fn ->
          RateLimiter.enforce!(agent_id(), [ip_rule, email_rule])
        end

      assert error.identity == context.ip

      error =
        assert_raise ExceededError, fn ->
          RateLimiter.enforce!(agent_id(), [email_rule, ip_rule])
        end

      assert error.identity == context.email
    end

    test "evaluates one identity under several windows", %{ip: ip} do
      insert_agent(agent_id(), ip, started_at: outside_window())
      short = policy(max_agents: 1)
      long = policy(window_ms: :timer.hours(1), max_agents: 1)

      error =
        assert_raise ExceededError, fn ->
          RateLimiter.enforce!(agent_id(), [rule(ip, short), rule(ip, long)])
        end

      assert error.policy == long
    end

    # Rules lock their identities in a global order, so two agents naming the
    # same identities in different orders never deadlock; one of them wins
    # every shared group and the rest are denied, and only it leaves a row.
    test "allows exactly one agent under concurrent calls with overlapping rules in mixed order",
         context do
      ip_rule = rule(context.ip, policy(max_agents: 1))
      email_rule = rule(context.email, policy(max_agents: 1))
      test_pid = self()

      tasks =
        for index <- 1..20 do
          rules = if rem(index, 2) == 0, do: [ip_rule, email_rule], else: [email_rule, ip_rule]

          Task.async(fn ->
            send(test_pid, {:ready, self()})

            receive do
              :enforce ->
                try do
                  RateLimiter.enforce!(agent_id(), rules)
                rescue
                  ExceededError -> :exceeded
                end
            end
          end)
        end

      for _ <- tasks, do: assert_receive({:ready, _})
      for task <- tasks, do: send(task.pid, :enforce)

      outcomes = Enum.map(tasks, &Task.await(&1, 5_000))

      assert Enum.count(outcomes, &(&1 == :ok)) == 1
      assert Enum.count(outcomes, &(&1 == :exceeded)) == 19

      assert %{rows: [[1]]} =
               Repo.query!(
                 "SELECT count(*) FROM legion_agents WHERE ratelimit_metadata @> $1::jsonb",
                 [context.ip]
               )
    end
  end

  test "does not notify for a metadata upsert with an unchanged identity", %{ip: ip} do
    notifications = start_supervised!({Postgrex.Notifications, postgres_options()})
    listen_ref = Postgrex.Notifications.listen!(notifications, "legion_agents")
    agent = agent_id()
    rules = [rule(ip, policy())]

    assert :ok = RateLimiter.enforce!(agent, rules)

    assert_receive {:notification, ^notifications, ^listen_ref, "legion_agents", ^agent}

    assert :ok = RateLimiter.enforce!(agent, rules)

    refute_receive {:notification, ^notifications, ^listen_ref, "legion_agents", ^agent}
  end

  test "moves an agent to its new identity without resetting its start time", context do
    agent = agent_id()
    assert :ok = RateLimiter.enforce!(agent, [rule(context.ip, policy())])
    started_at = started_at(agent)

    assert :ok = RateLimiter.enforce!(agent, [rule(context.other_ip, policy())])
    assert started_at(agent) == started_at

    assert :ok = RateLimiter.enforce!(agent_id(), [rule(context.ip, policy(max_agents: 1))])

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!(agent_id(), [rule(context.other_ip, policy(max_agents: 1))])
    end
  end

  describe "max_running_agents" do
    test "allows exactly max_running_agents live agents mid-turn", %{ip: ip} do
      rules = [rule(ip, policy(max_running_agents: 2))]
      [first, second, third] = for _ <- 1..3, do: start_live_agent()

      assert :ok = RateLimiter.enforce!(first, rules)
      assert :ok = RateLimiter.enforce!(second, rules)

      error = assert_raise(ExceededError, fn -> RateLimiter.enforce!(third, rules) end)
      assert error.violations == [:max_running_agents]
      assert error.usage.running == 3
    end

    test "frees the slot once the agent's turn ends", %{ip: ip} do
      rules = [rule(ip, policy(max_running_agents: 1))]
      finished = start_live_agent()

      assert :ok = RateLimiter.enforce!(finished, rules)
      Repo.query!("UPDATE legion_agents SET status = 'idle' WHERE agent_id = $1", [finished])

      assert :ok = RateLimiter.enforce!(start_live_agent(), rules)
    end

    test "does not count a running row whose agent is gone", %{ip: ip} do
      insert_agent(agent_id(), ip, status: "running")

      assert :ok =
               RateLimiter.enforce!(start_live_agent(), [rule(ip, policy(max_running_agents: 1))])
    end

    test "keeps counting a turn that outlasts the window", %{ip: ip} do
      long_turn = start_live_agent()

      insert_agent(long_turn, ip,
        status: "running",
        started_at: outside_window(),
        updated_at: outside_window()
      )

      error =
        assert_raise ExceededError, fn ->
          RateLimiter.enforce!(start_live_agent(), [rule(ip, policy(max_running_agents: 1))])
        end

      assert error.violations == [:max_running_agents]
    end

    test "leaves the status alone when no rule limits running agents", %{ip: ip} do
      agent = agent_id()
      assert :ok = RateLimiter.enforce!(agent, [rule(ip, policy())])

      assert %{rows: [["idle"]]} =
               Repo.query!("SELECT status FROM legion_agents WHERE agent_id = $1", [agent])
    end

    test "allows exactly max_running_agents under concurrent calls", %{ip: ip} do
      rules = [rule(ip, policy(max_running_agents: 1))]
      test_pid = self()

      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            agent = agent_id()
            :yes = Legion.AgentIndex.register_name(agent, self())
            send(test_pid, {:ready, self()})

            receive do
              :enforce -> :ok
            end

            outcome =
              try do
                RateLimiter.enforce!(agent, rules)
              rescue
                ExceededError -> :exceeded
              end

            # A real agent stays alive for its whole turn, so hold the slot
            # until every call has its verdict.
            send(test_pid, {:outcome, self(), outcome})

            receive do
              :stop -> outcome
            end
          end)
        end

      for _ <- tasks, do: assert_receive({:ready, _})
      for task <- tasks, do: send(task.pid, :enforce)
      for _ <- tasks, do: assert_receive({:outcome, _, _}, 5_000)
      for task <- tasks, do: send(task.pid, :stop)

      outcomes = Enum.map(tasks, &Task.await(&1, 5_000))

      assert Enum.count(outcomes, &(&1 == :ok)) == 1
      assert Enum.count(outcomes, &(&1 == :exceeded)) == 19
    end
  end

  describe "starting an agent" do
    test "usage limits need a store writing to the limiter's table", %{ip: ip} do
      for limit <- [:max_tokens, :max_evals, :max_running_agents],
          store <- [nil, MemoryStore, OtherTableStore] do
        rate_limit = [limiter: RateLimiter, rules: [rule(ip, policy([{limit, 1}]))]]

        assert_raise ArgumentError, ~r/need a Legion.Store.Postgres store/, fn ->
          Legion.start_link(MathAgent, store: store, rate_limit: rate_limit)
        end
      end

      rate_limit = [limiter: RateLimiter, rules: [rule(ip, policy(max_evals: 1))]]
      start_supervised!({MathAgent, store: Store, rate_limit: rate_limit})
    end

    test "max_agents needs no store", %{ip: ip} do
      rate_limit = [limiter: RateLimiter, rules: [rule(ip, policy(max_agents: 1))]]
      start_supervised!({MathAgent, rate_limit: rate_limit})
    end
  end

  defp rule(identity, policy), do: %Rule{identity: identity, policy: policy}

  defp policy(opts \\ []), do: struct!(Policy, Keyword.merge([window_ms: 60_000], opts))

  defp agent_id, do: "agent-#{UUID.generate()}"

  defp usage(opts) do
    total_tokens = Keyword.fetch!(opts, :total_tokens)
    at = Keyword.get(opts, :at, System.system_time(:millisecond))

    %{"total_tokens" => total_tokens, "at" => at}
  end

  defp evals(count, opts \\ []) do
    at = Keyword.get(opts, :at, System.system_time(:millisecond))

    List.duplicate(%{"evals" => 1, "at" => at}, count)
  end

  defp insert_agent(agent_id, identity, opts \\ []) do
    started_at = Keyword.get(opts, :started_at, NaiveDateTime.utc_now())
    usage = Keyword.get(opts, :usage, [])
    updated_at = Keyword.get(opts, :updated_at, NaiveDateTime.utc_now())
    status = Keyword.get(opts, :status, "idle")

    Repo.query!(
      """
      INSERT INTO legion_agents (
        agent_id, ratelimit_metadata, started_at, usage, updated_at, status
      )
      VALUES ($1, $2::jsonb, $3, $4::jsonb[], $5, $6)
      """,
      [agent_id, identity, started_at, usage, updated_at, status]
    )
  end

  defp started_at(agent_id) do
    %{rows: [[started_at]]} =
      Repo.query!("SELECT started_at FROM legion_agents WHERE agent_id = $1", [agent_id])

    started_at
  end

  defp start_live_agent do
    agent_id = agent_id()
    pid = start_supervised!({Task, fn -> Process.sleep(:infinity) end}, id: agent_id)
    :yes = Legion.AgentIndex.register_name(agent_id, pid)
    agent_id
  end

  defp outside_window do
    NaiveDateTime.add(NaiveDateTime.utc_now(), -@outside_window_ms, :millisecond)
  end

  defp outside_window_timestamp, do: System.system_time(:millisecond) - @outside_window_ms

  defp postgres_options do
    [
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
      username: System.get_env("POSTGRES_USER", "postgres"),
      password: System.get_env("POSTGRES_PASSWORD", "postgres"),
      database: System.get_env("POSTGRES_DB", "postgres")
    ]
  end
end

# These change the shared table's schema or the application environment, so
# they cannot run alongside the async tests above.
defmodule Legion.RateLimiter.PostgresDbSyncTest do
  use ExUnit.Case, async: false

  alias Legion.RateLimiter.Policy
  alias Legion.RateLimiter.PostgresDbTest.RateLimiter
  alias Legion.RateLimiter.PostgresDbTest.Store
  alias Legion.RateLimiter.Rule
  alias Legion.Test.Support.LegionAgentsMigration
  alias Legion.Test.Support.MathAgent
  alias Legion.Test.Support.PostgresRepo, as: Repo

  test "token and eval limits need usage tracking" do
    Application.put_env(:legion, :track_usage, false)
    on_exit(fn -> Application.delete_env(:legion, :track_usage) end)

    rule = %Rule{
      identity: %{"ip" => "203.0.113.42"},
      policy: %Policy{window_ms: 60_000, max_evals: 1}
    }

    rate_limit = [limiter: RateLimiter, rules: [rule]]

    assert_raise ArgumentError, ~r/need usage tracking/, fn ->
      Legion.start_link(MathAgent, store: Store, rate_limit: rate_limit)
    end
  end

  test "migration can be rolled back, reapplied, and rerun safely" do
    version = LegionAgentsMigration.version()

    assert :ok = Ecto.Migrator.down(Repo, version, LegionAgentsMigration, log: false)
    refute column_exists?("ratelimit_metadata")
    refute index_exists?("legion_agents_ratelimit_metadata_gin_idx")

    assert :already_down =
             Ecto.Migrator.down(Repo, version, LegionAgentsMigration, log: false)

    assert :ok = Ecto.Migrator.up(Repo, version, LegionAgentsMigration, log: false)
    assert column_exists?("ratelimit_metadata")
    assert index_exists?("legion_agents_ratelimit_metadata_gin_idx")
    assert :already_up = Ecto.Migrator.up(Repo, version, LegionAgentsMigration, log: false)
  end

  defp column_exists?(column) do
    %{rows: [[exists?]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_name = 'legion_agents' AND column_name = $1
        )
        """,
        [column]
      )

    exists?
  end

  defp index_exists?(index) do
    %{rows: [[exists?]]} = Repo.query!("SELECT to_regclass($1) IS NOT NULL", [index])
    exists?
  end
end
