defmodule Legion.AgentServerTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Legion.RateLimiter.ExceededError
  alias Legion.RateLimiter.Policy
  alias Legion.RateLimiter.Rule
  alias Legion.Store.Payload
  alias Legion.Test.Support.MathAgent
  alias ReqLLM.Message.ContentPart

  defmodule TestRateLimiter do
    @moduledoc "Limiter whose verdict and observer both travel in each rule's identity."
    @behaviour Legion.RateLimiter

    @impl Legion.RateLimiter
    def enforce!(agent_id, rules) do
      Enum.each(rules, fn %Rule{identity: identity, policy: policy} ->
        if pid = identity["report_to"], do: send(pid, {:enforced, agent_id, identity, policy})

        if identity["verdict"] == :reject do
          raise ExceededError,
            agent_id: agent_id,
            identity: identity,
            policy: policy,
            usage: %{agents: 3, tokens: nil},
            violations: [:max_agents]
        end
      end)

      :ok
    end
  end

  defmodule ConversationBindingsAgent do
    @moduledoc "Agent with bindings persisted across the whole conversation."
    use Legion.Agent

    def config, do: %{binding_scope: :conversation}
  end

  defmodule ConfiguredAgent do
    @moduledoc "Test agent with custom config."
    use Legion.Agent

    def config, do: %{model: "agent-model"}
    def tools, do: [Legion.Test.Support.MathTool]
  end

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

  setup :set_mimic_global

  @moduletag capture_log: true

  defp llm_response(result, turn_usage \\ 0) do
    llm_object(%{"action" => "return", "code" => "", "result" => result}, turn_usage)
  end

  defp llm_eval_response(code, turn_usage \\ 0) do
    llm_object(%{"action" => "eval_and_complete", "code" => code, "result" => ""}, turn_usage)
  end

  defp llm_eval_continue_response(code, turn_usage \\ 0) do
    llm_object(
      %{"action" => "eval_and_continue", "code" => code, "result" => ""},
      turn_usage
    )
  end

  defp llm_object(object, turn_usage) do
    {:ok,
     %ReqLLM.Response{
       id: "test",
       model: "test",
       context: nil,
       object: object,
       usage: %{turn_usage: turn_usage}
     }}
  end

  describe "get_messages/1" do
    test "returns conversation history from a running agent" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent)
      {:ok, _} = Legion.call(pid, "What is the capital of France?")

      messages = Legion.get_messages(pid)

      assert [
               %{role: "system", type: :system, content: _system},
               %{role: "user", type: :user, content: "What is the capital of France?", at: at},
               %{role: "assistant", type: :assistant} | _
             ] = messages

      assert is_integer(at)
    end
  end

  describe "start_monitor/2" do
    test "starts an agent and returns a monitor reference" do
      assert {:ok, {pid, monitor_ref}} = Legion.AgentServer.start_monitor(MathAgent)
      assert Process.alive?(pid)

      GenServer.stop(pid)

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}
    end
  end

  describe "config validation" do
    test "warns about unknown config keys" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("ok")
      end)

      log =
        capture_log(fn ->
          {:ok, pid} = Legion.start_link(MathAgent, bogus_key: true)
          {:ok, _} = Legion.call(pid, "hi")
        end)

      assert log =~ "Unknown Legion config keys: [:bogus_key]"
    end
  end

  describe "config resolution" do
    test "call-time opts override agent config" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn model, _messages, _schema ->
        send(test_pid, {:model_used, model})
        llm_response("ok")
      end)

      {:ok, pid} = Legion.start_link(ConfiguredAgent, model: "call-model")
      {:ok, _} = Legion.call(pid, "hi")

      assert_receive {:model_used, "call-model"}
    end

    test "agent config overrides application config" do
      Application.put_env(:legion, :config, %{model: "app-model"})

      on_exit(fn -> Application.delete_env(:legion, :config) end)

      test_pid = self()

      stub(ReqLLM, :generate_object, fn model, _messages, _schema ->
        send(test_pid, {:model_used, model})
        llm_response("ok")
      end)

      {:ok, pid} = Legion.start_link(ConfiguredAgent)
      {:ok, _} = Legion.call(pid, "hi")

      assert_receive {:model_used, "agent-model"}
    end
  end

  describe "terminate/2" do
    test "emits stopped event when agent terminates" do
      stub(ReqLLM, :generate_object, fn _, _, _ -> llm_response("ok") end)

      ref = :telemetry_test.attach_event_handlers(self(), [[:legion, :agent, :stopped]])
      on_exit(fn -> :telemetry.detach(ref) end)

      {:ok, pid} = Legion.start_link(MathAgent)
      GenServer.stop(pid)

      assert_receive {[:legion, :agent, :stopped], ^ref, _measurements,
                      %{agent: Legion.Test.Support.MathAgent}}
    end
  end

  defp capture_user_content(test_pid) do
    stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
      user_msg = Enum.find(messages, &(&1[:role] == "user"))
      send(test_pid, {:user_content, user_msg[:content]})
      llm_response("ok")
    end)
  end

  describe "multipart messages" do
    test "passes a text + image part list through to the LLM unchanged" do
      capture_user_content(self())

      parts = [
        ContentPart.text("Describe this image."),
        ContentPart.image(<<1, 2, 3>>, "image/png")
      ]

      assert {:ok, "ok"} = Legion.execute(MathAgent, {:multipart, parts})
      assert_received {:user_content, ^parts}
    end

    test "supports text + image_url parts" do
      capture_user_content(self())

      parts = [
        ContentPart.text("What is in this picture?"),
        ContentPart.image_url("https://example.com/photo.png")
      ]

      assert {:ok, "ok"} = Legion.execute(MathAgent, {:multipart, parts})
      assert_received {:user_content, ^parts}
    end

    test "supports a text-only part list" do
      capture_user_content(self())

      parts = [ContentPart.text("hello")]

      assert {:ok, "ok"} = Legion.execute(MathAgent, {:multipart, parts})
      assert_received {:user_content, ^parts}
    end

    test "supports an empty parts list" do
      capture_user_content(self())

      assert {:ok, "ok"} = Legion.execute(MathAgent, {:multipart, []})
      assert_received {:user_content, []}
    end
  end

  describe "image shorthand messages" do
    test "wraps {:image, data, media_type} into a single image ContentPart" do
      capture_user_content(self())

      data = <<1, 2, 3>>
      expected = [ContentPart.image(data, "image/png")]

      assert {:ok, "ok"} = Legion.execute(MathAgent, {:image, data, "image/png"})
      assert_received {:user_content, ^expected}
    end

    test "wraps {:image_url, url} into a single image_url ContentPart" do
      capture_user_content(self())

      url = "https://example.com/photo.png"
      expected = [ContentPart.image_url(url)]

      assert {:ok, "ok"} = Legion.execute(MathAgent, {:image_url, url})
      assert_received {:user_content, ^expected}
    end
  end

  describe "non-binary messages" do
    defmodule SampleStruct do
      defstruct [:id, :name]
    end

    test "structs are rendered via inspect" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        user_msg = Enum.find(messages, &(&1[:role] == "user"))
        send(test_pid, {:user_content, user_msg[:content]})
        llm_response("ok")
      end)

      assert {:ok, "ok"} = Legion.execute(MathAgent, %SampleStruct{id: 7, name: "ada"})

      assert_received {:user_content, content}
      assert content == inspect(%SampleStruct{id: 7, name: "ada"}, limit: :infinity)
    end

    test "maps are rendered via inspect" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        user_msg = Enum.find(messages, &(&1[:role] == "user"))
        send(test_pid, {:user_content, user_msg[:content]})
        llm_response("ok")
      end)

      assert {:ok, "ok"} = Legion.execute(MathAgent, %{id: 1, name: "x"})

      assert_received {:user_content, content}
      assert content == inspect(%{id: 1, name: "x"}, limit: :infinity)
    end

    test "terms containing PIDs do not crash the GenServer" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        user_msg = Enum.find(messages, &(&1[:role] == "user"))
        send(test_pid, {:user_content, user_msg[:content]})
        llm_response("ok")
      end)

      {:ok, pid} = Legion.start_link(MathAgent)
      assert {:ok, "ok"} = Legion.call(pid, %{pid: self()})
      assert Process.alive?(pid)

      assert_received {:user_content, content}
      assert content =~ inspect(self())
    end
  end

  describe "max_message_length" do
    test "truncates binary user input longer than the limit" do
      capture_user_content(self())

      {:ok, pid} = Legion.start_link(MathAgent, max_message_length: 100)
      {:ok, _} = Legion.call(pid, String.duplicate("a", 5_000))

      assert_received {:user_content, content}
      assert String.starts_with?(content, String.duplicate("a", 100))
      assert content =~ "[... truncated 4900 bytes ...]"
    end

    test "passes binary user input shorter than the limit through unchanged" do
      capture_user_content(self())

      {:ok, pid} = Legion.start_link(MathAgent, max_message_length: 100)
      {:ok, _} = Legion.call(pid, "hello")

      assert_received {:user_content, "hello"}
    end

    test "truncates text parts of multipart content individually" do
      capture_user_content(self())

      parts = [
        ContentPart.text(String.duplicate("a", 5_000)),
        ContentPart.image_url("https://example.com/image.png")
      ]

      {:ok, pid} = Legion.start_link(MathAgent, max_message_length: 100)
      {:ok, _} = Legion.call(pid, {:multipart, parts})

      assert_received {:user_content, [text_part, image_part]}
      assert String.starts_with?(text_part.text, String.duplicate("a", 100))
      assert text_part.text =~ "[... truncated 4900 bytes ...]"
      assert image_part == ContentPart.image_url("https://example.com/image.png")
    end

    test ":infinity disables truncation" do
      capture_user_content(self())

      big = String.duplicate("a", 5_000)

      {:ok, pid} = Legion.start_link(MathAgent, max_message_length: :infinity)
      {:ok, _} = Legion.call(pid, big)

      assert_received {:user_content, ^big}
    end

    test "nil raises ArgumentError" do
      assert_raise ArgumentError,
                   ~r/expected :max_message_length to be a positive integer or :infinity/,
                   fn ->
                     Legion.start_link(MathAgent, max_message_length: nil)
                   end
    end

    test "zero raises ArgumentError" do
      assert_raise ArgumentError,
                   ~r/expected :max_message_length to be a positive integer or :infinity/,
                   fn ->
                     Legion.start_link(MathAgent, max_message_length: 0)
                   end
    end

    test "per-agent config overrides application config" do
      Application.put_env(:legion, :config, %{max_message_length: 10})
      on_exit(fn -> Application.delete_env(:legion, :config) end)

      capture_user_content(self())

      {:ok, pid} = Legion.start_link(MathAgent, max_message_length: 1_000)
      {:ok, _} = Legion.call(pid, String.duplicate("a", 50))

      assert_received {:user_content, content}
      assert byte_size(content) == 50
    end

    test "application config applies when no per-agent override is given" do
      Application.put_env(:legion, :config, %{max_message_length: 10})
      on_exit(fn -> Application.delete_env(:legion, :config) end)

      capture_user_content(self())

      {:ok, pid} = Legion.start_link(MathAgent)
      {:ok, _} = Legion.call(pid, String.duplicate("a", 50))

      assert_received {:user_content, content}
      assert String.starts_with?(content, String.duplicate("a", 10))
      assert content =~ "[... truncated 40 bytes ...]"
    end

    test "default of 20_000 applies when no override is given anywhere" do
      Application.delete_env(:legion, :config)
      on_exit(fn -> Application.delete_env(:legion, :config) end)

      capture_user_content(self())

      {:ok, pid} = Legion.start_link(MathAgent)
      {:ok, _} = Legion.call(pid, String.duplicate("a", 25_000))

      assert_received {:user_content, content}
      assert String.starts_with?(content, String.duplicate("a", 20_000))
      assert content =~ "[... truncated 5000 bytes ...]"
    end
  end

  describe "cast/2" do
    test "processes message and updates state without blocking" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent)
      assert :ok = Legion.cast(pid, "What is the capital of France?")

      Process.sleep(100)

      messages = Legion.get_messages(pid)

      assert [
               %{role: "system"},
               %{role: "user", content: "What is the capital of France?"},
               %{role: "assistant"} | _
             ] = messages
    end
  end

  defmodule MemoryStore do
    @behaviour Legion.Store

    def start_link, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    @impl Legion.Store
    def get(agent_id), do: Agent.get(__MODULE__, &Map.get(&1, agent_id, :error))

    @impl Legion.Store
    def list(limit) do
      Agent.get(__MODULE__, fn state ->
        state
        |> Map.values()
        |> Enum.flat_map(fn
          {:ok, %Payload{} = payload} -> [payload]
          _ -> []
        end)
        |> Enum.take(limit)
      end)
    end

    def load(agent_id) do
      case get(agent_id) do
        {:ok, %Payload{conversation_state: state}} when not is_nil(state) -> {:ok, state}
        _ -> :error
      end
    end

    @impl Legion.Store
    def save(%Payload{} = payload) do
      Agent.update(__MODULE__, fn state ->
        existing =
          case Map.get(state, payload.agent_id) do
            {:ok, stored} -> stored
            nil -> %Payload{agent_id: payload.agent_id}
          end

        merged = merge(existing, payload)

        state =
          state
          |> Map.put(payload.agent_id, {:ok, merged})
          |> Map.update({:writes, payload.agent_id}, [payload], &[payload | &1])

        if watcher = Map.get(state, :save_watcher), do: send(watcher, {:store_saved, payload})

        state
      end)

      :ok
    end

    def save(_invalid), do: :error

    def writes(agent_id) do
      Agent.get(__MODULE__, &Map.get(&1, {:writes, agent_id}, []))
      |> Enum.reverse()
    end

    def watch_saves(test_pid) do
      Agent.update(__MODULE__, &Map.put(&1, :save_watcher, test_pid))
    end

    def statuses(agent_id) do
      agent_id
      |> writes()
      |> Enum.map(& &1.status)
      |> Enum.reject(&is_nil/1)
    end

    def get_run(agent_id) do
      case get(agent_id) do
        {:ok, %Payload{agent_module: nil}} -> nil
        {:ok, %Payload{} = payload} -> payload
        :error -> nil
      end
    end

    def runs do
      Agent.get(__MODULE__, fn state ->
        for {_agent_id, {:ok, %Payload{agent_module: agent_module} = payload}} <- state,
            not is_nil(agent_module),
            do: payload
      end)
    end

    defp merge(existing, incoming) do
      Enum.reduce(Map.from_struct(incoming), existing, fn
        {:agent_id, _agent_id}, payload -> payload
        {_field, nil}, payload -> payload
        {field, value}, payload -> Map.put(payload, field, value)
      end)
    end
  end

  defmodule EmptyStore do
    @behaviour Legion.Store

    @impl Legion.Store
    def get(_agent_id), do: :error

    @impl Legion.Store
    def list(_limit), do: []

    @impl Legion.Store
    def save(_payload), do: :ok
  end

  defmodule StepMemoryStore do
    @behaviour Legion.Store

    alias Legion.AgentServerTest.MemoryStore

    @impl Legion.Store
    def persistence_frequency, do: :step

    @impl Legion.Store
    def get(agent_id), do: MemoryStore.get(agent_id)

    @impl Legion.Store
    def list(limit), do: MemoryStore.list(limit)

    @impl Legion.Store
    def save(payload), do: MemoryStore.save(payload)
  end

  describe "persistence" do
    setup do
      start_supervised!(%{id: MemoryStore, start: {MemoryStore, :start_link, []}})
      :ok
    end

    test "passes the store persistence frequency into the agent server state" do
      {:ok, pid} =
        Legion.start_link(MathAgent, store: StepMemoryStore, agent_id: "step-frequency")

      assert %{persistence_frequency: :step} = :sys.get_state(pid)
    end

    test "brackets each turn with :running and :idle status writes" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "statuses")
      {:ok, _} = Legion.call(pid, "What is the capital of France?")

      assert MemoryStore.statuses("statuses") == [:running, :idle]

      {:ok, _} = Legion.call(pid, "And of Germany?")
      assert MemoryStore.statuses("statuses") == [:running, :idle, :running, :idle]
    end

    test "writes the new Store payloads for a completed message" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "payloads")
      {:ok, "Paris"} = Legion.call(pid, "What is the capital of France?")

      [started, running, completed] = MemoryStore.writes("payloads")

      assert %Payload{
               agent_id: "payloads",
               agent_module: MathAgent,
               parent_agent_id: nil,
               started_at: started_at,
               status: nil,
               conversation_state: nil,
               usage: []
             } = started

      assert is_struct(started_at, NaiveDateTime)

      assert %Payload{
               agent_id: "payloads",
               status: :running,
               conversation_state: %{
                 messages: [%{role: "user", content: "What is the capital of France?"}],
                 bindings: []
               }
             } = running

      assert %Payload{
               agent_id: "payloads",
               status: :idle,
               conversation_state: %{messages: messages, bindings: []}
             } = completed

      assert [
               %{role: "user", content: "What is the capital of France?"},
               %{role: "assistant"} | _
             ] = messages

      refute Enum.any?(messages, &(&1.role == "system"))
    end

    test "accumulates timestamped, string-keyed usage across turns" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> llm_response("first", 7)
          2 -> llm_response("second", 11)
        end
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "usage-turns")
      assert {:ok, "first"} = Legion.call(pid, "first turn")
      assert {:ok, "second"} = Legion.call(pid, "second turn")

      assert {:ok, payload} = MemoryStore.get("usage-turns")

      assert [
               %{"turn_usage" => 7, "at" => first_timestamp},
               %{"turn_usage" => 11, "at" => second_timestamp}
             ] = Map.fetch!(payload, :usage)

      assert first_timestamp <= second_timestamp
    end

    test "usage entries name the persisted assistant message their request produced" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> llm_eval_continue_response("x = 1", 7)
          2 -> llm_response("first", 11)
          3 -> llm_response("second", 13)
        end
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "usage-index")
      assert {:ok, "first"} = Legion.call(pid, "first turn")
      assert {:ok, "second"} = Legion.call(pid, "second turn")

      assert {:ok, %Payload{usage: usage, conversation_state: %{messages: messages}}} =
               MemoryStore.get("usage-index")

      # [user, assistant, eval_result, assistant, user, assistant]
      assert [%{"message_index" => 1}, %{"message_index" => 3}, %{"message_index" => 5}] = usage

      for %{"message_index" => index} <- usage do
        assert %{type: :assistant} = Enum.at(messages, index)
      end
    end

    test "restored conversations add only new invocation usage" do
      assert :ok =
               MemoryStore.save(%Payload{
                 agent_id: "usage-restore",
                 usage: [%{turn_usage: 100}],
                 conversation_state: %{messages: [], bindings: [], executor_state: nil}
               })

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("new work", 20)
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "usage-restore")
      assert {:ok, "new work"} = Legion.call(pid, "continue")

      assert {:ok,
              %Payload{usage: [%{turn_usage: 100}, %{"turn_usage" => 20, "at" => timestamp}]}} =
               MemoryStore.get("usage-restore")

      assert is_integer(timestamp)
    end

    test "does not update usage when globally disabled" do
      previous = Application.get_env(:legion, :track_usage, :unset)
      Application.put_env(:legion, :track_usage, false)

      on_exit(fn ->
        if previous == :unset,
          do: Application.delete_env(:legion, :track_usage),
          else: Application.put_env(:legion, :track_usage, previous)
      end)

      assert :ok =
               MemoryStore.save(%Payload{
                 agent_id: "usage-disabled",
                 usage: [%{turn_usage: 100}],
                 conversation_state: %{messages: [], bindings: [], executor_state: nil}
               })

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("new work", 20)
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "usage-disabled")
      assert {:ok, "new work"} = Legion.call(pid, "continue")

      assert {:ok, %Payload{usage: [%{turn_usage: 100}]}} =
               MemoryStore.get("usage-disabled")
    end

    test "saves a snapshot before the caller receives its reply" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "receipt")
      {:ok, _} = Legion.call(pid, "What is the capital of France?")

      assert {:ok, %{messages: messages, bindings: []}} = MemoryStore.load("receipt")

      assert [
               %{role: "user", content: "What is the capital of France?"},
               %{role: "assistant"} | _
             ] = messages

      refute Enum.any?(messages, &(&1.role == "system"))
    end

    test "persists the user message before the turn runs" do
      test_process = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        send(test_process, {:snapshot_during_turn, MemoryStore.load("early-save")})
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "early-save")
      {:ok, _} = Legion.call(pid, "What is the capital of France?")

      assert_received {:snapshot_during_turn, {:ok, %{messages: messages}}}
      assert [%{role: "user", content: "What is the capital of France?"}] = messages
    end

    test "a one-off execute/3 persists its snapshot before stopping" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, _} =
        Legion.execute(MathAgent, "What is the capital of France?",
          store: MemoryStore,
          agent_id: "one-off"
        )

      assert {:ok, %{messages: [%{role: "user"}, %{role: "assistant"} | _]}} =
               MemoryStore.load("one-off")
    end

    test "does not persist bindings under the default :turn scope" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_eval_response("x = 42\nreturn x")
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "turn-bindings")
      {:ok, 42} = Legion.call(pid, "set x")

      assert {:ok, %{bindings: []}} = MemoryStore.load("turn-bindings")
    end

    test "persists conversation-scoped bindings in the completed payload" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_eval_response("x = 42")
      end)

      {:ok, pid} =
        Legion.start_link(ConversationBindingsAgent,
          store: MemoryStore,
          agent_id: "conversation-bindings",
          sandbox: Legion.Sandbox.Elixir
        )

      assert {:ok, 42} = Legion.call(pid, "set x")

      assert {:ok,
              %Payload{
                conversation_state: %{bindings: [x: 42]}
              }} = MemoryStore.get("conversation-bindings")
    end

    test "a :step store persists a complete eval_and_continue checkpoint" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> llm_eval_continue_response("x = 42")
          2 -> llm_response("done")
        end
      end)

      {:ok, pid} =
        Legion.start_link(MathAgent,
          store: StepMemoryStore,
          agent_id: "step-continue",
          sandbox: Legion.Sandbox.Elixir
        )

      assert {:ok, "done"} = Legion.call(pid, "compute")

      [_started, running, checkpoint, completed] = MemoryStore.writes("step-continue")

      assert %Payload{
               status: :running,
               conversation_state: %{
                 messages: [%{type: :user}],
                 bindings: [],
                 executor_state: :nonexistent
               }
             } = running

      assert %Payload{
               status: nil,
               conversation_state: %{
                 messages: [%{type: :user}, %{type: :assistant}, %{type: :eval_result}],
                 bindings: [x: 42],
                 executor_state: %{phase: :awaiting_llm, iteration: 1, retries: 0}
               }
             } = checkpoint

      assert %Payload{status: :idle, conversation_state: final_state} = completed
      assert final_state.bindings == []
      assert final_state.executor_state == :nonexistent
    end

    test "a :step store persists eval_and_complete before the final snapshot" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_eval_response("return 1 + 1")
      end)

      {:ok, pid} =
        Legion.start_link(MathAgent, store: StepMemoryStore, agent_id: "step-complete")

      assert {:ok, 2} = Legion.call(pid, "compute")

      [_started, _running, checkpoint, completed] = MemoryStore.writes("step-complete")

      assert %Payload{
               status: nil,
               conversation_state: %{
                 executor_state: %{phase: :completing, iteration: 0, retries: 0}
               }
             } = checkpoint

      assert %Payload{status: :idle, conversation_state: final_state} = completed
      assert final_state.executor_state == :nonexistent
    end

    test "a :step store persists retry state after an error message" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> llm_eval_response("raise \"boom\"")
          2 -> llm_response("recovered")
        end
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: StepMemoryStore, agent_id: "step-retry")
      assert {:ok, "recovered"} = Legion.call(pid, "compute")

      [_started, _running, checkpoint, _completed] = MemoryStore.writes("step-retry")

      assert %Payload{
               status: nil,
               conversation_state: %{
                 messages: messages,
                 bindings: [],
                 executor_state: %{phase: :awaiting_llm, iteration: 0, retries: 1}
               }
             } = checkpoint

      assert List.last(messages).type == :error
    end

    test "a :step store retains conversation bindings in the final snapshot" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_eval_response("x = 42")
      end)

      {:ok, pid} =
        Legion.start_link(ConversationBindingsAgent,
          store: StepMemoryStore,
          agent_id: "step-conversation-bindings",
          sandbox: Legion.Sandbox.Elixir
        )

      assert {:ok, 42} = Legion.call(pid, "compute")

      [_started, _running, checkpoint, completed] =
        MemoryStore.writes("step-conversation-bindings")

      assert checkpoint.conversation_state.bindings == [x: 42]
      assert completed.conversation_state.bindings == [x: 42]
    end

    test "a :step store persists empty iteration-scoped bindings" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_eval_response("x = 42\nreturn x")
      end)

      {:ok, pid} =
        Legion.start_link(MathAgent,
          store: StepMemoryStore,
          agent_id: "step-iteration-bindings",
          binding_scope: :iteration
        )

      assert {:ok, 42} = Legion.call(pid, "compute")

      [_started, _running, checkpoint, completed] =
        MemoryStore.writes("step-iteration-bindings")

      assert checkpoint.conversation_state.bindings == []
      assert completed.conversation_state.bindings == []
    end

    test "a :step store does not add a checkpoint for return" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("done")
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: StepMemoryStore, agent_id: "step-return")
      assert {:ok, "done"} = Legion.call(pid, "compute")

      assert [_started, _running, _completed] = MemoryStore.writes("step-return")
    end

    test "restores the conversation under a fresh system prompt after a restart" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "restore")
      {:ok, _} = Legion.call(pid, "What is the capital of France?")
      GenServer.stop(pid)

      {:ok, revived} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "restore")

      assert [
               %{role: "system"},
               %{role: "user", content: "What is the capital of France?"},
               %{role: "assistant"} | _
             ] = Legion.get_messages(revived)
    end

    test "restores conversation-scoped bindings after a restart" do
      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        assistant_count = Enum.count(messages, &(&1[:role] == "assistant"))

        if assistant_count == 0 do
          llm_eval_response("x = 42\nreturn x")
        else
          llm_eval_response("return x + 1")
        end
      end)

      {:ok, pid} =
        Legion.start_link(ConversationBindingsAgent, store: MemoryStore, agent_id: "bindings")

      {:ok, 42} = Legion.call(pid, "set x")
      GenServer.stop(pid)

      {:ok, revived} =
        Legion.start_link(ConversationBindingsAgent, store: MemoryStore, agent_id: "bindings")

      assert {:ok, 43} = Legion.call(revived, "use x")
    end

    test "generates an agent_id when a store is given without one" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore)
      agent_id = Legion.get_agent_id(pid)

      assert is_binary(agent_id)
      assert String.valid?(agent_id)
      {:ok, _} = Legion.call(pid, "What is the capital of France?")
      assert {:ok, _snapshot} = MemoryStore.load(agent_id)
    end

    test "uses a store configured globally, needing only an agent_id" do
      Application.put_env(:legion, :store, MemoryStore)
      on_exit(fn -> Application.delete_env(:legion, :store) end)

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent, agent_id: "global-store")
      {:ok, _} = Legion.call(pid, "What is the capital of France?")

      assert {:ok, _snapshot} = MemoryStore.load("global-store")
    end

    test "get_agent_id/1 returns a generated id without a store" do
      {:ok, pid} = Legion.start_link(MathAgent)
      assert is_binary(Legion.get_agent_id(pid))
    end

    test "raises when :agent_id is given without a :store" do
      assert_raise ArgumentError, ~r/:agent_id requires a :store/, fn ->
        Legion.start_link(MathAgent, agent_id: "orphan")
      end
    end

    test "rejects non-string explicit agent IDs" do
      for agent_id <- [:agent, make_ref(), <<0xFF>>] do
        assert_raise ArgumentError, ~r/:agent_id must be a valid UTF-8 string/, fn ->
          Legion.start_link(MathAgent, store: MemoryStore, agent_id: agent_id)
        end
      end
    end

    test "public identity operations reject invalid non-string agent IDs" do
      non_binary_agent_id = :agent
      non_utf8_agent_id = <<0xFF>>

      for operation <- [
            fn -> Legion.lookup(non_binary_agent_id) end,
            fn -> Legion.resume(non_binary_agent_id, store: MemoryStore) end,
            fn -> Legion.recover(non_binary_agent_id, store: MemoryStore) end,
            fn -> Legion.lookup(non_utf8_agent_id) end,
            fn -> Legion.resume(non_utf8_agent_id, store: MemoryStore) end,
            fn -> Legion.recover(non_utf8_agent_id, store: MemoryStore) end
          ] do
        assert_raise ArgumentError, ~r/:agent_id must be a valid UTF-8 string/, operation
      end
    end

    test "records run metadata on start" do
      {:ok, _pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "meta")

      assert [run] = MemoryStore.runs()
      assert run.agent_id == "meta"
      assert run.agent_module == MathAgent
      assert run.parent_agent_id == nil
      assert is_struct(run.started_at, NaiveDateTime)
    end

    test "registers the agent pid by agent_id" do
      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "lookup")

      assert {:ok, ^pid} = Legion.lookup("lookup")
    end

    test "allows only one live process to own an agent_id" do
      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "unique")

      assert {:error, {:already_started, ^pid}} =
               Legion.start_link(MathAgent, store: MemoryStore, agent_id: "unique")
    end

    test "concurrent starts atomically choose one owner for an agent_id" do
      caller = self()

      contenders =
        for _index <- 1..8 do
          Task.async(fn ->
            send(caller, {:ready, self()})

            receive do
              :start -> Legion.start_link(MathAgent, store: MemoryStore, agent_id: "race")
            end
          end)
        end

      contender_pids =
        for _index <- 1..8 do
          assert_receive {:ready, contender_pid}
          contender_pid
        end

      Enum.each(contender_pids, &send(&1, :start))
      results = Task.await_many(contenders)
      started_pids = for {:ok, pid} <- results, do: pid

      on_exit(fn ->
        Enum.each(started_pids, fn pid ->
          if Process.alive?(pid), do: GenServer.stop(pid)
        end)
      end)

      assert [winner] = started_pids

      assert Enum.count(results, &(&1 == {:error, {:already_started, winner}})) == 7
      assert {:ok, ^winner} = Legion.lookup("race")
    end

    test "resume/2 returns the recorded process while it is alive" do
      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "resume-live")

      assert Process.alive?(pid)
      assert {:ok, ^pid} = Legion.resume("resume-live", store: MemoryStore)
    end

    test "resume/2 validates the requested store before resolving a live process" do
      {:ok, _pid} =
        Legion.start_link(MathAgent, store: MemoryStore, agent_id: "resume-wrong-store")

      assert {:error, :not_resumable} =
               Legion.resume("resume-wrong-store", store: EmptyStore)
    end

    test "resume/2 restarts a stopped conversation from its run metadata" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "resume-dead")
      {:ok, _} = Legion.call(pid, "What is the capital of France?")
      GenServer.stop(pid)
      refute Process.alive?(pid)

      {:ok, revived} = Legion.resume("resume-dead", store: MemoryStore)

      assert Process.alive?(revived)

      assert [
               %{role: "system"},
               %{role: "user", content: "What is the capital of France?"},
               %{role: "assistant"} | _
             ] = Legion.get_messages(revived)
    end

    test "an awaiting-LLM checkpoint resumes with one request and finishes idle" do
      assert :ok =
               MemoryStore.save(%Payload{
                 agent_id: "resume-awaiting-llm",
                 agent_module: MathAgent,
                 status: :running,
                 usage: [],
                 conversation_state: %{
                   messages: [%{role: "user", type: :user, content: "compute"}],
                   bindings: [x: 42],
                   executor_state: %{phase: :awaiting_llm, iteration: 1, retries: 0}
                 }
               })

      MemoryStore.watch_saves(self())
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        send(test_pid, :llm_requested)
        llm_response("done")
      end)

      assert {:ok, _pid} = Legion.resume("resume-awaiting-llm", store: MemoryStore)
      assert_receive :llm_requested

      assert_receive {:store_saved,
                      %Payload{status: :idle, conversation_state: %{executor_state: :nonexistent}}}

      refute_receive :llm_requested, 50
    end

    test "a completing checkpoint resumes without a request and finishes idle" do
      assert :ok =
               MemoryStore.save(%Payload{
                 agent_id: "resume-completing",
                 agent_module: MathAgent,
                 status: :running,
                 usage: [],
                 conversation_state: %{
                   messages: [%{role: "user", type: :user, content: "compute"}],
                   bindings: [x: 42],
                   executor_state: %{phase: :completing, iteration: 1, retries: 0}
                 }
               })

      MemoryStore.watch_saves(self())
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        send(test_pid, :llm_requested)
        llm_response("unexpected")
      end)

      assert {:ok, _pid} = Legion.resume("resume-completing", store: MemoryStore)

      assert_receive {:store_saved,
                      %Payload{status: :idle, conversation_state: %{executor_state: :nonexistent}}}

      refute_receive :llm_requested, 100
    end

    test "resume/2 returns not_resumable for an agent_id the store has no run for" do
      assert {:error, :not_resumable} = Legion.resume("ghost", store: MemoryStore)
    end

    test "resume/2 returns not_resumable when the stored run has no agent module" do
      assert :ok =
               MemoryStore.save(%Payload{
                 agent_id: "resume-missing-agent-module",
                 agent_module: nil
               })

      assert {:error, :not_resumable} =
               Legion.resume("resume-missing-agent-module", store: MemoryStore)
    end

    test "resume/2 identifies itself when no store is configured" do
      assert_raise ArgumentError, ~r/resume\/2 requires a :store/, fn ->
        Legion.resume("missing-store")
      end
    end

    test "recover/2 identifies itself when no store is configured" do
      assert_raise ArgumentError, ~r/recover\/2 requires a :store/, fn ->
        Legion.recover("missing-store")
      end
    end

    test "recover/2 completes an interrupted run and stops its process" do
      assert :ok =
               MemoryStore.save(%Payload{
                 agent_id: "recover-awaiting-llm",
                 parent_agent_id: nil,
                 agent_module: MathAgent,
                 status: :running,
                 usage: [],
                 conversation_state: %{
                   messages: [%{role: "user", type: :user, content: "compute"}],
                   bindings: [x: 42],
                   executor_state: %{phase: :awaiting_llm, iteration: 1, retries: 0}
                 }
               })

      assert :ok = Legion.recover("recover-awaiting-llm", store: MemoryStore)

      assert {:ok, %Payload{status: :idle, conversation_state: %{executor_state: :nonexistent}}} =
               MemoryStore.get("recover-awaiting-llm")

      assert(
        case Legion.lookup("recover-awaiting-llm") do
          :error -> true
          {:ok, pid} -> not Process.alive?(pid)
        end
      )
    end

    test "recover/2 finishes an interrupted turn with the bindings its checkpoint saved" do
      agent_id = "recover-bindings-#{System.unique_integer([:positive])}"
      test_pid = self()
      request_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(request_count, 1, 1)

        case :counters.get(request_count, 1) do
          1 ->
            llm_eval_continue_response("x = 6 * 7")

          2 ->
            # Kill the agent mid-turn, after the first eval has been checkpointed.
            send(test_pid, {:checkpointed, StepMemoryStore.get(agent_id)})
            Process.exit(self(), :kill)
            llm_response("unreachable")

          _ ->
            llm_eval_response("return x")
        end
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: StepMemoryStore, agent_id: agent_id)
      Process.unlink(pid)
      reference = Process.monitor(pid)
      Legion.cast(pid, "compute")

      assert_receive {:checkpointed, {:ok, %Payload{conversation_state: checkpoint}}}, 5_000
      assert checkpoint.bindings != []
      assert_receive {:DOWN, ^reference, :process, ^pid, _reason}, 5_000

      assert :ok = Legion.recover(agent_id, store: StepMemoryStore)

      {:ok, %Payload{conversation_state: final}} = StepMemoryStore.get(agent_id)
      results = Enum.map(final.messages, &inspect(&1.content))
      assert Enum.any?(results, &(&1 =~ "42")), "recovered eval lost x: #{inspect(results)}"
    end

    test "recover/2 returns error when agent is running" do
      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "recover-running")

      assert :ok =
               MemoryStore.save(%Payload{
                 agent_id: "recover-running",
                 status: :running,
                 conversation_state: %{
                   messages: [%{role: "user", type: :user, content: "recover me"}],
                   bindings: [],
                   executor_state: :nonexistent
                 }
               })

      assert {:error, :already_running} = Legion.recover("recover-running", store: MemoryStore)

      assert Process.alive?(pid)
    end

    test "recover/2 validates the requested store before resolving a live process" do
      {:ok, _pid} =
        Legion.start_link(MathAgent, store: MemoryStore, agent_id: "recover-wrong-store")

      assert {:error, :not_recoverable} =
               Legion.recover("recover-wrong-store", store: EmptyStore)
    end

    test "recover/2 returns not_recoverable for an agent_id the store has no run for" do
      assert {:error, :not_recoverable} =
               Legion.recover("recover-missing", store: MemoryStore)
    end

    test "recover/2 returns not_recoverable when the stored run has no agent module" do
      assert :ok =
               MemoryStore.save(%Payload{
                 agent_id: "recover-missing-agent-module",
                 agent_module: nil,
                 status: :running
               })

      assert {:error, :not_recoverable} =
               Legion.recover("recover-missing-agent-module", store: MemoryStore)
    end

    test "recover/2 refuses an idle run" do
      assert :ok =
               MemoryStore.save(%Payload{
                 agent_id: "recover-idle-root",
                 parent_agent_id: nil,
                 agent_module: MathAgent,
                 status: :idle,
                 usage: [],
                 conversation_state: %{
                   messages: [%{role: "user", type: :user, content: "compute"}],
                   bindings: [x: 42],
                   executor_state: %{phase: :completing, iteration: 1, retries: 0}
                 }
               })

      assert {:error, :not_recoverable} = Legion.recover("recover-idle-root", store: MemoryStore)
    end

    test "recover/2 refuses a running child run" do
      assert :ok =
               MemoryStore.save(%Payload{
                 agent_id: "recover-running-child",
                 parent_agent_id: "recover-parent",
                 agent_module: MathAgent,
                 status: :running,
                 usage: [],
                 conversation_state: %{
                   messages: [%{role: "user", type: :user, content: "compute"}],
                   bindings: [x: 42],
                   executor_state: %{phase: :completing, iteration: 1, retries: 0}
                 }
               })

      assert {:error, :not_recoverable} =
               Legion.recover("recover-running-child", store: MemoryStore)
    end

    test "sub-agents inherit the parent store and link to the parent conversation" do
      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        if Enum.any?(messages, &(&1[:content] == "child task")) do
          llm_response("child done")
        else
          llm_eval_response(~s|AgentTool.call(ChildAgent, "child task")|)
        end
      end)

      {:ok, _} = Legion.execute(DelegatingAgent, "parent task", store: MemoryStore)

      runs = MemoryStore.runs()
      parent = Enum.find(runs, &(&1.agent_module == DelegatingAgent))
      child = Enum.find(runs, &(&1.agent_module == ChildAgent))

      assert child.parent_agent_id == parent.agent_id
      assert {:ok, %{messages: [%{content: "child task"} | _]}} = MemoryStore.load(child.agent_id)
    end
  end

  describe "binding_scope" do
    test "bindings do not persist across turns by default (:turn)" do
      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        assistant_count = Enum.count(messages, &(&1[:role] == "assistant"))

        if assistant_count == 0 do
          llm_eval_response("x = 42\nreturn x")
        else
          llm_eval_response("return x + 1")
        end
      end)

      {:ok, pid} = Legion.start_link(MathAgent)
      {:ok, 42} = Legion.call(pid, "set x")

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:cancel, :reached_max_retries} = Legion.call(pid, "use x")
      end)
    end

    test "bindings persist across turns with :conversation" do
      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        assistant_count = Enum.count(messages, &(&1[:role] == "assistant"))

        if assistant_count == 0 do
          llm_eval_response("x = 42\nreturn x")
        else
          llm_eval_response("return x + 1")
        end
      end)

      {:ok, pid} = Legion.start_link(ConversationBindingsAgent)
      {:ok, 42} = Legion.call(pid, "set x")
      assert {:ok, 43} = Legion.call(pid, "use x")
    end

    test "Elixir bindings persist across turns with :conversation" do
      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        assistant_count = Enum.count(messages, &(&1[:role] == "assistant"))

        if assistant_count == 0 do
          llm_eval_response("x = 42")
        else
          llm_eval_response("x + 1")
        end
      end)

      {:ok, pid} = Legion.start_link(ConversationBindingsAgent, sandbox: Legion.Sandbox.Elixir)
      {:ok, 42} = Legion.call(pid, "set x")
      assert {:ok, 43} = Legion.call(pid, "use x")
    end

    test "system prompt reflects binding_scope resolved from start_link opts, not agent.config()" do
      {:ok, pid} = Legion.start_link(MathAgent, binding_scope: :conversation)
      [%{role: "system", content: system_prompt} | _] = Legion.get_messages(pid)

      assert system_prompt =~ "Variables also persist across turns"
    end

    test "system prompt reflects binding_scope resolved from Application config" do
      Application.put_env(:legion, :config, %{binding_scope: :iteration})
      on_exit(fn -> Application.delete_env(:legion, :config) end)

      {:ok, pid} = Legion.start_link(MathAgent)
      [%{role: "system", content: system_prompt} | _] = Legion.get_messages(pid)

      assert system_prompt =~ "Variables do not persist."
    end

    test "custom system_prompt/0 override wins over the default" do
      defmodule CustomPromptAgent do
        @moduledoc "Agent with custom system prompt."
        use Legion.Agent

        def system_prompt, do: "completely custom prompt"
      end

      {:ok, pid} = Legion.start_link(CustomPromptAgent, binding_scope: :conversation)
      [%{role: "system", content: system_prompt} | _] = Legion.get_messages(pid)

      assert system_prompt == "completely custom prompt"
    end
  end

  defp allowing_identity(test_pid), do: %{"report_to" => test_pid}
  defp rejecting_identity(test_pid), do: %{"report_to" => test_pid, "verdict" => :reject}

  defp limit_policy, do: %Policy{window_ms: 60_000, max_agents: 2}

  defp rule(identity, policy \\ limit_policy()), do: %Rule{identity: identity, policy: policy}

  defp limited(opts) do
    {rate_limit, opts} = Keyword.pop(opts, :rate_limit, [])

    Keyword.put(opts, :rate_limit, Keyword.merge([limiter: TestRateLimiter], rate_limit))
  end

  describe "rate limiting" do
    setup do
      start_supervised!(%{id: MemoryStore, start: {MemoryStore, :start_link, []}})
      :ok
    end

    test "cancels the turn when the limiter rejects it" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema -> llm_response("ok") end)

      {:ok, pid} =
        Legion.start_link(
          MathAgent,
          limited(rate_limit: [rules: [rule(rejecting_identity(self()))]])
        )

      assert {:cancel, {:rate_limited, [:max_agents]}} = Legion.call(pid, "hi")
    end

    test "leaves the conversation untouched when the limiter rejects the turn" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        send(test_pid, :llm_called)
        llm_response("ok")
      end)

      {:ok, pid} =
        Legion.start_link(
          MathAgent,
          limited(
            rate_limit: [rules: [rule(rejecting_identity(self()))]],
            store: MemoryStore,
            agent_id: "rejected"
          )
        )

      assert {:cancel, {:rate_limited, _}} = Legion.call(pid, "hi")

      refute_receive :llm_called
      assert [%{role: "system"}] = Legion.get_messages(pid)
      assert {:ok, %Payload{conversation_state: nil}} = MemoryStore.get("rejected")
    end

    test "enforces rules in order and cancels at the first rejection" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema -> llm_response("ok") end)
      allowing = allowing_identity(self())
      rejecting = rejecting_identity(self())

      {:ok, pid} =
        Legion.start_link(
          MathAgent,
          limited(rate_limit: [rules: [rule(allowing), rule(rejecting)]])
        )

      assert {:cancel, {:rate_limited, [:max_agents]}} = Legion.call(pid, "hi")

      assert_receive {:enforced, _, ^allowing, _}
      assert_receive {:enforced, _, ^rejecting, _}
    end

    test "refuses to start with rules but no limiter" do
      assert_raise ArgumentError, ~r/rules need a limiter/, fn ->
        Legion.start_link(MathAgent, rate_limit: [rules: [rule(rejecting_identity(self()))]])
      end
    end

    test "runs the turn unlimited, with a warning, when a limiter is configured without rules" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema -> llm_response("ok") end)

      {pid, log} =
        with_log(fn ->
          {:ok, pid} = Legion.start_link(MathAgent, rate_limit: [limiter: TestRateLimiter])
          pid
        end)

      assert log =~ "runs without rate limiting"
      assert {:ok, "ok"} = Legion.call(pid, "hi")
      refute_receive {:enforced, _, _, _}
    end

    test "emits telemetry for the rule that rejected the turn" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:legion, :rate_limit, :exceeded]])
      on_exit(fn -> :telemetry.detach(ref) end)

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema -> llm_response("ok") end)
      rejecting = rejecting_identity(self())

      {:ok, pid} =
        Legion.start_link(
          MathAgent,
          limited(rate_limit: [rules: [rule(allowing_identity(self())), rule(rejecting)]])
        )

      agent_id = Legion.get_agent_id(pid)

      {:cancel, _} = Legion.call(pid, "hi")

      assert_receive {[:legion, :rate_limit, :exceeded], ^ref, _measurements, metadata}
      assert metadata.agent == MathAgent
      assert metadata.agent_id == agent_id
      assert metadata.identity == rejecting
      assert metadata.policy == limit_policy()
      assert metadata.violations == [:max_agents]
    end

    test "sub-agents inherit the limiter and every rule" do
      ip_identity = allowing_identity(self())
      tenant_identity = Map.put(allowing_identity(self()), "tenant", "acme")
      tenant_policy = %Policy{window_ms: 1_000, max_agents: 1}

      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        if Enum.any?(messages, &(&1[:role] == "assistant")) do
          llm_response("child done")
        else
          llm_eval_response("""
          response = AgentTool.call(ChildAgent, "do work")
          return response[2]
          """)
        end
      end)

      {:ok, pid} =
        Legion.start_link(
          DelegatingAgent,
          limited(rate_limit: [rules: [rule(ip_identity), rule(tenant_identity, tenant_policy)]])
        )

      parent_id = Legion.get_agent_id(pid)
      policy = limit_policy()

      {:ok, _} = Legion.call(pid, "delegate")

      assert_receive {:enforced, ^parent_id, ^ip_identity, ^policy}
      assert_receive {:enforced, ^parent_id, ^tenant_identity, ^tenant_policy}
      assert_receive {:enforced, child_id, ^ip_identity, ^policy}
      assert_receive {:enforced, ^child_id, ^tenant_identity, ^tenant_policy}
      assert child_id != parent_id
    end

    test "sub-agents of a parent that opted out are not rate limited" do
      Application.put_env(:legion, :rate_limit,
        limiter: TestRateLimiter,
        default_policy: limit_policy()
      )

      on_exit(fn -> Application.delete_env(:legion, :rate_limit) end)

      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        if Enum.any?(messages, &(&1[:role] == "assistant")) do
          llm_response("child done")
        else
          llm_eval_response("""
          response = AgentTool.call(ChildAgent, "do work")
          return response[2]
          """)
        end
      end)

      {:ok, pid} = Legion.start_link(DelegatingAgent, rate_limit: [rules: []])

      assert {:ok, _} = Legion.call(pid, "delegate")

      refute_receive {:enforced, _, _, _}
    end

    test "rejects an invalid policy when the agent starts" do
      assert_raise ArgumentError, ~r/:window_ms/, fn ->
        Legion.start_link(
          MathAgent,
          rate_limit: [
            limiter: TestRateLimiter,
            rules: [rule(allowing_identity(self()), %Policy{window_ms: 0})]
          ]
        )
      end
    end

    test "rejects an identity with non-string keys when the agent starts" do
      assert_raise ArgumentError, ~r/:identity keys/, fn ->
        Legion.start_link(
          MathAgent,
          limited(rate_limit: [rules: [rule(%{report_to: self()})]])
        )
      end
    end

    test "fills rules from the application limiter and policy" do
      Application.put_env(:legion, :rate_limit,
        limiter: TestRateLimiter,
        default_policy: limit_policy()
      )

      on_exit(fn -> Application.delete_env(:legion, :rate_limit) end)

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema -> llm_response("ok") end)
      rejecting = rejecting_identity(self())

      {:ok, pid} =
        Legion.start_link(MathAgent, rate_limit: [rules: [%Rule{identity: rejecting}]])

      assert {:cancel, {:rate_limited, [:max_agents]}} = Legion.call(pid, "hi")

      policy = limit_policy()
      assert_receive {:enforced, _, ^rejecting, ^policy}
    end
  end
end
