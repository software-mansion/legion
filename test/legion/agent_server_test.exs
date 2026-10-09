defmodule Legion.AgentServerTest.Fixtures do
  @moduledoc "LLM responses and rate-limit rules shared by the AgentServer test modules."

  alias Legion.AgentServerTest.TestRateLimiter
  alias Legion.RateLimiter.Policy
  alias Legion.RateLimiter.Rule

  def llm_response(result, turn_usage \\ 0) do
    llm_object(%{"action" => "return", "code" => "", "result" => result}, turn_usage)
  end

  def llm_eval_response(code, turn_usage \\ 0) do
    llm_object(%{"action" => "eval_and_complete", "code" => code, "result" => ""}, turn_usage)
  end

  def llm_eval_continue_response(code, turn_usage \\ 0) do
    llm_object(
      %{"action" => "eval_and_continue", "code" => code, "result" => ""},
      turn_usage
    )
  end

  def llm_object(object, turn_usage) do
    {:ok,
     %ReqLLM.Response{
       id: "test",
       model: "test",
       context: nil,
       object: object,
       usage: %{turn_usage: turn_usage}
     }}
  end

  def allowing_identity(test_pid), do: %{"report_to" => test_pid}
  def rejecting_identity(test_pid), do: %{"report_to" => test_pid, "verdict" => :reject}

  # Allows the agent's start and rejects every check after it.
  def turn_rejecting_identity(test_pid),
    do: %{"report_to" => test_pid, "verdict" => :reject_after_start}

  # Rejects every check whose policy limits tokens, as when they are spent.
  def tokens_spent_identity(test_pid),
    do: %{"report_to" => test_pid, "verdict" => :reject_token_limit}

  def limit_policy, do: %Policy{window_ms: 60_000, max_agents: 2}

  def rule(identity, policy \\ limit_policy()), do: %Rule{identity: identity, policy: policy}

  def limited(opts) do
    {rate_limit, opts} = Keyword.pop(opts, :rate_limit, [])

    Keyword.put(opts, :rate_limit, Keyword.merge([limiter: TestRateLimiter], rate_limit))
  end
end

