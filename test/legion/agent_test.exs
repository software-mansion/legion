defmodule Legion.AgentTest do
  use ExUnit.Case, async: true

  defmodule MinimalAgent do
    @moduledoc "A minimal agent with no overrides."
    use Legion.Agent
  end

  defmodule PartialOverrideAgent do
    @moduledoc "Agent that overrides tool_config for one tool only."
    use Legion.Agent

    def tools, do: [Legion.Tools.AgentTool]
    def tool_config(Legion.Tools.AgentTool), do: [agents: [MinimalAgent]]
  end

  defmodule NoopStore do
    @behaviour Legion.Store

    @impl Legion.Store
    def get(_agent_id), do: :error

    @impl Legion.Store
    def list(_limit), do: []

    @impl Legion.Store
    def save(_payload), do: :ok
  end

  describe "tool_config/1" do
    test "returns [] for any argument without explicit override" do
      assert MinimalAgent.tool_config(:anything) == []
      assert MinimalAgent.tool_config(Legion.Tools.AgentTool) == []
    end

    test "partial override falls back to [] for non-matching tools" do
      assert PartialOverrideAgent.tool_config(Legion.Tools.AgentTool) == [agents: [MinimalAgent]]
      assert PartialOverrideAgent.tool_config(:other) == []
      assert PartialOverrideAgent.tool_config(SomeModule) == []
    end
  end

  describe "compile-time @moduledoc validation" do
    test "raises at compile time when @moduledoc is missing" do
      assert_raise CompileError, ~r/must define a @moduledoc/, fn ->
        Code.compile_string("""
        defmodule NoDocAgent do
          use Legion.Agent
        end
        """)
      end
    end

    test "raises at compile time when @moduledoc is false" do
      assert_raise CompileError, ~r/must define a @moduledoc/, fn ->
        Code.compile_string("""
        defmodule FalseDocAgent do
          @moduledoc false
          use Legion.Agent
        end
        """)
      end
    end

    test "raises at compile time when @moduledoc is empty" do
      assert_raise CompileError, ~r/must define a @moduledoc/, fn ->
        Code.compile_string("""
        defmodule EmptyDocAgent do
          @moduledoc ""
          use Legion.Agent
        end
        """)
      end
    end
  end

  describe "child_spec/1" do
    test "returns valid child spec with transient restart" do
      spec = MinimalAgent.child_spec([])
      assert spec.id == MinimalAgent
      assert spec.start == {Legion, :start_link, [MinimalAgent, []]}
      assert spec.restart == :transient
    end

    test "passes opts through to start args" do
      spec = MinimalAgent.child_spec(model: "openai:gpt-4o", max_iterations: 5)

      assert spec.start ==
               {Legion, :start_link, [MinimalAgent, [model: "openai:gpt-4o", max_iterations: 5]]}
    end

    test "starts under a DynamicSupervisor, unlinked from the caller" do
      {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
      agent_id = "supervised:#{System.unique_integer([:positive])}"

      {:ok, pid} =
        DynamicSupervisor.start_child(
          supervisor,
          {MinimalAgent, agent_id: agent_id, store: NoopStore}
        )

      {:links, links} = Process.info(self(), :links)
      refute pid in links
      assert Legion.lookup(agent_id) == {:ok, pid}
    end
  end

  defmodule ConfiguredAgent do
    @moduledoc "Agent with its own config and a configured tool."
    use Legion.Agent

    def tools, do: [Legion.Tools.AgentTool, Legion.Test.Support.MathTool]
    def tool_config(Legion.Tools.AgentTool), do: [agents: [MinimalAgent]]
    def config, do: %{model: "agent-model", max_iterations: 3}
  end

  describe "resolve_config/2" do
    setup do
      on_exit(fn -> Application.delete_env(:legion, :config) end)
    end

    test "starts from the executor defaults" do
      assert Legion.Agent.resolve_config(MinimalAgent) == Legion.Executor.default_config()
    end

    test "layers app env, then agent config, then opts on top of the defaults" do
      Application.put_env(:legion, :config, %{model: "app-model", max_retries: 9})

      config = Legion.Agent.resolve_config(ConfiguredAgent, max_iterations: 1)

      assert config.model == "agent-model"
      assert config.max_retries == 9
      assert config.max_iterations == 1
    end

    test "warns about unknown keys but keeps them" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %{bogus: true} = Legion.Agent.resolve_config(MinimalAgent, bogus: true)
        end)

      assert log =~ "Unknown Legion config keys: [:bogus]"
    end

    test "accepts :infinity and positive integers for max_message_length" do
      assert %{max_message_length: :infinity} =
               Legion.Agent.resolve_config(MinimalAgent, max_message_length: :infinity)

      assert %{max_message_length: 5} =
               Legion.Agent.resolve_config(MinimalAgent, max_message_length: 5)
    end

    test "rejects other max_message_length values" do
      assert_raise ArgumentError, ~r/expected :max_message_length/, fn ->
        Legion.Agent.resolve_config(MinimalAgent, max_message_length: 0)
      end
    end
  end

  describe "seed_tool_configs/1" do
    test "stores each tool's config in the calling process's Vault under the tool module" do
      assert :ok = Legion.Agent.seed_tool_configs(ConfiguredAgent)

      assert Vault.get(Legion.Tools.AgentTool) == [agents: [MinimalAgent]]
      assert Vault.get(Legion.Test.Support.MathTool) == []
    end
  end

  describe "defaults" do
    test "moduledoc returns @moduledoc" do
      assert MinimalAgent.moduledoc() == "A minimal agent with no overrides."
    end

    test "tools defaults to []" do
      assert MinimalAgent.tools() == []
    end

    test "output_schema defaults to string type" do
      assert MinimalAgent.output_schema() == %{"type" => "string"}
    end
  end
end
