defmodule Legion.OpenTelemetry.ExporterTest do
  @moduledoc """
  `Legion.OpenTelemetry.Exporter` building the OTLP exporter from the vendor
  adapter named in `config :legion, Legion.OpenTelemetry`.
  """

  use ExUnit.Case, async: false
  use Mimic

  alias Legion.OpenTelemetry.Adapter.Datadog
  alias Legion.OpenTelemetry.Exporter

  # Names `adapter` as the vendor in `config :legion` for one test.
  defp configure_vendor(adapter, opts) do
    put_env(:legion, Legion.OpenTelemetry, adapter: adapter)
    put_env(:legion, adapter, opts)
  end

  # Sets an app env key for one test.
  defp put_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  describe "export/3" do
    test "exports the spans to the vendor with its resource attributes over the SDK's" do
      configure_vendor(Datadog, api_key: "key", ml_app: "my-app")
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
