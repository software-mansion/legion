defmodule Legion.OpenTelemetry.Adapter.DatadogTest do
  @moduledoc """
  The exporter config `Legion.OpenTelemetry.Adapter.Datadog` hands to
  `Legion.OpenTelemetry.Exporter`, and the session it gives spans.
  """

  # The span test swaps the SDK's global exporter.
  use ExUnit.Case, async: false

  require Record

  alias Legion.OpenTelemetry.Adapter.{Datadog, OTel}

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
  end

  describe "spans" do
    test "are grouped by the session, not by a sub-agent's own conversation" do
      :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
      # `attach/1` loads the adapter; this test calls `OTel` directly.
      Code.ensure_loaded!(Datadog)
      config = [adapter: Datadog, span_kind: :internal]

      span =
        OTel.start_span(
          "invoke_agent Sub",
          %{"session.id": "top", "gen_ai.conversation.id": "sub"},
          config
        )

      OTel.end_span(span, config)

      assert_receive {:span, span(name: "invoke_agent Sub", attributes: attributes)}
      assert :otel_attributes.map(attributes)[:"gen_ai.conversation.id"] == "top"
    end
  end
end
