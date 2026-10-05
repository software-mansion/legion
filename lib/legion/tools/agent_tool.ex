defmodule Legion.Tools.AgentTool do
  @moduledoc """
  Built-in tool for delegating tasks to sub-agents.

  The calling agent must explicitly list allowed sub-agents via `tool_config/1`:

      def tool_config(Legion.Tools.AgentTool), do: [agents: [MyApp.WorkerAgent, MyApp.ResearchAgent]]
      def tool_config(_), do: []

  Only listed agents can be invoked. Attempts to call unlisted agents raise an error.

  An agent that lists this tool cannot be served over MCP; see `Legion.MCP.Server`.

  ## Usage example from agent code (executed in sandbox)

      AgentTool.call(WorkerAgent, "Summarize this data")

  Listed sub-agents are aliased into the sandbox automatically, so their short names
  (the last segment of the module) resolve to the full module atom - no need to spell
  out `MyApp.Agents.WorkerAgent`.
  """

  use Legion.Tool

  alias Legion.AgentServer

  @impl Legion.Tool
  def extra_allowed_modules, do: Vault.get(__MODULE__, [])[:agents] || []

  @impl Legion.Tool
  def description(sandbox) do
    summaries =
      case extra_allowed_modules() do
        [] ->
          "  (none configured - this tool will raise on any call)"

        modules ->
          Enum.map_join(modules, "\n", fn module ->
            short = module |> Module.split() |> List.last()
            "  - `#{short}` - #{moduledoc_summary(module)}"
          end)
      end

    docs = description_docs(sandbox)

    """
    Delegate work to a specialized sub-agent. Each call runs a full sub-agent
    turn, so start independent subtasks in parallel instead of in sequence.

    ## Your sub-agents

    #{summaries}

    #{docs.sub_agent_reference}

    ## One-shot call

    #{docs.one_shot}

    ## Parallel fan-out

    Use `AgentTool.parallel/1` for independent subtasks - each `call` blocks on
    a full sub-agent run, so serial calls cost N turns; parallel costs about one.

    #{docs.parallel}

    ## Split spawning from post-processing across turns

    Prefer one turn to start sub-agents and save results. Use a separate turn
    to shape the results. A long script is brittle: one sandbox error discards
    the script and the sub-agent work must run again. Bindings persist across
    turns, so this does not add work.

    #{docs.split_turns}

    ## Sequential pipeline

    #{docs.pipeline}

    ## Long-lived sub-agent (multi-turn conversation)

    #{docs.long_lived}
    """
  end

  defp moduledoc_summary(module) do
    module.moduledoc()
    |> String.split("\n\n", parts: 2)
    |> hd()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  Starts a long-lived sub-agent process and dispatches `task` to it asynchronously
  via `cast/2`. Returns `{:ok, pid}` once the process is started — the task runs
  in the background and its result is not returned. Use `call/2` if you need the
  result, or `start_link/2` followed by additional `cast/2` calls to queue more
  messages on the same process.

  Raises if the agent is not in the allowed list.
  """
  def start_link(agent_module, task) when is_atom(agent_module) do
    check_allowed!(agent_module)

    with {:ok, pid} <- AgentServer.start_link(agent_module) do
      AgentServer.cast(pid, task)
      {:ok, pid}
    end
  end

  @doc """
  Sends a fire-and-forget message to a running agent pid.
  """
  def cast(pid, message) when is_pid(pid) do
    AgentServer.cast(pid, message)
  end

  @doc """
  Executes a one-off task on a module, or sends a synchronous message to a running agent pid.

  When called with a module, the sub-agent runs to completion and returns
  `{:ok, result}` or `{:cancel, reason}`. Raises if the agent is not in the allowed list.

  When called with a pid, sends a message to the running agent and blocks for the reply.
  """
  def call(agent_module, task) when is_atom(agent_module) do
    check_allowed!(agent_module)
    Legion.execute(agent_module, task)
  end

  def call(pid, message) when is_pid(pid) do
    AgentServer.call(pid, message)
  end

  @doc """
  Runs multiple sub-agent tasks in parallel and collects results.

  Returns `{:ok, [result1, result2, ...]}` when every task succeeds, or the
  first `{:cancel, reason}`. Raises if any agent is not in the allowed list.
  """
  def parallel(tasks, timeout \\ :infinity) when is_list(tasks) do
    tasks = Enum.map(tasks, &normalize_pair/1)
    for {agent, _task} <- tasks, do: check_allowed!(agent)
    Legion.parallel(tasks, timeout)
  end

  @doc """
  Runs sub-agent tasks sequentially, threading each result to the next step.

  Each step is `{agent, task_or_fn}`. If `task_or_fn` is a 1-arity function,
  it receives the previous step's result and must return the task for the
  next call. Halts early on the first `{:cancel, reason}`.
  """
  def pipeline(steps) when is_list(steps) do
    steps = Enum.map(steps, &normalize_pair/1)
    for {agent, _} <- steps, do: check_allowed!(agent)
    Legion.pipeline(steps)
  end

  # Lua has no tuples - code from the Lua sandbox sends each `{Agent, task}`
  # pair as a 2-element array, which the bridge decodes to a 2-element list.
  defp normalize_pair([agent, task]) when is_atom(agent), do: {agent, task}
  defp normalize_pair(pair), do: pair

  @doc """
  Chains a sub-agent call after a previous `{:ok, result}`. Passes
  `{:cancel, reason}` through unchanged.
  """
  def then(prev, agent, fun) when is_function(fun, 1) do
    check_allowed!(agent)
    Legion.then(prev, agent, fun)
  end

  defp description_docs(Legion.Sandbox.Lua) do
    %{
      sub_agent_reference: """
      Call them by their short name (last module segment). Each listed
      sub-agent is a global Lua table. Pass that table directly where a call
      needs an agent.
      """,
      one_shot: """
      `task` can be a string, table, or list. Lua tables become Elixir maps
      or lists:

          response = AgentTool.call(SomeAgent, {
            key = value,
            other_key = other_value
          })
          result = response[2]
          return result

      Returns:
        - `{"ok", result}` - `result` matches the sub-agent's `output_schema`
        - `{"cancel", reason}` - the sub-agent hit its iteration or retry cap
      """,
      parallel: """
          tasks = {}

          for index, input in ipairs(inputs) do
            tasks[index] = {SomeAgent, input}
          end

          response = AgentTool.parallel(tasks)
          picks = response[2]
          return picks

      Returns `{"ok", {result1, result2, ...}}` or `{"cancel", reason}`.
      """,
      split_turns: """
      Turn 1 - start and save:

          response = AgentTool.parallel({
            {SomeAgent, first_input},
            {SomeAgent, second_input}
          })
          results = response[2]
          return results

      Turn 2 - shape the saved `results`:

          titles = {}

          for index, result in ipairs(results) do
            titles[index] = result.title
          end

          return titles
      """,
      pipeline: """
      `AgentTool.pipeline/1` runs fixed tasks in order:

          response = AgentTool.pipeline({
            {ResearchAgent, "find X"},
            {WriterAgent, "write a summary"}
          })
          final = response[2]
          return final

      Lua cannot pass a function through the tool bridge. If a later task
      needs an earlier result, call agents in separate executions and build
      the next task from the saved result.
      """,
      long_lived: """
      Long-lived sub-agents are not available from Lua. `start_link/2`
      returns an Elixir pid, and pids cannot cross the Lua tool bridge. Use
      one-shot calls or parallel fan-out instead.
      """
    }
  end

  defp description_docs(_sandbox) do
    %{
      sub_agent_reference: """
      Call them by their short name (last module segment). Listed sub-agents
      are auto-aliased in the sandbox.
      """,
      one_shot: """
      `task` can be any Elixir term: string, map, keyword list, or struct:

          {:ok, result} =
            AgentTool.call(SomeAgent, %{
              key: value,
              other_key: other_value
            })

      Returns:
        - `{:ok, result}` - `result` matches the sub-agent's `output_schema`
        - `{:cancel, reason}` - the sub-agent hit its iteration or retry cap
      """,
      parallel: """
          {:ok, picks} =
            AgentTool.parallel(
              for input <- inputs do
                {SomeAgent, input}
              end
            )

      Returns `{:ok, [result1, result2, ...]}` or the first
      `{:cancel, reason}`.
      """,
      split_turns: """
      Turn 1 - start and save:

          {:ok, results} =
            AgentTool.parallel(
              for input <- inputs do
                {SomeAgent, input}
              end
            )

      Turn 2 - shape the saved `results`:

          Enum.map(results, fn result -> Map.fetch!(result, :title) end)
      """,
      pipeline: """
      `AgentTool.pipeline/1` threads each step result into the next step:

          {:ok, final} =
            AgentTool.pipeline([
              {ResearchAgent, "find X"},
              {WriterAgent, fn research -> "summarize: \#{research}" end}
            ])
      """,
      long_lived: """
      `call/2` and `parallel/1` run the sub-agent to completion and discard it.
      Use `start_link/2` when you need to keep talking to the same sub-agent
      across follow-up messages. It preserves the sub-agent conversation history.

      Use this only when later messages depend on earlier ones. For independent
      tasks, use one-shot `call/2` or parallel fan-out.

      Turn 1 - start and save the pid:

          {:ok, pid} =
            AgentTool.start_link(
              WriterAgent,
              "Draft a release note for v2."
            )

      Later turn - send a follow-up and wait for the reply:

          reply = AgentTool.call(pid, "Tighten the second paragraph.")

      Or send a message when you do not need the reply now:

          AgentTool.cast(pid, "Also drop the marketing line.")
      """
    }
  end

  defp check_allowed!(agent_module) do
    allowed = Vault.get(__MODULE__, [])[:agents] || []

    unless agent_module in allowed do
      raise ArgumentError,
            "agent #{inspect(agent_module)} is not allowed; allowed agents: #{inspect(allowed)}"
    end
  end
end
