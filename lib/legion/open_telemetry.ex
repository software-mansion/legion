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

  Retries, eval guard denials and rate-limit denials are recorded as span
  events (`legion.retry`, `legion.eval_guard.denied`,
  `legion.rate_limit.exceeded`); a cancelled turn sets `legion.status`,
  `legion.cancel.reason` and `error.type`.

  Exporting is the host's job: add `opentelemetry` and `opentelemetry_exporter`
  and configure the OTLP endpoint (see the Observability guide). Legion only
  depends on `opentelemetry_api`, optionally; without it `attach/1` returns
  `{:error, :opentelemetry_unavailable}`.

  ## Options

    * `:adapter` - a `Legion.OpenTelemetry.Adapter` module. Defaults to
      `Legion.OpenTelemetry.Adapter.OTel`.
    * `:content` - `:none` (default) records no message content;
      `:attributes` puts messages, system instructions and tool definitions on
      the `chat` spans as `gen_ai.*` attributes. Also turns on
      `config :req_llm, telemetry: [payloads: :raw]` unless the host configured
      `:payloads` itself.
      Legion's own spans then record the user message
      (`gen_ai.input.messages`), the turn's result (`gen_ai.output.messages`)
      and the evaluated code and its result (`gen_ai.tool.call.arguments`,
      `gen_ai.tool.call.result`).
    * `:max_attribute_bytes` - longest content attribute Legion records, in
      bytes; longer values are cut on a UTF-8 boundary and end in
      `…[truncated]`. Defaults to `20_000`.
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
      :ok = Legion.OpenTelemetry.attach(content: :attributes)
  """

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
              default: :none,
              doc: "Message content capture: `:none` or `:attributes`."
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

  @doc """
  Attaches the OpenTelemetry integration. See the module docs for options.

  Safe to call more than once: a second call replaces the earlier attachment
  with the new options, so an application restart or a code reload never
  fails on it. Returns `{:error, :opentelemetry_unavailable}` when the adapter
  reports the OpenTelemetry API missing. Raises
  `NimbleOptions.ValidationError` on unknown options.
  """
  @spec attach(keyword()) :: :ok | {:error, term()}
  def attach(opts \\ []) do
    config = NimbleOptions.validate!(opts, @schema)

    if config[:adapter].available?() do
      detach()
      do_attach(config)
    else
      {:error, :opentelemetry_unavailable}
    end
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
