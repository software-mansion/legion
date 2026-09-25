defmodule Legion.OpenTelemetryTest do
  use ExUnit.Case, async: false
  use Mimic

  setup :set_mimic_global

  alias Legion.OpenTelemetry
  alias Legion.Test.Support.{FakeOTelAdapter, MathAgent, ReqLLMTelemetry}

  @model "openai:gpt-4o-mini"
  @span_name "chat gpt-4o-mini"

  defmodule UnavailableAdapter do
    @moduledoc "Adapter whose tracer is missing."
    @behaviour Legion.OpenTelemetry.Adapter

    @impl true
    def available?, do: false
    @impl true
    def start_span(_, _, _), do: nil
    @impl true
    def set_attributes(_, _, _), do: :ok
    @impl true
    def add_event(_, _, _, _), do: :ok
    @impl true
    def set_status(_, _, _, _), do: :ok
    @impl true
    def end_span(_, _), do: :ok
  end

  defmodule HostReqLLMAdapter do
    @moduledoc "A host's own ReqLLM adapter, bypassing Legion's adapter."
    @behaviour ReqLLM.OpenTelemetry.Adapter

    @impl true
    def available?, do: true

    @impl true
    def start_span(name, _attributes, _config) do
      send(Process.whereis(FakeOTelAdapter), {:host_req_llm, :start_span, name})
      make_ref()
    end

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
    telemetry_env = Application.get_env(:req_llm, :telemetry)

    on_exit(fn ->
      OpenTelemetry.detach()

      if telemetry_env,
        do: Application.put_env(:req_llm, :telemetry, telemetry_env),
        else: Application.delete_env(:req_llm, :telemetry)
    end)

    :ok
  end

  # Stubs the LLM so each call emits ReqLLM's request events with the options
  # the executor passed, then answers `result`.
  defp stub_llm(result) do
    stub(ReqLLM, :generate_object, fn _model, _messages, _schema, opts ->
      ReqLLMTelemetry.emit_request(@model, opts)
      {:ok, llm_response(result)}
    end)
  end

  defp llm_response(result) do
    %ReqLLM.Response{
      id: "test",
      model: "test",
      context: nil,
      object: %{"action" => "return", "code" => "", "result" => result},
      usage: %{turn_usage: 0}
    }
  end

  describe "attach/1" do
    test "forwards every LLM request as a client chat span to the adapter" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      stub_llm("done")

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      assert_receive {:otel, :start_span, span, @span_name, attrs, config}
      assert attrs[:"gen_ai.operation.name"] == "chat"
      assert attrs[:"gen_ai.provider.name"] == "openai"
      assert config[:span_kind] == :client
      assert config[:adapter] == FakeOTelAdapter
      assert_receive {:otel, :set_attributes, ^span, %{"gen_ai.usage.input_tokens": 3}, _}
      assert_receive {:otel, :end_span, ^span, _}
    end

    test "tags chat spans with the agent id as the conversation id" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      stub_llm("done")

      {:ok, pid} = Legion.start_link(MathAgent)
      agent_id = Legion.get_agent_id(pid)
      assert {:ok, "done"} = Legion.call(pid, "hi")

      assert_receive {:otel, :start_span, _, @span_name, attrs, _}
      assert attrs[:"gen_ai.conversation.id"] == agent_id
    end

    test "keeps the host's :req_llm telemetry config next to the conversation id" do
      Application.put_env(:req_llm, :telemetry, payloads: :raw)
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema, opts ->
        send(test_pid, {:llm_opts, opts})
        {:ok, llm_response("done")}
      end)

      {:ok, pid} = Legion.start_link(MathAgent)
      agent_id = Legion.get_agent_id(pid)
      assert {:ok, "done"} = Legion.call(pid, "hi")

      assert_receive {:llm_opts, opts}
      assert opts[:telemetry][:payloads] == :raw
      assert opts[:telemetry][:conversation_id] == agent_id
    end

    test "content: :attributes records messages on chat spans" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)
      stub_llm("done")

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      assert_receive {:otel, :start_span, _, @span_name, attrs, _}
      assert [message] = attrs[:"gen_ai.input.messages"]
      assert message =~ "hi"
    end

    test "content: :none keeps messages off chat spans" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      stub_llm("done")

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      assert_receive {:otel, :start_span, _, @span_name, attrs, _}
      refute Map.has_key?(attrs, :"gen_ai.input.messages")
      assert_receive {:otel, :set_attributes, _, attrs, _}
      refute Map.has_key?(attrs, :"gen_ai.output.messages")
    end

    test "content: :attributes turns on raw payloads in the :req_llm config" do
      Application.delete_env(:req_llm, :telemetry)

      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)

      assert Application.get_env(:req_llm, :telemetry)[:payloads] == :raw
    end

    test "leaves a :payloads setting the host configured alone" do
      Application.put_env(:req_llm, :telemetry, payloads: :none)

      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)

      assert Application.get_env(:req_llm, :telemetry) == [payloads: :none]
    end

    test "req_llm: [adapter: ...] hands ReqLLM spans to the host's adapter instead" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, req_llm: [adapter: HostReqLLMAdapter])
      stub_llm("done")

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      assert_receive {:host_req_llm, :start_span, @span_name}
      refute_received {:otel, :start_span, _, _, _, _}
    end

    test "req_llm: false leaves ReqLLM's telemetry untouched" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, req_llm: false)

      handler_ids = Enum.map(:telemetry.list_handlers([:req_llm, :request, :start]), & &1.id)
      refute OpenTelemetry.req_llm_handler_id() in handler_ids
    end

    test "returns {:error, :already_exists} when already attached" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)

      assert OpenTelemetry.attach(adapter: FakeOTelAdapter) == {:error, :already_exists}
    end

    test "returns {:error, :opentelemetry_unavailable} when the adapter has no tracer" do
      assert OpenTelemetry.attach(adapter: UnavailableAdapter) ==
               {:error, :opentelemetry_unavailable}

      assert OpenTelemetry.config() == nil
    end

    test "rejects unknown options" do
      assert_raise NimbleOptions.ValidationError, fn ->
        OpenTelemetry.attach(adapter: FakeOTelAdapter, iteration_spans: true)
      end
    end
  end

  describe "detach/0" do
    test "removes the ReqLLM handler and restores the :req_llm telemetry config" do
      Application.put_env(:req_llm, :telemetry, [])
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)

      assert OpenTelemetry.detach() == :ok

      handler_ids = Enum.map(:telemetry.list_handlers([:req_llm, :request, :start]), & &1.id)
      refute OpenTelemetry.req_llm_handler_id() in handler_ids
      assert Application.get_env(:req_llm, :telemetry) == []
      assert OpenTelemetry.config() == nil
    end

    test "returns {:error, :not_found} when nothing is attached" do
      assert OpenTelemetry.detach() == {:error, :not_found}
    end
  end
end
