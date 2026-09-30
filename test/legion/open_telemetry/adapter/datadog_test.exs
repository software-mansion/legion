defmodule Legion.OpenTelemetry.Adapter.DatadogTest do
  @moduledoc """
  The exporter config `Legion.OpenTelemetry.Adapter.Datadog` hands to
  `Legion.OpenTelemetry.Exporter`.
  """

  use ExUnit.Case, async: true

  alias Legion.OpenTelemetry.Adapter.Datadog

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
end
