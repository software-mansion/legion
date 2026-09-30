defmodule Legion.OpenTelemetryTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  setup :set_mimic_global

  alias Legion.OpenTelemetry
  alias Legion.OpenTelemetry.Adapter.{Braintrust, Datadog, OTel}
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

    test "content: :attributes records chat content as one JSON array string per attribute" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)
      stub_llm("done")

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      assert_receive {:otel, :start_span, _, @span_name, attrs, _}

      assert [%{"role" => "user", "parts" => [%{"content" => "hi"}]}] =
               Jason.decode!(attrs[:"gen_ai.input.messages"])
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

    test "rejects unknown options" do
      assert_raise NimbleOptions.ValidationError, fn ->
        OpenTelemetry.attach(adapter: FakeOTelAdapter, iteration_span: true)
      end
    end
  end

  describe "attach/1 with config :legion, :open_telemetry" do
    setup do
      app_config = Application.get_env(:legion, :open_telemetry)

      on_exit(fn ->
        if app_config,
          do: Application.put_env(:legion, :open_telemetry, app_config),
          else: Application.delete_env(:legion, :open_telemetry)
      end)
    end

    test "takes its options from the app config" do
      Application.put_env(:legion, :open_telemetry, adapter: Braintrust, iteration_spans: true)

      :ok = OpenTelemetry.attach()

      assert OpenTelemetry.config()[:adapter] == Braintrust
      assert OpenTelemetry.config()[:iteration_spans] == true
    end

    test "options given to attach/1 win over the app config" do
      Application.put_env(:legion, :open_telemetry, adapter: Braintrust)

      :ok = OpenTelemetry.attach(adapter: OTel)

      assert OpenTelemetry.config()[:adapter] == OTel
    end

    test "an app config that is not a keyword list is a clear error" do
      Application.put_env(:legion, :open_telemetry, %{adapter: Braintrust})

      assert_raise ArgumentError, ~r/must be a keyword list/, fn -> OpenTelemetry.attach() end
    end
  end

  describe "configure/2" do
    # Evaluates `body` as a config/runtime.exs file, the way Mix and releases
    # do; the result is returned, not applied to the app env.
    defp runtime_config(body), do: Config.Reader.eval!("runtime.exs", "import Config\n" <> body)

    test "writes the adapter's exporter config and selects the adapter for attach/1" do
      config =
        runtime_config("""
        Legion.OpenTelemetry.configure(Legion.OpenTelemetry.Adapter.Datadog,
          api_key: "key", site: "datadoghq.eu", ml_app: "my_app")
        """)

      assert config[:legion][:open_telemetry] == [adapter: Datadog]

      assert config[:opentelemetry] == [
               traces_exporter: :otlp,
               resource: [service: [name: "my_app"]]
             ]

      assert config[:opentelemetry_exporter][:otlp_endpoint] == "https://otlp.datadoghq.eu"
    end

    test "warns when the same config already set a trace exporter" do
      stderr =
        capture_io(:stderr, fn ->
          runtime_config("""
          config :opentelemetry, traces_exporter: {:otel_exporter_stdout, []}
          Legion.OpenTelemetry.configure(Legion.OpenTelemetry.Adapter.Braintrust,
            api_key: "key", project: "my_app")
          """)
        end)

      assert stderr =~ "traces_exporter"
      assert stderr =~ "Collector"
    end

    test "rejects invalid vendor options" do
      assert_raise NimbleOptions.ValidationError, ~r/required :api_key option not found/, fn ->
        runtime_config("""
        Legion.OpenTelemetry.configure(Legion.OpenTelemetry.Adapter.Datadog, ml_app: "my_app")
        """)
      end
    end

    test "raises for an adapter without exporter config" do
      assert_raise ArgumentError, ~r/has no exporter_config\/1/, fn ->
        runtime_config("Legion.OpenTelemetry.configure(Legion.OpenTelemetry.Adapter.OTel, [])")
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
      legion_ids = Enum.map(:telemetry.list_handlers([:legion]), & &1.id)
      refute "legion-otel" in legion_ids
      assert Application.get_env(:req_llm, :telemetry) == []
      assert OpenTelemetry.config() == nil
    end

    test "returns {:error, :not_found} when nothing is attached" do
      assert OpenTelemetry.detach() == {:error, :not_found}
    end
  end
end
