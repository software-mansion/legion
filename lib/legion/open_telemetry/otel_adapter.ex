defmodule Legion.OpenTelemetry.OTelAdapter do
  @moduledoc """
  Default `Legion.OpenTelemetry.Adapter`, backed by the OpenTelemetry API.

  Compiled against `opentelemetry_api` when it is present; without it every
  callback is a no-op and `available?/0` returns `false`, so
  `Legion.OpenTelemetry.attach/1` reports `{:error, :opentelemetry_unavailable}`
  instead of raising. Public so custom adapters can `defdelegate` the callbacks
  they do not override.

  Spans start under the tracer named `legion` with the span kind taken from
  `config[:span_kind]` (`:internal` by default). Metrics are recorded through
  ReqLLM's histogram instruments, which already implement the GenAI bucket
  boundaries.
  """

  @behaviour Legion.OpenTelemetry.Adapter

  if Code.ensure_loaded?(OpenTelemetry.Tracer) do
    @impl true
    def available?, do: true

    @impl true
    def start_span(name, attributes, config) do
      :otel_tracer.start_span(tracer(), name, %{kind: span_kind(config), attributes: attributes})
    end

    @impl true
    def set_attributes(span, attributes, _config) do
      OpenTelemetry.Span.set_attributes(span, attributes)
      :ok
    end

    @impl true
    def add_event(span, name, attributes, _config) do
      OpenTelemetry.Span.add_event(span, name, attributes)
      :ok
    end

    @impl true
    def set_status(span, :ok, nil, _config) do
      OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:ok))
      :ok
    end

    def set_status(span, :ok, message, _config) do
      OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:ok, message))
      :ok
    end

    def set_status(span, :error, nil, _config) do
      OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:error))
      :ok
    end

    def set_status(span, :error, message, _config) do
      OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:error, message))
      :ok
    end

    @impl true
    def end_span(span, _config) do
      OpenTelemetry.Span.end_span(span)
      :ok
    end

    @impl true
    def start_child_span(parent, name, attributes, opts, _config) do
      ctx = OpenTelemetry.Tracer.set_current_span(OpenTelemetry.Ctx.get_current(), parent)

      span_opts =
        case Map.get(opts, :start_time) do
          nil ->
            %{kind: Map.get(opts, :kind, :internal), attributes: attributes}

          start_time ->
            %{
              kind: Map.get(opts, :kind, :internal),
              attributes: attributes,
              start_time: start_time
            }
        end

      :otel_tracer.start_span(ctx, tracer(), name, span_opts)
    end

    @impl true
    def end_span_at(span, end_time, _config) when is_integer(end_time) do
      :otel_span.end_span(span, end_time)
      :ok
    end

    @impl true
    defdelegate metrics_available?(), to: ReqLLM.OpenTelemetry.OTelAdapter

    @impl true
    defdelegate record_histogram(record, config), to: ReqLLM.OpenTelemetry.OTelAdapter

    defp tracer, do: :opentelemetry.get_application_tracer(__MODULE__)

    defp span_kind(config), do: Keyword.get(config, :span_kind, :internal)
  else
    @impl true
    def available?, do: false

    @impl true
    def start_span(_name, _attributes, _config), do: nil

    @impl true
    def set_attributes(_span, _attributes, _config), do: :ok

    @impl true
    def add_event(_span, _name, _attributes, _config), do: :ok

    @impl true
    def set_status(_span, _status, _message, _config), do: :ok

    @impl true
    def end_span(_span, _config), do: :ok

    @impl true
    def metrics_available?, do: false

    @impl true
    def record_histogram(_record, _config), do: :ok

    @impl true
    def start_child_span(_parent, _name, _attributes, _opts, _config), do: nil

    @impl true
    def end_span_at(_span, _end_time, _config), do: :ok
  end
end
