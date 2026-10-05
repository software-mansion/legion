defmodule Legion.OpenTelemetry.Adapter.BraintrustTest do
  @moduledoc """
  Runs the real OpenTelemetry SDK with a pid exporter to check the session id
  `Legion.OpenTelemetry.Adapter.Braintrust` puts on exported spans.
  """

  use ExUnit.Case, async: false
  use Mimic

  setup :set_mimic_global

  @moduletag capture_log: true

  require Record

  alias Legion.OpenTelemetry.Adapter.Braintrust
  alias Legion.Test.Support.{MathAgent, ReqLLMTelemetry}

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  describe "spans" do
    setup do
      :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
      :ok = Legion.OpenTelemetry.attach(adapter: Legion.OpenTelemetry.Adapter.Braintrust)
      on_exit(fn -> Legion.OpenTelemetry.detach() end)

      {:ok, script} =
        Agent.start_link(fn ->
          [
            %{"action" => "eval_and_continue", "code" => "return 1 + 1", "result" => ""},
            %{"action" => "return", "code" => "", "result" => "done"}
          ]
        end)

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema, opts ->
        ReqLLMTelemetry.emit_request("openai:gpt-4o-mini", opts)
        object = Agent.get_and_update(script, fn [next | rest] -> {next, rest} end)
        {:ok, %ReqLLM.Response{id: "t", model: "t", context: nil, object: object, usage: %{}}}
      end)

      {:ok, pid} = Legion.start_link(MathAgent)
      assert {:ok, "done"} = Legion.call(pid, "hi")
      %{agent_id: Legion.get_agent_id(pid)}
    end

    test "every span carries the conversation's session id in braintrust.metadata", %{
      agent_id: agent_id
    } do
      for name <- [
            "invoke_agent Legion.Test.Support.MathAgent",
            "chat gpt-4o-mini",
            "execute_tool sandbox"
          ] do
        assert_receive {:span, span(name: ^name, attributes: {:attributes, _, _, _, attributes})}
        assert Jason.decode!(attributes[:"braintrust.metadata"]) == %{"session_id" => agent_id}
      end
    end
  end

  describe "exporter_config/1" do
    test "sends to the US data plane by default" do
      assert Braintrust.exporter_config(api_key: "key", project: "my_app") == %{
               exporter: %{
                 protocol: :http_protobuf,
                 endpoints: ["https://api.braintrust.dev/otel"],
                 headers: [
                   {"authorization", "Bearer key"},
                   {"x-bt-parent", "project_name:my_app"}
                 ]
               },
               resource: %{}
             }
    end

    test "region: :eu uses the EU data plane" do
      config = Braintrust.exporter_config(api_key: "key", project: "my_app", region: :eu)

      assert config.exporter.endpoints == ["https://api-eu.braintrust.dev/otel"]
    end
  end
end