defmodule Legion.AgentServerTest do
  use ExUnit.Case, async: true
  use Mimic

  import ExUnit.CaptureLog
  import Legion.AgentServerTest.Fixtures

  alias Legion.AgentServer
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

        # A start and the turns after it are checked in the agent's own process.
        reject? =
          case identity["verdict"] do
            :reject -> true
            :reject_after_start -> Process.put({__MODULE__, :started}, true) == true
            :reject_token_limit -> policy.max_tokens != nil
            _allow -> false
          end

        if reject? do
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

  defmodule VaultAgent do
    @moduledoc "Agent whose tool reports what its process was seeded with."
    use Legion.Agent

    def tools, do: [Legion.Test.Support.VaultTool]
  end

  defmodule ChildAgent do
    @moduledoc "Sub-agent invoked through AgentTool."
    use Legion.Agent
  end

  defmodule ReadOnlyAgent do
    @moduledoc "Agent that answers without running code."
    use Legion.Agent

    def action_types, do: ~w(return done)
  end

  defmodule DelegatingAgent do
    @moduledoc "Agent that delegates work to ChildAgent."
    use Legion.Agent

    def tools, do: [Legion.Tools.AgentTool]
    def tool_config(Legion.Tools.AgentTool), do: [agents: [ChildAgent]]
    def tool_config(_tool), do: []
  end

  defmodule CustomPromptAgent do
    @moduledoc "Agent with custom system prompt."
    use Legion.Agent

    def system_prompt, do: "completely custom prompt"
  end

  defmodule SampleStruct do
    defstruct [:id, :name]
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

  setup :set_mimic_private

  # Agent IDs are registered cluster-wide, so each test claims its own.
  setup do
    {:ok, agent_id: "agent-#{System.unique_integer([:positive])}"}
  end

  @moduletag capture_log: true

  # Agent processes have no `$callers`, so the test's ReqLLM stubs reach them
  # only through an allowance.
  defp start_agent(agent_module, opts \\ []) do
    {:ok, pid} = Legion.start_link(agent_module, opts)
    Mimic.allow(ReqLLM, self(), pid)
    pid
  end

  # The content of the user message the LLM receives for `message`.
  defp sent_user_content(message, opts \\ []) do
    test_pid = self()

    stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
      user_message = Enum.find(messages, &(&1[:role] == "user"))
      send(test_pid, {:user_content, user_message[:content]})
      llm_response("ok")
    end)

    pid = start_agent(MathAgent, opts)
    assert {:ok, "ok"} = Legion.call(pid, message)
    assert_received {:user_content, content}
    content
  end

  defp wait_until(condition) do
    if condition.() do
      :ok
    else
      Process.sleep(1)
      wait_until(condition)
    end
  end

  describe "get_messages/1" do
    test "returns conversation history from a running agent" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      pid = start_agent(MathAgent)
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
      assert {:ok, {pid, monitor_ref}} = AgentServer.start_monitor(MathAgent)
      assert Process.alive?(pid)

      GenServer.stop(pid)

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}
    end
  end

  describe "config resolution" do
    test "call-time opts override agent config" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn model, _messages, _schema ->
        send(test_pid, {:model_used, model})
        llm_response("ok")
      end)

      pid = start_agent(ConfiguredAgent, model: "call-model")
      {:ok, _} = Legion.call(pid, "hi")

      assert_received {:model_used, "call-model"}
    end
  end

  describe "terminate/2" do
    test "emits stopped event when agent terminates" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:legion, :agent, :stopped]])
      on_exit(fn -> :telemetry.detach(ref) end)

      {:ok, pid} = Legion.start_link(ConfiguredAgent)
      GenServer.stop(pid)

      assert_received {[:legion, :agent, :stopped], ^ref, _measurements,
                       %{agent: ConfiguredAgent}}
    end
  end

  describe "message shapes" do
    test "passes a multipart part list through to the LLM unchanged" do
      for parts <- [
            [
              ContentPart.text("Describe this image."),
              ContentPart.image(<<1, 2, 3>>, "image/png")
            ],
            [
              ContentPart.text("What is in this picture?"),
              ContentPart.image_url("https://example.com/photo.png")
            ],
            [ContentPart.text("hello")],
            []
          ] do
        assert sent_user_content({:multipart, parts}) == parts
      end
    end

    test "wraps image shorthands into a single image ContentPart" do
      assert sent_user_content({:image, <<1, 2, 3>>, "image/png"}) ==
               [ContentPart.image(<<1, 2, 3>>, "image/png")]

      assert sent_user_content({:image_url, "https://example.com/photo.png"}) ==
               [ContentPart.image_url("https://example.com/photo.png")]
    end

    test "renders any other term, PIDs included, via inspect" do
      for term <- [%SampleStruct{id: 7, name: "ada"}, %{id: 1, name: "x"}, %{pid: self()}] do
        assert sent_user_content(term) == inspect(term, limit: :infinity)
      end
    end
  end

  describe "max_message_length" do
    test "truncates binary user input longer than the limit" do
      content = sent_user_content(String.duplicate("a", 5_000), max_message_length: 100)

      assert String.starts_with?(content, String.duplicate("a", 100))
      assert content =~ "[... truncated 4900 bytes ...]"
    end

    test "passes binary user input shorter than the limit through unchanged" do
      assert sent_user_content("hello", max_message_length: 100) == "hello"
    end

    test "truncates text parts of multipart content individually" do
      parts = [
        ContentPart.text(String.duplicate("a", 5_000)),
        ContentPart.image_url("https://example.com/image.png")
      ]

      assert [text_part, image_part] =
               sent_user_content({:multipart, parts}, max_message_length: 100)

      assert String.starts_with?(text_part.text, String.duplicate("a", 100))
      assert text_part.text =~ "[... truncated 4900 bytes ...]"
      assert image_part == ContentPart.image_url("https://example.com/image.png")
    end

    test ":infinity disables truncation" do
      big = String.duplicate("a", 5_000)

      assert sent_user_content(big, max_message_length: :infinity) == big
    end

    test "defaults to 40_000 bytes" do
      content = sent_user_content(String.duplicate("a", 45_000))

      assert String.starts_with?(content, String.duplicate("a", 40_000))
      assert content =~ "[... truncated 5000 bytes ...]"
    end

    test "start_link refuses a limit that is not a big enough integer or :infinity" do
      for {key, bad_values, expected} <- [
            {:max_message_length, [nil, 0], "a positive integer"},
            {:idle_timeout, [nil, 0, -1, "100"], "a positive integer"},
            {:max_bindings_bytes, [nil, 0], "a positive integer"},
            {:sub_agent_idle_timeout, [nil, 0], "a positive integer"},
            {:max_sub_agents, [nil, -1, 1.5], "a non-negative integer"}
          ],
          value <- bad_values do
        message = "expected #{inspect(key)} to be #{expected} or :infinity"

        assert_raise ArgumentError, ~r/#{Regex.escape(message)}/, fn ->
          Legion.start_link(MathAgent, [{key, value}])
        end
      end

      for {key, value} <- [idle_timeout: :infinity, idle_timeout: 50, max_sub_agents: 0] do
        assert {:ok, pid} = Legion.start_link(MathAgent, [{key, value}])
        GenServer.stop(pid)
      end
    end

    test "start_link warns about unknown config keys and keeps them" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          pid = start_agent(MathAgent, bogus: true)
          assert %{bogus: true} = :sys.get_state(pid).config
          GenServer.stop(pid)
        end)

      assert log =~ "Unknown Legion config keys: [:bogus]"
    end
  end

  describe "cast/2" do
    test "returns at once and runs the message as a turn" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        send(test_pid, {:turn_started, self()})

        receive do
          :finish -> llm_response("Paris")
        end
      end)

      pid = start_agent(MathAgent)
      assert :ok = Legion.cast(pid, "What is the capital of France?")
      assert_receive {:turn_started, ^pid}
      send(pid, :finish)

      assert [
               %{role: "system"},
               %{role: "user", content: "What is the capital of France?"},
               %{role: "assistant"} | _
             ] = Legion.get_messages(pid)
    end
  end

  describe "persistence" do
    setup do
      start_supervised!(%{id: MemoryStore, start: {MemoryStore, :start_link, []}})
      :ok
    end

    test "brackets each turn with :running and :idle status writes", %{agent_id: agent_id} do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      pid = start_agent(MathAgent, store: MemoryStore, agent_id: agent_id)
      {:ok, _} = Legion.call(pid, "What is the capital of France?")

      assert MemoryStore.statuses(agent_id) == [:running, :idle]

      {:ok, _} = Legion.call(pid, "And of Germany?")
      assert MemoryStore.statuses(agent_id) == [:running, :idle, :running, :idle]
    end

    test "writes the new Store payloads for a completed message", %{agent_id: agent_id} do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      pid = start_agent(MathAgent, store: MemoryStore, agent_id: agent_id)
      {:ok, "Paris"} = Legion.call(pid, "What is the capital of France?")

      [started, running, completed] = MemoryStore.writes(agent_id)

      assert %Payload{
               agent_id: ^agent_id,
               agent_module: MathAgent,
               parent_agent_id: nil,
               started_at: started_at,
               status: nil,
               conversation_state: nil,
               usage: []
             } = started

      assert is_struct(started_at, NaiveDateTime)

      assert %Payload{
               agent_id: ^agent_id,
               status: :running,
               conversation_state: %{
                 messages: [%{role: "user", content: "What is the capital of France?"}],
                 bindings: []
               }
             } = running

      assert %Payload{
               agent_id: ^agent_id,
               status: :idle,
               conversation_state: %{messages: messages, bindings: []}
             } = completed

      assert [
               %{role: "user", content: "What is the capital of France?"},
               %{role: "assistant"} | _
             ] = messages

      refute Enum.any?(messages, &(&1.role == "system"))
    end

    test "accumulates timestamped, string-keyed usage across turns", %{agent_id: agent_id} do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> llm_response("first", 7)
          2 -> llm_response("second", 11)
        end
      end)

      pid = start_agent(MathAgent, store: MemoryStore, agent_id: agent_id)
      assert {:ok, "first"} = Legion.call(pid, "first turn")
      assert {:ok, "second"} = Legion.call(pid, "second turn")

      assert {:ok, payload} = MemoryStore.get(agent_id)

      assert [
               %{"turn_usage" => 7, "at" => first_timestamp},
               %{"turn_usage" => 11, "at" => second_timestamp}
             ] = Map.fetch!(payload, :usage)

      assert first_timestamp <= second_timestamp
    end

    test "usage entries name the persisted assistant message their request produced",
         %{agent_id: agent_id} do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> llm_object(nil, 5)
          2 -> llm_eval_continue_response("x = 1", 7)
          3 -> llm_response("first", 11)
          4 -> llm_response("second", 13)
        end
      end)

      pid = start_agent(MathAgent, store: MemoryStore, agent_id: agent_id)
      assert {:ok, "first"} = Legion.call(pid, "first turn")
      assert {:ok, "second"} = Legion.call(pid, "second turn")

      assert {:ok, %Payload{usage: usage, conversation_state: %{messages: messages}}} =
               MemoryStore.get(agent_id)

      # [user, error, assistant, eval_result, assistant, user, assistant]
      assert [
               %{"message_index" => nil},
               %{"message_index" => 2},
               %{"message_index" => 4},
               %{"message_index" => 6}
             ] = usage

      for %{"message_index" => index} when is_integer(index) <- usage do
        assert %{type: :assistant} = Enum.at(messages, index)
      end
    end

    test "usage of a cancelled turn names no message, so the next turn's user message stays unnamed",
         %{agent_id: agent_id} do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> llm_object(nil, 7)
          2 -> llm_response("second", 11)
        end
      end)

      pid = start_agent(MathAgent, store: MemoryStore, agent_id: agent_id, max_retries: 0)

      assert {:cancel, :reached_max_retries} = Legion.call(pid, "first turn")
      assert {:ok, "second"} = Legion.call(pid, "second turn")

      assert {:ok, %Payload{usage: usage, conversation_state: %{messages: messages}}} =
               MemoryStore.get(agent_id)

      # [user, user, assistant]
      assert [%{"message_index" => nil}, %{"message_index" => 2}] = usage
      assert %{type: :assistant} = Enum.at(messages, 2)
    end

    test "restored conversations add only new invocation usage", %{agent_id: agent_id} do
      assert :ok =
               MemoryStore.save(%Payload{
                 agent_id: agent_id,
                 usage: [%{turn_usage: 100}],
                 conversation_state: %{messages: [], bindings: [], executor_state: nil}
               })

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("new work", 20)
      end)

      pid = start_agent(MathAgent, store: MemoryStore, agent_id: agent_id)
      assert {:ok, "new work"} = Legion.call(pid, "continue")

      assert {:ok,
              %Payload{
                usage: [
                  %{turn_usage: 100},
                  %{"turn_usage" => 20, "at" => timestamp, "message_index" => 1}
                ]
              }} = MemoryStore.get(agent_id)

      assert is_integer(timestamp)
    end

    test "persists the user message before the turn runs", %{agent_id: agent_id} do
      test_process = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        send(test_process, {:snapshot_during_turn, MemoryStore.load(agent_id)})
        llm_response("Paris")
      end)

      pid = start_agent(MathAgent, store: MemoryStore, agent_id: agent_id)
      {:ok, _} = Legion.call(pid, "What is the capital of France?")

      assert_received {:snapshot_during_turn, {:ok, %{messages: messages}}}
      assert [%{role: "user", content: "What is the capital of France?"}] = messages
    end

    test "does not persist bindings under the default :turn scope", %{agent_id: agent_id} do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_eval_response("x = 42\nreturn x")
      end)

      pid = start_agent(MathAgent, store: MemoryStore, agent_id: agent_id)
      {:ok, 42} = Legion.call(pid, "set x")

      assert {:ok, %{bindings: []}} = MemoryStore.load(agent_id)
    end

    test "a :step store persists a complete eval_and_continue checkpoint", %{agent_id: agent_id} do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> llm_eval_continue_response("x = 42", 7)
          2 -> llm_response("done", 11)
        end
      end)

      pid =
        start_agent(MathAgent,
          store: StepMemoryStore,
          agent_id: agent_id,
          sandbox: Legion.Sandbox.Elixir
        )

      assert {:ok, "done"} = Legion.call(pid, "compute")

      [_started, running, checkpoint, completed] = MemoryStore.writes(agent_id)

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
               },
               usage: [%{"turn_usage" => 7, "message_index" => 1}]
             } = checkpoint

      assert %Payload{
               status: :idle,
               conversation_state: final_state,
               usage: [%{"turn_usage" => 7}, %{"turn_usage" => 11}]
             } = completed

      assert final_state.bindings == []
      assert final_state.executor_state == :nonexistent
    end

    test "a :step store persists eval_and_complete before the final snapshot",
         %{agent_id: agent_id} do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_eval_response("return 1 + 1")
      end)

      pid = start_agent(MathAgent, store: StepMemoryStore, agent_id: agent_id)

      assert {:ok, 2} = Legion.call(pid, "compute")

      [_started, _running, checkpoint, completed] = MemoryStore.writes(agent_id)

      assert %Payload{
               status: nil,
               conversation_state: %{
                 executor_state: %{phase: :completing, iteration: 0, retries: 0}
               }
             } = checkpoint

      assert %Payload{status: :idle, conversation_state: final_state} = completed
      assert final_state.executor_state == :nonexistent
    end

    test "a :step store persists retry state after an error message", %{agent_id: agent_id} do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> llm_eval_response("raise \"boom\"")
          2 -> llm_response("recovered")
        end
      end)

      pid = start_agent(MathAgent, store: StepMemoryStore, agent_id: agent_id)
      assert {:ok, "recovered"} = Legion.call(pid, "compute")

      [_started, _running, checkpoint, _completed] = MemoryStore.writes(agent_id)

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

    test "a :step store retains conversation bindings in the final snapshot",
         %{agent_id: agent_id} do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_eval_response("x = 42")
      end)

      pid =
        start_agent(ConversationBindingsAgent,
          store: StepMemoryStore,
          agent_id: agent_id,
          sandbox: Legion.Sandbox.Elixir
        )

      assert {:ok, 42} = Legion.call(pid, "compute")

      [_started, _running, checkpoint, completed] = MemoryStore.writes(agent_id)

      assert checkpoint.conversation_state.bindings == [x: 42]
      assert completed.conversation_state.bindings == [x: 42]
    end

    test "a :step store persists empty iteration-scoped bindings", %{agent_id: agent_id} do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_eval_response("x = 42\nreturn x")
      end)

      pid =
        start_agent(MathAgent,
          store: StepMemoryStore,
          agent_id: agent_id,
          binding_scope: :iteration
        )

      assert {:ok, 42} = Legion.call(pid, "compute")

      [_started, _running, checkpoint, completed] = MemoryStore.writes(agent_id)

      assert checkpoint.conversation_state.bindings == []
      assert completed.conversation_state.bindings == []
    end

    test "a :step store does not add a checkpoint for return", %{agent_id: agent_id} do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("done")
      end)

      pid = start_agent(MathAgent, store: StepMemoryStore, agent_id: agent_id)
      assert {:ok, "done"} = Legion.call(pid, "compute")

      assert [_started, _running, _completed] = MemoryStore.writes(agent_id)
    end

    test "restores the conversation under a fresh system prompt after a restart",
         %{agent_id: agent_id} do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      pid = start_agent(MathAgent, store: MemoryStore, agent_id: agent_id)
      {:ok, _} = Legion.call(pid, "What is the capital of France?")
      GenServer.stop(pid)

      {:ok, revived} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: agent_id)

      assert [
               %{role: "system"},
               %{role: "user", content: "What is the capital of France?"},
               %{role: "assistant"} | _
             ] = Legion.get_messages(revived)
    end

    test "restores conversation-scoped bindings after a restart", %{agent_id: agent_id} do
      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        assistant_count = Enum.count(messages, &(&1[:role] == "assistant"))

        if assistant_count == 0 do
          llm_eval_response("x = 42\nreturn x")
        else
          llm_eval_response("return x + 1")
        end
      end)

      pid = start_agent(ConversationBindingsAgent, store: MemoryStore, agent_id: agent_id)

      {:ok, 42} = Legion.call(pid, "set x")
      GenServer.stop(pid)

      revived = start_agent(ConversationBindingsAgent, store: MemoryStore, agent_id: agent_id)

      assert {:ok, 43} = Legion.call(revived, "use x")
    end

    test "generates an agent_id when a store is given without one" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      pid = start_agent(MathAgent, store: MemoryStore)
      agent_id = Legion.get_agent_id(pid)

      assert is_binary(agent_id)
      assert String.valid?(agent_id)
      {:ok, _} = Legion.call(pid, "What is the capital of France?")
      assert {:ok, _snapshot} = MemoryStore.load(agent_id)
    end

    test "raises when :agent_id is given without a :store", %{agent_id: agent_id} do
      assert_raise ArgumentError, ~r/:agent_id requires a :store/, fn ->
        Legion.start_link(MathAgent, agent_id: agent_id)
      end
    end

    test "every identity operation rejects an agent ID that is not a UTF-8 string" do
      for agent_id <- [:agent, make_ref(), <<0xFF>>],
          operation <- [
            fn -> Legion.start_link(MathAgent, store: MemoryStore, agent_id: agent_id) end,
            fn -> Legion.lookup(agent_id) end,
            fn -> Legion.resume(agent_id, store: MemoryStore) end,
            fn -> Legion.recover(agent_id, store: MemoryStore) end
          ] do
        assert_raise ArgumentError, ~r/:agent_id must be a valid UTF-8 string/, operation
      end
    end

    test "registers the agent pid by agent_id", %{agent_id: agent_id} do
      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: agent_id)

      assert {:ok, ^pid} = Legion.lookup(agent_id)
    end

    test "concurrent starts atomically choose one owner for an agent_id", %{agent_id: agent_id} do
      caller = self()

      contenders =
        for _index <- 1..8 do
          Task.async(fn ->
            send(caller, {:ready, self()})

            receive do
              :start -> Legion.start_link(MathAgent, store: MemoryStore, agent_id: agent_id)
            end
          end)
        end

      contender_pids =
        for _index <- 1..8 do
          assert_receive {:ready, contender_pid}
          contender_pid
        end

      for contender_pid <- contender_pids, do: send(contender_pid, :start)
      results = Task.await_many(contenders)
      started_pids = for {:ok, pid} <- results, do: pid

      on_exit(fn ->
        for pid <- started_pids, Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert [winner] = started_pids

      assert Enum.count(results, &(&1 == {:error, {:already_started, winner}})) == 7
      assert {:ok, ^winner} = Legion.lookup(agent_id)
    end

    test "resume/2 returns the recorded process while it is alive", %{agent_id: agent_id} do
      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: agent_id)

      assert {:ok, ^pid} = Legion.resume(agent_id, store: MemoryStore)
    end

    test "resume/2 validates the requested store before resolving a live process",
         %{agent_id: agent_id} do
      {:ok, _pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: agent_id)

      assert {:error, :not_resumable} = Legion.resume(agent_id, store: EmptyStore)
    end

    test "resume/2 restarts a stopped conversation from its run metadata",
         %{agent_id: agent_id} do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("Paris")
      end)

      pid = start_agent(MathAgent, store: MemoryStore, agent_id: agent_id)
      {:ok, _} = Legion.call(pid, "What is the capital of France?")
      GenServer.stop(pid)

      {:ok, revived} = Legion.resume(agent_id, store: MemoryStore)

      assert revived != pid

      assert [
               %{role: "system"},
               %{role: "user", content: "What is the capital of France?"},
               %{role: "assistant"} | _
             ] = Legion.get_messages(revived)
    end

    # A request would add messages before get_messages/1 could answer.
    test "a conversation an outside model drove resumes and recovers without a request",
         %{agent_id: agent_id} do
      {:ok, pid} = Legion.start_link(MathAgent, agent_id: agent_id, store: MemoryStore)
      assert {:ok, _text} = Legion.eval(pid, "x = 1")
      GenServer.stop(pid)

      assert {:ok, resumed} = Legion.resume(agent_id, store: MemoryStore)

      assert [%{type: :system}, %{type: :assistant}, %{type: :eval_result}] =
               Legion.get_messages(resumed)

      GenServer.stop(resumed)

      # As the rate limiter leaves a row it marked running.
      {:ok, payload} = MemoryStore.get(agent_id)
      :ok = MemoryStore.save(%{payload | status: :running})

      assert {:error, :not_recoverable} = Legion.recover(agent_id, store: MemoryStore)
    end

    test "another agent module cannot start under an id with a stored conversation",
         %{agent_id: agent_id} do
      {:ok, pid} = Legion.start_link(MathAgent, agent_id: agent_id, store: MemoryStore)
      GenServer.stop(pid)

      assert {:error, {:agent_module_mismatch, MathAgent}} =
               Legion.start_link(VaultAgent, agent_id: agent_id, store: MemoryStore)

      assert {:ok, %Payload{agent_module: MathAgent}} = MemoryStore.get(agent_id)
    end

    test "resume/2 returns not_resumable without a stored agent module", %{agent_id: agent_id} do
      assert :ok = MemoryStore.save(%Payload{agent_id: agent_id, agent_module: nil})

      assert {:error, :not_resumable} = Legion.resume("#{agent_id}-ghost", store: MemoryStore)
      assert {:error, :not_resumable} = Legion.resume(agent_id, store: MemoryStore)
    end

    test "resume/2 and recover/2 identify themselves when no store is configured" do
      assert_raise ArgumentError, ~r/resume\/2 requires a :store/, fn ->
        Legion.resume("missing-store")
      end

      assert_raise ArgumentError, ~r/recover\/2 requires a :store/, fn ->
        Legion.recover("missing-store")
      end
    end

    test "recover/2 returns error when agent is running", %{agent_id: agent_id} do
      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: agent_id)

      assert :ok =
               MemoryStore.save(%Payload{
                 agent_id: agent_id,
                 status: :running,
                 conversation_state: %{
                   messages: [%{role: "user", type: :user, content: "recover me"}],
                   bindings: [],
                   executor_state: :nonexistent
                 }
               })

      assert {:error, :already_running} = Legion.recover(agent_id, store: MemoryStore)

      assert Process.alive?(pid)
    end

    test "recover/2 validates the requested store before resolving a live process",
         %{agent_id: agent_id} do
      {:ok, _pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: agent_id)

      assert {:error, :not_recoverable} = Legion.recover(agent_id, store: EmptyStore)
    end

    test "recover/2 refuses anything but an interrupted run of a root agent",
         %{agent_id: agent_id} do
      interrupted = %Payload{
        agent_id: agent_id,
        parent_agent_id: nil,
        agent_module: MathAgent,
        status: :running,
        usage: [],
        conversation_state: %{
          messages: [%{role: "user", type: :user, content: "compute"}],
          bindings: [x: 42],
          executor_state: %{phase: :completing, iteration: 1, retries: 0}
        }
      }

      assert {:error, :not_recoverable} = Legion.recover(agent_id, store: MemoryStore)

      for {suffix, payload} <- [
            no_agent_module: %{interrupted | agent_module: nil},
            idle: %{interrupted | status: :idle},
            child: %{interrupted | parent_agent_id: "parent"}
          ] do
        unrecoverable_id = "#{agent_id}-#{suffix}"
        assert :ok = MemoryStore.save(%{payload | agent_id: unrecoverable_id})

        assert {:error, :not_recoverable} = Legion.recover(unrecoverable_id, store: MemoryStore)
      end
    end
  end

  describe "binding_scope" do
    test "a turn under :turn drops its own bindings and keeps those eval/2 made" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_eval_response("y = 7\nreturn y")
      end)

      pid = start_agent(MathAgent)

      {:ok, _text} = AgentServer.eval(pid, "x = 1")
      {:ok, 7} = Legion.call(pid, "set y")

      assert {:ok, text} = AgentServer.eval(pid, "return {x, y == nil}")
      assert text =~ "[1, true]"
      assert text =~ "Available variables: `x`"
    end

    test "a turn under :turn reads the bindings eval/2 made and cannot change them" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_eval_response("x = x + 1\nreturn x")
      end)

      pid = start_agent(MathAgent)

      {:ok, _text} = AgentServer.eval(pid, "x = 1")
      assert {:ok, 2} = Legion.call(pid, "bump x")

      assert {:ok, text} = AgentServer.eval(pid, "return x")
      assert text =~ "1"
      assert text =~ "Available variables: `x`"
    end

    test "bindings persist across turns with :conversation, in either sandbox" do
      for {sandbox, set_code, use_code} <- [
            {Legion.Sandbox.Lua, "x = 42\nreturn x", "return x + 1"},
            {Legion.Sandbox.Elixir, "x = 42", "x + 1"}
          ] do
        stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
          if Enum.any?(messages, &(&1[:role] == "assistant")),
            do: llm_eval_response(use_code),
            else: llm_eval_response(set_code)
        end)

        pid = start_agent(ConversationBindingsAgent, sandbox: sandbox)
        assert {:ok, 42} = Legion.call(pid, "set x")
        assert {:ok, 43} = Legion.call(pid, "use x")
      end
    end

    test "system prompt reflects binding_scope resolved from start_link opts, not agent.config()" do
      {:ok, pid} = Legion.start_link(MathAgent, binding_scope: :conversation)
      [%{role: "system", content: system_prompt} | _] = Legion.get_messages(pid)

      assert system_prompt =~ "Variables also persist across turns"
    end

    test "custom system_prompt/0 override wins over the default" do
      {:ok, pid} = Legion.start_link(CustomPromptAgent, binding_scope: :conversation)
      [%{role: "system", content: system_prompt} | _] = Legion.get_messages(pid)

      assert system_prompt == "completely custom prompt"
    end
  end

  describe "eval/2" do
    setup do
      start_supervised!(%{id: MemoryStore, start: {MemoryStore, :start_link, []}})
      :ok
    end

    test "runs code without an LLM and keeps variables between calls" do
      reject(&ReqLLM.generate_object/3)
      pid = start_agent(MathAgent)

      assert {:ok, _text} = AgentServer.eval(pid, "x = MathTool.random_add(1, 0)")
      assert {:ok, text} = AgentServer.eval(pid, "return x + 1")

      assert text =~ "984"
      assert text =~ "Available variables: `x`"
    end

    test "saves every step - the code, then its result or error - and never as running",
         %{agent_id: agent_id} do
      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: agent_id)

      {:ok, result} = AgentServer.eval(pid, "return 1 + 1")
      {:error, error} = AgentServer.eval(pid, "return (")

      {:ok, %{messages: messages}} = MemoryStore.load(agent_id)

      assert [
               %{type: :assistant, content: first_action},
               %{type: :eval_result, content: ^result},
               %{type: :assistant, content: second_action},
               %{type: :error, content: ^error}
             ] = messages

      assert Jason.decode!(first_action) ==
               %{"action" => "eval_and_continue", "code" => "return 1 + 1"}

      assert Jason.decode!(second_action)["code"] == "return ("
      assert MemoryStore.statuses(agent_id) == [:idle, :idle]
    end

    test "records one eval per call in usage, for :max_evals to count", %{agent_id: agent_id} do
      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: agent_id)

      {:ok, _result} = AgentServer.eval(pid, "return 1")
      {:error, _error} = AgentServer.eval(pid, "return (")

      assert {:ok, %Payload{usage: usage}} = MemoryStore.get(agent_id)

      assert [
               %{"evals" => 1, "message_index" => 0, "at" => _},
               %{"evals" => 1, "message_index" => 2, "at" => _}
             ] = usage
    end

    test "reads :vault from the agent process, where tools look it up" do
      {:ok, pid} = Legion.start_link(VaultAgent, vault: [current_user: "alice"])

      assert {:ok, text} = AgentServer.eval(pid, "return VaultTool.current_user()")
      assert text =~ "alice"
    end

    test "a per-call :vault holds for that call only" do
      {:ok, pid} = Legion.start_link(VaultAgent, vault: [current_user: "owner"])

      assert {:ok, text} =
               AgentServer.eval(pid, "return VaultTool.token()",
                 vault: [current_user: "alice", token: "alice-secret"]
               )

      assert text =~ "alice-secret"

      assert {:ok, text} =
               AgentServer.eval(pid, "return VaultTool.token()", vault: [current_user: "bob"])

      refute text =~ "alice-secret"

      assert {:ok, text} = AgentServer.eval(pid, "return VaultTool.current_user()")
      assert text =~ "owner"
    end

    test "runs as eval_and_continue, whatever action the last turn left behind" do
      # As the executor leaves it after a turn that ended in eval_and_complete.
      {:ok, pid} = Legion.start_link(VaultAgent, vault: [current_action: "eval_and_complete"])

      assert {:ok, text} = AgentServer.eval(pid, "return VaultTool.current_action()")
      assert text =~ "eval_and_continue"

      assert {:ok, text} =
               AgentServer.eval(pid, "return VaultTool.current_action()",
                 vault: [current_action: "eval_and_complete"]
               )

      assert text =~ "eval_and_continue"
    end

    test "a per-call :vault cannot replace the keys Legion sets", %{agent_id: agent_id} do
      {:ok, pid} = Legion.start_link(VaultAgent, agent_id: agent_id, store: MemoryStore)

      assert {:ok, text} =
               AgentServer.eval(pid, "return VaultTool.agent_id()",
                 vault: [agent_id: "forged", agent_module: MathAgent]
               )

      assert text =~ agent_id

      assert {:ok, text} =
               AgentServer.eval(pid, "return VaultTool.agent_module()",
                 vault: [agent_module: MathAgent]
               )

      assert text =~ "VaultAgent"
    end

    test "a rejected call runs nothing and saves nothing", %{agent_id: agent_id} do
      opts = limited(rate_limit: [rules: [rule(turn_rejecting_identity(self()))]])

      {:ok, pid} =
        Legion.start_link(MathAgent, [store: MemoryStore, agent_id: agent_id] ++ opts)

      assert {:cancel, {:rate_limited, [:max_agents]}} = AgentServer.eval(pid, "return 1")
      assert_received {:enforced, ^agent_id, _identity, _policy}
      assert MemoryStore.load(agent_id) == :error
    end

    test "an agent whose action_types allow no evaluation refuses, before the rate limit",
         %{agent_id: agent_id} do
      opts = limited(rate_limit: [rules: [rule(turn_rejecting_identity(self()))]])

      {:ok, pid} =
        Legion.start_link(ReadOnlyAgent, [store: MemoryStore, agent_id: agent_id] ++ opts)

      assert_received {:enforced, ^agent_id, _identity, _policy}
      assert {:error, text} = AgentServer.eval(pid, "return 1")
      assert text =~ "ReadOnlyAgent runs no code"
      refute_received {:enforced, _agent_id, _identity, _policy}
      assert MemoryStore.load(agent_id) == :error
    end

    test "a call whose caller died while it waited is skipped", %{agent_id: agent_id} do
      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: agent_id)

      # Busy, as with another call or a chat turn.
      :ok = :sys.suspend(pid)
      caller = spawn(fn -> AgentServer.eval(pid, "abandoned = 1") end)
      wait_until(fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 1} end)
      Process.exit(caller, :kill)
      :ok = :sys.resume(pid)

      assert {:ok, text} = AgentServer.eval(pid, "return abandoned")
      assert text =~ "nil"

      assert [%{type: :system}, %{type: :assistant}, %{type: :eval_result}] =
               Legion.get_messages(pid)
    end

    test "code over max_message_length or not UTF-8 is refused and not kept",
         %{agent_id: agent_id} do
      {:ok, pid} =
        Legion.start_link(MathAgent,
          store: MemoryStore,
          agent_id: agent_id,
          max_message_length: 10
        )

      assert {:error, "The code is 11 bytes, over the 10 byte limit" <> _} =
               AgentServer.eval(pid, "return 1+11")

      assert {:error, "The code is not valid UTF-8"} = AgentServer.eval(pid, "return \"\xFF\"")
      assert MemoryStore.load(agent_id) == :error
      assert {:ok, _text} = AgentServer.eval(pid, "return 1")
    end

    test ":require_sandbox refuses an agent that runs another sandbox", %{agent_id: agent_id} do
      {:ok, pid} =
        Legion.start_link(MathAgent,
          store: MemoryStore,
          agent_id: agent_id,
          sandbox: Legion.Sandbox.Elixir
        )

      assert {:error, text} =
               AgentServer.eval(pid, "1 + 1", require_sandbox: Legion.Sandbox.Lua)

      assert text =~ "requires Legion.Sandbox.Lua"
      assert text =~ "runs Legion.Sandbox.Elixir"
      assert MemoryStore.load(agent_id) == :error

      assert {:ok, _text} = AgentServer.eval(pid, "1 + 1", require_sandbox: Legion.Sandbox.Elixir)
    end

    test ":exclude_tools leaves tools out of that call only" do
      {:ok, pid} = Legion.start_link(MathAgent)

      assert {:ok, text} =
               AgentServer.eval(pid, "return {MathTool == nil, Help.help()}",
                 exclude_tools: [Legion.Test.Support.MathTool]
               )

      assert text =~ "true"
      refute text =~ "MathTool"

      assert {:ok, text} = AgentServer.eval(pid, "return {MathTool == nil, Help.help()}")
      assert text =~ "false"
      assert text =~ "MathTool"
    end
  end

  describe "idle_timeout" do
    # A GenServer timeout never fires early, so stopping before 100ms passed
    # since the call would mean the call did not start the wait over.
    test "stops the agent once nobody has called for that long, counted from the last call" do
      reject(&ReqLLM.generate_object/3)
      pid = start_agent(MathAgent, idle_timeout: 100)
      reference = Process.monitor(pid)

      Process.sleep(50)
      called_at = System.monotonic_time(:millisecond)
      assert {:ok, _text} = AgentServer.eval(pid, "return 1")

      assert_receive {:DOWN, ^reference, :process, ^pid, :normal}, 1_000
      assert System.monotonic_time(:millisecond) - called_at >= 100
    end

    test "a stray :timeout message does not stop an agent without one" do
      pid = start_agent(MathAgent)
      send(pid, :timeout)

      assert {:ok, _text} = AgentServer.eval(pid, "return 1")
    end

    test "a stray :timeout or idle message does not stop an agent with one" do
      pid = start_agent(MathAgent, idle_timeout: 10_000)
      send(pid, :timeout)
      send(pid, {:idle_timeout, make_ref()})

      assert {:ok, _text} = AgentServer.eval(pid, "return 1")
    end
  end

  describe "rate limiting" do
    setup do
      start_supervised!(%{id: MemoryStore, start: {MemoryStore, :start_link, []}})
      :ok
    end

    test "cancels a rejected turn and leaves the conversation untouched",
         %{agent_id: agent_id} do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        send(test_pid, :llm_called)
        llm_response("ok")
      end)

      pid =
        start_agent(
          MathAgent,
          limited(
            rate_limit: [rules: [rule(turn_rejecting_identity(self()))]],
            store: MemoryStore,
            agent_id: agent_id
          )
        )

      assert {:cancel, {:rate_limited, [:max_agents]}} = Legion.call(pid, "hi")

      refute_received :llm_called
      assert [%{role: "system"}] = Legion.get_messages(pid)
      assert {:ok, %Payload{conversation_state: nil}} = MemoryStore.get(agent_id)
    end

    test "hands the limiter every rule in order and cancels when one rejects" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema -> llm_response("ok") end)
      allowing = allowing_identity(self())
      rejecting = turn_rejecting_identity(self())

      pid =
        start_agent(
          MathAgent,
          limited(rate_limit: [rules: [rule(allowing), rule(rejecting)]])
        )

      assert {:cancel, {:rate_limited, [:max_agents]}} = Legion.call(pid, "hi")

      assert_received {:enforced, _, first, _}
      assert_received {:enforced, _, second, _}
      assert [first, second] == [allowing, rejecting]
    end

    test "a rejected start leaves no process and no row, and emits telemetry",
         %{agent_id: agent_id} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:legion, :rate_limit, :exceeded]])
      on_exit(fn -> :telemetry.detach(ref) end)

      opts =
        limited(
          rate_limit: [rules: [rule(rejecting_identity(self()))]],
          store: MemoryStore,
          agent_id: agent_id
        )

      assert {:error, {:rate_limited, [:max_agents]}} = Legion.start_link(MathAgent, opts)
      assert {:cancel, {:rate_limited, [:max_agents]}} = Legion.execute(MathAgent, "hi", opts)

      assert Legion.lookup(agent_id) == :error
      assert MemoryStore.get(agent_id) == :error

      assert_received {[:legion, :rate_limit, :exceeded], ^ref, _measurements,
                       %{agent_id: ^agent_id, violations: [:max_agents]}}
    end

    test "a start is checked against max_agents only, and a resumed run not at all" do
      policy = %Policy{
        window_ms: 60_000,
        max_agents: 2,
        max_running_agents: 1,
        max_tokens: 100,
        max_evals: 1
      }

      {:ok, pid} =
        Legion.start_link(
          MathAgent,
          limited(rate_limit: [rules: [rule(allowing_identity(self()), policy)]])
        )

      agent_id = Legion.get_agent_id(pid)

      assert_received {:enforced, ^agent_id, _identity,
                       %Policy{window_ms: 60_000, max_agents: 2} = checked}

      assert %{max_running_agents: nil, max_tokens: nil, max_evals: nil} = checked

      without_agent_limit = %{policy | max_agents: nil}

      {:ok, pid} =
        Legion.start_link(
          MathAgent,
          limited(rate_limit: [rules: [rule(allowing_identity(self()), without_agent_limit)]])
        )

      agent_id = Legion.get_agent_id(pid)
      refute_received {:enforced, ^agent_id, _identity, _policy}

      {:ok, pid} = Legion.start_link(MathAgent, store: MemoryStore, agent_id: "resumed-unchecked")
      GenServer.stop(pid)
      rejecting = limited(rate_limit: [rules: [rule(rejecting_identity(self()))]])

      assert {:ok, _pid} = Legion.resume("resumed-unchecked", [store: MemoryStore] ++ rejecting)
      refute_received {:enforced, "resumed-unchecked", _identity, _policy}
    end

    test "a supervisor restarts an agent whose tokens are spent, and its siblings live on",
         %{agent_id: agent_id} do
      supervisor = start_supervised!(DynamicSupervisor)
      policy = %Policy{window_ms: 60_000, max_agents: 2, max_tokens: 100}

      opts =
        limited(
          rate_limit: [rules: [rule(tokens_spent_identity(self()), policy)]],
          store: MemoryStore,
          agent_id: agent_id
        )

      {:ok, spent} = DynamicSupervisor.start_child(supervisor, {MathAgent, opts})
      {:ok, sibling} = DynamicSupervisor.start_child(supervisor, {MathAgent, []})

      Process.exit(spent, :kill)
      wait_until(fn -> match?({:ok, pid} when pid != spent, Legion.lookup(agent_id)) end)
      {:ok, restarted} = Legion.lookup(agent_id)

      assert {:cancel, {:rate_limited, [:max_agents]}} = Legion.call(restarted, "hi")
      assert Process.alive?(supervisor) and Process.alive?(sibling)
    end

    test "start_link validates the rate-limit options" do
      for {rate_limit, error} <- [
            {[rules: [rule(rejecting_identity(self()))]], ~r/rules need a limiter/},
            {[
               limiter: TestRateLimiter,
               rules: [rule(allowing_identity(self()), %Policy{window_ms: 0})]
             ], ~r/:window_ms/},
            {[limiter: TestRateLimiter, rules: [rule(%{report_to: self()})]], ~r/:identity keys/}
          ] do
        assert_raise ArgumentError, error, fn ->
          Legion.start_link(MathAgent, rate_limit: rate_limit)
        end
      end
    end

    test "runs the turn unlimited, with a warning, when a limiter is configured without rules" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema -> llm_response("ok") end)

      {pid, log} =
        with_log(fn -> start_agent(MathAgent, rate_limit: [limiter: TestRateLimiter]) end)

      assert log =~ "runs without rate limiting"
      assert {:ok, "ok"} = Legion.call(pid, "hi")
      refute_received {:enforced, _, _, _}
    end

    test "emits telemetry for the rule that rejected the turn" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:legion, :rate_limit, :exceeded]])
      on_exit(fn -> :telemetry.detach(ref) end)

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema -> llm_response("ok") end)
      rejecting = turn_rejecting_identity(self())

      pid =
        start_agent(
          MathAgent,
          limited(rate_limit: [rules: [rule(allowing_identity(self())), rule(rejecting)]])
        )

      agent_id = Legion.get_agent_id(pid)

      {:cancel, _} = Legion.call(pid, "hi")

      assert_received {[:legion, :rate_limit, :exceeded], ^ref, _measurements,
                       %{agent_id: ^agent_id} = metadata}

      assert metadata.agent == MathAgent
      assert metadata.identity == rejecting
      assert metadata.policy == limit_policy()
      assert metadata.violations == [:max_agents]
    end
  end
