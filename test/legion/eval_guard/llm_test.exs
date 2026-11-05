defmodule Legion.EvalGuard.LLMTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Legion.EvalGuard.LLM

  defmodule Reviewer do
    use Legion.EvalGuard.LLM, policy: "No looping over checkout."
  end

  defmodule DefaultReviewer do
    use Legion.EvalGuard.LLM
  end

  @context %{agent: SomeAgent, agent_id: "conversation-1", tools: [SomeTool]}

  test "an allow verdict passes the code through" do
    stub(ReqLLM, :generate_object, fn _model, _messages, _schema, _opts ->
      {:ok, %{object: %{"verdict" => "allow", "reason" => ""}}}
    end)

    assert Legion.EvalGuard.check(Reviewer, "1 + 1", @context) == :allow
  end

  test "a deny verdict hands the model's reason back" do
    stub(ReqLLM, :generate_object, fn _model, _messages, _schema, _opts ->
      {:ok, %{object: %{"verdict" => "deny", "reason" => "that loops over checkout"}}}
    end)

    assert Legion.EvalGuard.check(Reviewer, "Enum.each(carts, &Shop.checkout/1)", @context) ==
             {:deny, "that loops over checkout"}
  end

  test "a failed review request denies" do
    stub(ReqLLM, :generate_object, fn _model, _messages, _schema, _opts -> {:error, :timeout} end)

    assert {:deny, reason} = Legion.EvalGuard.check(Reviewer, "1 + 1", @context)
    assert reason =~ "timeout"
  end

  test "the policy, agent and tools reach the model" do
    test_pid = self()

    stub(ReqLLM, :generate_object, fn _model, messages, _schema, _opts ->
      send(test_pid, {:reviewed, messages})
      {:ok, %{object: %{"verdict" => "allow", "reason" => ""}}}
    end)

    Legion.EvalGuard.check(Reviewer, "Shop.checkout()", @context)

    assert_received {:reviewed, [system, user]}
    assert system.content =~ "No looping over checkout."
    assert system.content =~ "SomeAgent"
    assert system.content =~ "SomeTool"
    assert user.content == "Shop.checkout()"
  end

  test "a guard without a policy reviews against the default one" do
    test_pid = self()

    stub(ReqLLM, :generate_object, fn _model, messages, _schema, _opts ->
      send(test_pid, {:reviewed, messages})
      {:ok, %{object: %{"verdict" => "allow", "reason" => ""}}}
    end)

    Legion.EvalGuard.check(DefaultReviewer, "1 + 1", @context)

    assert_received {:reviewed, [system, _user]}
    assert system.content =~ LLM.default_policy()
  end
end
