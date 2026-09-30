defmodule Legion.OpenTelemetry.Adapter.Datadog do
  @exporter_schema NimbleOptions.new!(
                     api_key: [type: :string, required: true, doc: "Datadog API key."],
                     site: [
                       type: :string,
                       default: "datadoghq.com",
                       doc: "Datadog site, e.g. `\"datadoghq.eu\"`."
                     ],
                     ml_app: [
                       type: :string,
                       required: true,
                       doc: "ML app the spans are listed under; sets the `service.name` resource."
                     ]
                   )

  @moduledoc """
  `Legion.OpenTelemetry.Adapter` for Datadog LLM Observability.

  Datadog reads Legion's spans as they are: `invoke_agent`, `execute_tool` and
  `chat` show their input and output from the `gen_ai.*` message attributes,
  and `legion.*` attributes appear as tags. Datadog groups spans into sessions
  by `gen_ai.conversation.id`, so this adapter sets it to Legion's `session.id`:
  the conversation with the top agent, which the sub-agents its turns call
  share. A sub-agent keeps its own id in `gen_ai.agent.id`. Otherwise the spans
  go through `Legion.OpenTelemetry.Adapter.OTel` unchanged; the adapter also
  adds the export to Datadog, through `Legion.OpenTelemetry.Exporter`:

      # config/runtime.exs
      if config_env() == :prod do
        config :opentelemetry, traces_exporter: {Legion.OpenTelemetry.Exporter, []}
        config :legion, Legion.OpenTelemetry, adapter: Legion.OpenTelemetry.Adapter.Datadog

        config :legion, Legion.OpenTelemetry.Adapter.Datadog,
          api_key: System.fetch_env!("DD_API_KEY"),
          site: "datadoghq.eu",
          ml_app: "my-app"
      end

      # application.ex
      :ok = Legion.OpenTelemetry.attach()

  Spans go straight to Datadog's OTLP intake at `https://otlp.<site>/v1/traces`,
  with no Datadog Agent in between, listed under `ml_app`, which becomes the
  `service.name` resource attribute.

  ## Options

  #{NimbleOptions.docs(@exporter_schema)}
  """

  @behaviour Legion.OpenTelemetry.Adapter

  @impl true
  def span_attributes(attributes), do: with_session(attributes)

  @impl true
  def exporter_config(opts) do
    opts = NimbleOptions.validate!(opts, @exporter_schema)

    %{
      exporter: %{
        protocol: :http_protobuf,
        # A base URL: the exporter appends `/v1/traces`.
        endpoints: ["https://otlp.#{opts[:site]}"],
        headers: [{"dd-api-key", opts[:api_key]}, {"dd-otlp-source", "llmobs"}]
      },
      # Datadog lists spans under the ML app named by `service.name`.
      resource: %{"service.name" => opts[:ml_app]}
    }
  end

  # Datadog groups spans into sessions by `gen_ai.conversation.id`. A
  # sub-agent's spans carry its own conversation id and sit in the caller's
  # trace, so they would open an empty session; `session.id` is the
  # conversation the sub-agents of a turn share. ReqLLM's `chat` spans set the
  # id under a string key, Legion's under an atom one.
  defp with_session(%{"session.id": session} = attributes) when is_binary(session) do
    attributes
    |> Map.delete("gen_ai.conversation.id")
    |> Map.put(:"gen_ai.conversation.id", session)
  end

  defp with_session(attributes), do: attributes
end
