defmodule Legion.OpenTelemetry.TraceTest do
  @moduledoc """
  Runs the real OpenTelemetry SDK with a pid exporter to check the shape of
  whole traces: which span is whose parent, across the agent process, the
  sandbox process, sub-agents and `Legion.parallel/2`.
  """

  use ExUnit.Case, async: false
  use Mimic

  setup :set_mimic_global

  @moduletag capture_log: true

  require OpenTelemetry.Tracer, as: Tracer
  require Record

  alias Anubis.Server.{Context, Frame, Handlers}
  alias Legion.Test.Support.{MathAgent, ReqLLMTelemetry}

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  Record.defrecordp(
    :span_ctx,
    Record.extract(:span_ctx, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  defmodule ChildAgent do
    @moduledoc "Sub-agent invoked through AgentTool."
    use Legion.Agent
  end

  defmodule DelegatingAgent do
    @moduledoc "Agent that delegates work to ChildAgent."
    use Legion.Agent

    def tools, do: [Legion.Tools.AgentTool]
    def tool_config(Legion.Tools.AgentTool), do: [agents: [ChildAgent]]
    def tool_config(_tool), do: []
  end

  defmodule MathMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "math", version: "0.1.0"
  end

  defmodule FailingAttributesAdapter do
    @moduledoc "Adapter whose attribute writes fail."
    @behaviour Legion.OpenTelemetry.Adapter

    alias Legion.OpenTelemetry.Adapter.OTel

    @impl true
    defdelegate available?(), to: OTel
    @impl true
    defdelegate start_span(name, attributes, config), to: OTel
    @impl true
    defdelegate add_event(span, name, attributes, config), to: OTel
    @impl true
    defdelegate set_status(span, status, message, config), to: OTel
    @impl true
    defdelegate end_span(span, config), to: OTel

    @impl true
    def set_attributes(_span, _attributes, _config), do: raise("attributes are down")
  end

  @model "openai:gpt-4o-mini"

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok = Legion.OpenTelemetry.attach()
    on_exit(fn -> Legion.OpenTelemetry.detach() end)
    :ok
  end

  # The parent evaluates code that calls ChildAgent; everyone else returns.
  defp stub_llm do
    stub(ReqLLM, :generate_object, fn _model, messages, _schema, opts ->
      ReqLLMTelemetry.emit_request(@model, opts)

      object =
        if Enum.any?(messages, &(&1[:content] == "delegate")) and
             not Enum.any?(messages, &(&1[:role] == "assistant")) do
          code = ~s|local reply = AgentTool.call(ChildAgent, "child task")\nreturn reply[2]|
          %{"action" => "eval_and_complete", "code" => code, "result" => ""}
        else
          %{"action" => "return", "code" => "", "result" => "done"}
        end

      {:ok, %ReqLLM.Response{id: "t", model: "t", context: nil, object: object, usage: %{}}}
    end)
  end

  # Runs `fun` inside a `name` span and returns every span exported by the time
  # that span ends, as `%{name => [span]}`.
  defp trace(name, fun) do
    Tracer.with_span name do
      fun.()
    end

    collect(name, [])
  end

  defp collect(root, acc) do
    receive do
      {:span, span(name: ^root) = root_span} -> group([root_span | acc])
      {:span, span} -> collect(root, [span | acc])
    after
      1_000 -> flunk("#{root} span was not exported")
    end
  end

  defp group(spans), do: Enum.group_by(spans, &span(&1, :name))

  defp id(spans, name) do
    [span] = Map.fetch!(spans, name)
    span(span, :span_id)
  end

  defp parent_ids(spans, name), do: Enum.map(Map.fetch!(spans, name), &span(&1, :parent_span_id))

  test "a sub-agent called from tool code nests under the execute_tool span" do
    stub_llm()

    spans =
      trace("request", fn ->
        assert {:ok, "done"} = Legion.execute(DelegatingAgent, "delegate")
      end)

    parent = "invoke_agent Legion.OpenTelemetry.TraceTest.DelegatingAgent"
    child = "invoke_agent Legion.OpenTelemetry.TraceTest.ChildAgent"

    assert parent_ids(spans, parent) == [id(spans, "request")]
    assert parent_ids(spans, "execute_tool sandbox") == [id(spans, parent)]
    assert parent_ids(spans, child) == [id(spans, "execute_tool sandbox")]

    chat_parents = parent_ids(spans, "chat gpt-4o-mini")
    assert Enum.sort(chat_parents) == Enum.sort([id(spans, parent), id(spans, child)])
  end

  test "a sub-agent's spans carry the session of the turn that called it" do
    stub_llm()

    spans =
      trace("request", fn ->
        assert {:ok, "done"} = Legion.execute(DelegatingAgent, "delegate")
      end)

    [parent] = spans["invoke_agent Legion.OpenTelemetry.TraceTest.DelegatingAgent"]
    {:attributes, _, _, _, parent_attributes} = span(parent, :attributes)
    session = parent_attributes[:"session.id"]
    assert session == parent_attributes[:"gen_ai.agent.id"]

    for {name, list} <- spans, name != "request", span <- list do
      {:attributes, _, _, _, attributes} = span(span, :attributes)
      assert attributes[:"session.id"] == session, "#{name} has another session"
    end
  end

  test "Legion.parallel runs each agent under the caller's span" do
    stub_llm()

    spans =
      trace("job", fn ->
        assert {:ok, ["done", "done"]} = Legion.parallel([{MathAgent, "a"}, {MathAgent, "b"}])
      end)

    job = id(spans, "job")
    assert parent_ids(spans, "invoke_agent Legion.Test.Support.MathAgent") == [job, job]
  end

  test "Legion.cast nests the turn under the caller's span" do
    stub_llm()
    {:ok, pid} = Legion.start_link(MathAgent)

    outer_id =
      Tracer.with_span "job" do
        :ok = Legion.cast(pid, "hi")
        span_ctx(span_id: span_id) = Tracer.current_span_ctx()
        span_id
      end

    assert_receive {:span,
                    span(
                      name: "invoke_agent Legion.Test.Support.MathAgent",
                      parent_span_id: ^outer_id
                    )}
  end

  test "the agent process forgets the caller's span and its own once the turn ends" do
    stub_llm()
    {:ok, pid} = Legion.start_link(MathAgent)

    Tracer.with_span "request" do
      assert {:ok, "done"} = Legion.call(pid, "hi")
    end

    assert_receive {:span, span(name: "invoke_agent Legion.Test.Support.MathAgent") = first}
    assert span(first, :parent_span_id) != :undefined

    assert {:ok, "done"} = Legion.call(pid, "again")

    assert_receive {:span,
                    span(
                      name: "invoke_agent Legion.Test.Support.MathAgent",
                      parent_span_id: :undefined
                    )}
  end

  describe "conversation_traces: true" do
    setup do
      :ok = Legion.OpenTelemetry.attach(conversation_traces: true)
      stub_llm()
      {:ok, pid} = Legion.start_link(MathAgent)
      %{pid: pid}
    end

    test "turns called without a span share one trace under the conversation span", %{pid: pid} do
      assert {:ok, "done"} = Legion.call(pid, "hi")
      assert {:ok, "done"} = Legion.call(pid, "again")

      assert_receive {:span,
                      span(
                        name: "conversation Legion.Test.Support.MathAgent",
                        span_id: conversation_id,
                        trace_id: trace_id,
                        parent_span_id: :undefined
                      )}

      for _turn <- 1..2 do
        assert_receive {:span,
                        span(
                          name: "invoke_agent Legion.Test.Support.MathAgent",
                          trace_id: ^trace_id,
                          parent_span_id: ^conversation_id
                        )}
      end

      refute_receive {:span, span(name: "conversation " <> _)}, 100
    end

    test "a turn called under a span nests there instead", %{pid: pid} do
      outer_id =
        Tracer.with_span "request" do
          assert {:ok, "done"} = Legion.call(pid, "hi")
          span_ctx(span_id: span_id) = Tracer.current_span_ctx()
          span_id
        end

      assert_receive {:span,
                      span(
                        name: "invoke_agent Legion.Test.Support.MathAgent",
                        parent_span_id: ^outer_id
                      )}

      refute_receive {:span, span(name: "conversation " <> _)}, 100
    end
  end

  test "chat spans carry the agent id as the conversation id" do
    stub_llm()
    {:ok, pid} = Legion.start_link(MathAgent)
    agent_id = Legion.get_agent_id(pid)

    assert {:ok, "done"} = Legion.call(pid, "hi")

    assert_receive {:span, span(name: "chat gpt-4o-mini", attributes: attributes)}
    assert {:attributes, _, _, _, %{"gen_ai.conversation.id": ^agent_id}} = attributes
  end

  # Stubs the LLM to answer with `objects` in order.
  defp reply_with(objects) do
    {:ok, script} = Agent.start_link(fn -> objects end)

    stub(ReqLLM, :generate_object, fn _model, _messages, _schema, opts ->
      ReqLLMTelemetry.emit_request(@model, opts)
      object = Agent.get_and_update(script, fn [next | rest] -> {next, rest} end)
      {:ok, %ReqLLM.Response{id: "t", model: "t", context: nil, object: object, usage: %{}}}
    end)
  end

  test "a turn whose result breaks content serialization is still exported whole" do
    :ok = Legion.OpenTelemetry.attach(content: :attributes)

    reply_with([
      %{"action" => "eval_and_complete", "code" => "%{{1, 2} => 3}", "result" => ""},
      %{"action" => "return", "code" => "", "result" => "done"}
    ])

    {:ok, pid} = Legion.start_link(MathAgent, sandbox: Legion.Sandbox.Elixir)
    assert {:ok, _} = Legion.call(pid, "go")

    assert_receive {:span, span(name: "invoke_agent " <> _, span_id: agent_id)}
    assert_receive {:span, span(name: "execute_tool sandbox", parent_span_id: ^agent_id)}

    # The agent process holds no leftover context: the next turn is a new root.
    assert {:ok, "done"} = Legion.call(pid, "again")
    assert_receive {:span, span(name: "invoke_agent " <> _, parent_span_id: :undefined)}
  end

  test "iteration spans stay siblings when recording an iteration's outcome fails" do
    :ok =
      Legion.OpenTelemetry.attach(
        adapter: FailingAttributesAdapter,
        req_llm: false,
        iteration_spans: true
      )

    reply_with([
      %{"action" => "eval_and_continue", "code" => "1 + 1", "result" => ""},
      %{"action" => "return", "code" => "", "result" => "done"}
    ])

    {:ok, pid} = Legion.start_link(MathAgent, sandbox: Legion.Sandbox.Elixir)
    assert {:ok, "done"} = Legion.call(pid, "go")

    assert_receive {:span, span(name: "invoke_agent " <> _, span_id: agent_id)}
    assert_receive {:span, span(name: "iteration 0", parent_span_id: ^agent_id)}
    assert_receive {:span, span(name: "iteration 1", parent_span_id: ^agent_id)}
  end

  describe "MCP calls" do
    setup do
      start_supervised!({DynamicSupervisor, name: Legion.AgentSupervisor, strategy: :one_for_one})
      context = %Context{session_id: "mcp-session-1", client_info: %{}}
      {:ok, frame} = MathMCP.init(%{}, %Frame{context: context})
      %{frame: frame}
    end

    defp repl(frame, code) do
      request = %{
        "method" => "tools/call",
        "params" => %{"name" => "repl", "arguments" => %{"code" => code}}
      }

      {:reply, _response, _frame} = Handlers.handle(request, MathMCP, frame)
      collect("tools/call repl", [])
    end

    defp attributes(spans, name) do
      [span(attributes: attributes)] = Map.fetch!(spans, name)
      :otel_attributes.map(attributes)
    end

    test "a call is a trace keyed by the MCP session, with the agent's eval under it",
         %{frame: frame} do
      spans = repl(frame, "return 1 + 1")

      assert [span(parent_span_id: :undefined, kind: :server)] = spans["tools/call repl"]
      assert parent_ids(spans, "execute_tool sandbox") == [id(spans, "tools/call repl")]

      call = attributes(spans, "tools/call repl")
      assert call[:"session.id"] == "mcp-session-1"
      assert call[:"mcp.session.id"] == "mcp-session-1"
      assert call[:"gen_ai.tool.call.arguments"] == "return 1 + 1"
      assert call[:"gen_ai.tool.call.result"] =~ "2"
      assert attributes(spans, "execute_tool sandbox")[:"session.id"] == "mcp-session-1"
    end

    test "a failed call is marked as a tool error", %{frame: frame} do
      spans = repl(frame, "error('boom')")

      assert [span(status: {:status, :error, _message}, attributes: attributes)] =
               spans["tools/call repl"]

      assert :otel_attributes.map(attributes)[:"error.type"] == "tool_error"
    end
  end
end
