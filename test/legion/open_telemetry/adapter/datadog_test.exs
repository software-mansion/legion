defmodule Legion.OpenTelemetry.Adapter.DatadogTest do
  @moduledoc """
  The exporter config `Legion.OpenTelemetry.Adapter.Datadog` hands to
  `Legion.OpenTelemetry.Exporter`, and the session it gives spans.
  """

  # The span test swaps the SDK's global exporter.
  use ExUnit.Case, async: false

  require Record

  alias Legion.OpenTelemetry.Adapter.Datadog

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  describe "exporter_config/1" do
    test "points the OTLP exporter at the site's intake and names the ML app" do
      assert Datadog.exporter_config(api_key: "key", site: "datadoghq.eu", ml_app: "my_app") == %{
               exporter: %{
                 protocol: :http_protobuf,
                 endpoints: ["https://otlp.datadoghq.eu"],
                 headers: [{"dd-api-key", "key"}, {"dd-otlp-source", "llmobs"}]
               },
               resource: %{"service.name" => "my_app"}
             }
    end

    test "defaults to the US1 site" do
      config = Datadog.exporter_config(api_key: "key", ml_app: "my_app")
      assert config.exporter.endpoints == ["https://otlp.datadoghq.com"]
    end

    test "requires an API key and an ML app" do
      assert_raise NimbleOptions.ValidationError, fn -> Datadog.exporter_config(ml_app: "a") end
      assert_raise NimbleOptions.ValidationError, fn -> Datadog.exporter_config(api_key: "k") end
    end
  end

  describe "spans" do
    test "are grouped by the session, not by a sub-agent's own conversation" do
      :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
      config = [span_kind: :internal]

      span =
        Datadog.start_span(
          "invoke_agent Sub",
          %{"session.id": "top", "gen_ai.conversation.id": "sub"},
          config
        )

      Datadog.end_span(span, config)

      assert_receive {:span, span(name: "invoke_agent Sub", attributes: attributes)}
      assert :otel_attributes.map(attributes)[:"gen_ai.conversation.id"] == "top"
    end
  end
end
