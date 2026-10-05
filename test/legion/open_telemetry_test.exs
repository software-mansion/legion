defmodule Legion.OpenTelemetryTest do
  use ExUnit.Case, async: false
  use Mimic

  setup :set_mimic_global

  alias Legion.OpenTelemetry
  alias Legion.OpenTelemetry.Adapter.Datadog
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

    test "a :req_llm telemetry config that is neither a list nor a map still tags the conversation" do
      Application.put_env(:req_llm, :telemetry, false)
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema, opts ->
        send(test_pid, {:llm_opts, opts})
        {:ok, llm_response("done")}
      end)

      {:ok, pid} = Legion.start_link(MathAgent)
      agent_id = Legion.get_agent_id(pid)
      assert {:ok, "done"} = Legion.call(pid, "hi")

      assert_receive {:llm_opts, opts}
      assert opts[:telemetry] == [conversation_id: agent_id]
    end

    test "records chat content by default, as one JSON array string per attribute" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      stub_llm("done")

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      assert_receive {:otel, :start_span, _, @span_name, attrs, _}

      assert [%{"role" => "user", "parts" => [%{"content" => "hi"}]}] =
               Jason.decode!(attrs[:"gen_ai.input.messages"])
    end

    test "content: :none keeps messages off chat spans" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :none)
      stub_llm("done")

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      assert_receive {:otel, :start_span, _, @span_name, attrs, _}
      refute Map.has_key?(attrs, :"gen_ai.input.messages")
      assert_receive {:otel, :set_attributes, _, attrs, _}
      refute Map.has_key?(attrs, :"gen_ai.output.messages")
    end

    test "content: :attributes asks for raw payloads on Legion's own ReqLLM calls only" do
      Application.delete_env(:req_llm, :telemetry)
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema, opts ->
        send(test_pid, {:llm_opts, opts})
        {:ok, llm_response("done")}
      end)

      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)
      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      assert_receive {:llm_opts, opts}
      assert opts[:telemetry][:payloads] == :raw
      assert Application.get_env(:req_llm, :telemetry) == nil
    end

    test "leaves a :payloads setting the host configured alone" do
      Application.put_env(:req_llm, :telemetry, payloads: :none)
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema, opts ->
        send(test_pid, {:llm_opts, opts})
        {:ok, llm_response("done")}
      end)

      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)
      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      assert_receive {:llm_opts, opts}
      assert opts[:telemetry][:payloads] == :none
    end

    test "content: :none asks for no payloads" do
      Application.delete_env(:req_llm, :telemetry)
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema, opts ->
        send(test_pid, {:llm_opts, opts})
        {:ok, llm_response("done")}
      end)

      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :none)
      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      assert_receive {:llm_opts, opts}
      refute Keyword.has_key?(opts[:telemetry], :payloads)
    end

    test "req_llm: [adapter: ...] hands ReqLLM spans to the host's adapter instead" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, req_llm: [adapter: HostReqLLMAdapter])
      stub_llm("done")

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      assert_receive {:host_req_llm, :start_span, @span_name}
      refute_received {:otel, :start_span, _, @span_name, _, _}
    end

    test "req_llm: false leaves ReqLLM's telemetry untouched" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, req_llm: false)

      handler_ids = Enum.map(:telemetry.list_handlers([:req_llm, :request, :start]), & &1.id)
      refute OpenTelemetry.req_llm_handler_id() in handler_ids
    end

    test "attaching again replaces the earlier attachment" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      assert :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)
      assert OpenTelemetry.config()[:content] == :attributes

      stub_llm("done")
      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      # One chat span per request: the first attachment is gone, not doubled.
      assert_receive {:otel, :start_span, _, @span_name, _, _}
      refute_receive {:otel, :start_span, _, @span_name, _, _}, 100
    end

    test "returns {:error, :opentelemetry_unavailable} when the adapter has no tracer" do
      assert OpenTelemetry.attach(adapter: UnavailableAdapter) ==
               {:error, :opentelemetry_unavailable}

      assert OpenTelemetry.config() == nil
    end
  end

  describe "attach/1 with a vendor adapter in config" do
    @datadog [api_key: "key", site: "datadoghq.eu", ml_app: "my-app"]

    test "uses the vendor adapter and takes the other options from config" do
      put_env(:legion, OpenTelemetry, adapter: Datadog, iteration_spans: true)
      put_env(:legion, Datadog, @datadog)
      put_env(:opentelemetry, :traces_exporter, {Legion.OpenTelemetry.Exporter, []})

      :ok = OpenTelemetry.attach()

      assert OpenTelemetry.config()[:adapter] == Datadog
      assert OpenTelemetry.config()[:tracer] == Legion.OpenTelemetry.Adapter.OTel
      assert OpenTelemetry.config()[:iteration_spans] == true
    end

    test "raises on invalid vendor options, naming the option but not its value" do
      put_env(:legion, OpenTelemetry, adapter: Datadog)
      put_env(:legion, Datadog, api_key: 12_345, ml_app: "my-app")
      put_env(:opentelemetry, :traces_exporter, {Legion.OpenTelemetry.Exporter, []})

      error = assert_raise ArgumentError, fn -> OpenTelemetry.attach() end
      assert Exception.message(error) =~ ":api_key"
      refute Exception.message(error) =~ "12345"
    end

    test "raises with the config line to add when the SDK does not export through Legion" do
      put_env(:legion, OpenTelemetry, adapter: Datadog)
      put_env(:legion, Datadog, @datadog)
      put_env(:opentelemetry, :traces_exporter, :none)

      assert_raise ArgumentError,
                   ~r/config :opentelemetry, traces_exporter: \{Legion.OpenTelemetry.Exporter, \[\]\}/,
                   fn -> OpenTelemetry.attach() end
    end
  end

  describe "detach/0" do
    test "removes the Legion and ReqLLM handlers" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)

      assert OpenTelemetry.detach() == :ok

      handler_ids = Enum.map(:telemetry.list_handlers([:req_llm, :request, :start]), & &1.id)
      refute OpenTelemetry.req_llm_handler_id() in handler_ids
      legion_ids = Enum.map(:telemetry.list_handlers([:legion]), & &1.id)
      refute "legion-otel" in legion_ids
      assert OpenTelemetry.config() == nil
    end
  end
end
