defmodule Legion.Sandbox.LuaReadmeTest.ScraperTool do
  use Legion.Tool

  @doc "Fetches recent posts from HackerNews"
  def fetch_posts do
    [
      %{"title" => "Elixir Advent of Code 2024 - Day 5 walkthrough"},
      %{"title" => "My first AoC in Elixir!"},
      %{"title" => "Show HN: a Rust build tool"}
    ]
  end
end

defmodule Legion.Sandbox.LuaReadmeTest.DatabaseTool do
  use Legion.Tool

  @doc "Saves a post title to the database"
  def insert_post(title) do
    send(:lua_readme_test_sink, {:inserted, title})
    title
  end
end

# Stands in for Legion.Tools.AgentTool - same short name and call contract,
# without spinning up sub-agent LLM runs.
defmodule Legion.Sandbox.LuaReadmeTest.AgentTool do
  use Legion.Tool

  def description, do: "Delegates a task to a sub-agent."

  def call(agent_module, task) when is_atom(agent_module), do: {:ok, "done: " <> task}
end

defmodule Legion.Sandbox.LuaReadmeTest.ResearchAgent do
end

defmodule Legion.Sandbox.LuaReadmeTest.WriterAgent do
end

defmodule Legion.Sandbox.LuaReadmeTest do
  @moduledoc """
  Runs the exact generated-code snippets shown in README.md through the Lua
  sandbox. If a test here fails, the README needs the same fix.
  """
  use ExUnit.Case

  alias Legion.Sandbox.Lua
  alias Legion.Sandbox.LuaReadmeTest.AgentTool
  alias Legion.Sandbox.LuaReadmeTest.DatabaseTool
  alias Legion.Sandbox.LuaReadmeTest.ResearchAgent
  alias Legion.Sandbox.LuaReadmeTest.ScraperTool
  alias Legion.Sandbox.LuaReadmeTest.WriterAgent

  test "usage walkthrough: filter posts, then save the good ones" do
    Process.register(self(), :lua_readme_test_sink)

    filter_snippet = """
    local posts = ScraperTool.fetch_posts()
    local relevant = {}
    for _, post in ipairs(posts) do
      local title = string.lower(post.title or "")
      if title:find("elixir") and (title:find("advent") or title:find("aoc")) then
        table.insert(relevant, post)
      end
    end
    return relevant
    """

    assert {:ok, {relevant, bindings}} =
             Lua.execute(filter_snippet, 15_000, [ScraperTool, DatabaseTool])

    assert relevant == [
             %{"title" => "Elixir Advent of Code 2024 - Day 5 walkthrough"},
             %{"title" => "My first AoC in Elixir!"}
           ]

    insert_snippet = """
    local titles = {"Elixir Advent of Code 2024 - Day 5 walkthrough", "My first AoC in Elixir!"}
    for _, title in ipairs(titles) do
      DatabaseTool.insert_post(title)
    end
    """

    assert {:ok, {nil, _}} =
             Lua.execute(insert_snippet, 15_000, [ScraperTool, DatabaseTool], bindings)

    assert_receive {:inserted, "Elixir Advent of Code 2024 - Day 5 walkthrough"}
    assert_receive {:inserted, "My first AoC in Elixir!"}
    refute_receive {:inserted, _}
  end

  test "orchestrator: delegate to sub-agents and chain their results" do
    orchestrator_snippet = """
    local _, research = table.unpack(AgentTool.call(ResearchAgent, "Find info about Elixir 1.18"))
    local _, draft = table.unpack(AgentTool.call(WriterAgent, "Write a blog post using: " .. research))
    return draft
    """

    assert {:ok, {draft, _}} =
             Lua.execute(orchestrator_snippet, 15_000, [AgentTool, ResearchAgent, WriterAgent])

    assert draft == "done: Write a blog post using: done: Find info about Elixir 1.18"
  end
end
