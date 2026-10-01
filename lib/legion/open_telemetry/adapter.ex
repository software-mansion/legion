defmodule Legion.OpenTelemetry.Adapter do
  @moduledoc """
  Behaviour `Legion.OpenTelemetry` uses to shape, trace and export spans.

  Most adapters only shape spans: `span_attributes/1` rewrites the attributes
  every span starts with, and `Legion.OpenTelemetry.Adapter.OTel` traces them.
  A vendor adapter also implements `exporter_config/1`, which turns the
  vendor's settings from `config :legion, <adapter module>` into the OTLP
  endpoint, headers and resource attributes `Legion.OpenTelemetry.Exporter`
  sends spans with. It is chosen in config, where both
  `Legion.OpenTelemetry.attach/1` and the exporter read it:
  `config :legion, Legion.OpenTelemetry, adapter: MyApp.VendorAdapter`.

  An adapter that implements `start_span/3` is its own tracer instead, and
  implements the tracer callbacks (the ones `ReqLLM.OpenTelemetry.Adapter`
  has, plus the optional `record_counter/2`). Every tracer callback receives
  the `config` keyword: the options given to `Legion.OpenTelemetry.attach/1`
  plus `:span_kind` (`:client` for LLM call spans, `:internal` for Legion's
  own spans). `start_span/3` starts a span as a child of the calling process's
  current OpenTelemetry context and must **not** make it current; `end_span/2`
  ends it. Attribute keys arrive as atoms (`:"gen_ai.request.model"`).

  Metrics are optional for a tracer: `record_histogram/2` takes a histogram
  record (`:name`, `:value`, `:unit`, `:description`, `:boundaries`,
  `:attributes`), and `record_counter/2` adds `:value` to a counter (the same
  fields, with `kind: :counter` and no `:boundaries`). A tracer without
  `record_counter/2` gets histograms only.

  ## Example - tag every span with the deployment environment

      defmodule MyApp.OTelAdapter do
        @behaviour Legion.OpenTelemetry.Adapter

        @impl true
        def span_attributes(attrs),
          do: Map.put(attrs, :"deployment.environment.name", "production")
      end

      Legion.OpenTelemetry.attach(adapter: MyApp.OTelAdapter)
  """

  @doc """
  The attributes a span starts with, rewritten. Applied by
  `Legion.OpenTelemetry.Adapter.OTel` to every span, `chat` spans included;
  keys are atoms, except ones ReqLLM sets under a string key.
  """
  @callback span_attributes(attributes :: map()) :: map()

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

  @optional_callbacks span_attributes: 1,
                      available?: 0,
                      start_span: 3,
                      set_attributes: 3,
                      add_event: 4,
                      set_status: 4,
                      end_span: 2,
                      metrics_available?: 0,
                      record_histogram: 2,
                      record_counter: 2,
                      start_child_span: 5,
                      end_span_at: 3,
                      exporter_config: 1
end
