defmodule Legion.OpenTelemetry.Adapter do
  @moduledoc """
  Behaviour `Legion.OpenTelemetry` uses to talk to a tracer.

  `Legion.OpenTelemetry.Adapter.OTel` is the default implementation, backed by
  the OpenTelemetry API. Write your own to change what reaches the tracer.

  Every callback receives the `config` keyword: the options given to
  `Legion.OpenTelemetry.attach/1` plus `:span_kind` (`:client` for LLM call
  spans, `:internal` for Legion's own spans).

  Adapters are pure lifecycle shims: `start_span/3` starts a span as a child of
  the calling process's current OpenTelemetry context and must **not** make it
  current; `end_span/2` ends it. Attribute keys arrive as atoms
  (`:"gen_ai.request.model"`).

  Metrics are optional: `record_histogram/2` takes a histogram record
  (`:name`, `:value`, `:unit`, `:description`, `:boundaries`, `:attributes`),
  and `record_counter/2` adds `:value` to a counter (the same fields, with
  `kind: :counter` and no `:boundaries`). An adapter without
  `record_counter/2` gets histograms only.

  A vendor adapter also implements `exporter_config/1`, which turns the
  vendor's settings from `config :legion, <adapter module>` into the OTLP
  endpoint, headers and resource attributes `Legion.OpenTelemetry.Exporter`
  sends spans with. It is chosen in config, where both
  `Legion.OpenTelemetry.attach/1` and the exporter read it:
  `config :legion, Legion.OpenTelemetry, adapter: MyApp.VendorAdapter`.

  ## Example - tag every span with the deployment environment

      defmodule MyApp.OTelAdapter do
        @behaviour Legion.OpenTelemetry.Adapter

        alias Legion.OpenTelemetry.Adapter.OTel

        defdelegate available?(), to: OTel
        defdelegate add_event(span, name, attrs, config), to: OTel
        defdelegate set_status(span, kind, message, config), to: OTel
        defdelegate end_span(span, config), to: OTel
        defdelegate metrics_available?(), to: OTel
        defdelegate record_histogram(record, config), to: OTel
        defdelegate record_counter(record, config), to: OTel
        defdelegate start_child_span(parent, name, attrs, opts, config), to: OTel
        defdelegate end_span_at(span, end_time, config), to: OTel

        defdelegate set_attributes(span, attrs, config), to: OTel

        def start_span(name, attrs, config) do
          attrs = Map.put(attrs, :"deployment.environment.name", "production")
          OTel.start_span(name, attrs, config)
        end
      end

      Legion.OpenTelemetry.attach(adapter: MyApp.OTelAdapter)
  """

  @callback available?() :: boolean()
  @callback start_span(name :: String.t(), attributes :: map(), config :: keyword()) :: term()
  @callback set_attributes(span :: term(), attributes :: map(), config :: keyword()) :: :ok
  @callback add_event(
              span :: term(),
              name :: atom() | String.t(),
              attributes :: map(),
              config :: keyword()
            ) :: :ok
  @callback set_status(
              span :: term(),
              status :: :ok | :error,
              message :: String.t() | nil,
              config :: keyword()
            ) :: :ok
  @callback end_span(span :: term(), config :: keyword()) :: :ok

  @callback metrics_available?() :: boolean()
  @callback record_histogram(record :: map(), config :: keyword()) :: :ok
  @callback record_counter(record :: map(), config :: keyword()) :: :ok
  @callback start_child_span(
              parent :: term(),
              name :: String.t(),
              attributes :: map(),
              opts :: %{optional(:kind) => atom(), optional(:start_time) => integer()},
              config :: keyword()
            ) :: term()
  @callback end_span_at(span :: term(), end_time :: integer(), config :: keyword()) :: :ok

  @doc """
  How to export spans to the adapter's vendor, built from the vendor settings
  in `opts` (raising on invalid ones): `:exporter` is the options map for
  `opentelemetry_exporter` (`:protocol`, `:endpoints`, `:headers`; the
  exporter appends `/v1/traces` to the endpoint), and `:resource` holds
  resource attributes that override the SDK's, e.g. `%{"service.name" => "my-app"}`.
  """
  @callback exporter_config(opts :: keyword()) :: %{exporter: map(), resource: map()}

  @optional_callbacks metrics_available?: 0,
                      record_histogram: 2,
                      record_counter: 2,
                      start_child_span: 5,
                      end_span_at: 3,
                      exporter_config: 1
end
