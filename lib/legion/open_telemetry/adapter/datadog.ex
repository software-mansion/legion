defmodule Legion.OpenTelemetry.Adapter.Datadog do
  @exporter_schema NimbleOptions.new!(
                     api_key: [type: :string, required: true, doc: "Datadog API key."],
                     site: [
                       type: :string,
                       default: "datadoghq.com",
                       doc: "Datadog site, e.g. `\"datadoghq.eu\"`."
                     ],
                     ml_app: [
                       type: :string,
                       required: true,
                       doc: "ML app the spans are listed under; sets the `service.name` resource."
                     ]
                   )

  @moduledoc """
  `Legion.OpenTelemetry.Adapter` for Datadog LLM Observability.

  Datadog reads Legion's spans as they are: `invoke_agent`, `execute_tool` and
  `chat` show their input and output from the `gen_ai.*` message attributes,
  and `legion.*` attributes appear as tags. The spans go through
  `Legion.OpenTelemetry.Adapter.OTel` unchanged; what this adapter adds is the
  exporter config for `Legion.OpenTelemetry.configure/2`:

      # config/runtime.exs
      Legion.OpenTelemetry.configure(Legion.OpenTelemetry.Adapter.Datadog,
        api_key: System.fetch_env!("DD_API_KEY"),
        site: "datadoghq.eu",
        ml_app: "my_app"
      )

      # application.ex
      :ok = Legion.OpenTelemetry.attach(content: :attributes)

  Spans go straight to Datadog's OTLP intake at `https://otlp.<site>`, with
  no Datadog Agent in between.

  ## Options

  #{NimbleOptions.docs(@exporter_schema)}
  """

  @behaviour Legion.OpenTelemetry.Adapter

  alias Legion.OpenTelemetry.Adapter.OTel

  @impl true
  defdelegate available?(), to: OTel

  @impl true
  defdelegate start_span(name, attributes, config), to: OTel

  @impl true
  defdelegate set_attributes(span, attributes, config), to: OTel

  @impl true
  defdelegate add_event(span, name, attributes, config), to: OTel

  @impl true
  defdelegate set_status(span, status, message, config), to: OTel

  @impl true
  defdelegate end_span(span, config), to: OTel

  @impl true
  defdelegate start_child_span(parent, name, attributes, opts, config), to: OTel

  @impl true
  defdelegate end_span_at(span, end_time, config), to: OTel

  @impl true
  defdelegate metrics_available?(), to: OTel

  @impl true
  defdelegate record_histogram(record, config), to: OTel

  @impl true
  defdelegate record_counter(record, config), to: OTel

  @impl true
  def exporter_config(opts) do
    opts = NimbleOptions.validate!(opts, @exporter_schema)

    [
      opentelemetry: [traces_exporter: :otlp, resource: [service: [name: opts[:ml_app]]]],
      opentelemetry_exporter: [
        otlp_protocol: :http_protobuf,
        # A base URL: the exporter appends `/v1/traces`.
        otlp_endpoint: "https://otlp.#{opts[:site]}",
        otlp_headers: [{"dd-api-key", opts[:api_key]}, {"dd-otlp-source", "llmobs"}]
      ]
    ]
  end
end
