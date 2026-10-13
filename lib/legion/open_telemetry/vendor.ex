defmodule Legion.OpenTelemetry.Vendor do
  @moduledoc false

  # The vendor `Legion.OpenTelemetry.Exporter` sends spans to: the `:adapter`
  # of `config :legion, Legion.OpenTelemetry` when it has exporter config, with
  # that config's `:vendor` options. Read by `attach/1`, which checks the setup
  # up front, and by the exporter, which the SDK starts from config alone.

  alias Legion.OpenTelemetry.Adapter

  @endpoint_override [
    {"OTEL_EXPORTER_OTLP_ENDPOINT", :otlp_endpoint},
    {"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", :otlp_traces_endpoint}
  ]

  @headers_override [
    {"OTEL_EXPORTER_OTLP_HEADERS", :otlp_headers},
    {"OTEL_EXPORTER_OTLP_TRACES_HEADERS", :otlp_traces_headers}
  ]

  @doc "The adapter a `:adapter` option names, resolving the shorthands."
  @spec module(atom()) :: module()
  def module(:braintrust), do: Adapter.Braintrust
  def module(:datadog), do: Adapter.Datadog
  def module(:otel), do: Adapter.OTel
  def module(adapter), do: adapter

  @doc "The `opentelemetry_exporter` options and resource to export with."
  @spec exporter_config() :: {:ok, map()} | :no_vendor | {:error, String.t()}
  def exporter_config do
    with {:ok, {adapter, opts}} <- vendor(),
         {:ok, config} <- build(adapter, opts),
         :ok <- check_endpoint_override(adapter, config.exporter) do
      {:ok, config}
    end
  end

  @doc "Raises when the vendor in `config` cannot export, naming no values."
  @spec check!(keyword()) :: :ok
  def check!(config) do
    case vendor_in(config) do
      {:ok, {adapter, opts}} ->
        check_exporter!(adapter, opts)
        check_deps!(adapter)
        check_traces_exporter!(adapter)

      _no_vendor ->
        check_vendor_adapter!(config)
    end
  end

  defp check_vendor_adapter!(config) do
    if Keyword.get(config, :vendor, []) != [] do
      adapter = config |> Keyword.get(:adapter, Adapter.OTel) |> module()

      raise ArgumentError, """
      config :legion, Legion.OpenTelemetry carries :vendor settings, but its adapter \
      #{inspect(adapter)} has no exporter config, so they are never used. The exporter \
      takes its vendor from config, not from attach/1:

          config :legion, Legion.OpenTelemetry, adapter: :datadog, vendor: [...]
      """
    end

    :ok
  end

  defp vendor do
    config = Application.get_env(:legion, Legion.OpenTelemetry, [])

    if Keyword.keyword?(config),
      do: vendor_in(config),
      else: {:error, "config :legion, Legion.OpenTelemetry must be a keyword list"}
  end

  defp vendor_in(config) do
    adapter = config |> Keyword.get(:adapter, Adapter.OTel) |> module()

    if vendor?(adapter),
      do: {:ok, {adapter, Keyword.get(config, :vendor, [])}},
      else: :no_vendor
  end

  defp vendor?(adapter) do
    is_atom(adapter) and Code.ensure_loaded?(adapter) and
      function_exported?(adapter, :exporter_config, 1)
  end

  defp check_exporter!(adapter, opts) do
    with {:ok, config} <- build(adapter, opts),
         :ok <- check_endpoint_override(adapter, config.exporter) do
      :ok
    else
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp check_deps!(adapter) do
    if not (Code.ensure_loaded?(:opentelemetry_app) and
              Code.ensure_loaded?(:opentelemetry_exporter)) do
      raise ArgumentError, """
      #{inspect(adapter)} exports through the OpenTelemetry SDK and OTLP exporter. \
      Add them to your mix.exs deps:

          {:opentelemetry, "~> 1.5"},
          {:opentelemetry_exporter, "~> 1.8"}
      """
    end
  end

  defp check_traces_exporter!(adapter) do
    case Application.get_env(:opentelemetry, :traces_exporter) do
      {Legion.OpenTelemetry.Exporter, _opts} ->
        :ok

      other ->
        raise ArgumentError, """
        #{inspect(adapter)} is configured, but config :opentelemetry, traces_exporter: is \
        #{exporter_name(other)}. Add it next to the vendor config in config/runtime.exs:

            config :opentelemetry, traces_exporter: {Legion.OpenTelemetry.Exporter, []}
        """
    end
  end

  # Named, not quoted: another exporter's options hold its own credentials.
  defp exporter_name({module, _opts}) when is_atom(module), do: inspect(module)
  defp exporter_name(exporter) when is_atom(exporter), do: inspect(exporter)
  defp exporter_name(_exporter), do: "neither an exporter module nor a tuple"

  # The vendor's exporter config, or an error that names the invalid options
  # without their values, which can be secrets.
  defp build(adapter, opts) do
    {:ok, adapter.exporter_config(opts)}
  rescue
    error -> {:error, "#{inspect(adapter)} options are invalid: " <> redacted(error)}
  end

  defp redacted(%NimbleOptions.ValidationError{key: key, value: value} = error) do
    if is_nil(value),
      do: Exception.message(error),
      else: "invalid value for #{inspect(key)}"
  end

  defp redacted(error), do: "#{inspect(error.__struct__)} raised"

  # `otel_exporter_otlp:update_opts/6` replaces the vendor's endpoints with an
  # override but keeps its headers, which would send them to that host.
  defp check_endpoint_override(adapter, exporter_config) do
    endpoint = override(@endpoint_override)

    if exporter_config[:headers] not in [nil, []] and not is_nil(endpoint) and
         is_nil(override(@headers_override)) do
      {:error,
       "#{inspect(adapter)} authenticates with request headers, and #{endpoint} replaces its " <>
         "endpoint without replacing them, so they would be sent to that host. Unset it, or " <>
         "export through opentelemetry_exporter directly."}
    else
      :ok
    end
  end

  # The source is named, never quoted: an endpoint URL can carry credentials.
  defp override(sources) do
    Enum.find_value(sources, fn {variable, key} ->
      cond do
        System.get_env(variable) ->
          variable

        Application.get_env(:opentelemetry_exporter, key) ->
          "config :opentelemetry_exporter, #{inspect(key)}"

        true ->
          nil
      end
    end)
  end
end
