defmodule Legion.AgentPromptTest do
  use ExUnit.Case

  alias Legion.AgentPrompt
  alias Legion.Test.Support.{HackerNewsAgent, MathAgent, NoToolAgent}

  defmodule JasonAgent do
    @moduledoc "Agent that uses Jason as a 3rd party tool."
    use Legion.Agent

    def tools, do: [Jason]
  end

  defmodule AgentToolAgent do
    @moduledoc "Agent that delegates work."
    use Legion.Agent

    def tools, do: [Legion.Tools.AgentTool]
  end

  describe "system_prompt/1" do
    test "includes agent moduledoc" do
      prompt = AgentPrompt.system_prompt(MathAgent)
      assert prompt =~ "An agent that does math."
    end

    test "includes the sandbox language" do
      prompt = AgentPrompt.system_prompt(MathAgent)
      assert prompt =~ "Lua"
    end

    test "includes custom description when description/0 is overridden" do
      prompt = AgentPrompt.system_prompt(MathAgent)
      assert prompt =~ "MathTool — performs math operations using integer arithmetic only."
      refute prompt =~ "defmodule Legion.Test.Support.MathTool"
    end

    test "includes source code as default description" do
      prompt = AgentPrompt.system_prompt(HackerNewsAgent)
      assert prompt =~ "defmodule Legion.Test.Support.HackerNewsTool"
      assert prompt =~ "def fetch_posts"
    end

    test "includes Available Tools section header" do
      prompt = AgentPrompt.system_prompt(MathAgent)
      assert prompt =~ "## Available Tools"
    end

    test "no tools section when agent has no tools" do
      prompt = AgentPrompt.system_prompt(NoToolAgent)
      refute prompt =~ "## Available Tools"
    end

    test "result is trimmed" do
      prompt = AgentPrompt.system_prompt(MathAgent)
      assert prompt == String.trim(prompt)
    end

    test "includes 3rd party library source when listed in tools" do
      prompt = AgentPrompt.system_prompt(JasonAgent)
      assert prompt =~ "## Available Tools"
      assert prompt =~ "defmodule Jason"
    end

    test "uses Lua-safe AgentTool documentation in the Lua sandbox" do
      prompt = AgentPrompt.system_prompt(AgentToolAgent)

      assert prompt =~ ~s|response = AgentTool.call(SomeAgent, "Summarize|
      assert prompt =~ "writer = AgentTool.start_link(WriterAgent)[2]"
      refute prompt =~ "AgentTool.pipeline"
      refute prompt =~ "{:ok, result}"
    end

    test "uses Elixir AgentTool documentation in the Elixir sandbox" do
      prompt = AgentPrompt.system_prompt(AgentToolAgent, %{sandbox: Legion.Sandbox.Elixir})

      assert prompt =~ "{:ok, result} ="
      assert prompt =~ "{:ok, writer} = AgentTool.start_link(WriterAgent)"
      assert prompt =~ "AgentTool.pipeline"
      refute prompt =~ "response[2]"
    end
  end

  describe "tool_docs: :on_demand" do
    test "lists tools by name and summary instead of their source" do
      prompt = AgentPrompt.system_prompt(MathAgent, %{tool_docs: :on_demand})

      assert prompt =~ "- `MathTool` - This is math tool moduledoc."
      assert prompt =~ "- `Help` -"
      refute prompt =~ "MathTool — performs math operations"
      refute prompt =~ "random_add"
    end

    test "steers the model to Help before the first use of a tool" do
      prompt = AgentPrompt.system_prompt(MathAgent, %{tool_docs: :on_demand})

      assert prompt =~ "Help.help(Name)"
      assert prompt =~ "Help.help()"
      refute prompt =~ "Examine the tool source code below"
    end

    test "keeps the rest of the executor prompt" do
      prompt = AgentPrompt.system_prompt(MathAgent, %{tool_docs: :on_demand})

      assert prompt =~ "## How you work"
      assert prompt =~ "An agent that does math."
      assert prompt =~ "**Constraints:**"
    end

    test "an explicit :inline renders the same prompt as the default" do
      assert AgentPrompt.system_prompt(MathAgent, %{tool_docs: :inline}) ==
               AgentPrompt.system_prompt(MathAgent)
    end
  end

  describe "mode: :mcp" do
    test "defaults to tool_docs: :on_demand" do
      prompt = AgentPrompt.system_prompt(MathAgent, nil, mode: :mcp)

      assert prompt =~ "- `MathTool` - This is math tool moduledoc."
      assert prompt =~ "- `Help` -"
      assert prompt =~ "`help`"
      refute prompt =~ "MathTool — performs math operations"
      refute prompt =~ "**Constraints:**"
    end

    test "keeps the agent's purpose and the repl mechanics" do
      prompt = AgentPrompt.system_prompt(MathAgent, nil, mode: :mcp)

      assert prompt =~ "An agent that does math."
      assert prompt =~ "`repl`"
      assert prompt =~ "Variables persist"
      assert prompt =~ "Lua"
    end

    test "tool_docs: :inline renders the full tools section over MCP" do
      prompt = AgentPrompt.system_prompt(MathAgent, %{tool_docs: :inline}, mode: :mcp)

      assert prompt =~ "### MathTool"
      assert prompt =~ "MathTool — performs math operations"
      assert prompt =~ "**Constraints:**"
      refute prompt =~ "`help`"
    end
  end
end
