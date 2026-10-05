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

  describe "index/1" do
    test "one line per tool, name and summary" do
      index = Help.index(ToolsAgent)

      assert index =~ "- `MathTool` - This is math tool moduledoc."
      assert index =~ "- `SummaryTool` - Custom summary."
    end

    test "lists Help itself" do
      assert Help.index(ToolsAgent) =~ "- `Help` - Lists the tools available"
    end

    test "carries no signatures or source" do
      index = Help.index(ToolsAgent)

      refute index =~ "random_add"
      refute index =~ "defmodule"
    end
  end

  describe "reference/2" do
    test "returns the block the :full executor prompt renders for that tool" do
      assert {:ok, text} = Help.reference(MathAgent, Legion.Sandbox.Lua, "MathTool")
      assert text == AgentPrompt.tool_reference(MathTool, Legion.Sandbox.Lua)
      assert AgentPrompt.system_prompt(MathAgent) =~ text
    end

    test "describes Help itself" do
      assert {:ok, text} = Help.reference(MathAgent, Legion.Sandbox.Lua, "Help")
      assert text =~ "### Help"
      assert text =~ "def help(tool)"
    end

    test "an unknown name is an error carrying the index" do
      assert {:error, text} = Help.reference(MathAgent, Legion.Sandbox.Lua, "Nope")
      assert text =~ ~s|No tool named "Nope". Tools:|
      assert text =~ "- `MathTool` -"
    end
  end

  describe "inside the sandbox" do
    test "help/1 returns a tool's reference under tool_docs: :discovery" do
      {:ok, pid} = Legion.start_link(MathAgent, tool_docs: :discovery)

      assert {:ok, text} = AgentServer.eval(pid, "return Help.help(MathTool)")
      assert text =~ "### MathTool"
      assert text =~ "performs math operations"
    end

    test "help/0 lists the tools under :discovery" do
      {:ok, pid} = Legion.start_link(MathAgent, tool_docs: :discovery)

      assert {:ok, text} = AgentServer.eval(pid, "return Help.help()")
      assert text =~ "- `MathTool` -"
      assert text =~ "- `Help` -"
    end

    test "help/1 of an unknown tool returns the index as text, not an error" do
      {:ok, pid} = Legion.start_link(MathAgent, tool_docs: :discovery)

      # An unknown name is `nil` in Lua, so the index comes back without a complaint.
      assert {:ok, text} = AgentServer.eval(pid, "return Help.help(Nope)")
      refute text =~ "No tool named"
      assert text =~ "- `MathTool` -"
    end

    test "help/1 of an unknown tool names it in the Elixir sandbox" do
      {:ok, pid} =
        Legion.start_link(MathAgent, tool_docs: :discovery, sandbox: Legion.Sandbox.Elixir)

      assert {:ok, text} = AgentServer.eval(pid, "Help.help(Nope)")
      assert text =~ "No tool named"
      assert text =~ "- `MathTool` -"
    end

    test "help/1 also takes the name as a string" do
      {:ok, pid} = Legion.start_link(MathAgent, tool_docs: :discovery)

      assert {:ok, text} = AgentServer.eval(pid, ~s|return Help.help("MathTool")|)
      assert text =~ "### MathTool"

      assert {:ok, text} = AgentServer.eval(pid, ~s|return Help.help("Nope")|)
      assert text =~ "No tool named"
    end

    test "Help is in the sandbox under the default :full too" do
      {:ok, pid} = Legion.start_link(MathAgent)

      assert {:ok, text} = AgentServer.eval(pid, "return Help.help(MathTool)")
      assert text =~ "### MathTool"
    end

    test "help/1 works in the Elixir sandbox under :discovery" do
      {:ok, pid} =
        Legion.start_link(MathAgent, tool_docs: :discovery, sandbox: Legion.Sandbox.Elixir)

      assert {:ok, text} = AgentServer.eval(pid, "Help.help(MathTool)")
      assert text =~ "### MathTool"
      assert text =~ "performs math operations"
    end

    test "help/1 renders the reference for the sandbox the agent was started with" do
      {:ok, pid} =
        Legion.start_link(AgentToolAgent, tool_docs: :discovery, sandbox: Legion.Sandbox.Elixir)

      assert {:ok, text} = AgentServer.eval(pid, "Help.help(AgentTool)")
      assert text =~ "{:ok, result} ="
      refute text =~ "result = response[2]"
    end

    test "Help is in the Elixir sandbox under :full too" do
      {:ok, pid} = Legion.start_link(MathAgent, sandbox: Legion.Sandbox.Elixir)

      assert {:ok, text} = AgentServer.eval(pid, "Help.help(MathTool)")
      assert text =~ "### MathTool"
    end
  end
end
