defmodule Legion.Integration.EvalGuardTest do
  @moduledoc """
  Integration test: confirm `Legion.EvalGuard.LLM` vets generated code with a
  real model, on the executor's path.

  Skipped by default to avoid external API calls and LLM costs.
  Run with:

      mix test test/integration/eval_guard_test.exs --include integration
  """
  use ExUnit.Case, async: true

  alias Legion.Test.Support.MathTool

  @moduletag :integration
  @moduletag timeout: 120_000

  defmodule GuardedMathAgent do
    @moduledoc "A math agent whose code is reviewed before it runs."
    use Legion.Agent

    defmodule NoRandomAdd do
      @moduledoc "Denies the one tool function the agent is asked to call."
      use Legion.EvalGuard.LLM,
        policy: """
        Deny any code that calls random_add. Allow everything else, including
        plain arithmetic.
        """
    end

    def tools, do: [MathTool]
    def config, do: %{eval_guard: NoRandomAdd, max_iterations: 3, max_retries: 1}
  end

  setup do
    unless System.get_env("OPENAI_API_KEY"), do: raise("OPENAI_API_KEY not set")

    # Other tests in the suite emit the same global event concurrently; the
    # assertions below match on this agent's guard.
    ref = :telemetry_test.attach_event_handlers(self(), [[:legion, :eval_guard, :denied]])
    on_exit(fn -> :telemetry.detach(ref) end)

    {:ok, ref: ref}
  end

  test "the model denies code the policy forbids", %{ref: ref} do
    Legion.execute(GuardedMathAgent, "Call MathTool.random_add(2, 3) and return it.")

    assert_received {[:legion, :eval_guard, :denied], ^ref, _measurements,
                     %{guard: GuardedMathAgent.NoRandomAdd, code: code}}

    assert code =~ "random_add"
  end

  test "code the policy allows runs", %{ref: ref} do
    assert {:ok, result} =
             Legion.execute(GuardedMathAgent, "What is 21 + 21? Compute it and return it.")

    assert result =~ "42"

    refute_received {[:legion, :eval_guard, :denied], ^ref, _measurements,
                     %{guard: GuardedMathAgent.NoRandomAdd}}
  end
end
