defmodule Legion.MCP.ReplTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.{Context, Frame, Response}
  alias Legion.MCP.Repl
  alias Legion.Test.Support.MathAgent

  # What `Legion.MCP.Server` assigns at session start.
  defp session(config_overrides \\ %{}) do
    config = Map.merge(Legion.Agent.resolve_config(MathAgent), config_overrides)
    frame = %Frame{context: %Context{session_id: "session-1"}}
    Frame.assign(frame, agent: MathAgent, config: config)
  end

  defp call(frame, code) do
    {:reply, %Response{} = response, frame} = Repl.execute(%{code: code}, frame)
    [%{"text" => text}] = response.content
    {response.isError, text, frame}
  end

  describe "execute/2" do
    test "evaluates the code in the agent's sandbox and replies with the result" do
      {error?, text, _frame} = call(session(), "return MathTool.random_add(1, 2)")

      refute error?
      assert text =~ "983"
    end

    test "keeps variables between calls within the session" do
      {_, _, frame} = call(session(), "x = 40")
      {_, text, _} = call(frame, "return x + 2")

      assert text =~ "42"
      assert text =~ "Available variables: `x`"
    end

    test "a fresh session has no variables" do
      {_, text, _} = call(session(), "return x")

      assert text =~ "nil"
      refute text =~ "Available variables"
    end

    test "forgets variables between calls when binding_scope is :iteration" do
      {_, text, frame} = call(session(%{binding_scope: :iteration}), "x = 40")
      refute text =~ "Available variables"

      {_, text, _} = call(frame, "return x")
      assert text =~ "nil"
    end

    test "a sandbox failure is a tool error the model can read, and keeps the session's variables" do
      {_, _, frame} = call(session(), "x = 40")
      {error?, text, frame} = call(frame, "return (")

      assert error?
      assert text != ""

      {_, text, _} = call(frame, "return x")
      assert text =~ "40"
    end

    test "a guard refusal is a tool error naming the guard" do
      defmodule NoGuard do
        @moduledoc false
        @behaviour Legion.EvalGuard
        def check(_code, _context), do: {:deny, "not here"}
      end

      {error?, text, _} = call(session(%{eval_guard: NoGuard}), "return 1")

      assert error?
      assert text == "refused by Legion.MCP.ReplTest.NoGuard: not here"
    end

    test "a session that never completed initialization gets a tool error saying so" do
      frame = %Frame{context: %Context{session_id: "session-1"}}

      {error?, text, _frame} = call(frame, "return 1")

      assert error?
      assert text =~ "not initialized"
      assert text =~ "notifications/initialized"
    end

    test "wraps each call in a [:legion, :mcp, :call] span carrying the session" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "repl-test-#{inspect(ref)}",
        [[:legion, :mcp, :call, :start], [:legion, :mcp, :call, :stop]],
        fn event, _measurements, metadata, _ -> send(test_pid, {ref, event, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("repl-test-#{inspect(ref)}") end)

      {_, _, frame} = call(session(), "return 1")
      call(frame, "return (")

      assert_received {^ref, [:legion, :mcp, :call, :start],
                       %{agent: MathAgent, session_id: "session-1", code: "return 1"}}

      assert_received {^ref, [:legion, :mcp, :call, :stop],
                       %{session_id: "session-1", success: true, result: 1}}

      assert_received {^ref, [:legion, :mcp, :call, :stop],
                       %{session_id: "session-1", success: false, error: error}}

      assert is_binary(error)
    end
  end
end
