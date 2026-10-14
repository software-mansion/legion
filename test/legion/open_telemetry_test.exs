defmodule Legion.OpenTelemetryTest do
  use ExUnit.Case, async: false
  use Mimic

  setup :set_mimic_global

  import Legion.Test.Support.Env, only: [put_env: 3, put_system_env: 2]
  import Legion.Test.Support.LLMStub, only: [reply_with: 1, response: 1, return: 1]

  alias Legion.Executor
  alias Legion.OpenTelemetry
  alias Legion.OpenTelemetry.Adapter.Datadog
  alias Legion.Test.Support.{FakeOTelAdapter, MathAgent}

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
    on_exit(fn -> OpenTelemetry.detach() end)
    :ok
  end

  # Stubs the LLM so each call reports the options the executor passed.
  defp report_opts_to(test_pid) do
    stub(ReqLLM, :generate_object, fn _model, _messages, _schema, opts ->
      send(test_pid, {:llm_opts, opts})
      {:ok, response(return("done"))}
    end)
  end

  describe "attach/1" do
    test "forwards every LLM request as a client chat span to the adapter" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      reply_with(return("done"))

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
      reply_with(return("done"))

      {:ok, pid} = Legion.start_link(MathAgent)
      agent_id = Legion.get_agent_id(pid)
      assert {:ok, "done"} = Legion.call(pid, "hi")

      assert_receive {:otel, :start_span, _, @span_name, attrs, _}
      assert attrs[:"gen_ai.conversation.id"] == agent_id
    end

    test "hands every LLM call the telemetry options, host config and conversation id" do
      put_env(:req_llm, :telemetry, payloads: :raw)
      report_opts_to(self())

      {:ok, pid} = Legion.start_link(MathAgent)
      agent_id = Legion.get_agent_id(pid)
      assert {:ok, "done"} = Legion.call(pid, "hi")

      assert_receive {:llm_opts, opts}
      assert opts[:telemetry][:payloads] == :raw
      assert opts[:telemetry][:conversation_id] == agent_id
    end

    test "records chat content by default, as one JSON array string per attribute" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter)
      reply_with(return("done"))

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      assert_receive {:otel, :start_span, _, @span_name, attrs, _}

      assert [%{"role" => "user", "parts" => [%{"content" => "hi"}]}] =
               Jason.decode!(attrs[:"gen_ai.input.messages"])
    end

    test "content: :none keeps messages off chat spans" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :none)
      reply_with(return("done"))

      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      assert_receive {:otel, :start_span, _, @span_name, attrs, _}
      refute Map.has_key?(attrs, :"gen_ai.input.messages")
      assert_receive {:otel, :set_attributes, _, attrs, _}
      refute Map.has_key?(attrs, :"gen_ai.output.messages")
    end

    test "req_llm: [adapter: ...] hands ReqLLM spans to the host's adapter instead" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, req_llm: [adapter: HostReqLLMAdapter])
      reply_with(return("done"))

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

      reply_with(return("done"))
      assert {:ok, "done"} = Legion.execute(MathAgent, "hi")

      # One chat span per request: the first attachment is gone, not doubled.
      assert_receive {:otel, :start_span, _, @span_name, _, _}
      refute_receive {:otel, :start_span, _, @span_name, _, _}, 100
    end

    test "an adapter with no tracer leaves nothing attached, including a re-attach" do
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)

      assert OpenTelemetry.attach(adapter: UnavailableAdapter) ==
               {:error, :opentelemetry_unavailable}

      assert OpenTelemetry.config() == nil
      legion_ids = Enum.map(:telemetry.list_handlers([:legion]), & &1.id)
      refute "legion-otel" in legion_ids
    end
  end

  describe "telemetry_opts/0" do
    test "content: :attributes asks for raw payloads, leaving the host's config alone" do
      put_env(:req_llm, :telemetry, [])
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)

      assert Executor.telemetry_opts()[:payloads] == :raw
      assert Application.get_env(:req_llm, :telemetry) == []
    end

    test "keeps a :payloads setting the host configured" do
      put_env(:req_llm, :telemetry, payloads: :none)
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :attributes)

      assert Executor.telemetry_opts()[:payloads] == :none
    end

    test "content: :none asks for no payloads" do
      put_env(:req_llm, :telemetry, [])
      :ok = OpenTelemetry.attach(adapter: FakeOTelAdapter, content: :none)

      refute Keyword.has_key?(Executor.telemetry_opts(), :payloads)
    end

    test "a host config that is neither a list nor a map is dropped" do
      put_env(:req_llm, :telemetry, false)

      assert Executor.telemetry_opts() == []

      Vault.unsafe_put(:agent_id, "agent-1")
      assert Executor.telemetry_opts() == [conversation_id: "agent-1"]
    end
  end

  describe "attach/1 with a vendor adapter in config" do
    @datadog [api_key: "key", site: "datadoghq.eu", ml_app: "my-app"]

    test "resolves the adapter shorthand and takes the other options from config" do
      put_env(:legion, OpenTelemetry, adapter: :datadog, vendor: @datadog, iteration_spans: true)
      put_env(:opentelemetry, :traces_exporter, {Legion.OpenTelemetry.Exporter, []})

      :ok = OpenTelemetry.attach()

      assert OpenTelemetry.config()[:adapter] == Datadog
      assert OpenTelemetry.config()[:tracer] == Legion.OpenTelemetry.Adapter.OTel
      assert OpenTelemetry.config()[:iteration_spans] == true
    end

    test "keeps the vendor's settings out of the configuration handlers and adapters get" do
      put_env(:legion, OpenTelemetry, adapter: :datadog, vendor: @datadog)
      put_env(:opentelemetry, :traces_exporter, {Legion.OpenTelemetry.Exporter, []})

      :ok = OpenTelemetry.attach()

      refute Keyword.has_key?(OpenTelemetry.config(), :vendor)
    end

    test "raises when the vendor settings have no adapter in config to use them" do
      put_env(:legion, OpenTelemetry, vendor: @datadog)
      put_env(:opentelemetry, :traces_exporter, {Legion.OpenTelemetry.Exporter, []})

      error = assert_raise ArgumentError, fn -> OpenTelemetry.attach(adapter: :datadog) end
      assert Exception.message(error) =~ "takes its vendor from config"
    end

    test "a blank endpoint override is an override: the exporter parses it as one" do
      put_env(:legion, OpenTelemetry, adapter: :datadog, vendor: @datadog)
      put_env(:opentelemetry, :traces_exporter, {Legion.OpenTelemetry.Exporter, []})
      put_system_env("OTEL_EXPORTER_OTLP_ENDPOINT", "")

      assert_raise ArgumentError, fn -> OpenTelemetry.attach() end
    end

    test "raises on invalid vendor options, naming the option but not its value" do
      put_env(:legion, OpenTelemetry, adapter: :datadog, vendor: [api_key: 12_345, ml_app: "a"])
      put_env(:opentelemetry, :traces_exporter, {Legion.OpenTelemetry.Exporter, []})

      error = assert_raise ArgumentError, fn -> OpenTelemetry.attach() end
      assert Exception.message(error) =~ ":api_key"
      refute Exception.message(error) =~ "12345"
    end

    test "raises with the config line to add when the SDK does not export through Legion" do
      put_env(:legion, OpenTelemetry, adapter: :datadog, vendor: @datadog)
      put_env(:opentelemetry, :traces_exporter, :none)

      assert_raise ArgumentError,
                   ~r/config :opentelemetry, traces_exporter: \{Legion.OpenTelemetry.Exporter, \[\]\}/,
                   fn -> OpenTelemetry.attach() end
    end

    test "raises when an endpoint override would receive the vendor's headers" do
      put_env(:legion, OpenTelemetry, adapter: :datadog, vendor: @datadog)
      put_env(:opentelemetry, :traces_exporter, {Legion.OpenTelemetry.Exporter, []})
      put_system_env("OTEL_EXPORTER_OTLP_ENDPOINT", "https://collector.example.com")

      error = assert_raise ArgumentError, fn -> OpenTelemetry.attach() end
      assert Exception.message(error) =~ "OTEL_EXPORTER_OTLP_ENDPOINT"
      refute Exception.message(error) =~ "collector.example.com"
    end

    test "attaches when the endpoint override replaces the headers as well" do
      put_env(:legion, OpenTelemetry, adapter: :datadog, vendor: @datadog)
      put_env(:opentelemetry, :traces_exporter, {Legion.OpenTelemetry.Exporter, []})
      put_system_env("OTEL_EXPORTER_OTLP_ENDPOINT", "https://collector.example.com")
      put_system_env("OTEL_EXPORTER_OTLP_HEADERS", "x-tenant=acme")

      assert OpenTelemetry.attach() == :ok
    end

    test "names another traces_exporter without its options, which hold its credentials" do
      put_env(:legion, OpenTelemetry, adapter: :datadog, vendor: @datadog)

      put_env(
        :opentelemetry,
        :traces_exporter,
        {:opentelemetry_exporter, %{headers: [{"x-honeycomb-team", "hcaik_SUPER_SECRET"}]}}
      )

      error = assert_raise ArgumentError, fn -> OpenTelemetry.attach() end
      assert Exception.message(error) =~ ":opentelemetry_exporter"
      refute Exception.message(error) =~ "hcaik_SUPER_SECRET"
    end

    test "raises when :vendor is passed to attach/1, which the exporter never reads" do
      assert_raise ArgumentError, ~r/config :legion, Legion.OpenTelemetry/, fn ->
        OpenTelemetry.attach(adapter: :datadog, vendor: @datadog)
      end
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
