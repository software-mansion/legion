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

  alias Legion.{Executor, Store, Telemetry}
  alias Legion.RateLimiter
  alias Legion.RateLimiter.ExceededError
  alias Legion.Store.Payload
  alias ReqLLM.Message.ContentPart

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
    bindings: []
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
    gen_opts = [name: Legion.AgentIndex.name(agent_id)]
    config = agent_module |> resolve_config(opts) |> Map.put(:rate_limit, rate_limit)

    {{agent_module, config, store, agent_id, persistence_frequency, track_usage}, gen_opts}
  end

  def call(agent, message, timeout \\ :infinity) do
    GenServer.call(agent, {:message, message, Telemetry.capture_context()}, timeout)
  end

  def cast(agent, message) do
    GenServer.cast(agent, {:message, message, Telemetry.capture_context()})
  end

  def get_messages(agent) do
    GenServer.call(agent, :get_messages)
  end

  def get_agent_id(agent) do
    GenServer.call(agent, :get_agent_id)
  end

  # Server callbacks

  @impl true
  def init({agent_module, config, store, agent_id, persistence_frequency, track_usage}) do
    parent_agent_id = Vault.get(:agent_id)
    mode = Map.get(config, :start_mode, :normal)

    Vault.unsafe_put(:agent_id, agent_id)
    Vault.unsafe_put(:parent_agent_id, parent_agent_id)
    if store, do: Vault.unsafe_put(:store, store)

    for tool <- agent_module.tools() do
      Vault.unsafe_put(tool, agent_module.tool_config(tool))
    end

    Vault.unsafe_put(:rate_limit, config.rate_limit)

    system_prompt = Legion.AgentPrompt.system_prompt(agent_module, config)

    Telemetry.emit(
      [:legion, :agent, :started],
      %{system_time: NaiveDateTime.utc_now()},
      %{agent: agent_module}
    )

    {saved_messages, saved_bindings, saved_executor_state, saved_usage} =
      case store && store.get(agent_id) do
        {:ok,
         %Payload{
           conversation_state: %{
             messages: messages,
             bindings: bindings,
             executor_state: executor_state
           },
           usage: usage
         }} ->
          {messages, bindings, executor_state, if(track_usage, do: usage || [], else: nil)}

        _no_state ->
          {[], [], :nonexistent, if(track_usage, do: [], else: nil)}
      end

    state = %__MODULE__{
      agent_module: agent_module,
      messages: [Executor.message(:system, system_prompt) | saved_messages],
      config: config,
      store: store,
      agent_id: agent_id,
      persistence_frequency: persistence_frequency,
      bindings: saved_bindings,
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

  @impl true
  def handle_continue(%{start_mode: :normal}, state), do: {:noreply, state}

  @impl true
  def handle_continue(%{start_mode: :resume, executor_state: executor_state}, state) do
    if match?(%{role: "user"}, List.last(state.messages)) do
      {_reply, state} = do_run(state, executor_state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_continue(%{start_mode: :recover, executor_state: executor_state}, state) do
    {_reply, state} = do_run(state, executor_state)
    {:stop, :normal, state}
  end

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
    {:reply, state.messages, state}
  end

  @impl true
  def handle_call(:get_agent_id, _from, state) do
    {:reply, state.agent_id, state}
  end

  # The third element carries the caller's OpenTelemetry context, so spans
  # emitted during the turn nest under the caller's span. The two-element
  # shape is still accepted for mailboxes filled before an upgrade.
  @impl true
  def handle_call({:message, message, ctx}, _from, state) do
    {reply, state} = Telemetry.with_context(ctx, fn -> handle_message(message, state) end)
    {:reply, reply, state}
  end

  def handle_call({:message, message}, from, state) do
    handle_call({:message, message, nil}, from, state)
  end

  @impl true
  def handle_cast({:message, message, ctx}, state) do
    {_reply, state} = Telemetry.with_context(ctx, fn -> handle_message(message, state) end)
    {:noreply, state}
  end

  def handle_cast({:message, message}, state) do
    handle_cast({:message, message, nil}, state)
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

  defp do_run(state, executor_state \\ :nonexistent) do
    conversation_scope? = Map.get(state.config, :binding_scope, :turn) == :conversation

    checkpoint =
      if state.persistence_frequency == :step do
        fn checkpoint ->
          persist(state, [{:conversation_state, checkpoint}])
          :ok
        end
      end

    executor_config = Map.put(state.config, :checkpoint, checkpoint)

    {status, value, final_messages, final_bindings, turn_usage} =
      Telemetry.span(
        [:legion, :agent, :message],
        %{agent: state.agent_module, message: state.messages |> List.last() |> Map.get(:content)},
        fn ->
          messages = state.messages
          prev_count = Enum.count(messages, &(&1[:role] == "assistant"))

          # A resumed turn keeps the bindings its checkpoint saved, whatever the scope -
          # they belong to the turn being finished, not to a new one.
          resuming? = executor_state != :nonexistent
          initial_bindings = if conversation_scope? or resuming?, do: state.bindings, else: []

          {status, value, messages, bindings, _turn_usage} =
            result =
            Executor.run(
              state.agent_module,
              messages,
              executor_config,
              initial_bindings,
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

    kept_bindings = if conversation_scope?, do: final_bindings, else: []

    usage = if state.track_usage, do: state.usage ++ turn_usage

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

  defp persist(%{store: nil} = state, _fields), do: state

  defp persist(state, fields) do
    :ok = state.store.save(payload(state, fields))
    state
  end

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
         executor_state: executor_state
       }) do
    %{messages: messages, bindings: bindings, executor_state: executor_state}
  end

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

  @known_config_keys ~w(binding_scope eval_guard max_iterations max_message_length max_retries model sandbox sandbox_max_heap sandbox_max_reductions sandbox_priority sandbox_timeout start_mode)a

  defp resolve_config(agent_module, opts) do
    app_config = Application.get_env(:legion, :config, %{})
    call_config = Map.new(opts)

    merged =
      Executor.default_config()
      |> Map.merge(app_config)
      |> Map.merge(agent_module.config())
      |> Map.merge(call_config)

    unknown = Map.keys(merged) -- @known_config_keys

    if unknown != [] do
      Logger.warning("Unknown Legion config keys: #{inspect(unknown)}")
    end

    validate_max_message_length(merged)

    merged
  end

  defp validate_max_message_length(%{max_message_length: :infinity}), do: :ok

  defp validate_max_message_length(%{max_message_length: n}) when is_integer(n) and n > 0,
    do: :ok

  defp validate_max_message_length(%{max_message_length: other}) do
    raise ArgumentError,
          "expected :max_message_length to be a positive integer or :infinity, got: #{inspect(other)}"
  end

  defp validate_max_message_length(_config), do: :ok
end
