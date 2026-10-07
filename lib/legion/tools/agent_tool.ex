defmodule Legion.Tools.AgentTool do
  @moduledoc """
  Built-in tool for delegating tasks to sub-agents.

  The calling agent must explicitly list allowed sub-agents via `tool_config/1`:

      def tool_config(Legion.Tools.AgentTool), do: [agents: [MyApp.WorkerAgent, MyApp.ResearchAgent]]

  Only listed agents can be invoked. Attempts to call unlisted agents raise an error.

  Left out when the agent is served over MCP; see `Legion.MCP.Server`.

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
    Delegate work to sub-agents. A sub-agent sees only the task you pass it,
    so make the task self-contained.

    ## Your sub-agents

    #{summaries}

    ## One-shot

    #{docs.one_shot}
    ## Parallel

    Each task is a full sub-agent run: N calls in sequence take N runs,
    `parallel` takes about one. Save the results in one execution and shape
    them in the next - an error discards the whole execution, sub-agent work
    included.

    #{docs.parallel}#{docs.pipeline}
    ## Long-lived sub-agent

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
      one_shot: """
      `task` is a string or a table:

          response = AgentTool.call(SomeAgent, "Summarize the Elixir 1.18 changelog")
          return response[2]

      Returns `{"ok", result}`, or `{"cancel", reason}` when the sub-agent
      could not finish.
      """,
      parallel: """
          results = AgentTool.parallel({
            {SomeAgent, first_input},
            {SomeAgent, second_input}
          })[2]
          return results

      Returns `{"ok", {result1, result2, ...}}` in task order, or the first
      `{"cancel", reason}`. Next execution:

          titles = {}
          for index, result in ipairs(results) do
            titles[index] = result.title
          end
          return titles
      """,
      pipeline: "",
      long_lived: """
      `call` with an agent and `parallel` discard the sub-agent when it
      finishes. `start_link` keeps it running, so later messages continue its
      conversation - use it only when they depend on earlier ones. It returns
      `{"ok", id}`: keep the id in a global and pass it to `call(id, message)`,
      which waits for the reply, or `cast(id, message)`, which discards the
      reply.

          writer = AgentTool.start_link(WriterAgent)[2]
          return AgentTool.call(writer, "Draft a release note for v2.")[2]

      A later execution continues the same conversation:

          AgentTool.cast(writer, "Also drop the marketing line.")
          return AgentTool.call(writer, "Tighten the second paragraph.")[2]
      """
    }
  end

  defp description_docs(_sandbox) do
    %{
      one_shot: """
      `task` is any term, such as a string or a map:

          {:ok, result} = AgentTool.call(SomeAgent, "Summarize the Elixir 1.18 changelog")

      Returns `{:ok, result}`, or `{:cancel, reason}` when the sub-agent could
      not finish.
      """,
      parallel: """
          {:ok, results} = AgentTool.parallel(for input <- inputs, do: {SomeAgent, input})

      Returns `{:ok, [result1, result2, ...]}` in task order, or the first
      `{:cancel, reason}`. Next execution:

          Enum.map(results, fn result -> result["title"] end)
      """,
      pipeline: """

      ## Pipeline

      `pipeline` runs steps in order and returns the last result, or the first
      cancel. A step's task is a string, or a function that builds it from the
      previous result:

          {:ok, final} =
            AgentTool.pipeline([
              {ResearchAgent, "find X"},
              {WriterAgent, fn research -> "summarize: \#{inspect(research)}" end}
            ])
      """,
      long_lived: """
      `call` with an agent and `parallel` discard the sub-agent when it
      finishes. `start_link` keeps it running, so later messages continue its
      conversation - use it only when they depend on earlier ones. It returns
      `{:ok, id}`: keep the id in a variable and pass it to `call(id, message)`,
      which waits for the reply, or `cast(id, message)`, which discards the
      reply.

          {:ok, writer} = AgentTool.start_link(WriterAgent)
          {:ok, draft} = AgentTool.call(writer, "Draft a release note for v2.")

      A later execution continues the same conversation:

          AgentTool.cast(writer, "Also drop the marketing line.")
          {:ok, revised} = AgentTool.call(writer, "Tighten the second paragraph.")
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

  # A separate watcher: a link ignores the owner's :normal stop, and a
  # monitor in the sub-agent would only fire after its current turn.
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
