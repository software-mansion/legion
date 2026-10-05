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
  `Legion.OpenTelemetry.Adapter` for Datadog LLM Observability. Exports
  straight to Datadog's OTLP intake, listed under `ml_app`, and sets
  `gen_ai.conversation.id` to Legion's `session.id`, so a conversation and
  the sub-agents its turns call are one Datadog session.

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
