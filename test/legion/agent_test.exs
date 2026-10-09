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
    for {case_name, moduledoc} <- [
          {"missing", ""},
          {"false", "@moduledoc false"},
          {"empty", ~s(@moduledoc "")}
        ] do
      test "raises at compile time when @moduledoc is #{case_name}" do
        assert_raise CompileError, ~r/must define a @moduledoc/, fn ->
          Code.compile_string("""
          defmodule UndocumentedAgent do
            #{unquote(moduledoc)}
            use Legion.Agent
          end
          """)
        end
      end
    end
  end

  describe "child_spec/1" do
    test "starts the agent through Legion.start_link/2 with the opts, restarting it only on a crash" do
      spec = MinimalAgent.child_spec(model: "openai:gpt-4o", max_iterations: 5)

      assert spec.id == MinimalAgent
      assert spec.restart == :transient

      assert spec.start ==
               {Legion, :start_link, [MinimalAgent, [model: "openai:gpt-4o", max_iterations: 5]]}
    end

    test "starts under a DynamicSupervisor, unlinked from the caller" do
      supervisor = start_supervised!(DynamicSupervisor)
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
    test "starts from the executor defaults" do
      assert Legion.Agent.resolve_config(MinimalAgent) == Legion.Executor.default_config()
    end

    test "layers agent config, then opts on top of the defaults" do
      config = Legion.Agent.resolve_config(ConfiguredAgent, max_iterations: 1)

      assert config.model == "agent-model"
      assert config.max_iterations == 1
      assert config.max_retries == Legion.Executor.default_config().max_retries
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

  describe "tool short names" do
    test "warns when two tools share a short name" do
      assert compile_warnings("""
             defmodule Legion.ShadowAgent do
               @moduledoc "Test."
               use Legion.Agent
               def tools, do: [Legion.Test.Support.MathTool, Legion.Other.MathTool]
             end
             """) =~ "Legion.ShadowAgent lists tools with the same short name MathTool"
    end

    test "warns when a tool is named Help" do
      assert compile_warnings("""
             defmodule Legion.HelpAgent do
               @moduledoc "Test."
               use Legion.Agent
               def tools, do: [Legion.Mine.Help]
             end
             """) =~ "Legion.HelpAgent lists tools with the same short name Help"
    end
  end

  # Diagnostics are collected in the calling process, so concurrent tests
  # writing to stderr cannot leak into the assertion.
  defp compile_warnings(code) do
    {_modules, diagnostics} = Code.with_diagnostics(fn -> Code.compile_string(code) end)
    Enum.map_join(diagnostics, "\n", & &1.message)
  end
end

defmodule Legion.AgentAppConfigTest do
  # Sets the global `:legion, :config` app env.
  use ExUnit.Case, async: false

  alias Legion.AgentTest.ConfiguredAgent

  setup do
    on_exit(fn -> Application.delete_env(:legion, :config) end)
  end

  test "resolve_config/2 layers the app env between the defaults and the agent config" do
    Application.put_env(:legion, :config, %{model: "app-model", max_retries: 9})

    config = Legion.Agent.resolve_config(ConfiguredAgent)

    assert config.model == "agent-model"
    assert config.max_retries == 9
  end
end
