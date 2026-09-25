defmodule Legion.OpenTelemetry do
  @moduledoc """
  OpenTelemetry integration for Legion.

  `attach/1` wires Legion's LLM traffic into the host's OpenTelemetry pipeline
  in one call: it attaches `ReqLLM.OpenTelemetry` under Legion's own handler id
  so every LLM request becomes a GenAI `chat` span, forwards the content setting
  and vendor adapter, and tags each span with `gen_ai.conversation.id` = the
  agent id. `Legion.call/3` and `Legion.cast/2` carry the caller's OpenTelemetry
  context into the agent process, so `chat` spans nest under the host's own
  request or job span.

  Exporting is the host's job: add `opentelemetry` and `opentelemetry_exporter`
  and configure the OTLP endpoint (see the Observability guide). Legion only
  depends on `opentelemetry_api`, optionally; without it `attach/1` returns
  `{:error, :opentelemetry_unavailable}`.

  ## Options

    * `:adapter` - a `Legion.OpenTelemetry.Adapter` module. Defaults to
      `Legion.OpenTelemetry.OTelAdapter`.
    * `:content` - `:none` (default) records no message content;
      `:attributes` puts messages, system instructions and tool definitions on
      the `chat` spans as `gen_ai.*` attributes. Also turns on
      `config :req_llm, telemetry: [payloads: :raw]` unless the host configured
      `:payloads` itself.
    * `:req_llm` - extra options for `ReqLLM.OpenTelemetry.attach/2`, e.g.
      `[langfuse: true]` or `[adapter: MyApp.ReqLLMAdapter]` (which replaces
      `Legion.OpenTelemetry.ReqLLM`). `false` leaves ReqLLM alone, for hosts
      that attach `ReqLLM.OpenTelemetry` themselves.

  ## Example

      # application.ex
      :ok = Legion.OpenTelemetry.attach(content: :attributes)
  """

  @req_llm_handler_id "legion-req-llm-otel"
  @config_key {__MODULE__, :config}

  @schema NimbleOptions.new!(
            adapter: [
              type: :atom,
              default: Legion.OpenTelemetry.OTelAdapter,
              doc: "`Legion.OpenTelemetry.Adapter` implementation."
            ],
            content: [
              type: {:in, [:none, :attributes]},
              default: :none,
              doc: "Message content capture: `:none` or `:attributes`."
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

  Returns `{:error, :opentelemetry_unavailable}` when the adapter reports the
  OpenTelemetry API missing, and `{:error, :already_exists}` when already
  attached. Raises `NimbleOptions.ValidationError` on unknown options.
  """
  @spec attach(keyword()) :: :ok | {:error, :already_exists | :opentelemetry_unavailable}
  def attach(opts \\ []) do
    config = NimbleOptions.validate!(opts, @schema)

    cond do
      not config[:adapter].available?() ->
        {:error, :opentelemetry_unavailable}

      config() != nil ->
        {:error, :already_exists}

      true ->
        config =
          Keyword.put(config, :req_llm_telemetry_env, Application.get_env(:req_llm, :telemetry))

        :persistent_term.put(@config_key, config)

        case attach_req_llm(config) do
          :ok ->
            :ok

          {:error, _} = error ->
            :persistent_term.erase(@config_key)
            error
        end
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
