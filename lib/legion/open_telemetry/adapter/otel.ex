defmodule Legion.OpenTelemetry.Adapter.OTel do
  @moduledoc """
  Default `Legion.OpenTelemetry.Adapter`, backed by the OpenTelemetry API.

  Compiled against `opentelemetry_api` when it is present; without it every
  callback is a no-op and `available?/0` returns `false`, so
  `Legion.OpenTelemetry.attach/1` reports `{:error, :opentelemetry_unavailable}`
  instead of raising. Public so custom adapters can `defdelegate` the callbacks
  they do not override.

  Spans start under the tracer named `legion` with the span kind taken from
  `config[:span_kind]` (`:internal` by default). Metrics go to the meter named
  `legion` and need `opentelemetry_api_experimental` (and an SDK that reads
  it) in the host; without it `metrics_available?/0` returns `false` and
  metrics are skipped.
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

    # The metrics API ships separately (`opentelemetry_api_experimental`) and
    # is not a Legion dependency, so it is called through `apply/3` once
    # `metrics_available?/0` has found it.
    @metrics_api [
      {:opentelemetry_experimental, :get_meter, 1},
      {:otel_meter, :create_histogram, 3},
      {:otel_meter, :create_counter, 3},
      {:otel_meter, :create_updown_counter, 3},
      {:otel_histogram, :record, 5},
      {:otel_counter, :add, 5},
      {:otel_updown_counter, :add, 5}
    ]

    @impl true
    def metrics_available? do
      Enum.all?(@metrics_api, fn {module, function, arity} ->
        Code.ensure_loaded?(module) and function_exported?(module, function, arity)
      end)
    end

    @impl true
    def record_histogram(record, _config) do
      measure(:create_histogram, :otel_histogram, :record, record)
    end

    @impl true
    def record_counter(%{kind: :counter} = record, _config) do
      measure(:create_counter, :otel_counter, :add, record)
    end

    def record_counter(%{kind: :updown_counter} = record, _config) do
      measure(:create_updown_counter, :otel_updown_counter, :add, record)
    end

    # Instrument names and units are atoms in the OpenTelemetry API. Records
    # carry strings, so they are looked up here rather than converted.
    @instrument_names Map.new(
                        [
                          :"gen_ai.client.operation.duration",
                          :"gen_ai.client.token.usage",
                          :"gen_ai.client.operation.time_to_first_chunk",
                          :"gen_ai.client.operation.time_per_output_chunk",
                          :"gen_ai.invoke_agent.duration",
                          :"gen_ai.invoke_agent.inference_calls",
                          :"gen_ai.invoke_agent.tool_calls",
                          :"gen_ai.execute_tool.duration",
                          :"legion.turn.iterations",
                          :"legion.eval.errors",
                          :"legion.llm.retries",
                          :"legion.turn.cancellations",
                          :"legion.rate_limit.exceeded",
                          :"legion.agents.active"
                        ],
                        &{Atom.to_string(&1), &1}
                      )

    @units Map.new(
             [
               :s,
               :"{token}",
               :"{call}",
               :"{iteration}",
               :"{error}",
               :"{retry}",
               :"{turn}",
               :"{agent}"
             ],
             &{Atom.to_string(&1), &1}
           )

    defp measure(create, module, function, record) do
      case instrument_name(record.name) do
        nil ->
          :ok

        name ->
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          meter = apply(:opentelemetry_experimental, :get_meter, [scope()])
          ensure_instrument(meter, create, name, record)
          ctx = OpenTelemetry.Ctx.get_current()
          apply(module, function, [ctx, meter, name, record.value, record.attributes])
          :ok
      end
    end

    defp instrument_name(name) when is_atom(name), do: name
    defp instrument_name(name), do: Map.get(@instrument_names, name)

    # Instruments are created once per name; the SDK records by meter and name.
    defp ensure_instrument(meter, create, name, record) do
      key = {__MODULE__, :instrument, name}

      if :persistent_term.get(key, false) == false do
        apply(:otel_meter, create, [meter, name, instrument_opts(record)])
        :persistent_term.put(key, true)
      end

      :ok
    end

    defp instrument_opts(record) do
      opts = %{description: Map.get(record, :description, ""), unit: unit(record)}

      case Map.get(record, :boundaries, []) do
        [] -> opts
        boundaries -> Map.put(opts, :advisory_params, %{explicit_bucket_boundaries: boundaries})
      end
    end

    defp unit(%{unit: unit}) when is_binary(unit), do: Map.get(@units, unit, :undefined)
    defp unit(%{unit: unit}) when is_atom(unit), do: unit
    defp unit(_record), do: :undefined

    defp scope, do: :opentelemetry.get_application_scope(__MODULE__)

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
    def record_counter(_record, _config), do: :ok

    @impl true
    def start_child_span(_parent, _name, _attributes, _opts, _config), do: nil

    @impl true
    def end_span_at(_span, _end_time, _config), do: :ok
  end
end
