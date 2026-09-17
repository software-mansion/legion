defmodule Legion.MCP.ReplTest do
  # Two tests change application env, so this module runs on its own.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Anubis.Server.{Context, Frame, Response}
  alias Legion.MCP.Repl
  alias Legion.RateLimiter.{ExceededError, Policy, Rule}
  alias Legion.Test.Support.{MathAgent, MemoryStore, VaultTool}

  defmodule MathMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "math", version: "1"
  end

  defmodule StoredMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "stored", version: "1", store: MemoryStore
  end

  defmodule UserMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "user", version: "1", store: MemoryStore

    def agent_id(frame), do: "mcp:user:" <> frame.context.headers["x-user"]
  end

  defmodule BadIdMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "bad-id", version: "1"

    def agent_id(_frame), do: 42
  end

  defmodule VaultAgent do
    @moduledoc "Agent whose tool reports the Vault."
    use Legion.Agent

    def tools, do: [VaultTool]
  end

  defmodule VaultMCP do
    use Legion.MCP.Server, agent: VaultAgent, name: "vault", version: "1", store: MemoryStore
  end

  # Counts the evals the sessions recorded in MemoryStore.
  defmodule StoreLimiter do
    @behaviour Legion.RateLimiter

    @impl true
    def enforce!(agent_id, [%Rule{identity: identity, policy: policy}]) do
      evals =
        MemoryStore.list(100)
        |> Enum.flat_map(&(&1.usage || []))
        |> Enum.map(&Map.get(&1, "evals", 0))
        |> Enum.sum()

      if evals >= policy.max_evals do
        raise ExceededError,
          agent_id: agent_id,
          identity: identity,
          policy: policy,
          usage: %{evals: evals},
          violations: [:max_evals]
      end

      :ok
    end
  end

  defmodule LimitedMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "limited", version: "1", store: MemoryStore

    def rate_limit_rules(frame) do
      [
        %Rule{
          identity: %{"user" => frame.context.headers["x-user"]},
          policy: %Policy{window_ms: 60_000, max_evals: 2}
        }
      ]
    end
  end

  defmodule DefaultPolicyMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "default", version: "1", store: MemoryStore

    def rate_limit_rules(_frame), do: [%Rule{identity: %{"scope" => "mcp"}}]
  end

  defmodule OptedOutMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "opted-out", version: "1"

    def rate_limit_rules(_frame), do: []
  end

  defmodule LimitedVaultMCP do
    use Legion.MCP.Server, agent: VaultAgent, name: "limited-vault", version: "1"

    def rate_limit_rules(_frame),
      do: [%Rule{identity: %{"scope" => "mcp"}, policy: %Policy{window_ms: 60_000, max_evals: 2}}]
  end

  setup do
    start_supervised!(MemoryStore)
    :ok
  end

  # A session the way a client gets one: through the server's `init/2`.
  defp session(server \\ MathMCP, config_overrides \\ %{}) do
    context = %Context{session_id: "session-1", headers: %{"x-user" => "ann"}}
    {:ok, frame} = server.init(%{}, %Frame{context: context})
    Frame.assign(frame, :config, Map.merge(frame.assigns.config, config_overrides))
  end

  defp call(frame, code) do
    {:reply, %Response{} = response, frame} = Repl.execute(%{code: code}, frame)
    [%{"text" => text}] = response.content
    {response.isError, text, frame}
  end

  defp configure_rate_limit(config) do
    Application.put_env(:legion, :rate_limit, config)
    on_exit(fn -> Application.delete_env(:legion, :rate_limit) end)
  end

  defp attach(events) do
    ref = make_ref()
    test_pid = self()
    handler = "repl-test-#{inspect(ref)}"

    :telemetry.attach_many(
      handler,
      events,
      fn event, _measurements, metadata, _ -> send(test_pid, {ref, event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    ref
  end

  defp stored_row do
    [row] = MemoryStore.list(10)
    row
  end

  defp code_of(%{type: :assistant, content: content}), do: Jason.decode!(content)

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
      {_, text, frame} = call(session(MathMCP, %{binding_scope: :iteration}), "x = 40")
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

      {error?, text, _} = call(session(MathMCP, %{eval_guard: NoGuard}), "return 1")

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
      ref = attach([[:legion, :mcp, :call, :start], [:legion, :mcp, :call, :stop]])

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

  describe "execute/2 with a store" do
    test "stores the code, its result and one counted eval" do
      {_, text, _} = call(session(StoredMCP), "return 1 + 1")

      %{conversation_state: %{messages: [code, result]}, usage: [entry]} = stored_row()

      assert code_of(code) == %{"action" => "eval_and_continue", "code" => "return 1 + 1"}
      assert %{type: :eval_result, content: ^text} = result
      assert %{"evals" => 1, "message_index" => 0, "at" => at} = entry
      assert is_integer(at)
    end

    test "a failing eval is stored as an error and counted too" do
      {true, text, _} = call(session(StoredMCP), "return (")

      %{conversation_state: %{messages: [code, error]}, usage: [entry]} = stored_row()

      assert code_of(code)["code"] == "return ("
      assert %{type: :error, content: ^text} = error
      assert %{"evals" => 1, "message_index" => 0} = entry
    end

    test "a second call appends to the same row" do
      {_, _, frame} = call(session(StoredMCP), "x = 40")
      call(frame, "return x + 2")

      %{conversation_state: %{messages: messages}, usage: usage} = stored_row()

      assert [:assistant, :eval_result, :assistant, :eval_result] = Enum.map(messages, & &1.type)
      assert code_of(Enum.at(messages, 2))["code"] == "return x + 2"
      assert [%{"message_index" => 0}, %{"message_index" => 2}] = usage
    end

    test "records the agent and when the session made its first call" do
      {_, _, frame} = call(session(StoredMCP), "return 1")
      %{agent_module: MathAgent, started_at: %NaiveDateTime{} = started_at} = stored_row()

      call(frame, "return 2")
      assert stored_row().started_at == started_at
    end

    test "every session gets its own row under a generated mcp: id" do
      call(session(StoredMCP), "return 1")
      call(session(StoredMCP), "return 2")

      assert [first, second] = MemoryStore.list(10)
      assert "mcp:" <> _ = first.agent_id
      assert "mcp:" <> _ = second.agent_id
    end

    test "a stable agent_id/1 resumes the stored session: variables and history" do
      call(session(UserMCP), "x = 40")
      {_, text, _} = call(session(UserMCP), "return x + 2")

      assert text =~ "42"
      assert %{agent_id: "mcp:user:ann", conversation_state: %{messages: messages}} = stored_row()
      assert length(messages) == 4
    end

    test "an agent_id/1 that returns something other than a string or nil raises" do
      assert_raise ArgumentError, ~r/agent_id\/1/, fn -> call(session(BadIdMCP), "return 1") end
    end

    test "without a store, calls run and nothing is stored" do
      {_, _, frame} = call(session(MathMCP), "x = 40")
      {_, text, _} = call(frame, "return x + 2")

      assert text =~ "42"
      assert MemoryStore.list(10) == []
    end

    test "the store: option wins over the configured store" do
      Application.put_env(:legion, :store, NoSuchStore)
      on_exit(fn -> Application.delete_env(:legion, :store) end)

      call(session(StoredMCP), "return 1")

      assert %{agent_module: MathAgent} = stored_row()
    end

    test "with usage tracking off, the session is stored without usage" do
      Application.put_env(:legion, :track_usage, false)
      on_exit(fn -> Application.delete_env(:legion, :track_usage) end)

      call(session(StoredMCP), "return 1")

      assert %{conversation_state: %{messages: [_, _]}, usage: nil} = stored_row()
    end

    test "a failed save is a tool error and the session keeps its earlier variables" do
      {_, _, frame} = call(session(StoredMCP), "x = 1")

      MemoryStore.fail_saves(true)
      {error?, text, frame} = call(frame, "x = 2")
      assert error?
      assert text =~ "could not be saved"

      MemoryStore.fail_saves(false)
      {_, text, _} = call(frame, "return x")
      assert text =~ "```\n1\n```"
    end

    test "binding_scope :iteration stores no variables" do
      call(session(StoredMCP, %{binding_scope: :iteration}), "x = 40")

      assert stored_row().conversation_state.bindings == []
    end

    test "tools called from the code see the session's row id and store" do
      {_, id_text, frame} = call(session(VaultMCP), "return VaultTool.agent_id()")
      {_, store_text, _} = call(frame, "return VaultTool.store()")

      assert id_text =~ stored_row().agent_id
      assert store_text =~ "MemoryStore"
    end
  end

  describe "execute/2 with rate limit rules" do
    test "a server that gives no rules is not rate limited, and says so when a limiter is configured" do
      configure_rate_limit(
        limiter: StoreLimiter,
        default_policy: %Policy{window_ms: 60_000, max_evals: 0}
      )

      log =
        capture_log(fn ->
          {error?, _, _} = call(session(StoredMCP), "return 1")
          refute error?
        end)

      assert log =~ "no rules were given"
    end

    test "a server that returns no rules on purpose is not rate limited, silently" do
      configure_rate_limit(limiter: StoreLimiter)

      log =
        capture_log(fn ->
          {error?, _, _} = call(session(OptedOutMCP), "return 1")
          refute error?
        end)

      refute log =~ "no rules were given"
    end

    test "allows calls up to the limit, then denies naming the limit and the window" do
      configure_rate_limit(limiter: StoreLimiter)

      {false, _, frame} = call(session(LimitedMCP), "return 1")
      {false, _, frame} = call(frame, "return 2")
      {error?, text, _} = call(frame, "return 3")

      assert error?
      assert text == "Rate limited: max_evals (2 per 60s). Try again later."
    end

    test "the limit holds across sessions" do
      configure_rate_limit(limiter: StoreLimiter)

      {false, _, frame} = call(session(LimitedMCP), "return 1")
      {false, _, _} = call(frame, "return 2")
      {error?, _, _} = call(session(LimitedMCP), "return 3")

      assert error?
    end

    test "a denied call stores nothing" do
      configure_rate_limit(limiter: StoreLimiter)

      {_, _, frame} = call(session(LimitedMCP), "return 1")
      {_, _, frame} = call(frame, "return 2")
      {true, _, _} = call(frame, "return 3")

      assert %{conversation_state: %{messages: messages}, usage: usage} = stored_row()
      assert length(messages) == 4
      assert length(usage) == 2
    end

    test "a denied call emits rate_limit exceeded and stops the call span as failed" do
      configure_rate_limit(limiter: StoreLimiter)
      ref = attach([[:legion, :rate_limit, :exceeded], [:legion, :mcp, :call, :stop]])

      {_, _, frame} = call(session(LimitedMCP), "return 1")
      {_, _, frame} = call(frame, "return 2")
      {true, text, _} = call(frame, "return 3")

      agent_id = stored_row().agent_id

      assert_received {^ref, [:legion, :rate_limit, :exceeded],
                       %{
                         agent: MathAgent,
                         agent_id: ^agent_id,
                         session_id: "session-1",
                         identity: %{"user" => "ann"},
                         policy: %Policy{max_evals: 2},
                         usage: %{evals: 2},
                         violations: [:max_evals]
                       }}

      assert_received {^ref, [:legion, :mcp, :call, :stop], %{success: false, error: ^text}}
    end

    test "a rule without a policy takes the configured default policy" do
      configure_rate_limit(
        limiter: StoreLimiter,
        default_policy: %Policy{window_ms: 1_500, max_evals: 1}
      )

      {false, _, frame} = call(session(DefaultPolicyMCP), "return 1")
      {true, text, _} = call(frame, "return 2")

      assert text == "Rate limited: max_evals (1 per 1500ms). Try again later."
    end

    test "rules without a configured limiter raise" do
      assert_raise ArgumentError, ~r/need a limiter/, fn ->
        call(session(LimitedMCP), "return 1")
      end
    end

    test "code run by the call sees the session's rate limit, which sub-agents inherit" do
      configure_rate_limit(limiter: StoreLimiter)

      {_, text, _} = call(session(LimitedVaultMCP), "return VaultTool.rate_limit()")

      assert text =~ "StoreLimiter"
      assert text =~ "max_evals: 2"
    end
  end
end
