defmodule Legion.Tools.AgentTool do
  @moduledoc """
  Built-in tool for delegating tasks to sub-agents.

  The calling agent must explicitly list allowed sub-agents via `tool_config/1`:

      def tool_config(Legion.Tools.AgentTool), do: [agents: [MyApp.WorkerAgent, MyApp.ResearchAgent]]
      def tool_config(_), do: []

  Only listed agents can be invoked. Attempts to call unlisted agents raise an error.

  An agent that lists this tool cannot be served over MCP; see `Legion.MCP.Server`.

  `call/2` with an agent module runs one task, `start_link/1` returns a
  sub-agent id that `call/2` and `cast/2` take to hold a conversation, and
  `parallel/2`, `pipeline/1` and `then/3` compose tasks.

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
    Delegate work to a specialized sub-agent. `call` with an agent runs one
    task, `start_link` returns a sub-agent id that `call` and `cast` take to
    hold a conversation, and `parallel` and `pipeline` compose tasks. Each
    task runs a full sub-agent turn, so start independent subtasks in
    parallel instead of in sequence.

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
  Starts a sub-agent that keeps its conversation across messages, like
  `Legion.start_link/2`. Returns `{:ok, agent_id}`: pass the id to `call/2`
  and `cast/2`. Unlike a pid, it crosses the Lua bridge and persists in
  bindings.

  Only the agent that started the sub-agent reaches it by its id, and the
  sub-agent stops when that agent stops. Raises if the agent is not in the
  allowed list.
  """
  def start_link(agent_module) do
    check_allowed!(agent_module)
    owner_id = Vault.fetch!(:agent_id)
    {:ok, owner} = Legion.lookup(owner_id)
    {:ok, pid} = AgentServer.start_link(agent_module)
    agent_id = AgentServer.get_agent_id(pid)

    :yes = :global.register_name(owned_name(owner_id, agent_id), stop_with_owner(pid, owner))
    {:ok, agent_id}
  end

  @doc """
  Starts a sub-agent like `start_link/1` and casts `task` to it.
  """
  def start_link(agent_module, task) do
    {:ok, agent_id} = start_link(agent_module)
    cast(agent_id, task)
    {:ok, agent_id}
  end

  @doc """
  Runs a task on an agent module, or sends a message to a sub-agent id from
  `start_link/1`, and waits for the reply. Returns `{:ok, result}` or
  `{:cancel, reason}`.

  With a module, the sub-agent runs to completion and is discarded, like
  `Legion.execute/2`; raises if the agent is not in the allowed list. With an
  id, the sub-agent continues its conversation, like `Legion.call/3`; raises
  if this agent has no running sub-agent with that id.
  """
  def call(agent_module, task) when is_atom(agent_module) do
    check_allowed!(agent_module)
    Legion.execute(agent_module, task)
  end

  def call(agent_id, message), do: agent_id |> owned!() |> AgentServer.call(message)

  @doc """
  Sends `message` to a sub-agent from `start_link/1` without waiting for the
  reply, like `Legion.cast/2`.

  Raises if this agent has no running sub-agent with that id.
  """
  def cast(agent_id, message), do: agent_id |> owned!() |> AgentServer.cast(message)

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
      needs an earlier result, run agents in separate executions and build
      the next task from the saved result.
      """,
      long_lived: """
      `call` with an agent and `parallel` run a sub-agent to completion and
      discard it. `start_link` keeps one running, so later messages continue
      its conversation - use it only when they depend on earlier ones. It
      returns the sub-agent's id: keep it in a global and pass it to `call`,
      which waits for the reply, or `cast`, which does not. Only you can reach your
      sub-agents, and they stop when you do.

          writer = AgentTool.start_link(WriterAgent)[2]
          draft = AgentTool.call(writer, "Draft a release note for v2.")[2]
          return draft

      In a later execution, `writer` still remembers the draft:

          AgentTool.cast(writer, "Also drop the marketing line.")
          return AgentTool.call(writer, "Tighten the second paragraph.")[2]

      `call` returns `{"ok", reply}` or `{"cancel", reason}`.
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
      `call/2` with an agent and `parallel/1` run a sub-agent to completion
      and discard it. `start_link/1` keeps one running, so later messages
      continue its conversation - use it only when they depend on earlier
      ones. It returns the sub-agent's id: keep it in a variable and pass it
      to `call/2`, which waits for the reply, or `cast/2`, which does not. Only you can reach
      your sub-agents, and they stop when you do.

          {:ok, writer} = AgentTool.start_link(WriterAgent)
          {:ok, draft} = AgentTool.call(writer, "Draft a release note for v2.")

      In a later execution, `writer` still remembers the draft:

          AgentTool.cast(writer, "Also drop the marketing line.")
          {:ok, revised} = AgentTool.call(writer, "Tighten the second paragraph.")

      `call/2` returns `{:ok, reply}` or `{:cancel, reason}`.
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

  # Keyed by the owner's id, so an agent reaches only the sub-agents it
  # started: a forged or foreign id resolves to nothing. The watcher holds the
  # name, since `:global` gives a pid one name and the sub-agent's is its
  # agent id; the watcher lives exactly as long as the sub-agent.
  defp owned_name(owner_id, agent_id), do: {:legion_sub_agent, owner_id, agent_id}

  # Anything that is not one of this agent's running sub-agents lands here:
  # a stale id or a forged one.
  defp owned!(agent_id) do
    with watcher when is_pid(watcher) <-
           :global.whereis_name(owned_name(Vault.fetch!(:agent_id), agent_id)),
         {:ok, pid} <- Legion.lookup(agent_id) do
      pid
    else
      _not_running ->
        raise ArgumentError,
              "#{inspect(agent_id)} is not a running sub-agent of this agent - it stopped, " <>
                "or another agent started it. Start one with start_link/1, " <>
                "or run a one-off task by calling an agent module"
    end
  end

  # Not a link: links ignore :normal exits, and that is how GenServer.stop and
  # :idle_timeout stop the owner. Not a monitor inside the sub-agent: it would
  # see the owner go only after its own turn, spending tokens meanwhile.
  # Returns the watcher.
  defp stop_with_owner(pid, owner) do
    spawn(fn ->
      owner_ref = Process.monitor(owner)
      sub_agent_ref = Process.monitor(pid)

      receive do
        {:DOWN, ^owner_ref, :process, _pid, _reason} -> Process.exit(pid, :shutdown)
        {:DOWN, ^sub_agent_ref, :process, _pid, _reason} -> :ok
      end
    end)
  end
end
