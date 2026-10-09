defmodule Legion.EvalTest do
  use ExUnit.Case, async: true

  alias Legion.Eval

  defmodule RecordingSandbox do
    @moduledoc "Sandbox that reports every call to the test process and answers by script."
    @behaviour Legion.Sandbox

    @impl true
    def check(code, allowed) do
      send(self(), {:check, code, allowed})
      if code == "bad syntax", do: {:error, "cannot parse"}, else: :ok
    end

    @impl true
    def execute(code, timeout, allowed, bindings, limits) do
      send(self(), {:execute, code, timeout, allowed, bindings, limits})

      case code do
        "boom" -> {:error, "runtime boom"}
        _ -> {:ok, {String.length(code), [{:last, code} | bindings]}}
      end
    end

    @impl true
    def binding_names(bindings), do: Keyword.keys(bindings)

    @impl true
    def prompt_info, do: %{language: "Fake", constraints: "", tool_usage: ""}
  end

  defmodule ExtraTool do
    @moduledoc "Tool that opens Jason to the sandbox (no `use Legion.Tool`: nested modules cannot be source-extracted)."

    def extra_allowed_modules, do: [Jason]
  end

  defmodule ExtraAgent do
    @moduledoc "Agent whose tool needs an extra module."
    use Legion.Agent

    def tools, do: [ExtraTool]
  end

  defmodule DenyGuard do
    @moduledoc "Guard that refuses everything and reports the context it saw."
    @behaviour Legion.EvalGuard

    @impl true
    def check(_code, context) do
      send(self(), {:guard_context, context})
      {:deny, "not today"}
    end
  end

  defp config(overrides \\ %{}) do
    Legion.Executor.default_config()
    |> Map.merge(%{
      sandbox: RecordingSandbox,
      sandbox_timeout: 1_234,
      sandbox_max_heap: 10,
      sandbox_max_reductions: 20,
      sandbox_priority: :normal
    })
    |> Map.merge(overrides)
  end

  describe "run/4" do
    test "fails an execution whose variables would exceed max_bindings_bytes" do
      config = config(%{max_bindings_bytes: 30})

      assert {:ok, {_value, bindings}} = Eval.run(ExtraAgent, "x", config, [])
      assert {:error, error} = Eval.run(ExtraAgent, String.duplicate("y", 100), config, bindings)
      assert error =~ "over the 30 byte limit"
    end

    test "skips the max_bindings_bytes check under :iteration, which drops the variables" do
      config = config(%{max_bindings_bytes: 30, binding_scope: :iteration})

      assert {:ok, _} = Eval.run(ExtraAgent, String.duplicate("y", 100), config, [])
    end

    test "checks and executes the code with the agent's tools and their extra modules allowed" do
      assert {:ok, _} = Eval.run(ExtraAgent, "x = 1", config(), [])

      assert_received {:check, "x = 1", [ExtraTool, Legion.Tools.Help, Jason]}

      assert_received {:execute, "x = 1", _timeout, [ExtraTool, Legion.Tools.Help, Jason], [],
                       _limits}
    end

    test "passes the timeout and resource limits from the config to the sandbox" do
      Eval.run(ExtraAgent, "x = 1", config(), [])

      assert_received {:execute, _code, 1_234, _allowed, _bindings, limits}
      assert limits == [max_heap: 10, max_reductions: 20, priority: :normal]
    end

    test "returns the value and the bindings the sandbox produced" do
      assert Eval.run(ExtraAgent, "abc", config(), seed: 1) ==
               {:ok, {3, [last: "abc", seed: 1]}}
    end

    test "returns the static check error without executing" do
      assert Eval.run(ExtraAgent, "bad syntax", config(), []) == {:error, "cannot parse"}
      refute_received {:execute, _, _, _, _, _}
    end

    test "returns the sandbox execution error" do
      assert Eval.run(ExtraAgent, "boom", config(), []) == {:error, "runtime boom"}
    end

    test "a guard refusal is an error naming the guard and the reason, and nothing executes" do
      assert Eval.run(ExtraAgent, "x = 1", config(%{eval_guard: DenyGuard}), []) ==
               {:error, "refused by Legion.EvalTest.DenyGuard: not today"}

      refute_received {:execute, _, _, _, _, _}
    end

    test "the guard sees the agent, the current agent id and the tools" do
      Vault.unsafe_put(:agent_id, "agent-7")

      Eval.run(ExtraAgent, "x = 1", config(%{eval_guard: DenyGuard}), [])

      assert_received {:guard_context,
                       %{
                         agent: ExtraAgent,
                         agent_id: "agent-7",
                         tools: [ExtraTool, Legion.Tools.Help]
                       }}
    end

    test "emits a sandbox eval span with the outcome" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "eval-test-#{inspect(ref)}",
        [[:legion, :sandbox, :eval, :start], [:legion, :sandbox, :eval, :stop]],
        fn event, _measurements, metadata, _config ->
          if self() == test_pid, do: send(test_pid, {ref, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("eval-test-#{inspect(ref)}") end)

      Eval.run(ExtraAgent, "abc", config(), [])
      Eval.run(ExtraAgent, "boom", config(), [])

      assert_received {^ref, [:legion, :sandbox, :eval, :start],
                       %{agent: ExtraAgent, code: "abc"}}

      assert_received {^ref, [:legion, :sandbox, :eval, :stop], %{success: true, result: 3}}

      assert_received {^ref, [:legion, :sandbox, :eval, :stop],
                       %{success: false, error: "runtime boom"}}
    end
  end

  describe "format_result/3" do
    test "shows the inspected value and the variables now in scope" do
      text = Eval.format_result(%{a: 1}, [x: 1, y: 2], config())

      assert text =~ "Code executed successfully"
      assert text =~ "%{a: 1}"
      assert text =~ "Available variables: `x`, `y`"
    end

    test "omits the variables line when nothing is bound" do
      refute Eval.format_result(42, [], config()) =~ "Available variables"
    end

    test "truncates the inspected value to max_message_length" do
      text = Eval.format_result(String.duplicate("a", 500), [], config(%{max_message_length: 50}))

      assert text =~ "[... truncated"
      refute text =~ String.duplicate("a", 100)
    end

    test "truncates the variables line to max_message_length" do
      bindings = for index <- 1..1_000, do: {:"variable_#{index}", index}
      text = Eval.format_result(1, bindings, config(%{max_message_length: 200}))

      assert text =~ "Available variables: `variable_1`"
      assert text =~ "[... truncated"
      assert byte_size(text) < 600
    end

    test "a cut through a multibyte character leaves valid UTF-8" do
      for character <- ["é", "€", "🙂"], max <- 40..44 do
        text =
          Eval.format_result(
            String.duplicate(character, 100),
            [],
            config(%{max_message_length: max})
          )

        assert String.valid?(text), "#{character} at #{max} bytes"
        assert text =~ "[... truncated"
      end
    end

    test "a string past inspect's own 4096 limit is shown whole under max_message_length" do
      text = Eval.format_result(String.duplicate("a", 10_000), [], config())

      assert text =~ String.duplicate("a", 10_000)
      refute text =~ "<> ..."
      refute text =~ "[... truncated"
    end

    test "max_message_length: :infinity lifts inspect's limit too" do
      text =
        Eval.format_result(
          String.duplicate("a", 50_000),
          [],
          config(%{max_message_length: :infinity})
        )

      assert text =~ String.duplicate("a", 50_000)
    end
  end

  describe "format_error/1" do
    test "passes strings through" do
      assert Eval.format_error("nope") == "nope"
    end

    test "uses the message of exceptions and message maps" do
      assert Eval.format_error(%ArgumentError{message: "bad arg"}) == "bad arg"
      assert Eval.format_error(%{message: "from map"}) == "from map"
    end

    test "inspects anything else" do
      assert Eval.format_error({:exit, :killed}) == "{:exit, :killed}"
    end

    test "replaces bytes that are not UTF-8" do
      assert Eval.format_error("bad \xFF byte") == "bad \uFFFD byte"
    end
  end
end
