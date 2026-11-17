defmodule Legion.OpenTelemetry.ExporterTest do
  @moduledoc """
  `Legion.OpenTelemetry.Exporter` building the OTLP exporter from the vendor
  adapter named in `config :legion, Legion.OpenTelemetry`.
  """

  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog
  import Legion.Test.Support.Env, only: [put_env: 3, put_system_env: 2]

  alias Legion.OpenTelemetry.Exporter

  # Names `adapter` as the vendor in `config :legion` for one test.
  defp configure_vendor(adapter, opts) do
    put_env(:legion, Legion.OpenTelemetry, adapter: adapter, vendor: opts)
  end

  describe "init/1" do
    test "exports nothing when an endpoint override would receive the vendor's headers" do
      configure_vendor(:datadog, api_key: "key", ml_app: "my-app")
      put_system_env("OTEL_EXPORTER_OTLP_ENDPOINT", "https://collector.example.com")

      capture_log(fn -> assert Exporter.init([]) == :ignore end)
    end

    test "exports nothing when the OTLP exporter rejects the vendor's options" do
      configure_vendor(:datadog, api_key: "key", ml_app: "my-app")
      stub(:opentelemetry_exporter, :init, fn _config -> {:error, :badarg} end)

      log = capture_log(fn -> assert Exporter.init([]) == :ignore end)

      assert log =~ "opentelemetry_exporter rejected the vendor's exporter options"
    end
  end

  describe "export/3" do
    test "exports the spans to the vendor with its resource attributes over the SDK's" do
      configure_vendor(:datadog, api_key: "key", ml_app: "my-app")
      test_pid = self()

      stub(:opentelemetry_exporter, :init, fn config ->
        send(test_pid, {:init, config})
        {:ok, :inner}
      end)

      stub(:opentelemetry_exporter, :export, fn tab, resource, :inner ->
        send(test_pid, {:exported, tab, resource})
        :ok
      end)

      {:ok, state} = Exporter.init([])

      assert_receive {:init,
                      %{
                        endpoints: ["https://otlp.datadoghq.com"],
                        headers: [{"dd-api-key", "key"} | _]
                      }}

      sdk_resource = :otel_resource.create(%{"service.name" => "sdk-name", "host.name" => "h1"})

      assert Exporter.export(:spans_tab, sdk_resource, state) == :ok

      assert_receive {:exported, :spans_tab, resource}
      attributes = resource |> :otel_resource.attributes() |> :otel_attributes.map()
      assert attributes[:"service.name"] == "my-app"
      assert attributes[:"host.name"] == "h1"
    end
  end
end
