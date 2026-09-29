defmodule Legion.OpenTelemetry.Handler do
  @moduledoc false

  # Turns Legion's `:telemetry` events into OpenTelemetry spans, span events
  # and metrics:
  #
  #   * `[:legion, :agent, :message]` -> `invoke_agent <agent>`
  #   * `[:legion, :sandbox, :eval]`  -> `execute_tool sandbox`
  #   * `[:legion, :iteration]`       -> the current iteration number, plus an
  #     `iteration N` span with `iteration_spans: true`
  #   * `[:legion, :llm, :request]`   -> no span (ReqLLM's `chat` is one); its
  #     outcome feeds `legion.retry`
  #
  # Every Legion span starts and stops in the same process, strictly nested, so
  # the open spans live on a stack in the process dictionary. Each span is made
  # the current OpenTelemetry span while it is open, so `chat` spans and
  # anything the tool code traces nest under it.

  require Logger

  alias Legion.OpenTelemetry.{Attributes, Metrics}

  @handler_id "legion-otel"
  @stack_key {__MODULE__, :stack}
  @conversation_key {__MODULE__, :conversation}
  @session_key {Legion.OpenTelemetry, :session}

  @events [
    [:legion, :agent, :message, :start],
    [:legion, :agent, :message, :stop],
    [:legion, :agent, :message, :exception],
    [:legion, :iteration, :start],
    [:legion, :iteration, :stop],
    [:legion, :iteration, :exception],
    [:legion, :llm, :request, :start],
    [:legion, :llm, :request, :stop],
    [:legion, :llm, :request, :exception],
    [:legion, :sandbox, :eval, :start],
    [:legion, :sandbox, :eval, :stop],
    [:legion, :sandbox, :eval, :exception],
    [:legion, :eval_guard, :denied],
    [:legion, :rate_limit, :exceeded],
    [:legion, :agent, :started],
    [:legion, :agent, :stopped]
  ]

  def attach(config) do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, config)
  end

  def detach, do: :telemetry.detach(@handler_id)

  @doc """
  Legion attributes for a `chat` span started in this process: the agent and
  the iteration the LLM request belongs to. Empty outside an agent turn.
  """
  def chat_attributes do
    case find(:agent) do
      nil ->
        %{}

      agent ->
        attributes = agent.agent |> Attributes.agent(agent.agent_id) |> with_session(agent)

        case find(:iteration) do
          nil -> attributes
          iteration -> Map.put(attributes, :"legion.iteration", iteration.number)
        end
    end
  end

  # A raising handler gets detached by `:telemetry`, so failures are logged
  # and swallowed instead.
  def handle_event(event, measurements, meta, config) do
    handle(event, measurements, meta, config)
  rescue
    exception ->
      Logger.warning(
        "Legion.OpenTelemetry failed to handle #{inspect(event)}: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )
  catch
    kind, reason ->
      Logger.warning(
        "Legion.OpenTelemetry failed to handle #{inspect(event)}: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )
  end

  # -- invoke_agent --

  defp handle([:legion, :agent, :message, :start], _measurements, meta, config) do
    name = "invoke_agent " <> Attributes.agent_name(meta.agent)
    # A sub-agent inherits the session of the turn that called it, so every
    # span of a trace carries the same `session.id`.
    session = inherited_session() || meta[:agent_id]
    attributes = meta |> Attributes.invoke_agent_start(config) |> with_session(session)

    span =
      case conversation_parent(meta, session, config) do
        nil -> config[:adapter].start_span(name, attributes, config)
        parent -> start_child_span(parent, name, attributes, config)
      end

    push(%{
      kind: :agent,
      span: span,
      token: attach_span(span, session),
      agent: meta.agent,
      agent_id: meta[:agent_id],
      session: session,
      model: nil,
      inference_calls: 0,
      tool_calls: 0
    })
  end

  defp handle([:legion, :agent, :message, :stop], measurements, meta, config) do
    with %{} = frame <- pop(:agent, config) do
      adapter = config[:adapter]
      attributes = Attributes.invoke_agent_stop(meta, frame.model, config)
      error_type = attributes[:"error.type"]

      adapter.set_attributes(frame.span, attributes, config)
      if error_type, do: adapter.set_status(frame.span, :error, error_type, config)
      finish(frame, config)

      agent = %{"gen_ai.agent.name": Attributes.agent_name(frame.agent)}

      cancellations =
        if error_type,
          do: [
            Metrics.build("legion.turn.cancellations", 1, cancel_attributes(agent, error_type))
          ],
          else: []

      [
        agent_duration(frame, measurements, error_type),
        Metrics.build("gen_ai.invoke_agent.inference_calls", frame.inference_calls, agent),
        Metrics.build("gen_ai.invoke_agent.tool_calls", frame.tool_calls, agent),
        meta[:iterations] && Metrics.build("legion.turn.iterations", meta[:iterations], agent)
      ]
      |> Kernel.++(cancellations)
      |> Enum.reject(&is_nil/1)
      |> Metrics.record(config)
    end
  end

  defp handle([:legion, :agent, :message, :exception], measurements, meta, config) do
    with %{} = frame <- pop(:agent, config) do
      error_type = fail(frame, meta, config)
      finish(frame, config)

      [agent_duration(frame, measurements, error_type)]
      |> Enum.reject(&is_nil/1)
      |> Metrics.record(config)
    end
  end

  # -- iterations --

  defp handle([:legion, :iteration, :start], _measurements, meta, config) do
    number = meta.iteration

    # The executor starts the next iteration from inside the previous one, so
    # the enclosing iteration is over here: close its span so iteration spans
    # come out as siblings. The same number again means the LLM is retried.
    case stack() do
      [%{kind: :iteration} = enclosing | rest] ->
        if enclosing.number == number, do: record_retry(enclosing, number, config)
        finish(enclosing, config)
        put_stack([%{enclosing | span: nil, token: nil} | rest])

      _ ->
        :ok
    end

    span =
      with true <- config[:iteration_spans],
           %{} = agent <- find(:agent) do
        attributes =
          agent.agent |> Attributes.iteration(agent.agent_id, number) |> with_session(agent)

        config[:adapter].start_span("iteration #{number}", attributes, config)
      else
        _ -> nil
      end

    push(%{
      kind: :iteration,
      number: number,
      span: span,
      token: attach_span(span),
      llm: nil,
      eval: nil
    })
  end

  defp handle([:legion, :iteration, :stop], _measurements, meta, config) do
    with %{} = frame <- pop(:iteration, config) do
      if frame.span && meta[:action],
        do: config[:adapter].set_attributes(frame.span, %{"legion.action": meta[:action]}, config)

      finish(frame, config)
    end
  end

  defp handle([:legion, :iteration, :exception], _measurements, meta, config) do
    with %{} = frame <- pop(:iteration, config) do
      if frame.span, do: fail(frame, meta, config)
      finish(frame, config)
    end
  end

  # -- LLM requests --

  defp handle([:legion, :llm, :request, :start], _measurements, meta, _config) do
    update(:agent, &%{&1 | model: meta[:model], inference_calls: &1.inference_calls + 1})
    update(:iteration, &%{&1 | llm: :pending})
  end

  defp handle([:legion, :llm, :request, :stop], _measurements, meta, _config) do
    outcome =
      cond do
        Map.has_key?(meta, :object) -> :ok
        Map.has_key?(meta, :usage) -> {:error, "invalid_object"}
        true -> {:error, "request_failed"}
      end

    update(:iteration, &%{&1 | llm: outcome})
  end

  defp handle([:legion, :llm, :request, :exception], _measurements, _meta, _config) do
    update(:iteration, &%{&1 | llm: {:error, "request_failed"}})
  end

  # -- execute_tool --

  defp handle([:legion, :sandbox, :eval, :start], _measurements, meta, config) do
    iteration =
      case find(:iteration) do
        %{number: number} -> number
        nil -> nil
      end

    update(:agent, &%{&1 | tool_calls: &1.tool_calls + 1})
    update(:iteration, &%{&1 | eval: :pending})

    attributes =
      meta |> Attributes.execute_tool_start(iteration, config) |> with_session(find(:agent))

    span = config[:adapter].start_span("execute_tool sandbox", attributes, config)

    push(%{
      kind: :eval,
      span: span,
      token: attach_span(span),
      agent: meta.agent,
      guard_denied?: false
    })
  end

  defp handle([:legion, :sandbox, :eval, :stop], measurements, meta, config) do
    with %{} = frame <- pop(:eval, config) do
      adapter = config[:adapter]
      attributes = Attributes.execute_tool_stop(meta, config)

      error_kind =
        if meta[:success] do
          nil
        else
          message = Attributes.error_message(meta[:error], config[:max_attribute_bytes])
          adapter.set_status(frame.span, :error, message, config)
          Attributes.eval_error_kind(meta[:error], frame.guard_denied?)
        end

      attributes =
        if error_kind, do: Map.put(attributes, :"error.type", error_kind), else: attributes

      adapter.set_attributes(frame.span, attributes, config)
      finish(frame, config)
      update(:iteration, &%{&1 | eval: if(error_kind, do: :error, else: :ok)})
      record_eval(frame, measurements, error_kind, error_kind, config)
    end
  end

  defp handle([:legion, :sandbox, :eval, :exception], measurements, meta, config) do
    with %{} = frame <- pop(:eval, config) do
      error_type = fail(frame, meta, config)
      finish(frame, config)
      update(:iteration, &%{&1 | eval: :error})
      record_eval(frame, measurements, error_type, "crash", config)
    end
  end

  # -- failure events --

  defp handle([:legion, :eval_guard, :denied], _measurements, meta, config) do
    case stack() do
      [%{kind: :eval} = frame | rest] ->
        attributes = %{
          "legion.eval_guard.guard": inspect(meta[:guard]),
          "legion.eval_guard.reason":
            Attributes.error_message(meta[:reason], config[:max_attribute_bytes])
        }

        config[:adapter].add_event(frame.span, "legion.eval_guard.denied", attributes, config)
        put_stack([%{frame | guard_denied?: true} | rest])

      _ ->
        :ok
    end
  end

  defp handle([:legion, :rate_limit, :exceeded], _measurements, meta, config) do
    identity = identity_keys(meta[:identity])

    with %{} = agent <- find(:agent) do
      attributes = %{
        "legion.rate_limit.identity": identity,
        "legion.rate_limit.violations": Enum.map(meta[:violations] || [], &to_string/1)
      }

      config[:adapter].add_event(agent.span, "legion.rate_limit.exceeded", attributes, config)
    end

    attributes = %{
      "gen_ai.agent.name": Attributes.agent_name(meta.agent),
      "legion.rate_limit.identity": identity
    }

    Metrics.record([Metrics.build("legion.rate_limit.exceeded", 1, attributes)], config)
  end

  # -- agent processes --

  defp handle([:legion, :agent, :started], _measurements, meta, config) do
    attributes = %{"gen_ai.agent.name": Attributes.agent_name(meta.agent)}
    Metrics.record([Metrics.build("legion.agents.active", 1, attributes)], config)
  end

  defp handle([:legion, :agent, :stopped], _measurements, meta, config) do
    attributes = %{"gen_ai.agent.name": Attributes.agent_name(meta.agent)}
    Metrics.record([Metrics.build("legion.agents.active", -1, attributes)], config)
  end

  # -- helpers --

  # With `conversation_traces: true`, a turn nobody traces from outside joins
  # the agent's conversation trace. A caller's span (a request, a job, the
  # parent agent's `execute_tool`) always wins.
  defp conversation_parent(meta, session, config) do
    if config[:conversation_traces] and not current_span?() do
      Process.get(@conversation_key) || start_conversation(meta, session, config)
    end
  end

  # The conversation span is ended right away: OpenTelemetry exports a span only
  # when it ends, and Braintrust lists a trace only once its root has arrived,
  # so a span left open for the conversation would hide every turn until the
  # agent stops. Turns started later still parent on it.
  defp start_conversation(meta, session, config) do
    adapter = config[:adapter]
    name = "conversation " <> Attributes.agent_name(meta.agent)

    span =
      adapter.start_span(name, meta |> Attributes.conversation() |> with_session(session), config)

    adapter.end_span(span, config)
    Process.put(@conversation_key, span)
    span
  end

  defp with_session(attributes, %{session: session}), do: with_session(attributes, session)

  defp with_session(attributes, session) when is_binary(session),
    do: Map.put(attributes, :"session.id", session)

  defp with_session(attributes, _no_session), do: attributes

  defp start_child_span(parent, name, attributes, config) do
    adapter = config[:adapter]

    if function_exported?(adapter, :start_child_span, 5),
      do: adapter.start_child_span(parent, name, attributes, %{kind: :internal}, config),
      else: adapter.start_span(name, attributes, config)
  end

  defp record_retry(iteration, number, config) do
    reason =
      case iteration do
        %{llm: {:error, reason}} -> reason
        %{llm: :ok, eval: nil} -> "invalid_action"
        _eval_failed -> nil
      end

    with reason when is_binary(reason) <- reason,
         %{} = agent <- find(:agent) do
      config[:adapter].add_event(
        agent.span,
        "legion.retry",
        %{"legion.retry.reason": reason, "legion.iteration": number},
        config
      )

      attributes = %{
        "gen_ai.agent.name": Attributes.agent_name(agent.agent),
        "legion.retry.reason": reason
      }

      Metrics.record([Metrics.build("legion.llm.retries", 1, attributes)], config)
    end
  end

  defp record_eval(frame, measurements, error_type, error_kind, config) do
    agent_name = Attributes.agent_name(frame.agent)

    duration =
      case Metrics.seconds(measurements[:duration]) do
        nil ->
          nil

        seconds ->
          attributes =
            drop_nils(%{
              "gen_ai.tool.name": "sandbox",
              "gen_ai.tool.type": "extension",
              "gen_ai.agent.name": agent_name,
              "error.type": error_type
            })

          Metrics.build("gen_ai.execute_tool.duration", seconds, attributes)
      end

    errors =
      if error_kind do
        attributes = %{"gen_ai.agent.name": agent_name, "legion.error.kind": error_kind}
        Metrics.build("legion.eval.errors", 1, attributes)
      end

    [duration, errors] |> Enum.reject(&is_nil/1) |> Metrics.record(config)
  end

  defp agent_duration(frame, measurements, error_type) do
    with seconds when is_number(seconds) <- Metrics.seconds(measurements[:duration]) do
      attributes =
        drop_nils(%{
          "gen_ai.agent.name": Attributes.agent_name(frame.agent),
          "gen_ai.request.model": Attributes.model_name(frame.model),
          "error.type": error_type
        })

      Metrics.build("gen_ai.invoke_agent.duration", seconds, attributes)
    end
  end

  defp cancel_attributes(agent, reason), do: Map.put(agent, :"legion.cancel.reason", reason)

  # Marks `frame`'s span failed from an `:exception` event, returning `error.type`.
  defp fail(frame, meta, config) do
    adapter = config[:adapter]
    error_type = Attributes.exception_type(meta[:kind], meta[:reason])
    message = Attributes.error_message(meta[:reason], config[:max_attribute_bytes])

    adapter.set_attributes(frame.span, %{"error.type": error_type}, config)
    adapter.set_status(frame.span, :error, message, config)
    error_type
  end

  defp finish(frame, config) do
    if frame.span, do: config[:adapter].end_span(frame.span, config)
    detach_span(frame.token)
  end

  defp identity_keys(identity) when is_map(identity),
    do: identity |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(",")

  defp identity_keys(_identity), do: nil

  defp drop_nils(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  # -- span stack --

  defp stack, do: Process.get(@stack_key, [])

  defp put_stack([]), do: Process.delete(@stack_key)
  defp put_stack(stack), do: Process.put(@stack_key, stack)

  defp push(frame), do: put_stack([frame | stack()])

  defp find(kind), do: Enum.find(stack(), &(&1.kind == kind))

  defp update(kind, fun) do
    {above, rest} = Enum.split_while(stack(), &(&1.kind != kind))

    case rest do
      [frame | rest] -> put_stack(above ++ [fun.(frame) | rest])
      [] -> :ok
    end
  end

  # Pops the innermost frame of `kind`. Frames above it were left open by a
  # missed stop event; they are closed so the context stack stays balanced.
  defp pop(kind, config) do
    {above, rest} = Enum.split_while(stack(), &(&1.kind != kind))

    case rest do
      [frame | rest] ->
        Enum.each(above, &finish(&1, config))
        put_stack(rest)
        frame

      [] ->
        nil
    end
  end

  # -- current span --

  if Code.ensure_loaded?(OpenTelemetry.Ctx) do
    # Only real span contexts become current; an adapter that hands back
    # something else (a test fake, a vendor handle) still gets its lifecycle
    # callbacks, but nothing nests under its spans.
    defp attach_span(span) when is_tuple(span) and elem(span, 0) == :span_ctx do
      OpenTelemetry.Ctx.get_current()
      |> OpenTelemetry.Tracer.set_current_span(span)
      |> OpenTelemetry.Ctx.attach()
    end

    defp attach_span(_span), do: nil

    # The agent span also carries the session in the context, which follows the
    # turn into the sandbox and on to any agent it calls.
    defp attach_span(span, session) do
      ctx = OpenTelemetry.Ctx.set_value(OpenTelemetry.Ctx.get_current(), @session_key, session)

      ctx =
        if is_tuple(span) and tuple_size(span) > 0 and elem(span, 0) == :span_ctx,
          do: OpenTelemetry.Tracer.set_current_span(ctx, span),
          else: ctx

      OpenTelemetry.Ctx.attach(ctx)
    end

    defp inherited_session, do: OpenTelemetry.Ctx.get_value(@session_key, nil)

    defp detach_span(nil), do: :ok
    defp detach_span(token), do: OpenTelemetry.Ctx.detach(token)

    defp current_span?, do: OpenTelemetry.Span.is_valid(OpenTelemetry.Tracer.current_span_ctx())
  else
    defp attach_span(_span), do: nil
    defp attach_span(_span, _session), do: nil
    defp inherited_session, do: nil
    defp detach_span(_token), do: :ok
    defp current_span?, do: false
  end
end
