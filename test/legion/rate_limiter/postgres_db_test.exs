defmodule Legion.RateLimiter.PostgresDbTest do
  use ExUnit.Case, async: false

  alias Legion.RateLimiter.ExceededError
  alias Legion.RateLimiter.Policy
  alias Legion.RateLimiter.Rule
  alias Legion.Test.Support.LegionAgentsMigration
  alias Legion.Test.Support.PostgresRepo, as: Repo

  @ip_key %{"ip" => "203.0.113.42"}
  @other_ip_key %{"ip" => "198.51.100.7"}
  @tenant_ip_key %{"ip" => "203.0.113.42", "tenant" => "acme"}
  @email_key %{"email" => "someone@example.com"}

  defmodule RateLimiter do
    use Legion.RateLimiter.Postgres, repo: Legion.Test.Support.PostgresRepo
  end

  setup do
    Repo.query!("TRUNCATE legion_agents", [])
    :ok
  end

  test "allows exactly max_agents newly started matching agents" do
    rules = [rule(@ip_key, policy(max_agents: 2))]

    assert :ok = RateLimiter.enforce!("first", rules)
    assert :ok = RateLimiter.enforce!("second", rules)
  end

  test "rejects the agent that would exceed max_agents" do
    rules = [rule(@ip_key, policy(max_agents: 1))]

    assert :ok = RateLimiter.enforce!("first", rules)

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("second", rules)
    end
  end

  test "counts a broader key's agents with more specific metadata" do
    policy = policy(max_agents: 1)

    assert :ok = RateLimiter.enforce!("acme", [rule(@tenant_ip_key, policy)])

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("ip-wide", [rule(@ip_key, policy)])
    end
  end

  test "does not count agents whose starts predate the agent window" do
    insert_agent("old", @ip_key, started_at: milliseconds_ago(2_000))

    assert :ok =
             RateLimiter.enforce!(
               "new",
               [rule(@ip_key, policy(window_ms: 1_000, max_agents: 1))]
             )
  end

  test "counts timestamped token usage from agents started before the window" do
    insert_agent("long-running", @ip_key,
      started_at: milliseconds_ago(2_000),
      usage: [usage(total_tokens: 10, at: timestamp_milliseconds_ago(100))]
    )

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!(
        "new",
        [rule(@ip_key, policy(window_ms: 1_000, max_tokens: 10))]
      )
    end
  end

  test "does not count token usage outside the token window" do
    insert_agent("long-running", @ip_key,
      usage: [usage(total_tokens: 10, at: timestamp_milliseconds_ago(2_000))]
    )

    assert :ok =
             RateLimiter.enforce!(
               "new",
               [rule(@ip_key, policy(window_ms: 1_000, max_tokens: 10))]
             )
  end

  # Usage is only ever appended by a store save, and every save bumps
  # updated_at, so a row untouched since before the window cannot hold usage
  # inside it. Skipping those rows keeps the token sum proportional to the
  # window rather than to the whole history of the group.
  test "ignores rows untouched since before the token window" do
    insert_agent("stale", @ip_key,
      usage: [usage(total_tokens: 10, at: timestamp_milliseconds_ago(100))],
      updated_at: milliseconds_ago(2_000)
    )

    assert :ok =
             RateLimiter.enforce!(
               "new",
               [rule(@ip_key, policy(window_ms: 1_000, max_tokens: 10))]
             )
  end

  test "rejects when recorded tokens reach max_tokens" do
    insert_agent("first", @ip_key, usage: [usage(total_tokens: 10)])

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("next", [rule(@ip_key, policy(max_tokens: 10))])
    end
  end

  test "reports every active violation of a rule without requiring an order" do
    insert_agent("first", @ip_key, usage: [usage(total_tokens: 10)])

    error =
      assert_raise ExceededError, fn ->
        RateLimiter.enforce!("next", [rule(@ip_key, policy(max_agents: 1, max_tokens: 10))])
      end

    assert MapSet.new(error.violations) == MapSet.new([:max_agents, :max_tokens])
  end

  test "zero limits allow none" do
    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("agent-limit", [rule(@ip_key, policy(max_agents: 0))])
    end

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("token-limit", [rule(@other_ip_key, policy(max_tokens: 0))])
    end
  end

  test "allows an unrestricted policy" do
    assert :ok = RateLimiter.enforce!("unrestricted", [rule(@ip_key, policy())])
  end

  test "rejects arguments that are not an agent id and a list of rules" do
    assert_raise ArgumentError, ~r/invalid rate-limit arguments/, fn ->
      RateLimiter.enforce!("agent", rule(@ip_key, policy()))
    end
  end

  describe "several rules" do
    test "records the merged identities of every rule" do
      assert :ok =
               RateLimiter.enforce!("agent", [
                 rule(@ip_key, policy()),
                 rule(@email_key, policy())
               ])

      assert %{rows: [[metadata]]} =
               Repo.query!("SELECT ratelimit_metadata FROM legion_agents WHERE agent_id = $1", [
                 "agent"
               ])

      assert metadata == Map.merge(@ip_key, @email_key)
    end

    test "counts an agent under each of its rules' groups" do
      assert :ok =
               RateLimiter.enforce!("agent", [
                 rule(@ip_key, policy()),
                 rule(@email_key, policy())
               ])

      assert_raise ExceededError, fn ->
        RateLimiter.enforce!("same-ip", [rule(@ip_key, policy(max_agents: 1))])
      end

      assert_raise ExceededError, fn ->
        RateLimiter.enforce!("same-email", [rule(@email_key, policy(max_agents: 1))])
      end
    end

    test "rejects the agent when any rule is violated and records nothing" do
      insert_agent("existing", @email_key)

      error =
        assert_raise ExceededError, fn ->
          RateLimiter.enforce!("new", [
            rule(@ip_key, policy(max_agents: 5)),
            rule(@email_key, policy(max_agents: 1))
          ])
        end

      assert error.identity == @email_key
      assert error.violations == [:max_agents]

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM legion_agents WHERE agent_id = $1", ["new"])
    end

    test "reports the first violated rule in list order" do
      insert_agent("existing", Map.merge(@ip_key, @email_key))
      ip_rule = rule(@ip_key, policy(max_agents: 1))
      email_rule = rule(@email_key, policy(max_agents: 1))

      error =
        assert_raise(ExceededError, fn -> RateLimiter.enforce!("a", [ip_rule, email_rule]) end)

      assert error.identity == @ip_key

      error =
        assert_raise(ExceededError, fn -> RateLimiter.enforce!("b", [email_rule, ip_rule]) end)

      assert error.identity == @email_key
    end

    test "evaluates one identity under several windows" do
      insert_agent("old", @ip_key, started_at: milliseconds_ago(2_000))
      short = policy(window_ms: 1_000, max_agents: 1)
      long = policy(window_ms: 60_000, max_agents: 1)

      error =
        assert_raise ExceededError, fn ->
          RateLimiter.enforce!("new", [rule(@ip_key, short), rule(@ip_key, long)])
        end

      assert error.policy == long
    end

    # Rules lock their identities in a global order, so two agents naming the
    # same identities in different orders never deadlock; one of them wins
    # every shared group and the rest are denied.
    test "allows exactly one agent under concurrent calls with overlapping rules in mixed order" do
      ip_rule = rule(@ip_key, policy(max_agents: 1))
      email_rule = rule(@email_key, policy(max_agents: 1))
      test_pid = self()

      tasks =
        for index <- 1..20 do
          rules = if rem(index, 2) == 0, do: [ip_rule, email_rule], else: [email_rule, ip_rule]

          Task.async(fn ->
            send(test_pid, {:ready, self()})

            receive do
              :enforce ->
                try do
                  RateLimiter.enforce!("concurrent-#{index}", rules)
                rescue
                  ExceededError -> :exceeded
                end
            end
          end)
        end

      for _ <- tasks, do: assert_receive({:ready, _})
      Enum.each(tasks, &send(&1.pid, :enforce))

      outcomes = Enum.map(tasks, &Task.await(&1, 5_000))

      assert Enum.count(outcomes, &(&1 == :ok)) == 1
      assert Enum.count(outcomes, &(&1 == :exceeded)) == 19

      %{rows: [[recorded]]} =
        Repo.query!("SELECT count(*) FROM legion_agents WHERE ratelimit_metadata IS NOT NULL", [])

      assert recorded == 1
    end
  end

  test "does not notify for a metadata upsert with an unchanged key" do
    notifications = start_supervised!({Postgrex.Notifications, postgres_options()})
    listen_ref = Postgrex.Notifications.listen!(notifications, "legion_agents")
    rules = [rule(@ip_key, policy())]

    assert :ok = RateLimiter.enforce!("agent", rules)

    assert_receive {:notification, ^notifications, ^listen_ref, "legion_agents", "agent"}

    assert :ok = RateLimiter.enforce!("agent", rules)

    refute_receive {:notification, ^notifications, ^listen_ref, "legion_agents", "agent"}
  end

  test "moves an agent to its new key without resetting its start time" do
    assert :ok = RateLimiter.enforce!("agent", [rule(@ip_key, policy())])

    assert :ok = RateLimiter.enforce!("agent", [rule(@other_ip_key, policy())])

    assert :ok = RateLimiter.enforce!("ip-agent", [rule(@ip_key, policy(max_agents: 1))])

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("other-ip-agent", [rule(@other_ip_key, policy(max_agents: 1))])
    end
  end

  test "rolls back a rejected new agent's metadata" do
    rules = [rule(@ip_key, policy(max_agents: 1))]

    assert :ok = RateLimiter.enforce!("first", rules)

    assert_raise ExceededError, fn ->
      RateLimiter.enforce!("rejected", rules)
    end

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM legion_agents WHERE agent_id = $1", ["rejected"])
  end

  # `max_agents` is not concurrency-safe: each transaction counts only rows
  # committed before it started, so simultaneous starts can overshoot the
  # limit. What must hold is that every caller gets a verdict and that only
  # allowed agents leave a row behind.
  test "allows exactly max_agents under concurrent calls and records only the allowed ones" do
    rules = [rule(@ip_key, policy(max_agents: 1))]
    test_pid = self()

    tasks =
      for index <- 1..20 do
        Task.async(fn ->
          send(test_pid, {:ready, self()})

          receive do
            :enforce ->
              try do
                RateLimiter.enforce!("concurrent-#{index}", rules)
              rescue
                ExceededError -> :exceeded
              end
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    Enum.each(tasks, &send(&1.pid, :enforce))

    outcomes = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(outcomes, &(&1 == :ok)) == 1
    assert Enum.count(outcomes, &(&1 == :exceeded)) == 19

    %{rows: [[recorded]]} =
      Repo.query!("SELECT count(*) FROM legion_agents WHERE ratelimit_metadata IS NOT NULL", [])

    assert recorded == Enum.count(outcomes, &(&1 == :ok))
  end

  describe "max_running_agents" do
    test "allows exactly max_running_agents live agents mid-turn" do
      rules = [rule(@ip_key, policy(max_running_agents: 2))]
      for agent_id <- ~w(running-1 running-2 running-3), do: start_live_agent(agent_id)

      assert :ok = RateLimiter.enforce!("running-1", rules)
      assert :ok = RateLimiter.enforce!("running-2", rules)

      error = assert_raise(ExceededError, fn -> RateLimiter.enforce!("running-3", rules) end)
      assert error.violations == [:max_running_agents]
      assert error.usage.running == 3
    end

    test "frees the slot once the agent's turn ends" do
      rules = [rule(@ip_key, policy(max_running_agents: 1))]
      for agent_id <- ~w(finished next), do: start_live_agent(agent_id)

      assert :ok = RateLimiter.enforce!("finished", rules)
      Repo.query!("UPDATE legion_agents SET status = 'idle' WHERE agent_id = $1", ["finished"])

      assert :ok = RateLimiter.enforce!("next", rules)
    end

    test "does not count a running row whose agent is gone" do
      insert_agent("crashed", @ip_key, status: "running")
      start_live_agent("new")

      assert :ok = RateLimiter.enforce!("new", [rule(@ip_key, policy(max_running_agents: 1))])
    end

    test "does not count a running row untouched since before the window" do
      start_live_agent("stale")
      insert_agent("stale", @ip_key, status: "running", updated_at: milliseconds_ago(2_000))
      start_live_agent("new")

      assert :ok =
               RateLimiter.enforce!(
                 "new",
                 [rule(@ip_key, policy(window_ms: 1_000, max_running_agents: 1))]
               )
    end

    test "leaves the status alone when no rule limits running agents" do
      assert :ok = RateLimiter.enforce!("agent", [rule(@ip_key, policy())])

      assert %{rows: [["idle"]]} =
               Repo.query!("SELECT status FROM legion_agents WHERE agent_id = $1", ["agent"])
    end

    # The caller is marked running inside the locked transaction, so
    # simultaneous starts count each other rather than all seeing zero.
    test "allows exactly max_running_agents under concurrent calls" do
      rules = [rule(@ip_key, policy(max_running_agents: 1))]
      test_pid = self()

      tasks =
        for index <- 1..20 do
          Task.async(fn ->
            agent_id = "running-concurrent-#{index}"
            :yes = Legion.AgentIndex.register_name(agent_id, self())
            send(test_pid, {:ready, self()})

            receive do
              :enforce -> :ok
            end

            outcome =
              try do
                RateLimiter.enforce!(agent_id, rules)
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
      Enum.each(tasks, &send(&1.pid, :enforce))
      for _ <- tasks, do: assert_receive({:outcome, _, _}, 5_000)
      Enum.each(tasks, &send(&1.pid, :stop))

      outcomes = Enum.map(tasks, &Task.await(&1, 5_000))

      assert Enum.count(outcomes, &(&1 == :ok)) == 1
      assert Enum.count(outcomes, &(&1 == :exceeded)) == 19
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

  defp rule(identity, policy), do: %Rule{identity: identity, policy: policy}

  defp policy(opts \\ []) do
    struct!(Policy, Keyword.merge([window_ms: 60_000, max_agents: nil, max_tokens: nil], opts))
  end

  defp usage(opts) do
    total_tokens = Keyword.fetch!(opts, :total_tokens)
    at = Keyword.get(opts, :at, System.system_time(:millisecond))

    %{"total_tokens" => total_tokens, "at" => at}
  end

  defp insert_agent(agent_id, key, opts \\ []) do
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
      [agent_id, key, started_at, usage, updated_at, status]
    )
  end

  # The running limit only counts agents whose process is alive, so stand in
  # for one under the id the way AgentServer registers itself.
  defp start_live_agent(agent_id) do
    pid = start_supervised!({Task, fn -> Process.sleep(:infinity) end}, id: agent_id)
    :yes = Legion.AgentIndex.register_name(agent_id, pid)
    pid
  end

  defp milliseconds_ago(milliseconds) do
    DateTime.utc_now()
    |> DateTime.add(-milliseconds, :millisecond)
    |> DateTime.to_naive()
  end

  defp timestamp_milliseconds_ago(milliseconds),
    do: System.system_time(:millisecond) - milliseconds

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
