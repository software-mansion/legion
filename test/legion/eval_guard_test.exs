defmodule Legion.EvalGuardTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  defmodule DenyEverything do
    @behaviour Legion.EvalGuard

    @impl true
    def check(_code, _context), do: {:deny, "the shop is closed for renovations"}
  end

  defmodule RecordContext do
    @behaviour Legion.EvalGuard

    @impl true
    def check(code, context) do
      send(self(), {:checked, code, context})
      :allow
    end
  end

  @context %{agent: SomeAgent, agent_id: "conversation-1", tools: [SomeTool]}

  test "no guard configured allows everything" do
    assert Legion.EvalGuard.check(nil, "System.halt()", @context) == :allow
  end

  test "a denying guard returns its reason" do
    assert {:deny, reason} = Legion.EvalGuard.check(DenyEverything, "1 + 1", @context)
    assert reason =~ "renovations"
  end

  @tag capture_log: true
  test "a denial emits telemetry carrying the code and reason" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:legion, :eval_guard, :denied]])
    on_exit(fn -> :telemetry.detach(ref) end)

    Legion.EvalGuard.check(DenyEverything, "Shop.checkout()", @context)

    # The handler is global, so denials from concurrently running tests also
    # land in this mailbox - match on this test's own guard.
    assert_receive {[:legion, :eval_guard, :denied], ^ref, _measurements,
                    %{guard: DenyEverything} = metadata}

    assert metadata.code == "Shop.checkout()"
    assert metadata.reason =~ "renovations"
  end

  defmodule Broken do
    @behaviour Legion.EvalGuard

    @impl true
    def check("raise", _context), do: raise("the reviewer is on fire")
    def check("throw", _context), do: throw(:nope)
    def check("exit", _context), do: exit(:shutdown)
    def check("garbage", _context), do: :maybe
  end

  test "a guard that raises denies rather than taking the caller down" do
    log =
      capture_log(fn ->
        assert {:deny, reason} = Legion.EvalGuard.check(Broken, "raise", @context)
        assert reason =~ "the reviewer is on fire"
      end)

    assert log =~ "[error]"
    assert log =~ "Broken failed to return a verdict"
  end

  @tag capture_log: true
  test "a guard that throws, exits, or returns something that is not a verdict denies" do
    for {code, failure} <- [{"throw", ":nope"}, {"exit", ":shutdown"}, {"garbage", ":maybe"}] do
      assert {:deny, reason} = Legion.EvalGuard.check(Broken, code, @context)
      assert reason =~ failure
    end
  end

  test "an allowing guard receives the code and the agent context" do
    assert Legion.EvalGuard.check(RecordContext, "Shop.list_records()", @context) == :allow

    assert_received {:checked, "Shop.list_records()", context}
    assert context.agent == SomeAgent
    assert context.agent_id == "conversation-1"
    assert context.tools == [SomeTool]
  end
end
