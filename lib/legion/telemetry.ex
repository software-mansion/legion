defmodule Legion.Telemetry do
  @moduledoc """
  Telemetry integration for Legion agents.

  Legion emits the following telemetry events:

  ## Agent Lifecycle Events

  - `[:legion, :agent, :started]` — emitted during `init/1`, before any
    persisted conversation is restored
    - Measurements: `%{system_time: NaiveDateTime.t()}`
    - Metadata: `%{agent: module, agent_id: String.t()}` (plus `parent_agent_id: String.t()`
      when the agent was started inside another agent's run)
    - `agent_id` names the conversation — stable across restarts, so a resumed
      conversation emits under the same id.
    - Not emitted if `init/1` crashes before the event fires (e.g. while building
    the system prompt) — in that case `:stopped` is not emitted either, since
    GenServer does not call `terminate/2` on init failure.

  - `[:legion, :agent, :stopped]` — agent process terminated via `terminate/2`
    - Measurements: `%{system_time: NaiveDateTime.t()}`
    - Metadata: `%{agent: module, agent_id: String.t()}` (plus `parent_agent_id: String.t()`
      when the agent was started inside another agent's run)

  ## Agent Message Events (spans)

  - `[:legion, :agent, :message, :start | :stop | :exception]` — agent handling a message
    - Metadata includes: `agent`, `agent_id`, `message`
    - Stop adds: `iterations` (count of assistant turns in this message),
      `status` (`:ok` or `:cancel`), `result` (the value returned, or the
      cancellation reason such as `:reached_max_iterations`), and `bindings`
      (the variable bindings carried out of the turn)

  ## Iteration Events (spans)

  - `[:legion, :iteration, :start | :stop | :exception]`
    - Metadata includes: `agent`, `agent_id`, `iteration`
    - Stop adds: `action`

  ## LLM Request Events (spans)

  - `[:legion, :llm, :request, :start | :stop | :exception]`
    - Metadata includes: `agent`, `agent_id`, `model`, `message_count`, `iteration`
    - Stop adds: `object` or `error`, and `usage` (the string-keyed usage map
      with its `"at"` timestamp and `"message_index"`, when a response was received)

  ## Sandbox Eval Events (spans)

  - `[:legion, :sandbox, :eval, :start | :stop | :exception]`
    - Metadata includes: `agent`, `agent_id`, `code`
    - Stop adds: `success` and `result` or `error`.

  ## Eval Guard Events

  - `[:legion, :eval_guard, :denied]` — a guard refused generated code
    - Metadata: `%{agent: module, agent_id: String.t(), guard: module, code: String.t(), reason: String.t()}`

  ## Rate Limit Events

  - `[:legion, :rate_limit, :exceeded]` — a rate limiter denied a turn before
    it started; metadata carries the identity and policy of the rule that
    denied it, the usage measured for it, and the violations
    - Measurements: `%{system_time: NaiveDateTime.t()}`
    - Metadata: `%{agent: module, agent_id: String.t(), identity: map, policy:
      Legion.RateLimiter.Policy.t(), usage: map, violations: [atom]}`
    - `violations` names the limits that were reached, e.g. `[:max_tokens]`.

  ## Default Logger

  A default logger is provided that outputs human-readable telemetry to `Logger`.
  Attach it with `Legion.Telemetry.attach_default_logger/1`.
  """

  require Logger

  @handler_id "legion-default-logger"

  @doc """
  Attaches a default logger for Legion telemetry events.

  ## Options

    - `:level` — log level, defaults to `:info`
    - `:events` — `:all` or a list of event categories
      (`:agent`, `:message`, `:iteration`, `:llm`, `:sandbox`).
      Defaults to `:all`.
  """
  def attach_default_logger(opts \\ []) do
    level = Keyword.get(opts, :level, :info)
    filter = Keyword.get(opts, :events, :all)

    events =
      for {category, event_names} <- [
            agent: [[:legion, :agent, :started], [:legion, :agent, :stopped]],
            message: [
              [:legion, :agent, :message, :start],
              [:legion, :agent, :message, :stop],
              [:legion, :agent, :message, :exception]
            ],
            iteration: [
              [:legion, :iteration, :start],
              [:legion, :iteration, :stop],
              [:legion, :iteration, :exception]
            ],
            llm: [
              [:legion, :llm, :request, :start],
              [:legion, :llm, :request, :stop],
              [:legion, :llm, :request, :exception]
            ],
            sandbox: [
              [:legion, :sandbox, :eval, :start],
              [:legion, :sandbox, :eval, :stop],
              [:legion, :sandbox, :eval, :exception]
            ]
          ],
          filter == :all or category in filter,
          event <- event_names do
        event
      end

    :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, level: level)
  end

  @doc """
  Detaches the default logger.
  """
  def detach_default_logger do
    :telemetry.detach(@handler_id)
  end

  # -- Span helper --

  @doc """
  Wraps a function with `:start` / `:stop` / `:exception` telemetry events.

  The function should return `{result, extra_stop_metadata}`.
  `agent_id` is automatically injected from the process dictionary.
  """
  def span(event_prefix, metadata, fun) when is_function(fun, 0) do
    metadata = with_agent_id(metadata)
    start_time = System.monotonic_time()

    :telemetry.execute(event_prefix ++ [:start], %{system_time: System.system_time()}, metadata)

    try do
      {result, extra} = fun.()
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        event_prefix ++ [:stop],
        %{duration: duration},
        Map.merge(metadata, extra)
      )

      result
    rescue
      e ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          event_prefix ++ [:exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: :error, reason: e, stacktrace: __STACKTRACE__})
        )

        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          event_prefix ++ [:exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: __STACKTRACE__})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc """
  Emits a single telemetry event. Injects `agent_id` from the process dictionary.
  """
  def emit(event, measurements \\ %{}, metadata) do
    :telemetry.execute(event, measurements, with_agent_id(metadata))
  end

  defp with_agent_id(metadata) do
    metadata
    |> put_from_vault(:agent_id)
    |> put_from_vault(:parent_agent_id)
  end

  defp put_from_vault(metadata, key) do
    case Vault.get(key) do
      nil -> metadata
      value -> Map.put_new(metadata, key, value)
    end
  end

  # -- Default logger handlers --

  @doc false
  def handle_event([:legion, :agent, :started], _measurements, meta, opts) do
    log(opts, meta, "agent:started #{short(meta.agent)}")
  end

  def handle_event([:legion, :agent, :stopped], _measurements, meta, opts) do
    log(opts, meta, "agent:stopped #{short(meta.agent)}")
  end

  def handle_event([:legion, :agent, :message, :start], _measurements, meta, opts) do
    message =
      if is_binary(meta.message),
        do: String.slice(meta.message, 0, 80),
        else: inspect(meta.message, limit: 5)

    log(opts, meta, "message:start #{short(meta.agent)} #{inspect(message)}")
  end

  def handle_event([:legion, :agent, :message, :stop], measurements, meta, opts) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    log(opts, meta, "message:stop #{short(meta.agent)} iterations=#{meta[:iterations]} #{ms}ms")
  end

  def handle_event([:legion, :agent, :message, :exception], measurements, meta, opts) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    log(
      opts,
      meta,
      "message:exception #{short(meta.agent)} #{inspect(meta.reason)} #{ms}ms",
      :error
    )
  end

  def handle_event([:legion, :iteration, :start], _measurements, meta, opts) do
    log(opts, meta, "  iteration:start #{short(meta.agent)} ##{meta.iteration}")
  end

  def handle_event([:legion, :iteration, :stop], measurements, meta, opts) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    log(
      opts,
      meta,
      "  iteration:stop #{short(meta.agent)} ##{meta.iteration} action=#{meta[:action]} #{ms}ms"
    )
  end

  def handle_event([:legion, :iteration, :exception], measurements, meta, opts) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    log(
      opts,
      meta,
      "  iteration:exception #{short(meta.agent)} ##{meta.iteration} #{inspect(meta.reason)} #{ms}ms",
      :error
    )
  end

  def handle_event([:legion, :llm, :request, :start], _measurements, meta, opts) do
    log(opts, meta, "    llm:start #{meta.model} messages=#{meta.message_count}")
  end

  def handle_event([:legion, :llm, :request, :stop], measurements, meta, opts) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    log(opts, meta, "    llm:stop #{meta.model} #{ms}ms")
  end

  def handle_event([:legion, :llm, :request, :exception], measurements, meta, opts) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    log(opts, meta, "    llm:exception #{meta.model} #{inspect(meta.reason)} #{ms}ms", :error)
  end

  def handle_event([:legion, :sandbox, :eval, :start], _measurements, meta, opts) do
    log(opts, meta, "    eval:start\n#{indent_code(meta.code)}")
  end

  def handle_event([:legion, :sandbox, :eval, :stop], measurements, meta, opts) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    if meta.success do
      log(opts, meta, "    eval:stop ok #{ms}ms")
    else
      error = format_eval_error(meta[:error])
      log(opts, meta, "    eval:stop error #{ms}ms\n      #{error}", :warning)
    end
  end

  def handle_event([:legion, :sandbox, :eval, :exception], measurements, meta, opts) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    log(opts, meta, "    eval:exception #{inspect(meta.reason)} #{ms}ms", :error)
  end

  def handle_event(event, _measurements, _meta, _opts) do
    Logger.warning("Legion.Telemetry: unhandled event #{inspect(event)}")
  end

  defp log(opts, meta, message, level \\ nil) do
    level = level || Keyword.fetch!(opts, :level)
    prefix = run_prefix(meta)
    Logger.log(level, "#{prefix} #{message}")
  end

  # ANSI colors indexed by agent_id hash for visual grouping
  @colors [
    IO.ANSI.cyan(),
    IO.ANSI.green(),
    IO.ANSI.yellow(),
    IO.ANSI.magenta(),
    IO.ANSI.blue(),
    IO.ANSI.light_cyan(),
    IO.ANSI.light_green(),
    IO.ANSI.light_yellow(),
    IO.ANSI.light_magenta(),
    IO.ANSI.light_blue()
  ]

  defp run_prefix(meta) do
    color = color_for(meta[:agent_id])
    marker = if meta[:parent_agent_id], do: "┃▸", else: "┃ "
    "#{color}#{marker}#{IO.ANSI.reset()}"
  end

  defp color_for(nil), do: IO.ANSI.white()

  defp color_for(agent_id) do
    index = :erlang.phash2(agent_id, length(@colors))
    Enum.at(@colors, index)
  end

  defp short(module) when is_atom(module) do
    module |> Module.split() |> List.last()
  end

  defp indent_code(code) do
    code
    |> String.split("\n")
    |> Enum.map_join("\n", &("      " <> &1))
  end

  defp format_eval_error(message) when is_binary(message), do: message
  defp format_eval_error(%{message: message}) when is_binary(message), do: message
  defp format_eval_error(error) when is_exception(error), do: Exception.message(error)
  defp format_eval_error(error), do: inspect(error, pretty: true, limit: 50)
end
