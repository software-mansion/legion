defmodule Legion.OpenTelemetry.Exporter do
  @moduledoc """
  OpenTelemetry trace exporter that sends spans to the vendor adapter named in
  `config :legion, Legion.OpenTelemetry, adapter: ..., vendor: [...]`, using
  its `c:Legion.OpenTelemetry.Adapter.exporter_config/1`:

      config :opentelemetry, traces_exporter: {Legion.OpenTelemetry.Exporter, []}

  `OTEL_EXPORTER_OTLP_*` variables and `config :opentelemetry_exporter`
  settings still take precedence, and `OTEL_TRACES_EXPORTER` replaces this
  exporter altogether. Without a valid vendor it logs once and
  exports nothing. Needs `opentelemetry` and `opentelemetry_exporter` in the
  host.
  """

  # Implements the SDK's `otel_exporter_traces` behaviour (`init/1`,
  # `export/3`, `shutdown/1`), plus the older `otel_exporter` `export/4`. The
  # SDK and the OTLP exporter belong to the host, which may compile them after
  # Legion, so they are called through `apply/3` rather than referenced at
  # compile time.

  require Logger

  alias Legion.OpenTelemetry.Vendor

  @doc false
  def init(_opts) do
    with {:ok, config} <- Vendor.exporter_config(),
         :ok <- otlp_exporter() do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      {:ok, inner} = apply(:opentelemetry_exporter, :init, [config.exporter])
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      resource = apply(:otel_resource, :create, [config.resource])
      {:ok, %{inner: inner, resource: resource}}
    else
      # With no vendor there is nothing wrong with the exporter itself, only
      # nothing to send to, so it is a warning.
      :no_vendor ->
        log(
          :warning,
          "config :legion, Legion.OpenTelemetry names no adapter with exporter config"
        )

      {:error, message} ->
        log(:error, message)
    end
  end

  @doc false
  def export(tab, resource, %{inner: inner, resource: extra}) do
    # `otel_resource:merge/2` keeps the first resource's value on a collision.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    resource = apply(:otel_resource, :merge, [extra, resource])
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(:opentelemetry_exporter, :export, [tab, resource, inner])
  end

  @doc false
  def export(:traces, tab, resource, state), do: export(tab, resource, state)
  def export(_kind, _data, _resource, _state), do: :ok

  @doc false
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  def shutdown(%{inner: inner}), do: apply(:opentelemetry_exporter, :shutdown, [inner])

  # The SDK calls `init/1` again every few seconds after `:ignore`, so each
  # reason is logged once per VM.
  defp log(level, reason) do
    message = "Legion.OpenTelemetry.Exporter exports nothing: " <> reason
    key = {__MODULE__, :logged, :erlang.phash2({level, message})}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)
      Logger.log(level, message)
    end

    :ignore
  end

  defp otlp_exporter do
    if Code.ensure_loaded?(:opentelemetry_exporter),
      do: :ok,
      else: {:error, "the opentelemetry_exporter dependency is missing"}
  end
end
