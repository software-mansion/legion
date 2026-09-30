defmodule Legion.OpenTelemetry.Adapter.DatadogTest do
  @moduledoc """
  The exporter config `Legion.OpenTelemetry.Adapter.Datadog` hands to
  `Legion.OpenTelemetry.configure/2`.
  """

  use ExUnit.Case, async: true

  alias Legion.OpenTelemetry.Adapter.Datadog

  describe "exporter_config/1" do
    test "points the OTLP exporter at the site's intake" do
      assert Datadog.exporter_config(api_key: "key", site: "datadoghq.eu", ml_app: "my_app") == [
               opentelemetry: [traces_exporter: :otlp, resource: [service: [name: "my_app"]]],
               opentelemetry_exporter: [
                 otlp_protocol: :http_protobuf,
                 otlp_endpoint: "https://otlp.datadoghq.eu",
                 otlp_headers: [{"dd-api-key", "key"}, {"dd-otlp-source", "llmobs"}]
               ]
             ]
    end

    test "defaults to the US1 site" do
      config = Datadog.exporter_config(api_key: "key", ml_app: "my_app")
      assert config[:opentelemetry_exporter][:otlp_endpoint] == "https://otlp.datadoghq.com"
    end

    test "requires an API key and an ML app" do
      assert_raise NimbleOptions.ValidationError, fn -> Datadog.exporter_config(ml_app: "a") end
      assert_raise NimbleOptions.ValidationError, fn -> Datadog.exporter_config(api_key: "k") end
    end
  end
end
