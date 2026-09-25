defmodule Legion.OpenTelemetry.ReqLLMNestingTest do
  @moduledoc """
  Runs the real OpenTelemetry SDK with a pid exporter to check that ReqLLM's
  chat spans nest under the span current in the process that calls the agent.
  """

  use ExUnit.Case, async: false
  use Mimic

  setup :set_mimic_global

  @moduletag capture_log: true

  require OpenTelemetry.Tracer, as: Tracer
  require Record

  alias Legion.Test.Support.{MathAgent, ReqLLMTelemetry}

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  Record.defrecordp(
    :span_ctx,
    Record.extract(:span_ctx, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  @model "openai:gpt-4o-mini"
  @span_name "chat gpt-4o-mini"

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok = Legion.OpenTelemetry.attach()
    on_exit(fn -> Legion.OpenTelemetry.detach() end)

    stub(ReqLLM, :generate_object, fn _model, _messages, _schema, opts ->
      ReqLLMTelemetry.emit_request(@model, opts)

      {:ok,
       %ReqLLM.Response{
         id: "test",
         model: "test",
         context: nil,
         object: %{"action" => "return", "code" => "", "result" => "done"},
         usage: %{turn_usage: 0}
       }}
    end)

    {:ok, pid} = Legion.start_link(MathAgent)
    %{pid: pid}
  end

  defp current_span_id do
    span_ctx(span_id: span_id) = Tracer.current_span_ctx()
    span_id
  end

  test "Legion.call nests the chat span under the caller's current span", %{pid: pid} do
    outer_id =
      Tracer.with_span "request" do
        assert {:ok, "done"} = Legion.call(pid, "hi")
        current_span_id()
      end

    assert_receive {:span, span(name: @span_name, parent_span_id: ^outer_id)}
  end

  test "Legion.cast nests the chat span under the caller's current span", %{pid: pid} do
    outer_id =
      Tracer.with_span "job" do
        :ok = Legion.cast(pid, "hi")
        current_span_id()
      end

    assert_receive {:span, span(name: @span_name, parent_span_id: ^outer_id)}
  end

  test "a chat span with no caller span is a root span", %{pid: pid} do
    assert {:ok, "done"} = Legion.call(pid, "hi")

    assert_receive {:span, span(name: @span_name, parent_span_id: :undefined)}
  end

  test "the agent process drops the caller's context once the turn ends", %{pid: pid} do
    Tracer.with_span "request" do
      assert {:ok, "done"} = Legion.call(pid, "hi")
    end

    assert_receive {:span, span(name: @span_name, parent_span_id: parent_id)}
    assert parent_id != :undefined

    assert {:ok, "done"} = Legion.call(pid, "again")

    assert_receive {:span, span(name: @span_name, parent_span_id: :undefined)}
  end

  test "chat spans carry the agent id as the conversation id", %{pid: pid} do
    agent_id = Legion.get_agent_id(pid)
    assert {:ok, "done"} = Legion.call(pid, "hi")

    assert_receive {:span, span(name: @span_name, attributes: attributes)}
    assert {:attributes, _, _, _, %{"gen_ai.conversation.id": ^agent_id}} = attributes
  end
end
