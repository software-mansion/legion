defmodule Legion.Store.StepPersistenceTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Legion.Store.Payload
  alias Legion.Test.Support.MathAgent

  defmodule StepStore do
    use Legion.Store.Postgres,
      repo: Legion.Test.Support.PostgresRepo,
      persistence_frequency: :step
  end

  test "persists the recoverable turn state before executor_state advances" do
    agent_id = "step-persistence-#{System.unique_integer([:positive])}"
    test_pid = self()
    request_count = :counters.new(1, [:atomics])

    stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
      :counters.add(request_count, 1, 1)

      case :counters.get(request_count, 1) do
        1 ->
          send(test_pid, {:before_first_request, StepStore.get(agent_id)})
          response("eval_and_continue", "x = 42", "")

        2 ->
          send(test_pid, {:before_second_request, StepStore.get(agent_id)})
          response("return", "", "done")
      end
    end)

    {:ok, pid} =
      Legion.start_link(MathAgent,
        store: StepStore,
        agent_id: agent_id,
        sandbox: Legion.Sandbox.Elixir
      )

    allow(ReqLLM, test_pid, pid)
    assert {:ok, "done"} = Legion.call(pid, "compute")

    assert_received {:before_first_request,
                     {:ok,
                      %Payload{
                        status: :running,
                        conversation_state: initial_state
                      }}}

    assert Enum.map(initial_state.messages, & &1.type) == [:user]
    assert initial_state.bindings == []
    assert initial_state.executor_state == :nonexistent

    assert_received {:before_second_request,
                     {:ok,
                      %Payload{
                        status: :running,
                        conversation_state: checkpoint
                      }}}

    assert Enum.map(checkpoint.messages, & &1.type) == [:user, :assistant, :eval_result]
    assert checkpoint.bindings == [x: 42]

    assert checkpoint.executor_state == %{
             phase: :awaiting_llm,
             iteration: 1,
             retries: 0
           }

    assert {:ok, %Payload{status: :idle, conversation_state: completed}} =
             StepStore.get(agent_id)

    assert completed.bindings == []
    assert completed.executor_state == :nonexistent
  end

  defp response(action, code, result) do
    {:ok,
     %ReqLLM.Response{
       id: "test",
       model: "test",
       context: nil,
       object: %{"action" => action, "code" => code, "result" => result},
       usage: %{turn_usage: 0}
     }}
  end
end
