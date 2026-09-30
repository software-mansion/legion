defmodule Legion.OpenTelemetry.HandlerTest do
  @moduledoc """
  Legion's own spans, span events and metrics, observed through a fake adapter.
  """

  use ExUnit.Case, async: false
  use Mimic

  setup :set_mimic_global

  @moduletag capture_log: true

  alias Legion.OpenTelemetry
  alias Legion.OpenTelemetry.{Attributes, Handler}
  alias Legion.Test.Support.{FakeOTelAdapter, MathAgent, ReqLLMTelemetry}

  @model "openai:gpt-4o-mini"
  @agent_span "invoke_agent Legion.Test.Support.MathAgent"
  @tool_span "execute_tool sandbox"
  @chat_span "chat gpt-4o-mini"

  defmodule DenyEverything do
    @moduledoc "Eval guard that refuses all code."
    @behaviour Legion.EvalGuard

    @impl true
    def check(_code, _context), do: {:deny, "the shop is closed"}
  end

  defmodule RaisingAdapter do
    @moduledoc "Adapter whose spans cannot be started."
    @behaviour Legion.OpenTelemetry.Adapter

    @impl true
    def available?, do: true
    @impl true
    def start_span(_, _, _), do: raise("tracer is down")
    @impl true
    def set_attributes(_, _, _), do: :ok
    @impl true
    def add_event(_, _, _, _), do: :ok
    @impl true
    def set_status(_, _, _, _), do: :ok
    @impl true
    def end_span(_, _), do: :ok
  end

  setup do
    FakeOTelAdapter.register(self())
    on_exit(fn -> OpenTelemetry.detach() end)
    :ok
  end

  # Stubs the LLM to answer with `replies` in order. A reply is an action map,
  # or `{:error, reason}` for a failed request.
  defp reply_with(replies) do
    {:ok, script} = Agent.start_link(fn -> replies end)

    stub(ReqLLM, :generate_object, fn _model, _messages, _schema, opts ->
      script
      |> Agent.get_and_update(fn [next | rest] -> {next, rest} end)
      |> answer(opts)
    end)
  end

  defp answer({:error, reason}, _opts), do: {:error, reason}

  defp answer(object, opts) do
    ReqLLMTelemetry.emit_request(@model, opts)
    {:ok, %ReqLLM.Response{id: "t", model: "t", context: nil, object: object, usage: %{}}}
  end

  defp return(result), do: %{"action" => "return", "code" => "", "result" => result}
  defp eval(code), do: %{"action" => "eval_and_continue", "code" => code, "result" => ""}

  defp span_named(name) do
    assert_receive {:otel, :start_span, span, ^name, attributes, config}
    {span, attributes, config}
  end

  defp stop_attributes(span) do
    assert_receive {:otel, :set_attributes, ^span, attributes, _}
    attributes
  end

  # Every adapter message received so far.
  defp flush(acc \\ []) do
    receive do
      message when is_tuple(message) and elem(message, 0) == :otel -> flush([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp started_span_names(messages) do
    for {:otel, :start_span, _, name, _, _} <- messages, do: name
  end

  defp metric_records(messages) do
    for {:otel, kind, record, _} <- messages, kind in [:record_histogram, :record_counter] do
      record
    end
  end

  describe "invoke_agent" do
    test "an agent turn becomes an invoke_agent span around its chat spans" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      reply_with([return("done")])

      {:ok, pid} = Legion.start_link(MathAgent)
      agent_id = Legion.get_agent_id(pid)
      assert {:ok, "done"} = Legion.call(pid, "hi")

      {agent, attributes, config} = span_named(@agent_span)
      assert attributes[:"gen_ai.operation.name"] == "invoke_agent"
      assert attributes[:"gen_ai.agent.name"] == "Legion.Test.Support.MathAgent"
      assert attributes[:"gen_ai.agent.id"] == agent_id
      assert attributes[:"gen_ai.conversation.id"] == agent_id
      assert config[:span_kind] == :internal

      {_chat, chat_attributes, _} = span_named(@chat_span)
      assert chat_attributes[:"gen_ai.agent.name"] == "Legion.Test.Support.MathAgent"
      assert chat_attributes[:"legion.iteration"] == 0

      attributes = stop_attributes(agent)
      assert attributes[:"legion.status"] == "ok"
      assert attributes[:"legion.iterations"] == 1
      assert attributes[:"gen_ai.provider.name"] == "openai"
      assert_receive {:otel, :end_span, ^agent, _}
      refute_received {:otel, :set_status, ^agent, _, _, _}
    end

    test "a cancelled turn records the reason as the error type" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      reply_with([eval("return 1")])

      assert {:cancel, :reached_max_iterations} =
               Legion.execute(MathAgent, "hi", max_iterations: 1)

      {agent, _, _} = span_named(@agent_span)
      attributes = stop_attributes(agent)
      assert attributes[:"legion.status"] == "cancelled"
      assert attributes[:"legion.cancel.reason"] == "reached_max_iterations"
      assert attributes[:"error.type"] == "reached_max_iterations"
      assert_receive {:otel, :set_status, ^agent, :error, "reached_max_iterations", _}
    end

    test "retries become legion.retry events on the invoke_agent span" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)

      reply_with([
        %{"action" => "bogus", "code" => "", "result" => ""},
        {:error, :timeout},
        return("done")
      ])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      {agent, _, _} = span_named(@agent_span)

      assert_receive {:otel, :add_event, ^agent, "legion.retry",
                      %{"legion.retry.reason": "invalid_action", "legion.iteration": 0}, _}

      assert_receive {:otel, :add_event, ^agent, "legion.retry",
                      %{"legion.retry.reason": "request_failed", "legion.iteration": 0}, _}
    end
  end

  describe "execute_tool" do
    test "each evaluation becomes an execute_tool span" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      reply_with([eval("return 1 + 1"), return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      {tool, attributes, config} = span_named(@tool_span)
      assert attributes[:"gen_ai.operation.name"] == "execute_tool"
      assert attributes[:"gen_ai.tool.name"] == "sandbox"
      assert attributes[:"gen_ai.tool.type"] == "extension"
      assert attributes[:"gen_ai.agent.name"] == "Legion.Test.Support.MathAgent"
      assert attributes[:"legion.iteration"] == 0
      assert config[:span_kind] == :internal
      refute Map.has_key?(attributes, :"gen_ai.tool.call.arguments")

      assert stop_attributes(tool) == %{"legion.eval.success": true}
      assert_receive {:otel, :end_span, ^tool, _}
    end

    test "a failed evaluation marks the span as an error, with its message when content is on" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)
      reply_with([eval("error('boom')"), return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      {tool, _, _} = span_named(@tool_span)
      assert_receive {:otel, :set_status, ^tool, :error, message, _}
      assert message =~ "boom"

      attributes = stop_attributes(tool)
      assert attributes[:"legion.eval.success"] == false
      assert attributes[:"error.type"] == "runtime"
    end

    test "an eval guard denial becomes an event on the span, with its reason when content is on" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)
      reply_with([eval("return 1"), return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi", eval_guard: DenyEverything)

      {tool, _, _} = span_named(@tool_span)

      assert_receive {:otel, :add_event, ^tool, "legion.eval_guard.denied", attributes, _}
      assert attributes[:"legion.eval_guard.guard"] == inspect(DenyEverything)
      assert attributes[:"legion.eval_guard.reason"] == "the shop is closed"

      assert stop_attributes(tool)[:"error.type"] == "guard_denied"
    end

    test "without content, a failed evaluation's status names only the error type" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      reply_with([eval("error('boom')"), return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      {tool, _, _} = span_named(@tool_span)
      assert_receive {:otel, :set_status, ^tool, :error, "runtime", _}
    end

    test "without content, an eval guard denial records the guard but not its reason" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      reply_with([eval("return 1"), return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi", eval_guard: DenyEverything)

      {tool, _, _} = span_named(@tool_span)
      assert_receive {:otel, :add_event, ^tool, "legion.eval_guard.denied", attributes, _}
      assert attributes[:"legion.eval_guard.guard"] == inspect(DenyEverything)
      refute Map.has_key?(attributes, :"legion.eval_guard.reason")
      assert_receive {:otel, :set_status, ^tool, :error, "guard_denied", _}
    end
  end

  describe "content" do
    test "content: :attributes records the turn's messages and the evaluated code" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)
      reply_with([eval("return 1 + 1"), return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      {agent, attributes, _} = span_named(@agent_span)

      assert Jason.decode!(attributes[:"gen_ai.input.messages"]) == [
               %{"role" => "user", "parts" => [%{"type" => "text", "content" => "hi"}]}
             ]

      {tool, attributes, _} = span_named(@tool_span)
      assert attributes[:"gen_ai.tool.call.arguments"] == "return 1 + 1"
      assert stop_attributes(tool)[:"gen_ai.tool.call.result"] == "2"

      assert [%{"role" => "assistant", "parts" => [%{"content" => "done"}]}] =
               Jason.decode!(stop_attributes(agent)[:"gen_ai.output.messages"])
    end

    test "content: :none keeps messages and code off Legion's spans" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      reply_with([eval("return 1 + 1"), return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      {agent, attributes, _} = span_named(@agent_span)
      refute Map.has_key?(attributes, :"gen_ai.input.messages")
      {tool, _, _} = span_named(@tool_span)
      refute Map.has_key?(stop_attributes(tool), :"gen_ai.tool.call.result")
      refute Map.has_key?(stop_attributes(agent), :"gen_ai.output.messages")
    end

    test "max_attribute_bytes cuts long content on a UTF-8 boundary" do
      :ok =
        OpenTelemetry.attach(
          adapter: FakeOTelAdapter,
          content: :attributes,
          max_attribute_bytes: 20
        )

      reply_with([return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, String.duplicate("ż", 50))

      {_agent, attributes, _} = span_named(@agent_span)

      [%{"parts" => [%{"content" => content}]}] =
        Jason.decode!(attributes[:"gen_ai.input.messages"])

      assert byte_size(content) <= 20
      assert String.valid?(content)
      assert String.ends_with?(content, "…[truncated]")
    end

    test "a result JSON cannot encode is recorded as inspected text, and the spans still end" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)

      reply_with([
        %{"action" => "eval_and_complete", "code" => "%{{1, 2} => 3}", "result" => ""}
      ])

      assert {:ok, %{{1, 2} => 3}} =
               Legion.execute(MathAgent, "hi", sandbox: Legion.Sandbox.Elixir)

      {agent, _, _} = span_named(@agent_span)
      {tool, _, _} = span_named(@tool_span)

      assert stop_attributes(tool)[:"gen_ai.tool.call.result"] == "%{{1, 2} => 3}"
      assert_receive {:otel, :end_span, ^tool, _}
      assert_receive {:otel, :end_span, ^agent, _}
    end

    test "a result that is not valid UTF-8 is recorded as valid UTF-8" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)

      reply_with([
        %{"action" => "eval_and_complete", "code" => "return string.char(255, 1)", "result" => ""}
      ])

      assert {:ok, <<255, 1>>} = Legion.execute(MathAgent, "hi")

      {agent, _, _} = span_named(@agent_span)
      {tool, _, _} = span_named(@tool_span)

      assert String.valid?(stop_attributes(tool)[:"gen_ai.tool.call.result"])
      assert {:ok, _} = Jason.decode(stop_attributes(agent)[:"gen_ai.output.messages"])
      assert_receive {:otel, :end_span, ^agent, _}
    end

    test "a small result JSON cannot encode is recorded whole" do
      config = [content: :attributes, max_attribute_bytes: 20_000]
      result = for i <- 1..60, do: {i, "name#{i}"}

      attributes = Attributes.execute_tool_stop(%{success: true, result: result}, config)

      assert attributes[:"gen_ai.tool.call.result"] == inspect(result, limit: :infinity)
    end

    test "a large result JSON cannot encode is cut to the cap" do
      config = [content: :attributes, max_attribute_bytes: 20_000]
      result = for i <- 1..2_500, do: {i, String.duplicate("x", 20_000)}

      attributes = Attributes.execute_tool_stop(%{success: true, result: result}, config)
      text = attributes[:"gen_ai.tool.call.result"]

      assert byte_size(text) == 20_000
      assert text =~ ~r/^\[\{1, "x+/
      assert String.ends_with?(text, "…[truncated]")
    end

    test "truncate/2 replaces invalid UTF-8" do
      assert Attributes.truncate(<<255, "abc">>, 100) == "\uFFFDabc"
    end

    test "truncate/2 stays within a cap smaller than the truncation marker" do
      assert Attributes.truncate("abcdefghijklmnopqrstuvwxyz", 5) == "abcde"
    end

    test "truncate/2 cuts on a UTF-8 boundary and marks the cut" do
      assert Attributes.truncate(String.duplicate("ż", 20), 20) == "żżż…[truncated]"
    end
  end

  describe "iteration_spans" do
    test "true adds one sibling iteration span per iteration" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, iteration_spans: true)
      reply_with([eval("return 1"), return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      {first, attributes, _} = span_named("iteration 0")
      assert attributes[:"legion.iteration"] == 0
      assert attributes[:"gen_ai.agent.name"] == "Legion.Test.Support.MathAgent"

      # The first iteration ends before the next one starts.
      assert_receive {:otel, :end_span, ^first, _}
      {second, _, _} = span_named("iteration 1")
      assert_receive {:otel, :end_span, ^second, _}
    end

    test "false (the default) adds no iteration spans" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      reply_with([eval("return 1"), return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      names = started_span_names(flush())
      assert @agent_span in names
      refute Enum.any?(names, &String.starts_with?(&1, "iteration"))
    end

    test "every iteration span gets the action its LLM reply chose" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, iteration_spans: true)
      reply_with([eval("return 1"), eval("return 2"), return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      actions =
        for number <- 0..2 do
          {span, _, _} = span_named("iteration #{number}")
          assert_receive {:otel, :set_attributes, ^span, %{"legion.action": action}, _}
          action
        end

      assert actions == ["eval_and_continue", "eval_and_continue", "return"]
    end

    test "iteration spans are invoke_workflow operations" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, iteration_spans: true)
      reply_with([return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      {_, attributes, _} = span_named("iteration 0")
      assert attributes[:"gen_ai.operation.name"] == "invoke_workflow"
    end
  end

  describe "conversation_traces" do
    test "true opens one conversation span per agent, ended at once" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, conversation_traces: true)
      reply_with([return("one"), return("two")])

      {:ok, pid} = Legion.start_link(MathAgent)
      agent_id = Legion.get_agent_id(pid)
      assert {:ok, "one"} = Legion.call(pid, "hi")
      assert {:ok, "two"} = Legion.call(pid, "again")

      messages = flush()
      names = started_span_names(messages)

      assert Enum.count(names, &(&1 == "conversation Legion.Test.Support.MathAgent")) == 1
      assert Enum.count(names, &(&1 == @agent_span)) == 2

      assert [{conversation, attributes}] =
               for(
                 {:otel, :start_span, span, "conversation " <> _, attributes, _} <- messages,
                 do: {span, attributes}
               )

      assert attributes[:"gen_ai.conversation.id"] == agent_id

      # Ended before the first turn starts, so the trace is exported at once.
      assert Enum.find_index(messages, &match?({:otel, :end_span, ^conversation, _}, &1)) <
               Enum.find_index(messages, &match?({:otel, :start_span, _, @agent_span, _, _}, &1))
    end

    test "false (the default) adds no conversation span" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      reply_with([return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      refute Enum.any?(started_span_names(flush()), &String.starts_with?(&1, "conversation"))
    end

    test "the conversation span is an invoke_workflow operation" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, conversation_traces: true)
      reply_with([return("done")])

      {:ok, pid} = Legion.start_link(MathAgent)
      assert {:ok, "done"} = Legion.call(pid, "hi")

      {_, attributes, _} = span_named("conversation Legion.Test.Support.MathAgent")
      assert attributes[:"gen_ai.operation.name"] == "invoke_workflow"
    end
  end

  describe "chat_attributes/0" do
    test "outside the agent process, a turn's context still gives the session" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema, _opts ->
        ctx = Legion.Telemetry.capture_context()

        attributes =
          Task.async(fn -> Legion.Telemetry.with_context(ctx, &Handler.chat_attributes/0) end)
          |> Task.await()

        send(test_pid, {:tool_process_attributes, attributes})

        {:ok,
         %ReqLLM.Response{id: "t", model: "t", context: nil, object: return("done"), usage: %{}}}
      end)

      {:ok, pid} = Legion.start_link(MathAgent)
      agent_id = Legion.get_agent_id(pid)
      assert {:ok, "done"} = Legion.call(pid, "hi")

      assert_receive {:tool_process_attributes, attributes}
      assert attributes == %{"session.id": agent_id}
    end
  end

  describe "metrics" do
    test "records agent, tool and LLM metrics" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      reply_with([eval("error('boom')"), return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      all_records = metric_records(flush())
      records = Map.new(all_records, &{&1.name, &1})
      agent = %{"gen_ai.agent.name": "Legion.Test.Support.MathAgent"}

      assert records["gen_ai.invoke_agent.duration"].unit == "s"
      assert records["gen_ai.invoke_agent.inference_calls"].value == 2
      assert records["gen_ai.invoke_agent.tool_calls"].value == 1
      assert records["gen_ai.execute_tool.duration"].attributes[:"error.type"] == "runtime"
      assert records["legion.turn.iterations"].attributes == agent

      assert %{kind: :counter, value: 1, attributes: %{"legion.error.kind": "runtime"}} =
               records["legion.eval.errors"]

      assert Map.has_key?(records, "gen_ai.client.operation.duration")
    end

    test "counts rate-limit denials by identity fields, not values" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)

      :telemetry.execute([:legion, :rate_limit, :exceeded], %{}, %{
        agent: MathAgent,
        identity: %{"ip" => "203.0.113.42", "tenant" => "acme"},
        violations: [:max_agents]
      })

      assert_receive {:otel, :record_counter,
                      %{
                        name: "legion.rate_limit.exceeded",
                        value: 1,
                        attributes: %{"legion.rate_limit.identity": "ip,tenant"}
                      }, _}
    end

    test "metrics: false records none" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, metrics: false)
      reply_with([eval("return 1"), return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      assert metric_records(flush()) == []
    end

    test "starting and stopping an agent records no metrics" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)

      {:ok, pid} = Legion.start_link(MathAgent)
      :ok = GenServer.stop(pid)

      assert metric_records(flush()) == []
    end

    test "agent call counts use the GenAI semantic-convention units" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      reply_with([eval("return 1"), return("done")])

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      records = Map.new(metric_records(flush()), &{&1.name, &1})
      assert records["gen_ai.invoke_agent.inference_calls"].unit == "{inference_call}"
      assert records["gen_ai.invoke_agent.tool_calls"].unit == "{tool_call}"
    end
  end

  test "an adapter that raises is logged and stays attached" do
    :ok = OpenTelemetry.attach(adapter: RaisingAdapter, req_llm: false)
    reply_with([return("done"), return("again")])

    assert {:ok, "done"} = Legion.execute(MathAgent, "hi")
    assert {:ok, "again"} = Legion.execute(MathAgent, "hi")

    handler_ids = Enum.map(:telemetry.list_handlers([:legion, :agent, :message]), & &1.id)
    assert "legion-otel" in handler_ids
  end
end
