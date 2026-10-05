defmodule Legion.OpenTelemetry.Adapter.Braintrust do
  @exporter_schema NimbleOptions.new!(
                     api_key: [type: :string, required: true, doc: "Braintrust API key."],
                     project: [
                       type: :string,
                       required: true,
                       doc: "Braintrust project the traces are logged to."
                     ],
                     region: [
                       type: {:in, [:us, :eu]},
                       default: :us,
                       doc: "Data plane of the organization: `:us` or `:eu`."
                     ]
                   )

  @endpoints %{
    us: "https://api.braintrust.dev/otel",
    eu: "https://api-eu.braintrust.dev/otel"
  }

  @moduledoc """
  `Legion.OpenTelemetry.Adapter` for Braintrust. Exports to the project and
  adds `braintrust.metadata` with Legion's `session.id` as `session_id` to
  every span, so grouping the logs by `session_id` shows a conversation in
  Thread view.

      # config/runtime.exs
      if config_env() == :prod do
        config :opentelemetry, traces_exporter: {Legion.OpenTelemetry.Exporter, []}
        config :legion, Legion.OpenTelemetry, adapter: Legion.OpenTelemetry.Adapter.Braintrust

        config :legion, Legion.OpenTelemetry.Adapter.Braintrust,
          api_key: System.fetch_env!("BRAINTRUST_API_KEY"),
          project: "my_app",
          region: :eu
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
        endpoints: [Map.fetch!(@endpoints, opts[:region])],
        headers: [
          {"authorization", "Bearer " <> opts[:api_key]},
          {"x-bt-parent", "project_name:" <> opts[:project]}
        ]
      },
      resource: %{}
    }
  end

  defp with_session(%{"session.id": session} = attributes) when is_binary(session),
    do: Map.put(attributes, :"braintrust.metadata", Jason.encode!(%{"session_id" => session}))

  defp with_session(attributes), do: attributes
end
