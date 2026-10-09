defmodule Legion.Tools.AgentToolTest do
  use ExUnit.Case, async: false

  alias Legion.RateLimiter.{ExceededError, Policy, Rule}
  alias Legion.Tools.AgentTool

  defmodule ChildAgent do
    @moduledoc "Agent started as a long-lived sub-agent."
    use Legion.Agent
  end

  defmodule OwnerAgent do
    @moduledoc "Agent that starts sub-agents."
    use Legion.Agent

    def tools, do: [AgentTool]
    def tool_config(AgentTool), do: [agents: [ChildAgent]]
  end

  defmodule SingleChildAgent do
    @moduledoc "Agent allowed one sub-agent at a time."
    use Legion.Agent

    def tools, do: [AgentTool]
    def tool_config(AgentTool), do: [agents: [ChildAgent]]
    def config, do: %{max_sub_agents: 1}
  end

  defmodule OwnerOnlyLimiter do
    @moduledoc "Allows the agent its rule names as owner, denies every other."
    @behaviour Legion.RateLimiter

    @impl Legion.RateLimiter
    def enforce!(agent_id, [%Rule{identity: %{"owner" => owner}} = rule] = rules) do
      send(:agent_tool_test, {:enforced, agent_id, rules})

      if agent_id != owner do
        raise ExceededError,
          agent_id: agent_id,
          identity: rule.identity,
          policy: rule.policy,
          usage: %{agents: 2, tokens: nil, evals: 0},
          violations: [:max_agents]
      end

      :ok
    end
  end

  defp start_owner(agent \\ OwnerAgent, opts \\ []) do
    {:ok, pid} = Legion.start_link(agent, opts)
    pid
  end

  defp sub_agents(owner) do
    owner_id = Legion.get_agent_id(owner)
    for {:legion_sub_agent, ^owner_id, child_id} <- :global.registered_names(), do: child_id
  end

  describe "max_sub_agents" do
    test "refuses a start past the cap, and stop/1 frees a slot" do
      owner = start_owner(OwnerAgent, max_sub_agents: 2)

      assert {:ok, _text} =
               Legion.eval(owner, """
               first = AgentTool.start_link(ChildAgent)[2]
               second = AgentTool.start_link(ChildAgent)[2]
               """)

      assert {:error, text} = Legion.eval(owner, "third = AgentTool.start_link(ChildAgent)[2]")
      assert text =~ "already runs 2 sub-agents"

      assert {:ok, _text} =
               Legion.eval(owner, """
               AgentTool.stop(first)
               third = AgentTool.start_link(ChildAgent)[2]
               """)

      assert length(sub_agents(owner)) == 2

      assert {:error, text} = Legion.eval(owner, "return AgentTool.call(first, 'hi')")
      assert text =~ "is not a running sub-agent"
    end

    test "is read from the agent's config/0" do
      owner = start_owner(SingleChildAgent)

      assert {:ok, _text} = Legion.eval(owner, "first = AgentTool.start_link(ChildAgent)[2]")
      assert {:error, text} = Legion.eval(owner, "AgentTool.start_link(ChildAgent)")
      assert text =~ "already runs 1 sub-agents"
    end

    test "is read from the application config" do
      Application.put_env(:legion, :config, %{max_sub_agents: 0})
      on_exit(fn -> Application.delete_env(:legion, :config) end)

      owner = start_owner()

      assert {:error, text} = Legion.eval(owner, "AgentTool.start_link(ChildAgent)")
      assert text =~ "already runs 0 sub-agents"
    end
  end

  test "a sub-agent nobody messages stops after sub_agent_idle_timeout" do
    owner = start_owner(OwnerAgent, sub_agent_idle_timeout: 50)

    assert {:ok, _text} = Legion.eval(owner, "child = AgentTool.start_link(ChildAgent)[2]")
    [child_id] = sub_agents(owner)
    {:ok, child} = Legion.lookup(child_id)

    ref = Process.monitor(child)
    assert_receive {:DOWN, ^ref, :process, ^child, :normal}, 1_000
  end

  describe "a start under a rate limit" do
    setup do
      start_supervised!(Legion.Test.Support.MemoryStore)
      Process.register(self(), :agent_tool_test)

      rule = fn owner_id ->
        %Rule{
          identity: %{"owner" => owner_id},
          policy: %Policy{window_ms: 60_000, max_agents: 1, max_running_agents: 1}
        }
      end

      %{rule: rule}
    end

    test "is checked before the sub-agent runs, without counting it as running", %{rule: rule} do
      owner =
        start_owner(OwnerAgent,
          agent_id: "owner-limited",
          store: Legion.Test.Support.MemoryStore,
          rate_limit: [limiter: OwnerOnlyLimiter, rules: [rule.("owner-limited")]]
        )

      assert {:ok, text} = Legion.eval(owner, "return AgentTool.start_link(ChildAgent)")
      assert text =~ ~s(["cancel", ["rate_limited", ["max_agents"]]])

      # The owner's start, then its eval.
      assert_received {:enforced, "owner-limited", _rules}
      assert_received {:enforced, "owner-limited", _rules}
      assert_received {:enforced, child_id, [%Rule{policy: policy}]}
      assert child_id != "owner-limited"
      assert policy.max_running_agents == nil

      assert sub_agents(owner) == []
      assert Legion.lookup(child_id) == :error
    end
  end
end