end

defmodule Legion.AgentServerGlobalTest do
  # Sync: these set application env, or stub the LLM for agent processes the
  # test never gets a pid for in time (one-off, resumed, recovered and
  # sub-agents), which Mimic reaches only in global mode.
  use ExUnit.Case, async: false
  use Mimic

  import Legion.AgentServerTest.Fixtures

  alias Legion.AgentServer
  alias Legion.AgentServerTest.ChildAgent
  alias Legion.AgentServerTest.DelegatingAgent
  alias Legion.AgentServerTest.MemoryStore
  alias Legion.AgentServerTest.StepMemoryStore
  alias Legion.RateLimiter.Policy
  alias Legion.Store.Payload
  alias Legion.Test.Support.MathAgent

  setup :set_mimic_global

  @moduletag capture_log: true

  setup do
    start_supervised!(%{id: MemoryStore, start: {MemoryStore, :start_link, []}})
    :ok
  end

  describe "application config" do
    test "does not update usage when :track_usage is disabled" do
      Application.put_env(:legion, :track_usage, false)
      on_exit(fn -> Application.delete_env(:legion, :track_usage) end)

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

      assert {:ok, %Payload{usage: [%{turn_usage: 100}]}} = MemoryStore.get("usage-disabled")
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
  end

  describe "one-off, resumed and recovered agents" do
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

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        llm_response("done")
      end)

      assert :ok = Legion.recover("recover-awaiting-llm", store: MemoryStore)

      assert {:ok,
              %Payload{
                status: :idle,
                conversation_state: %{executor_state: :nonexistent, messages: messages}
              }} = MemoryStore.get("recover-awaiting-llm")

      assert %{type: :assistant} = List.last(messages)
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

    test "recover/2 under :turn keeps what eval/2 made and drops what the turn made" do
      agent_id = "recover-base-#{System.unique_integer([:positive])}"
      test_pid = self()
      request_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(request_count, 1, 1)

        case :counters.get(request_count, 1) do
          1 ->
            llm_eval_continue_response("y = x + 1")

          2 ->
            send(test_pid, :checkpointed)
            Process.exit(self(), :kill)
            llm_response("unreachable")

          _ ->
            llm_eval_response("return y")
        end
      end)

      {:ok, pid} = Legion.start_link(MathAgent, store: StepMemoryStore, agent_id: agent_id)
      Process.unlink(pid)
      reference = Process.monitor(pid)
      {:ok, _text} = AgentServer.eval(pid, "x = 1")
      Legion.cast(pid, "compute")

      assert_receive :checkpointed, 5_000
      assert_receive {:DOWN, ^reference, :process, ^pid, _reason}, 5_000

      assert :ok = Legion.recover(agent_id, store: StepMemoryStore)

      {:ok, %Payload{conversation_state: final}} = StepMemoryStore.get(agent_id)
      assert final.bindings == [{"x", 1}]
    end
  end

  describe "sub-agents" do
    test "inherit the parent store and link to the parent conversation" do
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

    test "inherit the limiter and every rule" do
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

      # Its start was checked too.
      assert_received {:enforced, ^parent_id, ^ip_identity, ^policy}
      assert_received {:enforced, ^parent_id, ^tenant_identity, ^tenant_policy}

      {:ok, _} = Legion.call(pid, "delegate")

      assert_received {:enforced, ^parent_id, ^ip_identity, ^policy}
      assert_received {:enforced, ^parent_id, ^tenant_identity, ^tenant_policy}
      assert_received {:enforced, child_id, ^ip_identity, ^policy}
      assert_received {:enforced, ^child_id, ^tenant_identity, ^tenant_policy}
      assert child_id != parent_id
    end

    test "Lua holds one sub-agent conversation across executions" do
      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        llm_response("turn #{Enum.count(messages, &(&1[:role] == "user"))}")
      end)

      {:ok, pid} = Legion.start_link(DelegatingAgent)

      assert {:ok, first} =
               AgentServer.eval(pid, """
               writer = AgentTool.start_link(ChildAgent)[2]
               return AgentTool.call(writer, "draft")[2]
               """)

      assert {:ok, second} =
               AgentServer.eval(pid, ~s|return AgentTool.call(writer, "tighten")[2]|)

      assert first =~ "turn 1"
      assert second =~ "turn 2"
    end

    test "start_link/2 casts the task, and its id stands in for the pid it used to return" do
      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        llm_response("turn #{Enum.count(messages, &(&1[:role] == "user"))}")
      end)

      {:ok, pid} = Legion.start_link(DelegatingAgent, sandbox: Legion.Sandbox.Elixir)

      assert {:ok, text} =
               AgentServer.eval(pid, """
               {:ok, pid} = AgentTool.start_link(ChildAgent, "draft")
               {:ok, reply} = AgentTool.call(pid, "tighten")
               reply
               """)

      assert text =~ "turn 2"
    end

    test "only the owner reaches a sub-agent, which stops with it even mid-turn" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        send(test_pid, {:sub_agent_turn, Vault.get(:agent_id)})
        Process.sleep(:infinity)
      end)

      {:ok, owner} = Legion.start_link(DelegatingAgent)
      {:ok, other} = Legion.start_link(DelegatingAgent)

      {:ok, _text} =
        AgentServer.eval(owner, ~s|AgentTool.cast(AgentTool.start_link(ChildAgent)[2], "draft")|)

      assert_receive {:sub_agent_turn, agent_id}
      {:ok, sub_agent} = Legion.lookup(agent_id)

      assert {:error, text} =
               AgentServer.eval(other, ~s|return AgentTool.call("#{agent_id}", "hi")|)

      assert text =~ "is not a running sub-agent of this agent"

      ref = Process.monitor(sub_agent)
      GenServer.stop(owner)
      assert_receive {:DOWN, ^ref, :process, ^sub_agent, :shutdown}
    end
  end
end
