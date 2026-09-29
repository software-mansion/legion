defmodule Legion.OpenTelemetry.Adapter.DatadogTest do
  @moduledoc """
  Runs the real OpenTelemetry SDK with a pid exporter to check the attributes
  `Legion.OpenTelemetry.Adapter.Datadog` leaves on exported spans.
  """

  use ExUnit.Case, async: false
  use Mimic

  setup :set_mimic_global

  @moduletag capture_log: true

  require Record

  alias Legion.Test.Support.{MathAgent, ReqLLMTelemetry}

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  @agent_span "invoke_agent Legion.Test.Support.MathAgent"

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

    :ok =
      Legion.OpenTelemetry.attach(
        adapter: Legion.OpenTelemetry.Adapter.Datadog,
        content: :attributes
      )

    on_exit(fn -> Legion.OpenTelemetry.detach() end)

    # An action the agent may not take, then an eval, then the answer.
    {:ok, script} =
      Agent.start_link(fn ->
        [
          %{"action" => "bogus", "code" => "", "result" => ""},
          %{"action" => "eval_and_continue", "code" => "return 1 + 1", "result" => ""},
          %{"action" => "return", "code" => "", "result" => "done"}
        ]
      end)

    stub(ReqLLM, :generate_object, fn _model, _messages, _schema, opts ->
      ReqLLMTelemetry.emit_request("openai:gpt-4o-mini", opts)
      object = Agent.get_and_update(script, fn [next | rest] -> {next, rest} end)
      {:ok, %ReqLLM.Response{id: "t", model: "t", context: nil, object: object, usage: %{}}}
    end)

    assert {:ok, "done"} = Legion.execute(MathAgent, "hi")
    :ok
  end

  defp attributes(name) do
    assert_receive {:span, span(name: ^name, attributes: {:attributes, _, _, _, attributes})}
    attributes
  end

  defp metadata(attributes), do: Jason.decode!(attributes[:"_dd.ml_obs.metadata"])

  test "Legion's own attributes move into _dd.ml_obs.metadata" do
    attributes = attributes(@agent_span)

    refute Enum.any?(Map.keys(attributes), &String.starts_with?(to_string(&1), "legion."))
    assert %{"legion.status" => "ok", "legion.iterations" => 3} = metadata(attributes)
    assert attributes[:"gen_ai.agent.name"] == "Legion.Test.Support.MathAgent"
  end

  test "invoke_agent shows the turn's text as input.value and output.value" do
    attributes = attributes(@agent_span)

    assert attributes[:"input.value"] == "hi"
    assert attributes[:"output.value"] == "done"
  end

  test "span events are kept in the metadata" do
    assert %{"events" => [event]} = metadata(attributes(@agent_span))
    assert event["name"] == "legion.retry"
    assert event["legion.retry.reason"] == "invalid_action"
  end

  test "chat and execute_tool spans keep their GenAI content and move the rest" do
    chat = attributes("chat gpt-4o-mini")
    assert is_binary(chat[:"gen_ai.input.messages"])
    refute Map.has_key?(chat, :"input.value")
    assert %{"legion.iteration" => _} = metadata(chat)

    tool = attributes("execute_tool sandbox")
    assert tool[:"gen_ai.tool.call.arguments"] == "return 1 + 1"
    assert %{"legion.eval.success" => true} = metadata(tool)
  end
end
