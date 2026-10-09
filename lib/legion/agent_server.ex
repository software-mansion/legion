defmodule Legion.AgentServer do
  @moduledoc """
  GenServer that maintains conversation history for a long-lived agent.

  Holds the message history across multiple turns. Each `call` or `cast`
  appends the user message and runs `Executor` to completion (blocking).

  When Legion starts an agent in resume or recovery mode, the server restores
  the persisted conversation and executor checkpoint, then continues it during
  startup. Recovery stops the temporary process after that execution finishes.
  """

  use GenServer

  require Logger

  alias Legion.{Eval, Executor, Store, Telemetry}
  alias Legion.RateLimiter
  alias Legion.RateLimiter.ExceededError
  alias Legion.RateLimiter.Policy
  alias Legion.Store.Payload
  alias Legion.Tools.AgentTool
  alias ReqLLM.Message.ContentPart

  @legion_vault_keys ~w(agent_id parent_agent_id agent_module sandbox store rate_limit sub_agents)a

  defstruct [
    :agent_module,
    :messages,
    :config,
    :store,
    :agent_id,
    :persistence_frequency,
    :track_usage,
    usage: nil,
    executor_state: :nonexistent,
    bindings: [],
    # Under `:turn` scope, what a resumed turn goes back to when it ends: the
    # bindings `Legion.eval/3` made outside any turn, as its checkpoint saved them.
    base_bindings: [],
    idle_timer: nil
  ]

  # Client API

  def start_link(agent_module, opts \\ []) do
    {init_arg, gen_opts} = start_args(agent_module, opts)

    GenServer.start_link(__MODULE__, init_arg, gen_opts)
  end

  @doc false
  def start_monitor(agent_module, opts \\ []) do
    {init_arg, gen_opts} = start_args(agent_module, opts)
    {name, gen_opts} = Keyword.pop!(gen_opts, :name)

    :gen_server.start_monitor(name, __MODULE__, init_arg, gen_opts)
  end

  defp start_args(agent_module, opts) do
    {store, opts} = Keyword.pop(opts, :store)
    {rate_limit_opts, opts} = Keyword.pop(opts, :rate_limit)
    {agent_id, opts} = Keyword.pop(opts, :agent_id)
    {vault, opts} = Keyword.pop(opts, :vault, [])

    store = store || Vault.get(:store) || Application.get_env(:legion, :store)

    if is_nil(store) and not is_nil(agent_id) do
      raise ArgumentError,
            ":agent_id requires a :store - pass one or set `config :legion, :store, MyStore`"
    end

    agent_id =
      cond do
        is_nil(agent_id) ->
          generate_id()

        is_binary(agent_id) and String.valid?(agent_id) ->
          agent_id

        true ->
          raise ArgumentError, ":agent_id must be a valid UTF-8 string, got: #{inspect(agent_id)}"
      end

    persistence_frequency = Store.persistence_frequency(store)
    track_usage = Application.get_env(:legion, :track_usage, true)

    rate_limit = RateLimiter.resolve!(rate_limit_opts)
    check_store!(rate_limit, store, track_usage)
    gen_opts = [name: Legion.AgentIndex.name(agent_id)]
    config = Legion.Agent.resolve_config(agent_module, opts)
    Legion.Agent.warn_unknown_keys(config)
    config = Map.put(config, :rate_limit, rate_limit)

    {{agent_module, config, store, agent_id, persistence_frequency, track_usage, vault}, gen_opts}
  end

  defp check_store!(%{limiter: limiter, rules: rules}, store, track_usage)
       when not is_nil(limiter) and rules != [] do
    if Code.ensure_loaded?(limiter) and function_exported?(limiter, :check_store!, 3),
      do: limiter.check_store!(store, track_usage, rules)
  end

  defp check_store!(_rate_limit, _store, _track_usage), do: :ok

  def call(agent, message, timeout \\ :infinity) do
    GenServer.call(agent, {:message, message}, timeout)
  end

  def cast(agent, message) do
    GenServer.cast(agent, {:message, message})
  end

  @doc false
  # Runs `code` written by an outside model (an MCP host) as one step of this
  # conversation - rate-limited and persisted like a turn, with no LLM request.
  # Returns `{:ok, text}`, `{:error, text}` or `{:cancel, {:rate_limited, violations}}`.
  def eval(agent, code, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, :infinity)
    GenServer.call(agent, {:eval, code, opts}, timeout)
  end

  def get_messages(agent) do
    GenServer.call(agent, :get_messages)
  end

  def get_agent_id(agent) do
    GenServer.call(agent, :get_agent_id)
  end

  # Server callbacks

  @impl true
  def init({agent_module, config, store, agent_id, _frequency, _track_usage, _vault} = init_arg) do
    stored = store && store.get(agent_id)

    case stored do
      {:ok, %Payload{agent_module: stored_module}}
      when not is_nil(stored_module) and stored_module != agent_module ->
        {:error, {:agent_module_mismatch, stored_module}}

      _stored ->
        case enforce_start(%{agent_module: agent_module, agent_id: agent_id, config: config}) do
          :ok -> start(init_arg, stored)
          {:rate_limited, violations} -> {:error, {:rate_limited, violations}}
        end
    end
  end

  # A start is checked against `:max_agents` only, so it counts the agent from
  # its start. Every turn checks the other limits anyway, and a supervisor
  # restarts a crashed agent through this same start: denying it on spent
  # tokens would fail every restart until the supervisor gives up and takes
  # its other agents down. The restarted agent's id is already counted, so
  # `:max_agents` lets it through. Resumed and recovered runs finish work that
  # was already allowed, so they are not checked again.
  defp enforce_start(%{config: config} = state) do
    case Map.get(config, :start_mode, :normal) do
      :normal ->
        case agent_limit_only(config.rate_limit.rules) do
          [] -> :ok
          rules -> enforce_rate_limit(put_in(state.config.rate_limit.rules, rules))
        end

      _resume_or_recover ->
        :ok
    end
  end

  defp agent_limit_only(rules) do
    for %{policy: %Policy{max_agents: max_agents} = policy} = rule <- List.wrap(rules),
        not is_nil(max_agents),
        do: %{rule | policy: %Policy{window_ms: policy.window_ms, max_agents: max_agents}}
  end

  defp start(
         {agent_module, config, store, agent_id, persistence_frequency, track_usage, vault},
         stored
       ) do
    parent_agent_id = Vault.get(:agent_id)
    mode = Map.get(config, :start_mode, :normal)

    for {key, value} <- vault, do: Vault.unsafe_put(key, value)
    Vault.unsafe_put(:agent_id, agent_id)
    Vault.unsafe_put(:parent_agent_id, parent_agent_id)
    Vault.unsafe_put(:agent_module, agent_module)
    Vault.unsafe_put(:sandbox, config.sandbox)
    if store, do: Vault.unsafe_put(:store, store)

    Legion.Agent.seed_tool_configs(agent_module)
    Vault.unsafe_put(:rate_limit, config.rate_limit)

    Vault.unsafe_put(:sub_agents, %{
      max: config.max_sub_agents,
      idle_timeout: config.sub_agent_idle_timeout
    })

    system_prompt = Legion.AgentPrompt.system_prompt(agent_module, config)

    Telemetry.emit(
      [:legion, :agent, :started],
      %{system_time: NaiveDateTime.utc_now()},
      %{agent: agent_module}
    )

    {saved_messages, saved_bindings, saved_base, saved_executor_state, saved_usage} =
      case stored do
        {:ok,
         %Payload{
           conversation_state:
             %{
               messages: messages,
               bindings: bindings,
               executor_state: executor_state
             } = conversation_state,
           usage: usage
         }} ->
          {messages, bindings, Map.get(conversation_state, :base_bindings, []), executor_state,
           if(track_usage, do: usage || [], else: nil)}

        _no_state ->
          {[], [], [], :nonexistent, if(track_usage, do: [], else: nil)}
      end

    saved_bindings =
      restored_bindings(saved_bindings, saved_base, mode, saved_executor_state, config)

    state = %__MODULE__{
      agent_module: agent_module,
      messages: [Executor.message(:system, system_prompt) | saved_messages],
      config: config,
      store: store,
      agent_id: agent_id,
      persistence_frequency: persistence_frequency,
      bindings: saved_bindings,
      base_bindings: saved_base,
      executor_state: saved_executor_state,
      track_usage: track_usage,
      usage: saved_usage
    }

    {:ok,
     persist(state,
       agent_module: state.agent_module,
       parent_agent_id: parent_agent_id,
       started_at: NaiveDateTime.utc_now(),
       usage: state.usage
     ), {:continue, %{start_mode: mode, executor_state: saved_executor_state}}}
  end

  # A normal start over a checkpoint abandons that turn, so it keeps what the
  # turn would have gone back to. A resume or recovery finishes the turn, with
  # the bindings its checkpoint saved.
  defp restored_bindings(bindings, base, :normal, executor_state, config)
       when executor_state != :nonexistent do
    case Map.get(config, :binding_scope, :turn) do
      :conversation -> bindings
      :turn -> base
      :iteration -> []
    end
  end

  defp restored_bindings(bindings, _base, _mode, _executor_state, _config), do: bindings

  @impl true
  def handle_continue(%{start_mode: :normal}, state), do: {:noreply, reset_idle(state)}

  @impl true
  def handle_continue(%{start_mode: :resume, executor_state: executor_state}, state) do
    if unfinished_turn?(%{messages: state.messages, executor_state: executor_state}) do
      {_reply, state} = do_run(state, executor_state)
      {:noreply, reset_idle(state)}
    else
      {:noreply, reset_idle(state)}
    end
  end

  @impl true
  def handle_continue(%{start_mode: :recover, executor_state: executor_state}, state) do
    {_reply, state} = do_run(state, executor_state)
    {:stop, :normal, state}
  end

  @doc false
  # Whether a conversation state stopped mid-turn: behind a checkpoint, or on
  # a prompt with nothing after it. Resume and recovery finish only such a
  # turn. A `Legion.eval/3` step, an MCP call, leaves neither, and finishing
  # it would run the agent's own model over a conversation an outside model
  # drives; nor does a turn that ended on its eval result.
  def unfinished_turn?(%{executor_state: executor_state}) when executor_state != :nonexistent,
    do: true

  def unfinished_turn?(%{messages: messages}), do: match?(%{type: :user}, List.last(messages))
  def unfinished_turn?(_conversation_state), do: false

  @impl true
  def terminate(_reason, state) do
    Telemetry.emit(
      [:legion, :agent, :stopped],
      %{system_time: NaiveDateTime.utc_now()},
      %{agent: state.agent_module}
    )
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, reset_idle(state)}
  end

  @impl true
  def handle_call(:get_agent_id, _from, state) do
    {:reply, state.agent_id, reset_idle(state)}
  end

  @impl true
  def handle_call({:message, message}, _from, state) do
    {reply, state} = handle_message(message, state)
    {:reply, reply, reset_idle(state)}
  end

  # A call waits while the agent is busy. One whose caller gave up and died
  # meanwhile, as an MCP request does when it times out, is skipped: run now,
  # it would act for nobody, and the caller's retry would run it again.
  @impl true
  def handle_call({:eval, code, opts}, {caller, _tag}, state) do
    if node(caller) == node() and not Process.alive?(caller) do
      {:noreply, reset_idle(state)}
    else
      {reply, state} = handle_eval(code, opts, state)
      {:reply, reply, reset_idle(state)}
    end
  end

  @impl true
  def handle_cast({:message, message}, state) do
    {_reply, state} = handle_message(message, state)
    {:noreply, reset_idle(state)}
  end

  # A tag no longer in the state is a timer a later call replaced.
  @impl true
  def handle_info({:idle_timeout, tag}, %{idle_timer: {tag, _timer}} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  # A tagged timer rather than a GenServer timeout: that one is reset by any
  # message, not only calls, and fired by a plain `:timeout` from anyone.
  defp reset_idle(state) do
    case Map.get(state.config, :idle_timeout, :infinity) do
      :infinity ->
        state

      milliseconds ->
        if state.idle_timer, do: Process.cancel_timer(elem(state.idle_timer, 1))
        tag = make_ref()
        timer = Process.send_after(self(), {:idle_timeout, tag}, milliseconds)
        %{state | idle_timer: {tag, timer}}
    end
  end

  @doc """
  Normalizes `message`, appends it to the conversation, and runs the executor
  to completion. Returns `{{status, value}, new_state}`.

  Accepted `message` shapes:
    - `binary` - passed verbatim as the user message
    - `{:image, data, media_type}` - single inline image from binary data
    - `{:image_url, url}` - single image from a URL
    - `{:multipart, [ContentPart.t()]}` - mixed text/image/file content; build
      parts with `ReqLLM.Message.ContentPart.text/1`, `image/2`, `image_url/1`,
      `file/3`
    - anything else - rendered via `inspect/2`
  """
  def handle_message(message, state) do
    case enforce_rate_limit(state) do
      :ok ->
        content = stringify(message, state.config[:max_message_length])

        # Persist the user message before the turn runs so store-backed views
        # (e.g. the legion_web database source) show it without waiting for the
        # response.
        state =
          state
          |> Map.update!(:messages, &(&1 ++ [Executor.message(:user, content)]))
          |> persist([
            :conversation_state,
            status: :running
          ])

        do_run(state)

      {:rate_limited, violations} ->
        {{:cancel, {:rate_limited, violations}}, state}
    end
  end

  defp enforce_rate_limit(%{config: %{rate_limit: %{limiter: limiter, rules: rules}}} = state)
       when not is_nil(limiter) and is_list(rules) do
    :ok = limiter.enforce!(state.agent_id, rules)
  rescue
    error in ExceededError ->
      Telemetry.emit(
        [:legion, :rate_limit, :exceeded],
        %{system_time: NaiveDateTime.utc_now()},
        %{
          agent: state.agent_module,
          agent_id: state.agent_id,
          identity: error.identity,
          policy: error.policy,
          usage: error.usage,
          violations: error.violations
        }
      )

      {:rate_limited, error.violations}
  end

  defp enforce_rate_limit(_state), do: :ok

  # The step is saved once, after it ran, and never as `status: :running`:
  # `Legion.Recovery` would resume a running row through the LLM loop, which a
  # conversation driven by an outside model does not have. Only the rate
  # limiter marks the row running, on enforcing `:max_running_agents`, and
  # the save below clears it. There are no turns here either, so bindings live
  # on unless the scope is `:iteration`. Usage records the evaluation, not
  # tokens: that is what `:max_evals` counts. A step that cannot be saved is
  # answered as an error and forgotten, so the conversation on record and the
  # one in memory stay the same; only its usage entry is kept.
  defp handle_eval(code, opts, state) do
    case eval_refusal(code, opts, state) || enforce_rate_limit(state) do
      :ok ->
        action = %{"action" => "eval_and_continue", "code" => code}
        action_message = Executor.message(:assistant, Jason.encode!(action))

        {reply, result_message, bindings} =
          with_call_vault(opts, state.agent_module, fn -> run_eval(code, state) end)

        entry = %{
          "at" => System.system_time(:millisecond),
          "evals" => 1,
          "message_index" => length(state.messages) - 1
        }

        messages = state.messages ++ [action_message, result_message]
        usage = if state.track_usage, do: state.usage ++ [entry]
        new_state = %{state | messages: messages, bindings: bindings, usage: usage}

        case save(new_state, [:conversation_state, status: :idle, usage: usage]) do
          :ok ->
            {reply, new_state}

          # The evaluation still counts: its entry, pointing at no message,
          # is kept for the next save that succeeds. The limiter may have
          # marked the row running; a status-only save frees that slot if
          # the store answers again.
          :error ->
            _ = save(state, status: :idle)
            usage = if state.track_usage, do: state.usage ++ [%{entry | "message_index" => nil}]

            {{:error,
              "The code ran, but the step could not be saved. Its effects stand; its variables were discarded and do not exist."},
             %{state | usage: usage}}
        end

      {:rate_limited, violations} ->
        {{:cancel, {:rate_limited, violations}}, state}

      {:refused, reason} ->
        {{:error, reason}, state}
    end
  end

  # `:require_agent` and `:require_sandbox` are the caller's conditions on the
  # agent it reached: `Legion.MCP.Server` finds named agents with
  # `Legion.lookup/1`, and one started elsewhere may be any agent, on any sandbox.
  defp eval_refusal(code, opts, %{agent_module: agent_module, config: config}) do
    required_agent = Keyword.get(opts, :require_agent, agent_module)
    required = Keyword.get(opts, :require_sandbox, config.sandbox)
    max_length = config.max_message_length

    evaluates? =
      Enum.any?(agent_module.action_types(), &(&1 in ~w(eval_and_continue eval_and_complete)))

    cond do
      not evaluates? ->
        {:refused,
         "#{inspect(agent_module)} runs no code: its action_types/0 allow no evaluation"}

      required_agent != agent_module ->
        {:refused,
         "This call requires #{inspect(required_agent)}; " <>
           "the agent it reached is #{inspect(agent_module)}"}

      required != config.sandbox ->
        {:refused,
         "This call requires #{inspect(required)}; " <>
           "#{inspect(agent_module)} runs #{inspect(config.sandbox)}"}

      # The code is kept as a message of the conversation, so it is held to
      # the same limit as any other.
      is_integer(max_length) and byte_size(code) > max_length ->
        {:refused,
         "The code is #{byte_size(code)} bytes, over the #{max_length} byte limit; " <>
           "send less at a time"}

      not String.valid?(code) ->
        {:refused, "The code is not valid UTF-8"}

      true ->
        nil
    end
  end

  # A key one caller passed never reaches the next call or a later turn, and no
  # caller replaces the agent's store or identity.
  defp with_call_vault(opts, agent_module, fun) do
    saved = Vault.vault(propagate_vault: :none)

    opts
    |> Keyword.get(:vault, [])
    |> Keyword.drop(@legion_vault_keys)
    |> Keyword.put(:excluded_tools, excluded_tools(opts, agent_module))
    |> Keyword.put(:current_action, "eval_and_continue")
    |> Vault.unsafe_merge()

    try do
      fun.()
    after
      # Vault 0.2.1 cannot drop keys; `Vault.unsafe_replace/1` is in the next
      # release, until then this writes its process dictionary key directly.
      Process.put(:__vault__, saved)
    end
  end

  defp excluded_tools(opts, agent_module) do
    case Keyword.get(opts, :exclude_tools, []) do
      excluded? when is_function(excluded?, 1) -> Enum.filter(agent_module.tools(), excluded?)
      excluded -> excluded
    end
  end

  defp run_eval(code, %{config: config} = state) do
    case Eval.run(state.agent_module, code, config, state.bindings) do
      {:ok, {value, bindings}} ->
        bindings = if config.binding_scope == :iteration, do: [], else: bindings
        text = Eval.format_result(value, bindings, config)
        {{:ok, text}, Executor.message(:eval_result, text), bindings}

      {:error, error} ->
        text =
          error |> Eval.format_error() |> Executor.truncate_content(config.max_message_length)

        {{:error, text}, Executor.message(:error, text), state.bindings}
    end
  end

  defp do_run(state, executor_state \\ :nonexistent) do
    conversation_scope? = Map.get(state.config, :binding_scope, :turn) == :conversation
    # A resumed turn keeps the bindings its checkpoint saved, whatever the scope -
    # they belong to the turn being finished, not to a new one.
    resuming? = executor_state != :nonexistent

    # What the turn goes back to when it ends, unless bindings outlive turns:
    # a new turn starts from it, a resumed turn's checkpoint saved it.
    base = if resuming?, do: state.base_bindings, else: state.bindings

    checkpoint =
      if state.persistence_frequency == :step do
        fn checkpoint ->
          usage = persisted_usage(state, checkpoint.turn_usage)
          checkpoint = Map.put(checkpoint, :base_bindings, base)
          persist(state, [{:conversation_state, checkpoint}, usage: usage])
          :ok
        end
      end

    executor_config = Map.put(state.config, :checkpoint, checkpoint)

    # Unless bindings outlive the turn, the ids of the sub-agents it starts
    # go with them at its end, and so do the sub-agents.
    sub_agents_before =
      if not conversation_scope? and AgentTool in state.agent_module.tools(),
        do: AgentTool.running(state.agent_id)

    {status, value, final_messages, final_bindings, turn_usage} =
      Telemetry.span(
        [:legion, :agent, :message],
        %{agent: state.agent_module, message: state.messages |> List.last() |> Map.get(:content)},
        fn ->
          messages = state.messages
          prev_count = Enum.count(messages, &(&1[:role] == "assistant"))

          {status, value, messages, bindings, _turn_usage} =
            result =
            Executor.run(
              state.agent_module,
              messages,
              executor_config,
              state.bindings,
              executor_state
            )

          iterations = Enum.count(messages, &(&1[:role] == "assistant")) - prev_count

          {result,
           %{
             iterations: iterations,
             status: status,
             result: value,
             bindings: bindings
           }}
        end
      )

    if sub_agents_before, do: AgentTool.stop_running(state.agent_id, sub_agents_before)

    kept_bindings = if conversation_scope?, do: final_bindings, else: base

    usage = persisted_usage(state, turn_usage)

    state =
      %{
        state
        | messages: final_messages,
          bindings: kept_bindings,
          usage: usage
      }

    fields = [:conversation_state, status: :idle, usage: usage]
    state = persist(state, fields)

    {{status, value}, state}
  end

  defp persist(state, fields) do
    :ok = save(state, fields)
    state
  end

  defp save(%{store: nil}, _fields), do: :ok
  defp save(state, fields), do: state.store.save(payload(state, fields))

  defp payload(state, fields) do
    Enum.reduce(fields, %Payload{agent_id: state.agent_id}, fn
      :conversation_state, payload ->
        %{payload | conversation_state: persisted_conversation_state(state)}

      {:conversation_state, checkpoint}, payload ->
        %{payload | conversation_state: persisted_conversation_state(checkpoint)}

      {field, value}, payload
      when field in [:agent_module, :parent_agent_id, :status, :started_at, :usage] ->
        Map.put(payload, field, value)

      unknown, _payload ->
        raise ArgumentError, "unsupported persistence field: #{inspect(unknown)}"
    end)
  end

  defp persisted_conversation_state(%__MODULE__{} = state) do
    [%{role: "system"} | messages] = state.messages

    %{messages: messages, bindings: state.bindings, executor_state: :nonexistent}
  end

  defp persisted_conversation_state(%{
         messages: [%{role: "system"} | messages],
         bindings: bindings,
         base_bindings: base_bindings,
         executor_state: executor_state
       }) do
    %{
      messages: messages,
      bindings: bindings,
      base_bindings: base_bindings,
      executor_state: executor_state
    }
  end

  defp persisted_usage(state, turn_usage) do
    if state.track_usage, do: state.usage ++ Enum.map(turn_usage, &stored_usage/1)
  end

  # The executor indexes the list it was given, which starts with the system
  # prompt. persisted_conversation_state/1 drops that prompt, so stored
  # entries point one earlier.
  defp stored_usage(%{"message_index" => index} = usage) when is_integer(index),
    do: %{usage | "message_index" => index - 1}

  defp stored_usage(usage), do: usage

  defp generate_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp stringify(message, max_length) when is_binary(message),
    do: Executor.truncate_content(message, max_length)

  defp stringify({:image, data, media_type}, _max_length)
       when is_binary(data) and is_binary(media_type) do
    [ContentPart.image(data, media_type)]
  end

  defp stringify({:image_url, url}, _max_length) when is_binary(url) do
    [ContentPart.image_url(url)]
  end

  defp stringify({:multipart, parts}, max_length) when is_list(parts) do
    Enum.map(parts, &truncate_text_part(&1, max_length))
  end

  defp stringify(message, max_length) do
    message
    |> inspect(limit: :infinity)
    |> Executor.truncate_content(max_length)
  end

  # Only text parts can be truncated safely - cutting image bytes or a URL
  # corrupts them.
  defp truncate_text_part(%ContentPart{type: :text, text: text} = part, max_length)
       when is_binary(text) do
    %{part | text: Executor.truncate_content(text, max_length)}
  end

  defp truncate_text_part(part, _max_length), do: part
end
