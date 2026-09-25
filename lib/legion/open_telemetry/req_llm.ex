defmodule Legion.OpenTelemetry.ReqLLM do
  @moduledoc """
  `ReqLLM.OpenTelemetry.Adapter` that forwards ReqLLM's `chat` spans to the
  `Legion.OpenTelemetry.Adapter` chosen in `Legion.OpenTelemetry.attach/1`.

  Installed by `Legion.OpenTelemetry.attach/1` unless the host passes its own
  `req_llm: [adapter: ...]`. Every callback receives ReqLLM's bridge config,
  which carries the Legion adapter as `:legion_adapter` and the Legion attach
  options as `:legion_config`; the Legion adapter is called with the latter plus
  `span_kind: :client`.
  """

  @behaviour ReqLLM.OpenTelemetry.Adapter

  @impl true
  def available? do
    case Legion.OpenTelemetry.config() do
      nil -> false
      config -> config[:adapter].available?()
    end
  end

  @impl true
  def metrics_available? do
    case Legion.OpenTelemetry.config() do
      nil -> false
      config -> metrics?(config[:adapter])
    end
  end

  @impl true
  def start_span(name, attributes, config) do
    adapter(config).start_span(name, attributes, legion_config(config))
  end

  @impl true
  def set_attributes(span, attributes, config) do
    adapter(config).set_attributes(span, attributes, legion_config(config))
  end

  @impl true
  def add_event(span, name, attributes, config) do
    adapter(config).add_event(span, name, attributes, legion_config(config))
  end

  @impl true
  def set_status(span, status, message, config) do
    adapter(config).set_status(span, status, message, legion_config(config))
  end

  @impl true
  def end_span(span, config) do
    adapter(config).end_span(span, legion_config(config))
  end

  @impl true
  def record_histogram(record, config) do
    adapter = adapter(config)

    if metrics?(adapter),
      do: adapter.record_histogram(record, legion_config(config)),
      else: :ok
  end

  @impl true
  def start_child_span(parent, name, attributes, opts, config) do
    adapter = adapter(config)
    legion_config = legion_config(config, Map.get(opts, :kind, :internal))

    if function_exported?(adapter, :start_child_span, 5),
      do: adapter.start_child_span(parent, name, attributes, opts, legion_config),
      else: adapter.start_span(name, attributes, legion_config)
  end

  @impl true
  def end_span_at(span, end_time, config) do
    adapter = adapter(config)

    if function_exported?(adapter, :end_span_at, 3),
      do: adapter.end_span_at(span, end_time, legion_config(config)),
      else: adapter.end_span(span, legion_config(config))
  end

  defp adapter(config), do: Keyword.fetch!(config, :legion_adapter)

  defp legion_config(config, span_kind \\ :client) do
    config
    |> Keyword.get(:legion_config, [])
    |> Keyword.put(:span_kind, span_kind)
  end

  defp metrics?(adapter) do
    function_exported?(adapter, :metrics_available?, 0) and
      function_exported?(adapter, :record_histogram, 2) and
      adapter.metrics_available?()
  end
end
