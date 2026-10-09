defmodule Legion.RateLimiterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Legion.RateLimiter
  alias Legion.RateLimiter.Policy
  alias Legion.RateLimiter.Rule

  defmodule Limiter do
    @behaviour Legion.RateLimiter

    @impl Legion.RateLimiter
    def enforce!(_agent_id, _rules), do: :ok
  end

  defmodule OtherLimiter do
    @behaviour Legion.RateLimiter

    @impl Legion.RateLimiter
    def enforce!(_agent_id, _rules), do: :ok
  end

  @ip %{"ip" => "203.0.113.42"}
  @other_ip %{"ip" => "198.51.100.7"}
  @email %{"email" => "someone@example.com"}
  @policy %Policy{window_ms: 60_000, max_agents: 2}
  @narrow %Policy{window_ms: 1_000, max_agents: 1}
  @off %{limiter: nil, rules: []}

  setup do
    on_exit(fn -> Application.delete_env(:legion, :rate_limit) end)
    :ok
  end

  describe "resolve!/1" do
    test "resolves to no limit when nothing is configured" do
      assert RateLimiter.resolve!(nil) == @off
      assert RateLimiter.resolve!([]) == @off
    end

    test "combines the application limiter with the rules given at start" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter)

      assert RateLimiter.resolve!(rules: [rule(@ip, @policy)]) ==
               %{limiter: Limiter, rules: [rule(@ip, @policy)]}
    end

    test "a limiter given at start wins over the application limiter" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter)

      assert %{limiter: OtherLimiter} =
               RateLimiter.resolve!(limiter: OtherLimiter, rules: [rule(@ip, @policy)])
    end

    test "fills a rule's missing policy from the application policy" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter, default_policy: @policy)

      assert %{limiter: Limiter, rules: [rule(@ip, @policy), rule(@email, @narrow)]} ==
               RateLimiter.resolve!(rules: [%Rule{identity: @ip}, rule(@email, @narrow)])
    end

    test "raises when a rule has no policy and no application policy is set" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter)

      assert_raise ArgumentError, ~r/Legion\.RateLimiter\.Policy/, fn ->
        RateLimiter.resolve!(rules: [%Rule{identity: @ip}])
      end
    end

    test "raises with rules but no limiter" do
      assert_raise ArgumentError, ~r/rules need a limiter/, fn ->
        RateLimiter.resolve!(rules: [rule(@ip, @policy)])
      end
    end

    test "raises when a limiter given at start is nil next to rules" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter)

      assert_raise ArgumentError, ~r/rules need a limiter/, fn ->
        RateLimiter.resolve!(limiter: nil, rules: [rule(@ip, @policy)])
      end
    end

    test "resolves to no limit and warns with a limiter but no rules given" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter)

      log =
        capture_log(fn ->
          assert RateLimiter.resolve!(nil) == @off
          assert RateLimiter.resolve!([]) == @off
          assert RateLimiter.resolve!(limiter: OtherLimiter) == @off
        end)

      assert log =~ "Legion.RateLimiterTest.Limiter is configured but no rules were given"
      assert log =~ "Legion.RateLimiterTest.OtherLimiter is configured but no rules were given"
      assert log =~ "runs without rate limiting"
    end

    test "resolves to no limit silently when opting out with empty rules" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter)

      assert capture_log(fn -> assert RateLimiter.resolve!(rules: []) == @off end) == ""
    end

    test "validates rules even when no limiter is configured" do
      assert_raise ArgumentError, ~r/:identity keys/, fn ->
        RateLimiter.resolve!(rules: [rule(%{ip: "203.0.113.42"}, @policy)])
      end
    end

    test "rejects an invalid policy" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter)

      assert_raise ArgumentError, ~r/:window_ms/, fn ->
        RateLimiter.resolve!(rules: [rule(@ip, %Policy{window_ms: 0})])
      end
    end

    test "rejects :rules that is not a list" do
      assert_raise ArgumentError, ~r/expected :rules to be a list/, fn ->
        RateLimiter.resolve!(rules: rule(@ip, @policy))
      end
    end

    test "warns about and ignores overrides keys other than :limiter and :rules" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter)

      log =
        capture_log(fn ->
          assert RateLimiter.resolve!(identity: @ip, policy: @policy) == @off
        end)

      assert log =~ ":rate_limit ignores unknown keys [:identity, :policy]"
      assert log =~ "allowed keys are [:limiter, :rules]"
      # Dropping the stale keys leaves no rules, which is worth a second warning.
      assert log =~ "runs without rate limiting"
    end

    test "rejects overrides that are not a keyword list" do
      assert_raise ArgumentError, ~r/expected :rate_limit to be a keyword list/, fn ->
        RateLimiter.resolve!([rule(@ip, @policy)])
      end

      assert_raise ArgumentError, ~r/expected :rate_limit to be a keyword list or nil/, fn ->
        RateLimiter.resolve!(%{rules: [rule(@ip, @policy)]})
      end
    end

    test "warns about and ignores application config keys other than :limiter and :default_policy" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter, policy: @policy)

      log =
        capture_log(fn ->
          assert RateLimiter.resolve!(rules: [rule(@ip, @policy)]) ==
                   %{limiter: Limiter, rules: [rule(@ip, @policy)]}
        end)

      assert log =~ "config :legion, :rate_limit ignores unknown keys [:policy]"
      assert log =~ "allowed keys are [:limiter, :default_policy]"
    end

    test "does not take rules from the application config" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter, rules: [rule(@ip, @policy)])

      log =
        capture_log(fn ->
          assert RateLimiter.resolve!(rules: [rule(@email, @narrow)]) ==
                   %{limiter: Limiter, rules: [rule(@email, @narrow)]}

          assert RateLimiter.resolve!(rules: []) == @off
        end)

      assert log =~ "config :legion, :rate_limit ignores unknown keys [:rules]"
    end

    test "rejects application config that is not a keyword list" do
      Application.put_env(:legion, :rate_limit, %{limiter: Limiter})

      assert_raise ArgumentError,
                   ~r/expected config :legion, :rate_limit to be a keyword list/,
                   fn ->
                     RateLimiter.resolve!(nil)
                   end
    end

    test "rejects a rule that is not a Rule struct" do
      assert_raise ArgumentError, ~r/expected a Legion\.RateLimiter\.Rule/, fn ->
        RateLimiter.resolve!(rules: [%{identity: @ip, policy: @policy}])
      end
    end

    test "rejects rules that disagree on an identity value" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter)

      assert_raise ArgumentError, ~r/disagree on "ip"/, fn ->
        RateLimiter.resolve!(rules: [rule(@ip, @policy), rule(@other_ip, @narrow)])
      end
    end

    test "accepts rules that share an identity under different policies" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter)

      assert %{rules: [_, _]} =
               RateLimiter.resolve!(rules: [rule(@ip, @policy), rule(@ip, @narrow)])
    end

    test "inherits the parent's resolved configuration without overrides" do
      inherited = %{limiter: Limiter, rules: [rule(@ip, @policy), rule(@email, @narrow)]}
      Vault.unsafe_put(:rate_limit, inherited)

      assert RateLimiter.resolve!(nil) == inherited
    end

    test "a sub-agent of a parent that opted out stays unlimited without a warning" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter, default_policy: @policy)

      parent = RateLimiter.resolve!(rules: [])
      assert parent == @off

      # AgentServer.init stores the parent's verdict for sub-agents to inherit.
      Vault.unsafe_put(:rate_limit, parent)

      assert capture_log(fn -> assert RateLimiter.resolve!(nil) == @off end) == ""
    end

    test "a limiter given below a parent that opted out does not re-enable rate limiting" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter, default_policy: @policy)
      Vault.unsafe_put(:rate_limit, @off)

      log = capture_log(fn -> assert RateLimiter.resolve!(limiter: OtherLimiter) == @off end)
      assert log =~ "runs without rate limiting"
    end

    test "rules given below a parent that opted out raise" do
      Application.put_env(:legion, :rate_limit, limiter: Limiter, default_policy: @policy)
      Vault.unsafe_put(:rate_limit, @off)

      assert_raise ArgumentError, ~r/parent agent runs without rate limiting/, fn ->
        RateLimiter.resolve!(rules: [rule(@ip, @policy)])
      end
    end

    test "the parent's resolved configuration wins over the application environment" do
      Application.put_env(:legion, :rate_limit, limiter: OtherLimiter)
      Vault.unsafe_put(:rate_limit, %{limiter: Limiter, rules: [rule(@ip, @policy)]})

      assert %{limiter: Limiter} = RateLimiter.resolve!(nil)
    end

    test "rules given at start replace the inherited rules as a whole" do
      Vault.unsafe_put(:rate_limit, %{limiter: Limiter, rules: [rule(@ip, @policy)]})

      assert %{limiter: Limiter, rules: [rule(@email, @narrow)]} ==
               RateLimiter.resolve!(rules: [rule(@email, @narrow)])
    end

    test "a limiter given at start keeps the inherited rules" do
      Vault.unsafe_put(:rate_limit, %{limiter: Limiter, rules: [rule(@ip, @policy)]})

      assert %{limiter: OtherLimiter, rules: [rule(@ip, @policy)]} ==
               RateLimiter.resolve!(limiter: OtherLimiter)
    end
  end

  describe "Rule.validate!/1" do
    test "accepts a complete rule" do
      assert :ok = Rule.validate!(rule(@ip, @policy))
    end

    test "accepts an empty identity" do
      assert :ok = Rule.validate!(rule(%{}, @policy))
    end

    test "rejects a non-struct" do
      assert_raise ArgumentError, ~r/expected a Legion\.RateLimiter\.Rule struct/, fn ->
        Rule.validate!(%{identity: @ip, policy: @policy})
      end
    end

    test "rejects an identity that is not a map" do
      assert_raise ArgumentError, ~r/expected :identity to be a map/, fn ->
        Rule.validate!(rule("203.0.113.42", @policy))
      end
    end

    test "rejects identity keys that are not strings" do
      assert_raise ArgumentError, ~r/expected :identity keys to be strings, got: \[:ip\]/, fn ->
        Rule.validate!(rule(%{ip: "203.0.113.42"}, @policy))
      end
    end

    test "rejects a missing policy" do
      assert_raise ArgumentError, ~r/Legion\.RateLimiter\.Policy/, fn ->
        Rule.validate!(%Rule{identity: @ip})
      end
    end

    test "rejects an invalid policy" do
      assert_raise ArgumentError, ~r/:max_agents/, fn ->
        Rule.validate!(rule(@ip, %Policy{window_ms: 1_000, max_agents: -1}))
      end
    end
  end

  defp rule(identity, policy), do: %Rule{identity: identity, policy: policy}
end
