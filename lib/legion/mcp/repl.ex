if Code.ensure_loaded?(Anubis.Server.Component) do
  defmodule Legion.MCP.Repl do
    @moduledoc """
    Execute code in this server's sandbox. The language, its rules and the tool modules you
    can call are described in the server instructions. Variables persist across calls
    within this session unless the instructions say otherwise.
    """

    use Anubis.Server.Component, type: :tool

    alias Anubis.Server.Frame
    alias Anubis.Server.Response
    alias Legion.{Eval, Executor, RateLimiter, Telemetry}
    alias Legion.RateLimiter.ExceededError
    alias Legion.Store.Payload

    schema do
      field :code, :string, required: true, description: "Code to execute in the sandbox"
    end

    @impl true
    def execute(%{code: code}, %Frame{assigns: %{agent: agent}} = frame) do
      frame = frame |> resolve_agent_id() |> resolve_rate_limit()

      Vault.unsafe_put(:agent_id, frame.assigns.agent_id)
      Vault.unsafe_put(:rate_limit, frame.assigns.rate_limit)
      if store = frame.assigns.store, do: Vault.unsafe_put(:store, store)

      meta = %{agent: agent, session_id: frame.context.session_id, code: code}

      Telemetry.span([:legion, :mcp, :call], meta, fn ->
        case enforce_rate_limit(frame) do
          :ok ->
            run(code, load_row(frame))

          {:rate_limited, error} ->
            {{:reply, Response.error(Response.tool(), error), frame},
             %{success: false, error: error}}
        end
      end)
    end

    def execute(_params, %Frame{} = frame) do
      message = "Session is not initialized: send notifications/initialized before calling tools."
      {:reply, Response.error(Response.tool(), message), frame}
    end

    defp resolve_agent_id(%Frame{assigns: %{agent_id: _}} = frame), do: frame

    defp resolve_agent_id(%Frame{assigns: %{server: server}} = frame) do
      agent_id =
        case server.agent_id(frame) do
          nil ->
            "mcp:" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

          id when is_binary(id) ->
            if String.valid?(id), do: id, else: raise_agent_id(server, id)

          other ->
            raise_agent_id(server, other)
        end

      Frame.assign(frame, :agent_id, agent_id)
    end

    defp raise_agent_id(server, value) do
      raise ArgumentError,
            "#{inspect(server)}.agent_id/1 must return a valid UTF-8 string or nil, " <>
              "got: #{inspect(value)}"
    end

    # Rules are built per call, since the identity lives in the request. A server
    # that gives none resolves once per session, like an agent started without
    # `:rate_limit`: `resolve!/1` warns when a limiter is configured.
    defp resolve_rate_limit(%Frame{assigns: %{server: server} = assigns} = frame) do
      rate_limit =
        case server.rate_limit_rules(frame) do
          nil -> Map.get(assigns, :rate_limit) || RateLimiter.resolve!([])
          rules -> RateLimiter.resolve!(rules: rules)
        end

      Frame.assign(frame, :rate_limit, rate_limit)
    end

    # A denied call runs nothing and records nothing; only what was resolved
    # stays in the frame.
    defp enforce_rate_limit(
           %Frame{assigns: %{rate_limit: %{limiter: limiter, rules: rules}} = assigns} = frame
         )
         when not is_nil(limiter) and is_list(rules) do
      :ok = limiter.enforce!(assigns.agent_id, rules)
    rescue
      error in ExceededError ->
        Telemetry.emit(
          [:legion, :rate_limit, :exceeded],
          %{system_time: NaiveDateTime.utc_now()},
          %{
            agent: assigns.agent,
            agent_id: assigns.agent_id,
            session_id: frame.context.session_id,
            identity: error.identity,
            policy: error.policy,
            usage: error.usage,
            violations: error.violations
          }
        )

        {:rate_limited, denial(error)}
    end

    defp enforce_rate_limit(_frame), do: :ok

    defp denial(%ExceededError{policy: policy, violations: violations}) do
      window =
        if rem(policy.window_ms, 1_000) == 0,
          do: "#{div(policy.window_ms, 1_000)}s",
          else: "#{policy.window_ms}ms"

      limits = Enum.map_join(violations, ", ", &"#{&1} (#{Map.get(policy, &1)} per #{window})")

      "Rate limited: #{limits}. Try again later."
    end

    # The Store is read once, on the first call of a fresh frame; after that the
    # frame is the cache. `usage: nil` means usage is not tracked.
    defp load_row(%Frame{assigns: %{messages: _}} = frame), do: frame

    defp load_row(%Frame{assigns: %{store: store, agent_id: agent_id}} = frame) do
      track_usage = Application.get_env(:legion, :track_usage, true)

      {messages, bindings, usage} =
        case store && store.get(agent_id) do
          {:ok,
           %Payload{
             conversation_state: %{messages: messages, bindings: bindings},
             usage: usage
           }} ->
            {messages, bindings, usage || []}

          _no_state ->
            {[], [], []}
        end

      Frame.assign(frame,
        messages: messages,
        bindings: bindings,
        usage: if(track_usage, do: usage),
        started_at: NaiveDateTime.utc_now()
      )
    end

    # Returns `{tool reply, span stop metadata}`.
    defp run(code, %Frame{assigns: %{agent: agent, config: config, bindings: bindings}} = frame) do
      call =
        Executor.message(
          :assistant,
          Jason.encode!(%{"action" => "eval_and_continue", "code" => code})
        )

      {response, outcome, bindings, stop} =
        case Eval.run(agent, code, config, bindings) do
          {:ok, {value, bindings}} ->
            bindings = if config.binding_scope == :iteration, do: [], else: bindings
            text = Eval.format_result(value, bindings, config)

            {Response.text(Response.tool(), text), Executor.message(:eval_result, text), bindings,
             %{success: true, result: value}}

          {:error, reason} ->
            error =
              reason
              |> Eval.format_error()
              |> Executor.truncate_content(config.max_message_length)

            {Response.error(Response.tool(), error), Executor.message(:error, error), bindings,
             %{success: false, error: error}}
        end

      case record(frame, call, outcome, bindings) do
        {:ok, frame} ->
          {{:reply, response, frame}, stop}

        :error ->
          error = "The code ran, but the session could not be saved. Try again."

          {{:reply, Response.error(Response.tool(), error), frame},
           %{success: false, error: error}}
      end
    end

    # Appends the call the way the Executor records an eval, so a stored session
    # reads like an agent's conversation, and saves the whole row.
    defp record(%Frame{assigns: assigns} = frame, call, outcome, bindings) do
      entry = %{
        "at" => System.system_time(:millisecond),
        "evals" => 1,
        "message_index" => length(assigns.messages)
      }

      messages = assigns.messages ++ [call, outcome]
      usage = assigns.usage && assigns.usage ++ [entry]

      payload = %Payload{
        agent_id: assigns.agent_id,
        agent_module: assigns.agent,
        started_at: assigns.started_at,
        conversation_state: %{
          messages: messages,
          bindings: bindings,
          executor_state: :nonexistent
        },
        usage: usage
      }

      case assigns.store && assigns.store.save(payload) do
        result when result in [nil, :ok] ->
          {:ok, Frame.assign(frame, messages: messages, usage: usage, bindings: bindings)}

        :error ->
          :error
      end
    end
  end
end
