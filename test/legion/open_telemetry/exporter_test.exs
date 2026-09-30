defmodule Legion.OpenTelemetry.ExporterTest do
  @moduledoc """
  `Legion.OpenTelemetry.Exporter` building the OTLP exporter from the vendor
  adapter named in `config :legion, Legion.OpenTelemetry`.
  """

  use ExUnit.Case, async: false
  use Mimic

  alias Legion.OpenTelemetry.Adapter.{Braintrust, Datadog}
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

  # Where and with which headers the OTLP exporter posts traces, read from the
  # state it was initialized with.
  defp export_target({:ok, %{inner: inner}}) do
    fields = Tuple.to_list(inner)
    [endpoint | _] = Enum.find(fields, &(is_list(&1) and &1 != [] and is_map(hd(&1))))
    url = endpoint |> Map.take([:scheme, :host, :port, :path]) |> :uri_string.normalize()

    headers =
      fields
      |> Enum.find(&(is_list(&1) and &1 != [] and match?({_, _}, hd(&1))))
      |> Enum.map(fn {name, value} -> {to_string(name), to_string(value)} end)

    {to_string(url), headers}
  end

  describe "init/1" do
    test "sends Datadog traces to the site's intake with the API key" do
      configure_vendor(Datadog, api_key: "key", site: "datadoghq.eu", ml_app: "my-app")

      {url, headers} = export_target(Exporter.init([]))

      assert url == "https://otlp.datadoghq.eu/v1/traces"
      assert {"dd-api-key", "key"} in headers
      assert {"dd-otlp-source", "llmobs"} in headers
    end

    test "sends Braintrust traces to the region's data plane with the key and project" do
      configure_vendor(Braintrust, api_key: "key", project: "my-app", region: :eu)

      {url, headers} = export_target(Exporter.init([]))

      assert url == "https://api-eu.braintrust.dev/otel/v1/traces"
      assert {"authorization", "Bearer key"} in headers
      assert {"x-bt-parent", "project_name:my-app"} in headers
    end
  end

  describe "export/3" do
    test "exports the spans with the vendor's resource attributes over the SDK's" do
      configure_vendor(Datadog, api_key: "key", ml_app: "my-app")
      test_pid = self()

      stub(:opentelemetry_exporter, :export, fn tab, resource, _inner ->
        send(test_pid, {:exported, tab, resource})
        :ok
      end)

      {:ok, state} = Exporter.init([])
      sdk_resource = :otel_resource.create(%{"service.name" => "sdk-name", "host.name" => "h1"})

      assert Exporter.export(:spans_tab, sdk_resource, state) == :ok

      assert_receive {:exported, :spans_tab, resource}
      attributes = resource |> :otel_resource.attributes() |> :otel_attributes.map()
      assert attributes[:"service.name"] == "my-app"
      assert attributes[:"host.name"] == "h1"
    end
  end
end
