defmodule Legion.RateLimiter.PolicyTest do
  use ExUnit.Case, async: true

  alias Legion.RateLimiter.Policy

  @limits ~w(max_agents max_running_agents max_tokens max_evals)a

  describe "validate!/1" do
    test "accepts a policy with every limit set" do
      assert :ok =
               Policy.validate!(%Policy{
                 window_ms: 1_000,
                 max_agents: 1,
                 max_running_agents: 1,
                 max_tokens: 10,
                 max_evals: 30
               })
    end

    test "accepts an unrestricted policy" do
      assert :ok = Policy.validate!(%Policy{window_ms: 1_000})
    end

    test "accepts zero limits" do
      assert :ok =
               Policy.validate!(%Policy{
                 window_ms: 1_000,
                 max_agents: 0,
                 max_running_agents: 0,
                 max_tokens: 0,
                 max_evals: 0
               })
    end

    test "rejects a non-positive window" do
      assert_raise ArgumentError, ~r/:window_ms/, fn ->
        Policy.validate!(%Policy{window_ms: 0})
      end
    end

    test "rejects a limit that is not a non-negative integer" do
      for limit <- @limits, value <- [-1, "10"] do
        assert_raise ArgumentError, ~r/#{inspect(limit)}/, fn ->
          Policy.validate!(struct!(Policy, [{:window_ms, 1_000}, {limit, value}]))
        end
      end
    end

    test "rejects anything that is not a policy" do
      assert_raise ArgumentError, ~r/Legion.RateLimiter.Policy/, fn ->
        Policy.validate!(%{window_ms: 1_000})
      end
    end
  end
end
