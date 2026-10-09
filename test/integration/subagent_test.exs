defmodule Legion.Integration.SubagentTest do
  @moduledoc """
  Integration test: orchestrator agent delegates to sub-agents.

  Skipped by default to avoid external API calls and LLM costs.
  Run with:

      mix test test/integration/subagent_test.exs --include integration
  """
  use ExUnit.Case, async: true

  alias Legion.Test.Support.{HackerNewsAgent, OrchestratorAgent, RedditAgent}

  @moduletag :integration
  @moduletag timeout: 600_000

  setup do
    unless System.get_env("OPENAI_API_KEY"), do: raise("OPENAI_API_KEY not set")

    ref = :telemetry_test.attach_event_handlers(self(), [[:legion, :agent, :started]])
    on_exit(fn -> :telemetry.detach(ref) end)

    {:ok, ref: ref}
  end

  test "orchestrator delegates to sub-agents and combines results", %{ref: ref} do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("Sub-agent Integration Test")
    IO.puts(String.duplicate("=", 60))

    task = """
    Research what people are saying about Elixir programming language.
    Use AgentTool.call/2 to delegate:
    - Call Legion.Test.Support.HackerNewsAgent with "Fetch up to 3 posts about Elixir and summarize the key topics"
    - Call Legion.Test.Support.RedditAgent with "Fetch up to 3 posts about Elixir from r/elixir and summarize the key topics"
    Then combine both summaries into a brief overall summary.
    """

    result = Legion.execute(OrchestratorAgent, task)

    IO.puts("\nResult: #{inspect(result, pretty: true, limit: 20)}")
    IO.puts(String.duplicate("=", 60) <> "\n")

    assert match?({:ok, _}, result) or match?({:cancel, _}, result)

    assert_receive {[:legion, :agent, :started], ^ref, _measurements,
                    %{agent: OrchestratorAgent, agent_id: orchestrator_id}}

    for sub_agent <- [HackerNewsAgent, RedditAgent] do
      assert_receive {[:legion, :agent, :started], ^ref, _measurements,
                      %{agent: ^sub_agent, parent_agent_id: ^orchestrator_id}}
    end
  end
end
