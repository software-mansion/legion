defmodule Legion.OpenTelemetry do
  @moduledoc """
  OpenTelemetry integration for Legion.

  `attach/1` wires Legion into the host's OpenTelemetry pipeline in one call.
  Each agent turn becomes a GenAI `invoke_agent <agent>` span, each code
  evaluation an `execute_tool sandbox` span under it, and every LLM request a
  `chat` span from `ReqLLM.OpenTelemetry`, which Legion attaches under its own
  handler id with the same content setting and adapter. All of them carry
  `gen_ai.agent.name`, `gen_ai.conversation.id` (the agent id) and
  `session.id` (the id of the agent the conversation is with, shared by the
  sub-agents its turns call).

  The OpenTelemetry context follows the work across processes:
  `Legion.call/3`, `Legion.cast/2`, `Legion.parallel/2` and the sandbox
  process all run under the caller's context, so a sub-agent started from
  tool code nests under the `execute_tool` span that started it, and the whole
  tree nests under the host's own request or job span.

  Retries and eval guard denials are recorded as span events (`legion.retry`,
  `legion.eval_guard.denied`); a cancelled turn sets `legion.status`,
  `legion.cancel.reason` and `error.type`. A rate-limit denial comes before
  the turn starts, so it has no span and only counts in the
  `legion.rate_limit.exceeded` metric.

  Exporting is the host's job: add `opentelemetry` and `opentelemetry_exporter`
  and configure the OTLP endpoint. For Datadog and Braintrust, name the
  vendor's adapter in `config :legion, Legion.OpenTelemetry, adapter: ...`,
  put its settings under `config :legion, <adapter>`, and export through
  `Legion.OpenTelemetry.Exporter` (see the Observability guide). Legion only depends on `opentelemetry_api`, optionally; without it
  `attach/1` returns `{:error, :opentelemetry_unavailable}`.

  Options can also be set in `config :legion, Legion.OpenTelemetry`; options
  given to `attach/1` win.

  ## Options

    * `:adapter` - a `Legion.OpenTelemetry.Adapter` module. Defaults to
      `Legion.OpenTelemetry.Adapter.OTel`. `Legion.OpenTelemetry.Exporter`
      exports to the vendor adapter (one with
      `c:Legion.OpenTelemetry.Adapter.exporter_config/1`) named in
      `config :legion, Legion.OpenTelemetry`; an `:adapter` given to
      `attach/1` only changes how spans are shaped.
    * `:content` - `:attributes` (default) sends message content to the
      tracing backend: prompts, replies, the code the model wrote, tool
      results and error messages. `:none` turns that off. With `:attributes`,
      messages, system instructions and tool definitions go on the `chat`
      spans as `gen_ai.*` attributes. Also turns on
      `config :req_llm, telemetry: [payloads: :raw]` unless the host configured
      `:payloads` itself.
      Legion's own spans then record the user message
      (`gen_ai.input.messages`), the turn's result (`gen_ai.output.messages`)
      and the evaluated code and its result (`gen_ai.tool.call.arguments`,
      `gen_ai.tool.call.result`), a failed span's status carries the error's
      message, and `legion.eval_guard.denied` the guard's reason. With
      `:none` a failed span's status is just its `error.type`, since error
      messages can quote tool data.
    * `:max_attribute_bytes` - longest content attribute on Legion's own
      spans, in bytes; `chat` span content is sent whole. Longer values are
      cut on a UTF-8 boundary and end in `…[truncated]`, and invalid UTF-8 is
      replaced. Results JSON cannot encode are inspected with at most 1,000
      items and each string cut to a quarter of the cap, so they may be
      shortened with `...` before reaching it. Defaults to `20_000`. The hard
      cap on every attribute is the SDK's
      `attribute_value_length_limit` (`OTEL_SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT`),
      which cuts values mid-string, JSON included.
    * `:metrics` - `false` turns off metrics, both Legion's and ReqLLM's.
      Defaults to `true`. Metrics also need the adapter to support them; see
      `Legion.OpenTelemetry.Adapter.OTel`.
    * `:iteration_spans` - `true` adds an `iteration N` span per executor
      iteration between `invoke_agent` and its `chat` and `execute_tool`
      spans. Defaults to `false`; every child span carries `legion.iteration`
      either way.
    * `:conversation_traces` - `true` puts every turn of an agent process in
      one trace, under a `conversation <agent>` root span created on the
      first turn. Only turns called without a current span join it; a
      caller's span always wins. The root span is ended as soon as it starts
      (a trace only shows up once its root is exported), so its duration is
      zero. Defaults to `false`: one trace per turn, the turns of a
      conversation sharing `session.id`, the way vendors group sessions.
    * `:req_llm` - extra options for `ReqLLM.OpenTelemetry.attach/2`, e.g.
      `[langfuse: true]` or `[adapter: MyApp.ReqLLMAdapter]` (which replaces
      `Legion.OpenTelemetry.ReqLLM`). `false` leaves ReqLLM alone, for hosts
      that attach `ReqLLM.OpenTelemetry` themselves.

  ## Example

      # application.ex
      :ok = Legion.OpenTelemetry.attach()

      # or, keeping message content out of traces
      :ok = Legion.OpenTelemetry.attach(content: :none)
  """

  require Logger

  alias Legion.OpenTelemetry.{Handler, Metrics}

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
            metrics: [
              type: :boolean,
              default: true,
              doc: "Record metrics."
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
  They default to `config :legion, Legion.OpenTelemetry`; options given here
  win, `:adapter` included, but `Legion.OpenTelemetry.Exporter` always exports
  to the vendor adapter named in config.

  Safe to call more than once: a second call that succeeds replaces the
  earlier attachment with the new options, so an application restart or a
  code reload never fails on it. Returns `{:error, :opentelemetry_unavailable}`
  when the adapter reports the OpenTelemetry API missing.

  Raises `NimbleOptions.ValidationError` on unknown options, and
  `ArgumentError` when `config :legion, Legion.OpenTelemetry` is not a keyword
  list, or when a vendor adapter is configured and its options under
  `config :legion, <adapter>` are missing or invalid (the message names the
  option, never its value), the SDK and exporter are missing, or
  `config :opentelemetry, traces_exporter:` is not `Legion.OpenTelemetry.Exporter`.
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

    if config[:adapter].available?() do
      detach()
      do_attach(config)
    else
      {:error, :opentelemetry_unavailable}
    end
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
    config =
      Keyword.merge(config,
        metrics?: config[:metrics] and Metrics.available?(config[:adapter]),
        req_llm_telemetry_env: Application.get_env(:req_llm, :telemetry)
      )

    :persistent_term.put(@config_key, config)

    with :ok <- Handler.attach(Keyword.put(config, :span_kind, :internal)),
         :ok <- attach_req_llm(config) do
      :ok
    else
      {:error, _} = error ->
        Handler.detach()
        restore_req_llm_env(config[:req_llm_telemetry_env])
        :persistent_term.erase(@config_key)
        error
    end
  end

  @doc """
  Detaches the integration and restores the `:req_llm` telemetry config
  `attach/1` may have changed.
  """
  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    case config() do
      nil ->
        {:error, :not_found}

      config ->
        Handler.detach()
        if config[:req_llm] != false, do: ReqLLM.OpenTelemetry.detach(@req_llm_handler_id)
        restore_req_llm_env(config[:req_llm_telemetry_env])
        :persistent_term.erase(@config_key)
        :ok
    end
  end

  @doc """
  Returns the active configuration, or `nil` when not attached.
  """
  @spec config() :: keyword() | nil
  def config, do: :persistent_term.get(@config_key, nil)

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
              legion_adapter: config[:adapter],
              legion_config: config
            ],
            req_llm_opts
          )

        if opts[:content] not in [nil, :none, false], do: enable_req_llm_payloads()
        ReqLLM.OpenTelemetry.attach(@req_llm_handler_id, opts)
    end
  end

  # ReqLLM only maps message content when its telemetry payloads are `:raw`;
  # content capture would otherwise be a silent no-op.
  defp enable_req_llm_payloads do
    case Application.get_env(:req_llm, :telemetry, []) do
      env when is_list(env) ->
        unless Keyword.has_key?(env, :payloads),
          do: Application.put_env(:req_llm, :telemetry, Keyword.put(env, :payloads, :raw))

      env when is_map(env) ->
        unless Map.has_key?(env, :payloads) or Map.has_key?(env, "payloads"),
          do: Application.put_env(:req_llm, :telemetry, Map.put(env, :payloads, :raw))

      _ ->
        :ok
    end

    :ok
  end

  defp restore_req_llm_env(nil), do: Application.delete_env(:req_llm, :telemetry)
  defp restore_req_llm_env(env), do: Application.put_env(:req_llm, :telemetry, env)
end
