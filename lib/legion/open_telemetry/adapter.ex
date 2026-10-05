defmodule Legion.OpenTelemetry.Adapter do
  @moduledoc """
  Behaviour `Legion.OpenTelemetry` uses to shape, trace and export spans.

  Most adapters implement only `span_attributes/1`, and
  `Legion.OpenTelemetry.Adapter.OTel` traces their spans. A vendor adapter
  adds `exporter_config/1`, which `Legion.OpenTelemetry.Exporter` sends spans
  with. An adapter that implements `start_span/3` is its own tracer and
  implements the other tracer callbacks too, which mirror
  `ReqLLM.OpenTelemetry.Adapter`; `start_span/3` must not make the span
  current. Every tracer callback gets the attach options plus `:span_kind`
  (`:internal`, `:client` for `chat`, `:server` for MCP calls). Only
  OpenTelemetry span contexts become current, so nothing nests under a span
  handle of another shape.

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
  The attributes a span starts with, rewritten. Keys are atoms.
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

  @callback start_child_span(
              parent :: term(),
              name :: String.t(),
              attributes :: map(),
              opts :: %{optional(:kind) => atom(), optional(:start_time) => integer()},
              config :: keyword()
            ) :: term()
  @callback end_span_at(span :: term(), end_time :: integer(), config :: keyword()) :: :ok

  @doc """
  The `opentelemetry_exporter` options (`:exporter`) and resource attributes
  (`:resource`) to export to the vendor with, built from its settings.
  Raises on invalid settings.
  """
  @callback exporter_config(opts :: keyword()) :: %{exporter: map(), resource: map()}

  @optional_callbacks span_attributes: 1,
                      available?: 0,
                      start_span: 3,
                      set_attributes: 3,
                      add_event: 4,
                      set_status: 4,
                      end_span: 2,
                      start_child_span: 5,
                      end_span_at: 3,
                      exporter_config: 1
end
