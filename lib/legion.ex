defmodule Legion do
  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC -->")
             |> Enum.fetch!(1)

  use Supervisor

  alias Legion.{AgentIndex, AgentServer}
  alias Legion.Store.Payload

  @doc """
  Starts Legion's supervisor.

  Add it to your application's supervision tree after dependencies required by
  its configured recovery stores. For a Repo-backed store, place it after your
  Repo.

  ## Examples

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            MyApp.Repo,
            Legion
          ]

          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end
      end
  """
  def start_link(opts) when is_list(opts) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Legion.Recovery, Application.fetch_env(:legion, :recovery)},
      {DynamicSupervisor, name: Legion.AgentSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one, name: Legion.Supervisor)
  end

  @doc """
  Runs an agent on a single task and returns the result.

  Starts a temporary agent process, blocks until the task completes, then stops it.
  Accepts the same `opts` as `start_link/2`, so a one-off run can resume and
  persist a conversation by passing `:store` and `:agent_id`. Passing `:store`
  overrides the globally configured store for this agent; see `Legion.Store`.

  When a live process already owns the given `:agent_id`, the task is sent to
  that process instead and it is left running afterwards.

  ## Examples

      {:ok, summary} = Legion.execute(ResearchAgent, "Summarize the Elixir getting started guide")
      {:cancel, :reached_max_iterations} = Legion.execute(ResearchAgent, "impossible task")
      {:ok, reply} = Legion.execute(ChatAgent, "next question", store: MyApp.AgentStore, agent_id: "user_42:chat_7")
  """
  def execute(agent_module, task, opts \\ []) do
    case AgentServer.start_link(agent_module, opts) do
      {:ok, pid} ->
        result = AgentServer.call(pid, task)
        GenServer.stop(pid)
        result

      {:error, {:already_started, pid}} ->
        AgentServer.call(pid, task)

      {:error, reason} ->
        raise "could not start #{inspect(agent_module)}: #{inspect(reason)}"
    end
  end

  @doc """
  Starts a long-lived agent process.

  ## Options
    - `:store`, `:agent_id` - persist the conversation across restarts; see `Legion.Store`.
      When supplied, `:agent_id` must be a valid UTF-8 string.
      A store set globally with `config :legion, :store, MyApp.AgentStore` applies to
      every agent, so you need only pass `:agent_id`. If a store is in effect but no
      `:agent_id` is given, Legion generates one - read it back with `get_agent_id/1`.
      An agent ID can belong to at most one live process across connected nodes.
    - `:rate_limit` - a keyword list with `:limiter` and `:rules`, a list of
      `Legion.RateLimiter.Rule`s pairing an identity (for example,
      `%{"ip" => "203.0.113.42"}`) with a policy, checked for every turn by a
      `Legion.RateLimiter`. The limiter and a default policy can be set
      globally; rules are given here. Rules without a limiter raise, and a
      limiter without rules runs the agent without rate limiting and logs a
      warning unless `rules: []` opts out on purpose. A denied turn returns
      `{:cancel, {:rate_limited, violations}}`; see `Legion.RateLimiter`.
    - `:vault` - a keyword list put in the agent process's `Vault`, where its
      tools and sandbox read it with `Vault.get/1`. The way to hand an agent
      something request-specific, a current user say, when it is not started
      from the process that holds it.
    - `:idle_timeout` - milliseconds without a call after which the agent stops
      normally. With a store, its state is on record and a later start under
      the same `:agent_id` continues it (default: `:infinity`).
    - Any config overrides (`:model`, `:max_iterations`, etc.)

  ## Examples

      {:ok, pid} = Legion.start_link(AssistantAgent)
      {:ok, pid} = Legion.start_link(ChatAgent, store: MyApp.AgentStore, agent_id: "user_42:chat_7")
      {:ok, pid} = Legion.start_link(ChatAgent, agent_id: "user_42:chat_7")   # store from app config

      {:ok, pid} =
        Legion.start_link(ChatAgent,
          rate_limit: [
            limiter: MyApp.RateLimiter,
            rules: [
              %Legion.RateLimiter.Rule{
                identity: %{"ip" => "203.0.113.42"},
                policy: %Legion.RateLimiter.Policy{
                  window_ms: :timer.minutes(1),
                  max_agents: 10,
                  max_tokens: 100_000
                }
              }
            ]
          ]
        )
  """
  def start_link(agent_module, opts \\ []) when is_atom(agent_module) do
    AgentServer.start_link(agent_module, opts)
  end

  @doc """
  Sends a message to a running agent and waits for the result.

  ## Examples

      {:ok, pid} = Legion.start_link(AssistantAgent)
      {:ok, answer} = Legion.call(pid, "What is the capital of France?")
      {:ok, follow_up} = Legion.call(pid, "And its population?")
  """
  def call(pid, message, timeout \\ :infinity) do
    AgentServer.call(pid, message, timeout)
  end

  @doc """
  Runs `code` in a running agent's sandbox and returns what the agent's model
  would read: the result, or the error.

  This is the agent without its model. Nothing is sent to an LLM: the code is
  taken as the agent's own step and evaluated with its tools, sandbox limits,
  eval guard and variables, then appended to the conversation and persisted
  like a turn. It is what `Legion.MCP.Server` runs for a host's model, and what a
  console or a test can use to drive an agent by hand. Variables persist
  between calls unless `:binding_scope` is `:iteration`.

  Returns `{:ok, text}` with the formatted result, `{:error, text}` when the
  code failed to check, was refused or raised, or when the step could not be
  saved to the store after it ran, and `{:cancel, {:rate_limited, violations}}`
  when a rate limit denied the call before it ran.

  ## Options

    - `:vault` - a keyword list put in the agent process's `Vault` before the
      code runs, for tools to read; the per-call form of the `:vault` option
      of `start_link/2`
    - `:timeout` - how long to wait for the call (default: `:infinity`)

  ## Examples

      {:ok, pid} = Legion.start_link(MathAgent)
      {:ok, text} = Legion.eval(pid, "x = MathTool.add(1, 2)")
      {:ok, text} = Legion.eval(pid, "return x * 2")
      {:error, text} = Legion.eval(pid, "return (")
      {:ok, text} = Legion.eval(pid, "return Reports.mine()", vault: [current_user: user])
  """
  def eval(pid, code, opts \\ []) when is_binary(code) and is_list(opts) do
    AgentServer.eval(pid, code, opts)
  end

  @doc """
  Sends a message to a running agent without waiting for a result.

  ## Examples

      {:ok, pid} = Legion.start_link(ReportAgent)
      Legion.cast(pid, "Generate the weekly report and email it")
  """
  def cast(pid, message) do
    AgentServer.cast(pid, message)
  end

  @doc """
  Returns the conversation history from a running agent.

  ## Examples

      {:ok, pid} = Legion.start_link(AssistantAgent)
      {:ok, _} = Legion.call(pid, "Hello")
      messages = Legion.get_messages(pid)
  """
  def get_messages(pid) do
    AgentServer.get_messages(pid)
  end

  @doc """
  Returns the valid UTF-8 string id of a running agent. Always set - Legion
  generates one when none is passed.

  When a store is configured but you let Legion generate the id, capture it
  with this to resume the same conversation on a later start.

  ## Examples

      {:ok, pid} = Legion.start_link(ChatAgent)
      agent_id = Legion.get_agent_id(pid)
  """
  def get_agent_id(pid) do
    AgentServer.get_agent_id(pid)
  end

  @doc """
  Whether `pid` - typically one returned by `lookup/1` or recorded in persisted
  run metadata - is alive. Accepts `nil` and returns `false`.

  Checks local processes directly and processes on connected nodes through RPC.
  An unreachable remote node returns `false`.

  A stored pid can outlive the VM that wrote it, so after a restart this remains
  best-effort: a recycled pid value can collide with an unrelated live process.

  ## Examples

      case Legion.lookup("user_42:chat_7") do
        {:ok, pid} -> Legion.running?(pid)
        :error -> false
      end
  """
  def running?(pid) when is_pid(pid) do
    if node(pid) == node() do
      Process.alive?(pid)
    else
      :rpc.call(node(pid), :erlang, :is_process_alive, [pid]) == true
    end
  rescue
    ArgumentError -> false
  end

  def running?(_other), do: false

  @doc """
  Looks up the live process for an agent id.

  `agent_id` must be a valid UTF-8 string. Raises `ArgumentError` otherwise.

  Uses Legion's cluster-wide runtime index as the source of truth for the
  `agent_id -> pid` mapping. Returns `{:ok, pid}` when the agent is currently
  registered on any connected node, or `:error` when no live process owns
  `agent_id`.

  ## Examples

      {:ok, pid} = Legion.lookup("user_42:chat_7")
      :error = Legion.lookup("missing_agent_id")
  """
  def lookup(agent_id) do
    if not is_binary(agent_id) or not String.valid?(agent_id) do
      raise ArgumentError, ":agent_id must be a valid UTF-8 string, got: #{inspect(agent_id)}"
    end

    case AgentIndex.lookup(agent_id) do
      {:ok, pid} -> {:ok, pid}
      _ -> :error
    end
  end

  @doc """
  Resumes a persisted conversation.

  `agent_id` must be a valid UTF-8 string. Raises `ArgumentError` otherwise.

  Loads the persisted conversation with the store's `c:Legion.Store.get/1` to
  determine its agent module,
  then atomically starts it under the same `agent_id`. If a live process already
  owns that ID, returns the existing pid instead. A new process restores the
  conversation and continues execution in the background. It resumes from a
  saved checkpoint when one exists; otherwise it starts a new executor loop
  with the restored history.

  `opts` are passed through to `start_link/2`. Rate-limit rules are not
  persisted, so the resumed agent is checked on its later turns only when
  `:rate_limit` is passed here again; otherwise it runs without rate limiting.

  Pass `:store` or configure one globally. Returns:

    - `{:ok, pid}` when a new process starts or one already owns `agent_id`
    - `{:error, :not_resumable}` when the store has no payload containing an
      agent module for `agent_id`
    - `{:error, reason}` when the process cannot start

  Raises when no store is available.

  ## Examples

      {:ok, pid} = Legion.resume("user_42:chat_7")
      {:ok, pid} = Legion.resume("user_42:chat_7", store: MyApp.AgentStore)

      {:error, :not_resumable} =
        Legion.resume("missing_chat", store: MyApp.AgentStore)
  """
  def resume(agent_id, opts \\ []) do
    if not is_binary(agent_id) or not String.valid?(agent_id) do
      raise ArgumentError, ":agent_id must be a valid UTF-8 string, got: #{inspect(agent_id)}"
    end

    store = store!(opts, :resume)

    case store.get(agent_id) do
      {:ok, %Payload{agent_module: agent_module}} when not is_nil(agent_module) ->
        case AgentServer.start_link(
               agent_module,
               Keyword.merge(opts, agent_id: agent_id, store: store, start_mode: :resume)
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :not_resumable}
    end
  end

  @doc """
  Recovers an interrupted persisted run and waits for it to finish.

  `agent_id` must be a valid UTF-8 string. Raises `ArgumentError` otherwise.

  An interrupted run is signaled by a stored payload with `status: :running`. In addition
  only runs without `parent_agent_id` are recoverable, since sub-agents are not restarted. Unlike
  `resume/2`, a live agent is not returned.

  The agent is only driven to completion, the executor result is not returned. `:ok` means
  only that the temporary agent process stopped normally.

  Pass `:store` or configure one globally. Other options are passed through to
  `start_link/2`. Rate-limit rules are not persisted and the recovered run only
  finishes the interrupted turn before stopping, so it is never rate-limited
  and `:rate_limit` defaults to `[rules: []]`. Returns:

    - `:ok` when the temporary process stops normally
    - `{:error, reason}` when the temporary process stops abnormally
    - `{:error, :already_running}` when a recoverable run already has a live process
    - `{:error, :not_recoverable}` when there is no stored payload with an agent
      module, or when the stored payload is not an interrupted run

  Raises when no store is available.

  ## Examples

      :ok = Legion.recover("user_42:chat_7", store: MyApp.AgentStore)

      {:error, :already_running} =
        Legion.recover("active_chat", store: MyApp.AgentStore)

      {:error, :not_recoverable} =
        Legion.recover("completed_chat", store: MyApp.AgentStore)
  """
  def recover(agent_id, opts \\ []) do
    if not is_binary(agent_id) or not String.valid?(agent_id) do
      raise ArgumentError, ":agent_id must be a valid UTF-8 string, got: #{inspect(agent_id)}"
    end

    store = store!(opts, :recover)

    case store.get(agent_id) do
      {:ok, %Payload{agent_module: agent_module, status: :running, parent_agent_id: nil}}
      when not is_nil(agent_module) ->
        # The recovered turn is never checked, so opt out of rate limiting to
        # keep a globally configured limiter from warning once per recovery.
        opts =
          opts
          |> Keyword.put_new(:rate_limit, rules: [])
          |> Keyword.merge(agent_id: agent_id, store: store, start_mode: :recover)

        case AgentServer.start_monitor(agent_module, opts) do
          {:ok, {pid, ref}} ->
            receive do
              {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
              {:DOWN, ^ref, :process, ^pid, reason} -> {:error, reason}
            end

          {:error, {:already_started, _pid}} ->
            {:error, :already_running}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :not_recoverable}
    end
  end

  defp store!(opts, operation) do
    Keyword.get(opts, :store) || Vault.get(:store) || Application.get_env(:legion, :store) ||
      raise ArgumentError,
            "#{operation}/2 requires a :store - pass one or set `config :legion, :store, MyStore`"
  end

  @doc """
  Runs multiple agent tasks concurrently and collects results.

  Returns `{:ok, results}` if all succeed, or the first `{:cancel, reason}`.

  ## Examples

      # Run two agents in parallel
      {:ok, [research, analysis]} =
        Legion.parallel([
          {ResearchAgent, "Find recent Elixir blog posts"},
          {AnalysisAgent, "Summarize market trends"}
        ])

      # With a timeout (in milliseconds)
      {:ok, results} =
        Legion.parallel(
          [{FastAgent, "task 1"}, {FastAgent, "task 2"}],
          30_000
        )
  """
  def parallel(tasks, timeout \\ :infinity) when is_list(tasks) do
    tasks
    |> Enum.map(fn {agent, task} -> Task.async(fn -> execute(agent, task) end) end)
    |> Task.await_many(timeout)
    |> collect_results()
  end

  @doc """
  Runs agent tasks sequentially, threading each result to the next step.

  Each step is `{agent, task}` where `task` is a string or a function
  that receives the previous result and returns a task string.

  Halts early if any step returns `{:cancel, reason}`.

  ## Examples

      # Static tasks — each runs independently
      {:ok, final} =
        Legion.pipeline([
          {ResearchAgent, "Find info about Elixir OTP"},
          {WriterAgent, "Write a blog post about OTP"}
        ])

      # Thread results — each step receives the previous result
      {:ok, post} =
        Legion.pipeline([
          {ResearchAgent, "Find recent Elixir news"},
          {WriterAgent, fn research -> "Write a summary based on: \#{research}" end},
          {EditorAgent, fn draft -> "Polish this draft: \#{draft}" end}
        ])
  """
  def pipeline(steps) when is_list(steps) do
    Enum.reduce_while(steps, {:ok, nil}, fn
      {agent, task}, _acc when is_binary(task) ->
        continue_or_halt(execute(agent, task))

      {agent, fun}, {:ok, prev} when is_function(fun, 1) ->
        continue_or_halt(execute(agent, fun.(prev)))

      {_agent, task}, _acc ->
        raise ArgumentError,
              "expected task to be a binary or a function/1, got: #{inspect(task)}"
    end)
  end

  @doc """
  Chains an agent task after a previous result.

  Useful for piping from `parallel/2` or `pipeline/1`.

  ## Examples

      # Chain after parallel
      Legion.parallel([
        {ResearchAgent, "Find Elixir news"},
        {ResearchAgent, "Find Erlang news"}
      ])
      |> Legion.then(WriterAgent, fn results ->
        "Summarize these findings: \#{inspect(results)}"
      end)

      # Passes through cancellations
      {:cancel, reason} |> Legion.then(WriterAgent, fn _ -> "ignored" end)
      #=> {:cancel, reason}
  """
  def then({:ok, result}, agent, fun) when is_function(fun, 1) do
    execute(agent, fun.(result))
  end

  def then({:cancel, _} = cancelled, _agent, _fun), do: cancelled

  defp continue_or_halt({:ok, _} = ok), do: {:cont, ok}
  defp continue_or_halt({:cancel, _} = cancel), do: {:halt, cancel}

  defp collect_results(results) do
    case Enum.find(results, &match?({:cancel, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, v} -> v end)}
      cancel -> cancel
    end
  end
end
