defmodule Legion.Tools.HelpTest do
  use ExUnit.Case, async: true

  alias Legion.{AgentPrompt, AgentServer}
  alias Legion.Test.Support.{MathAgent, MathTool, SummaryTool}
  alias Legion.Tools.Help

  defmodule ToolsAgent do
    @moduledoc "Agent with two tools."
    use Legion.Agent

    def tools, do: [MathTool, SummaryTool]
  end

  defmodule AgentToolAgent do
    @moduledoc "Agent that delegates work."
    use Legion.Agent

    def tools, do: [Legion.Tools.AgentTool]
  end

  describe "AgentPrompt.tool_index/2" do
    test "one line per tool, Help included, with no signatures or source" do
      index = AgentPrompt.tool_index(ToolsAgent, [])

      assert index =~ "- `MathTool` - This is math tool moduledoc."
      assert index =~ "- `SummaryTool` - Custom summary."
      assert index =~ "- `Help` - Lists the tools available"
      refute index =~ "random_add"
      refute index =~ "defmodule"
    end
  end

  describe "AgentPrompt.tool_help/4" do
    test "returns the block the :inline executor prompt renders for that tool" do
      text = AgentPrompt.tool_help(MathAgent, Legion.Sandbox.Lua, "MathTool", [])
      assert text == AgentPrompt.tool_reference(MathTool, Legion.Sandbox.Lua)
      assert AgentPrompt.system_prompt(MathAgent) =~ text
    end

    test "describes Help itself" do
      text = AgentPrompt.tool_help(MathAgent, Legion.Sandbox.Lua, Help, [])
      assert text =~ "### Help"
      assert text =~ "def help(tool)"
    end

    test "an unknown name returns the index" do
      text = AgentPrompt.tool_help(MathAgent, Legion.Sandbox.Lua, "Nope", [])
      assert text =~ ~s|No tool named "Nope". Tools:|
      assert text =~ "- `MathTool` -"
    end
  end

  describe "inside the sandbox" do
    test "no function takes another agent, so its tools stay unread" do
      {:ok, pid} = Legion.start_link(MathAgent, sandbox: Legion.Sandbox.Elixir)

      for code <- [
            "Help.index(#{inspect(ToolsAgent)})",
            ~s|Help.reference(#{inspect(ToolsAgent)}, Legion.Sandbox.Elixir, "SummaryTool")|,
            "Legion.AgentPrompt.tool_index(#{inspect(ToolsAgent)}, [])"
          ] do
        assert {:error, text} = AgentServer.eval(pid, code), code
        refute text =~ "SummaryTool"
      end
    end

    for {sandbox, code} <- [
          {Legion.Sandbox.Lua, "return Help.help(MathTool)"},
          {Legion.Sandbox.Elixir, "Help.help(MathTool)"}
        ],
        tool_docs <- [:inline, :on_demand] do
      test "help/1 returns a tool's reference in #{inspect(sandbox)} under tool_docs: #{inspect(tool_docs)}" do
        {:ok, pid} =
          Legion.start_link(MathAgent,
            sandbox: unquote(sandbox),
            tool_docs: unquote(tool_docs)
          )

        assert {:ok, text} = AgentServer.eval(pid, unquote(code))
        assert text =~ "### MathTool"
        assert text =~ "performs math operations"
      end
    end

    test "help/0 lists the tools under :on_demand" do
      {:ok, pid} = Legion.start_link(MathAgent, tool_docs: :on_demand)

      assert {:ok, text} = AgentServer.eval(pid, "return Help.help()")
      assert text =~ "- `MathTool` -"
      assert text =~ "- `Help` -"
    end

    test "help/1 of an unknown tool returns the index as text, not an error" do
      {:ok, pid} = Legion.start_link(MathAgent, tool_docs: :on_demand)

      # An unknown name is `nil` in Lua, so the index comes back without a complaint.
      assert {:ok, text} = AgentServer.eval(pid, "return Help.help(Nope)")
      refute text =~ "No tool named"
      assert text =~ "- `MathTool` -"
    end

    test "help/1 of an unknown tool names it in the Elixir sandbox" do
      {:ok, pid} =
        Legion.start_link(MathAgent, tool_docs: :on_demand, sandbox: Legion.Sandbox.Elixir)

      assert {:ok, text} = AgentServer.eval(pid, "Help.help(Nope)")
      assert text =~ "No tool named"
      assert text =~ "- `MathTool` -"
    end

    test "help/1 also takes the name as a string" do
      {:ok, pid} = Legion.start_link(MathAgent, tool_docs: :on_demand)

      assert {:ok, text} = AgentServer.eval(pid, ~s|return Help.help("MathTool")|)
      assert text =~ "### MathTool"

      assert {:ok, text} = AgentServer.eval(pid, ~s|return Help.help("Nope")|)
      assert text =~ "No tool named"
    end

    test "help/1 renders the reference for the sandbox the agent was started with" do
      {:ok, pid} =
        Legion.start_link(AgentToolAgent, tool_docs: :on_demand, sandbox: Legion.Sandbox.Elixir)

      assert {:ok, text} = AgentServer.eval(pid, "Help.help(AgentTool)")
      assert text =~ "{:ok, result} ="
      refute text =~ "result = response[2]"
    end

    test "help/1 renders the Lua reference on the Lua sandbox" do
      {:ok, pid} = Legion.start_link(AgentToolAgent, tool_docs: :on_demand)

      assert {:ok, text} = AgentServer.eval(pid, "return Help.help(AgentTool)")
      assert text =~ "return response[2]"
      refute text =~ "{:ok, result} ="
    end
  end
end
