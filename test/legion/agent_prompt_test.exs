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

      assert prompt =~ "response = AgentTool.call(SomeAgent, {"
      assert prompt =~ "result = response[2]"
      assert prompt =~ "Lua cannot pass a function through the tool bridge"
      assert prompt =~ "Long-lived sub-agents are not available from Lua"
      refute prompt =~ "{:ok, result}"
    end

    test "uses Elixir AgentTool documentation in the Elixir sandbox" do
      prompt = AgentPrompt.system_prompt(AgentToolAgent, %{sandbox: Legion.Sandbox.Elixir})

      assert prompt =~ "{:ok, result} ="
      assert prompt =~ "AgentTool.start_link("
      assert prompt =~ "WriterAgent,"
      refute prompt =~ "result = response[2]"
    end
  end

  describe "tool_docs: :discovery" do
    test "lists tools by name and summary instead of their source" do
      prompt = AgentPrompt.system_prompt(MathAgent, %{tool_docs: :discovery})

      assert prompt =~ "- `MathTool` - This is math tool moduledoc."
      assert prompt =~ "- `Help` -"
      refute prompt =~ "MathTool — performs math operations"
      refute prompt =~ "random_add"
    end

    test "steers the model to Help before the first use of a tool" do
      prompt = AgentPrompt.system_prompt(MathAgent, %{tool_docs: :discovery})

      assert prompt =~ ~s|Help.describe("Name")|
      assert prompt =~ "Help.tools()"
      refute prompt =~ "Examine the tool source code below"
    end

    test "keeps the rest of the executor prompt" do
      prompt = AgentPrompt.system_prompt(MathAgent, %{tool_docs: :discovery})

      assert prompt =~ "## How you work"
      assert prompt =~ "An agent that does math."
      assert prompt =~ "**Constraints:**"
    end

    test "an explicit :full renders the same prompt as the default" do
      assert AgentPrompt.system_prompt(MathAgent, %{tool_docs: :full}) ==
               AgentPrompt.system_prompt(MathAgent)
    end
  end
end
