defmodule Legion.OpenTelemetry do
  @moduledoc """
  Turns Legion's work into OpenTelemetry traces: an `invoke_agent <agent>`
  span per turn, an `execute_tool sandbox` span per code evaluation, and
  ReqLLM's `chat` spans, which Legion attaches under its own handler. See the
  Observability guide for the trace shape and vendor setup.

  Legion only depends on `opentelemetry_api`, optionally; without it
  `attach/1` returns `{:error, :opentelemetry_unavailable}`. Options can also
  be set in `config :legion, Legion.OpenTelemetry`; options given to
  `attach/1` win.

  > #### Message content is recorded by default {: .warning}
  >
  > Unlike `ReqLLM.OpenTelemetry`, Legion defaults to `content: :attributes`,
  > so prompts, replies, generated code and tool results reach the tracing
  > backend. Attach with `content: :none` to keep them out.

  ## Options

    * `:adapter` - a `Legion.OpenTelemetry.Adapter`. Defaults to
      `Legion.OpenTelemetry.Adapter.OTel`. `Legion.OpenTelemetry.Exporter`
      always exports to the vendor adapter named in config.
    * `:content` - `:attributes` (default) records message content, `:none`
      leaves it out, and a failed span's status then names only its
      `error.type`.
    * `:max_attribute_bytes` - longest content attribute on Legion's own spans,
      cut on a UTF-8 boundary. Defaults to `20_000`.
    * `:iteration_spans` - `true` adds an `iteration N` span per executor
      iteration. Defaults to `false`.
    * `:conversation_traces` - `true` puts an agent's turns in one trace under
      a `conversation <agent>` root span. Defaults to `false`.
    * `:req_llm` - extra options for `ReqLLM.OpenTelemetry.attach/2`, or
      `false` for hosts that attach it themselves.

  ## Example

      # application.ex
      :ok = Legion.OpenTelemetry.attach()
  """

  require Logger

  alias Legion.OpenTelemetry.Handler

  @req_llm_handler_id "legion-req-llm-otel"
  @config_key {__MODULE__, :config}

  @schema NimbleOptions.new!(
            adapter: [
              type: :atom,
              default: Legion.OpenTelemetry.Adapter.OTel,
              doc: "`Legion.OpenTelemetry.Adapter` implementation."
            ],
            content: [
              type: {:in, [:none, :attributes]},
              default: :attributes,
              doc: "Message content capture: `:attributes` or `:none`."
            ],
            max_attribute_bytes: [
              type: :pos_integer,
              default: 20_000,
              doc: "Longest content attribute, in bytes."
            ],
            iteration_spans: [
              type: :boolean,
              default: false,
              doc: "Add an `iteration N` span per executor iteration."
            ],
            conversation_traces: [
              type: :boolean,
              default: false,
              doc: "Put an agent's turns in one trace under a `conversation` span."
            ],
            req_llm: [
              type: {:or, [:keyword_list, {:in, [false]}]},
              default: [],
              doc: "Options passed through to `ReqLLM.OpenTelemetry.attach/2`, or `false`."
            ]
          )

  @doc """
  Returns the handler id Legion attaches `ReqLLM.OpenTelemetry` under.
  """
  @spec req_llm_handler_id() :: String.t()
  def req_llm_handler_id, do: @req_llm_handler_id

  @doc false
  # The vendor Legion.OpenTelemetry.Exporter sends spans to: the `:adapter` of
  # `config :legion, Legion.OpenTelemetry` when it has exporter config, with
  # the options under its own key, `config :legion, <adapter>`. Shared by
  # `attach/1` and the exporter, which the SDK starts from config alone.
  @spec vendor() :: {:ok, nil | {module(), term()}} | {:error, String.t()}
  def vendor do
    config = Application.get_env(:legion, __MODULE__, [])

    if Keyword.keyword?(config),
      do: {:ok, vendor_in(config)},
      else: {:error, "config :legion, Legion.OpenTelemetry must be a keyword list"}
  end

  defp vendor_in(config) do
    adapter = Keyword.get(config, :adapter, Legion.OpenTelemetry.Adapter.OTel)
    if exporter_config?(adapter), do: {adapter, Application.get_env(:legion, adapter, [])}
  end

  defp exporter_config?(adapter) do
    is_atom(adapter) and Code.ensure_loaded?(adapter) and
      function_exported?(adapter, :exporter_config, 1)
  end

  @doc """
  Attaches the OpenTelemetry integration. See the module docs for options.

  Safe to call again: the new options replace the earlier attachment. Raises
  on unknown options, and on an incomplete vendor setup in config (naming the
  option, never its value).
  """
  @spec attach(keyword()) :: :ok | {:error, term()}
  def attach(opts \\ []) do
    defaults = Application.get_env(:legion, __MODULE__, [])

    if not Keyword.keyword?(defaults) do
      raise ArgumentError,
            "config :legion, Legion.OpenTelemetry must be a keyword list, got: " <>
              inspect(defaults)
    end

    # The exporter sends to the vendor in config, whatever adapter shapes the
    # spans, so that vendor's setup is checked up front: a misconfiguration
    # fails at boot instead of dropping traces.
    with {adapter, vendor_opts} <- vendor_in(defaults), do: check_vendor!(adapter, vendor_opts)

    config = defaults |> Keyword.merge(opts) |> NimbleOptions.validate!(@schema)
    config = Keyword.put(config, :tracer, tracer(config[:adapter]))

    if config[:tracer].available?() do
      detach()
      do_attach(config)
    else
      {:error, :opentelemetry_unavailable}
    end
  end

  # An adapter without its own `start_span/3` only shapes spans
  # (`span_attributes/1`) or exports them (`exporter_config/1`), and is traced
  # by `Adapter.OTel`.
  defp tracer(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :start_span, 3),
      do: adapter,
      else: Legion.OpenTelemetry.Adapter.OTel
  end

  defp check_vendor!(adapter, vendor_opts) do
    with {:error, message} <- exporter_config(adapter, vendor_opts),
         do: raise(ArgumentError, message)

    if not (Code.ensure_loaded?(:opentelemetry_app) and
              Code.ensure_loaded?(:opentelemetry_exporter)) do
      raise ArgumentError, """
      #{inspect(adapter)} exports through the OpenTelemetry SDK and OTLP exporter. \
      Add them to your mix.exs deps:

          {:opentelemetry, "~> 1.5"},
          {:opentelemetry_exporter, "~> 1.8"}
      """
    end

    case Application.get_env(:opentelemetry, :traces_exporter) do
      {Legion.OpenTelemetry.Exporter, _opts} ->
        :ok

      other ->
        raise ArgumentError, """
        #{inspect(adapter)} is configured, but config :opentelemetry, traces_exporter: is \
        #{inspect(other)}. Add it next to the vendor config in config/runtime.exs:

            config :opentelemetry, traces_exporter: {Legion.OpenTelemetry.Exporter, []}
        """
    end
  end

  @doc false
  # The vendor's exporter config, or an error that names the invalid options
  # without their values, which can be secrets.
  @spec exporter_config(module(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def exporter_config(adapter, opts) do
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

  @doc false
  # Logs `message` at `level` once per VM, for conditions the SDK or a
  # restart would otherwise report over and over.
  @spec log_once(Logger.level(), String.t()) :: :ok
  def log_once(level, message) do
    key = {__MODULE__, :logged, :erlang.phash2({level, message})}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)
      Logger.log(level, message)
    end

    :ok
  end

  defp do_attach(config) do
    config = Keyword.put(config, :req_llm_content?, req_llm_content?(config))

    :persistent_term.put(@config_key, config)

    with :ok <- Handler.attach(Keyword.put(config, :span_kind, :internal)),
         :ok <- attach_req_llm(config) do
      :ok
    else
      {:error, _} = error ->
        Handler.detach()
        :persistent_term.erase(@config_key)
        error
    end
  end

  @doc """
  Detaches the integration.
  """
  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    case config() do
      nil ->
        {:error, :not_found}

      config ->
        Handler.detach()
        if config[:req_llm] != false, do: ReqLLM.OpenTelemetry.detach(@req_llm_handler_id)
        :persistent_term.erase(@config_key)
        :ok
    end
  end

  @doc """
  Returns the active configuration, or `nil` when not attached.
  """
  @spec config() :: keyword() | nil
  def config, do: :persistent_term.get(@config_key, nil)

  @doc false
  # Whether Legion's ReqLLM handler records message content, which ReqLLM only
  # maps when a call's telemetry payloads are `:raw`.
  @spec req_llm_content?() :: boolean()
  def req_llm_content? do
    case config() do
      nil -> false
      config -> config[:req_llm_content?]
    end
  end

  defp req_llm_content?(config) do
    case config[:req_llm] do
      false ->
        false

      req_llm_opts ->
        Keyword.get(req_llm_opts, :content, config[:content]) not in [nil, :none, false]
    end
  end

  defp attach_req_llm(config) do
    case config[:req_llm] do
      false ->
        :ok

      req_llm_opts ->
        opts =
          Keyword.merge(
            [
              content: config[:content],
              adapter: Legion.OpenTelemetry.ReqLLM,
              legion_adapter: config[:tracer],
              legion_config: config
            ],
            req_llm_opts
          )

        ReqLLM.OpenTelemetry.attach(@req_llm_handler_id, opts)
    end
  end
end
