defmodule Legion.OpenTelemetry.Adapter do
  @moduledoc """
  Behaviour `Legion.OpenTelemetry` uses to talk to a tracer.

  The callbacks mirror `ReqLLM.OpenTelemetry.Adapter` one-to-one, so a single
  host module can implement both behaviours and serve Legion's spans and
  ReqLLM's `chat` spans alike. `Legion.OpenTelemetry.OTelAdapter` is the default
  implementation, backed by the OpenTelemetry API.

  Every callback receives the `config` keyword: the options given to
  `Legion.OpenTelemetry.attach/1` plus `:span_kind` (`:client` for ReqLLM
  spans forwarded through Legion, `:internal` for Legion's own spans).

  Adapters are pure lifecycle shims: `start_span/3` starts a span as a child of
  the calling process's current OpenTelemetry context and must **not** make it
  current; `end_span/2` ends it. Attribute keys arrive as atoms
  (`:"gen_ai.request.model"`), matching ReqLLM's bridge.

  ## Example - copy message content into vendor-specific attributes

      defmodule MyApp.OTelAdapter do
        @behaviour Legion.OpenTelemetry.Adapter

        alias Legion.OpenTelemetry.OTelAdapter

        defdelegate available?(), to: OTelAdapter
        defdelegate add_event(span, name, attrs, config), to: OTelAdapter
        defdelegate set_status(span, kind, message, config), to: OTelAdapter
        defdelegate end_span(span, config), to: OTelAdapter
        defdelegate metrics_available?(), to: OTelAdapter
        defdelegate record_histogram(record, config), to: OTelAdapter
        defdelegate start_child_span(parent, name, attrs, opts, config), to: OTelAdapter
        defdelegate end_span_at(span, end_time, config), to: OTelAdapter

        def start_span(name, attrs, config),
          do: OTelAdapter.start_span(name, with_copies(attrs), config)

        def set_attributes(span, attrs, config),
          do: OTelAdapter.set_attributes(span, with_copies(attrs), config)

        defp with_copies(%{"gen_ai.input.messages": input} = attrs),
          do: Map.put(attrs, :"braintrust.input_json", Jason.encode!(input))

        defp with_copies(attrs), do: attrs
      end

      Legion.OpenTelemetry.attach(adapter: MyApp.OTelAdapter, content: :attributes)
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
  @callback start_child_span(
              parent :: term(),
              name :: String.t(),
              attributes :: map(),
              opts :: %{optional(:kind) => atom(), optional(:start_time) => integer()},
              config :: keyword()
            ) :: term()
  @callback end_span_at(span :: term(), end_time :: integer(), config :: keyword()) :: :ok

  @optional_callbacks metrics_available?: 0,
                      record_histogram: 2,
                      start_child_span: 5,
                      end_span_at: 3
end
