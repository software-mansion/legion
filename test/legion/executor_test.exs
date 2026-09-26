defmodule Legion.ExecutorTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Legion.Test.Support.MathAgent

  defmodule ReturnOnlyAgent do
    @moduledoc "An agent restricted to return/done actions only."
    use Legion.Agent

    def action_types, do: ~w(return done)
  end

  defmodule StructuredOutputAgent do
    @moduledoc "An agent with a custom output schema."
    use Legion.Agent

    def output_schema do
      %{
        "type" => "object",
        "properties" => %{
          "summary" => %{"type" => "string"},
          "score" => %{"type" => "integer"}
        },
        "required" => ["summary", "score"]
      }
    end
  end

  defmodule ThirdPartyToolAgent do
    @moduledoc "An agent exposing a third-party module as a tool."
    use Legion.Agent

    def tools, do: [Jason]
  end

  defmodule DeeplyNestedAgent do
    @moduledoc "An agent with deeply nested output schema."
    use Legion.Agent

    def output_schema do
      %{
        "type" => "object",
        "properties" => %{
          "data" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"}
            }
          },
          "items" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "id" => %{"type" => "integer"},
                "meta" => %{
                  "type" => "object",
                  "properties" => %{
                    "tag" => %{"type" => "string"}
                  }
                }
              }
            }
          }
        }
      }
    end
  end

  setup :set_mimic_global

  @moduletag capture_log: true

  defp response(object, turn_usage \\ 0) do
    {:ok,
     %ReqLLM.Response{
       id: "test",
       model: "test",
       context: nil,
       object: object,
       usage: %{turn_usage: turn_usage}
     }}
  end

  defp executor_messages(message) do
    [
      Legion.Executor.message(:system, "system"),
      Legion.Executor.message(:user, message)
    ]
  end

  describe "run/3-5" do
    test "returns recursively string-keyed usage with its receipt timestamp" do
      usage = %{
        input_tokens: 12,
        output_tokens: 5,
        turn_usage: 17,
        tool_usage: %{web_search: 1}
      }

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        {:ok,
         %ReqLLM.Response{
           id: "test",
           model: "test",
           context: nil,
           object: %{"action" => "return", "code" => "", "result" => "42"},
           usage: usage
         }}
      end)

      before = System.system_time(:millisecond)

      assert {:ok, "42", _messages, [],
              [
                %{
                  "input_tokens" => 12,
                  "output_tokens" => 5,
                  "turn_usage" => 17,
                  "tool_usage" => %{"web_search" => 1},
                  "at" => timestamp
                }
              ]} = Legion.Executor.run(MathAgent, executor_messages("what is 42?"), %{})

      assert timestamp in before..System.system_time(:millisecond)
    end

    test "returns usage list from a single LLM request" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{"action" => "return", "code" => "", "result" => "42"}, 17)
      end)

      assert {:ok, "42", _messages, [], [%{"turn_usage" => 17}]} =
               Legion.Executor.run(MathAgent, executor_messages("what is 42?"), %{})
    end

    test "preserves provider usage values while stringifying keys" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        {:ok,
         %ReqLLM.Response{
           id: "test",
           model: "test",
           context: nil,
           object: %{"action" => "return", "code" => "", "result" => "42"},
           usage: %{input_tokens: 12, output_tokens: 5}
         }}
      end)

      assert {:ok, "42", _messages, [], [%{"input_tokens" => 12, "output_tokens" => 5}]} =
               Legion.Executor.run(MathAgent, executor_messages("what is 42?"), %{})
    end

    test "preserves usage order across a multi-response turn" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> response(%{"action" => "eval_and_continue", "code" => "x = 10", "result" => ""}, 7)
          2 -> response(%{"action" => "return", "code" => "", "result" => "done"}, 11)
        end
      end)

      assert {:ok, "done", _messages, _bindings, [%{"turn_usage" => 7}, %{"turn_usage" => 11}]} =
               Legion.Executor.run(
                 MathAgent,
                 executor_messages("compute"),
                 %{}
               )
    end

    test "retains usage from an invalid response while retrying" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> response(nil, 7)
          2 -> response(%{"action" => "return", "code" => "", "result" => "recovered"}, 11)
        end
      end)

      assert {:ok, "recovered", _messages, [], [%{"turn_usage" => 7}, %{"turn_usage" => 11}]} =
               Legion.Executor.run(MathAgent, executor_messages("recover"), %{})
    end

    test "emits normalized usage in LLM request stop telemetry" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:legion, :llm, :request, :stop]])
      on_exit(fn -> :telemetry.detach(ref) end)

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        {:ok,
         %ReqLLM.Response{
           id: "test",
           model: "test",
           context: nil,
           object: %{"action" => "return", "code" => "", "result" => "42"},
           usage: %{input_tokens: 12, output_tokens: 5}
         }}
      end)

      before = System.system_time(:millisecond)

      assert {:ok, "42", _messages, [], [_usage]} =
               Legion.Executor.run(MathAgent, executor_messages("what is 42?"), %{})

      assert_receive {[:legion, :llm, :request, :stop], ^ref, _measurements, metadata}

      assert %{
               object: %{"action" => "return"},
               usage: %{
                 "input_tokens" => 12,
                 "output_tokens" => 5,
                 "at" => timestamp,
                 "message_index" => index
               },
               message_count: index
             } = metadata

      assert timestamp in before..System.system_time(:millisecond)
    end

    test "emits usage in LLM request stop telemetry for an invalid response" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:legion, :llm, :request, :stop]])
      on_exit(fn -> :telemetry.detach(ref) end)

      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> response(nil, 7)
          2 -> response(%{"action" => "return", "code" => "", "result" => "recovered"}, 11)
        end
      end)

      assert {:ok, "recovered", _messages, [], [_first, _second]} =
               Legion.Executor.run(MathAgent, executor_messages("recover"), %{})

      assert_receive {[:legion, :llm, :request, :stop], ^ref, _measurements,
                      %{error: _, usage: usage}}

      assert %{"turn_usage" => 7, "at" => at, "message_index" => nil} = usage
      assert is_integer(at)

      assert_receive {[:legion, :llm, :request, :stop], ^ref, _measurements,
                      %{object: %{"action" => "return"}, usage: %{"turn_usage" => 11}}}
    end

    test "returns result for return action" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{"action" => "return", "code" => "", "result" => "42"})
      end)

      assert {:ok, "42"} = Legion.execute(MathAgent, "what is 42?")
    end

    test "returns nil for done action" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{"action" => "done", "code" => "", "result" => ""})
      end)

      assert {:ok, nil} = Legion.execute(MathAgent, "nothing")
    end

    test "eval_and_complete executes code and returns result" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{"action" => "eval_and_complete", "code" => "return 1 + 1", "result" => ""})
      end)

      assert {:ok, 2} = Legion.execute(MathAgent, "add")
    end

    test "eval_and_continue chains into next iteration" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 ->
            response(%{"action" => "eval_and_continue", "code" => "x = 10", "result" => ""})

          2 ->
            response(%{"action" => "eval_and_complete", "code" => "return x * 2", "result" => ""})
        end
      end)

      assert {:ok, 20} = Legion.execute(MathAgent, "compute")
    end

    test "cancels after max_iterations" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{"action" => "eval_and_continue", "code" => "return 1", "result" => ""})
      end)

      assert {:cancel, :reached_max_iterations} =
               Legion.execute(MathAgent, "loop forever")
    end

    test "retries on code execution error and cancels after max_retries" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{
          "action" => "eval_and_complete",
          "code" => "error(\"boom\")",
          "result" => ""
        })
      end)

      assert {:cancel, :reached_max_retries} = Legion.execute(MathAgent, "fail")
    end

    test "eval_guard denial stops the code from running and reaches the agent" do
      defmodule NoArithmetic do
        @behaviour Legion.EvalGuard

        @impl true
        def check(code, _context) do
          if String.contains?(code, "+"),
            do: {:deny, "addition is off limits here"},
            else: :allow
        end
      end

      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 ->
            response(%{"action" => "eval_and_complete", "code" => "return 1 + 1", "result" => ""})

          2 ->
            # The agent is told why, in the conversation, and can adapt.
            assert Enum.any?(
                     messages,
                     &(is_binary(&1.content) and &1.content =~ "addition is off limits")
                   )

            response(%{
              "action" => "eval_and_complete",
              "code" => "return 21 * 2",
              "result" => ""
            })
        end
      end)

      assert {:ok, 42} = Legion.execute(MathAgent, "add things", eval_guard: NoArithmetic)
    end

    test "eval_guard allowing code leaves execution untouched" do
      defmodule AllowAll do
        @behaviour Legion.EvalGuard

        @impl true
        def check(_code, _context), do: :allow
      end

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{"action" => "eval_and_complete", "code" => "return 2 + 2", "result" => ""})
      end)

      assert {:ok, 4} = Legion.execute(MathAgent, "add", eval_guard: AllowAll)
    end

    test "LLM error triggers retry" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> {:error, "connection refused"}
          2 -> response(%{"action" => "return", "code" => "", "result" => "recovered"})
        end
      end)

      assert {:ok, "recovered"} = Legion.execute(MathAgent, "retry me")
    end

    test "raised LLM exception triggers retry without adding usage" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> raise "provider exploded"
          2 -> response(%{"action" => "return", "code" => "", "result" => "recovered"}, 11)
        end
      end)

      assert {:ok, "recovered", _messages, [], [%{"turn_usage" => 11}]} =
               Legion.Executor.run(MathAgent, executor_messages("retry raised error"), %{})
    end

    test "third-party tool module without extra_allowed_modules/0 does not crash eval" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{
          "action" => "eval_and_complete",
          "code" => "Jason.encode!(%{a: 1})",
          "result" => ""
        })
      end)

      assert {:ok, ~s({"a":1})} =
               Legion.execute(ThirdPartyToolAgent, "encode", sandbox: Legion.Sandbox.Elixir)
    end

    test "missing action field in LLM response triggers retry" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> response(%{"code" => "1 + 1", "result" => ""})
          2 -> response(%{"action" => "return", "code" => "", "result" => "ok"})
        end
      end)

      assert {:ok, "ok"} = Legion.execute(MathAgent, "recover")
    end
  end

  describe "checkpoints" do
    test "emits complete checkpoints for continuing and completing eval results" do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 ->
            response(%{
              "action" => "eval_and_continue",
              "code" => "x = 10",
              "result" => ""
            })

          2 ->
            response(%{
              "action" => "eval_and_complete",
              "code" => "x * 2",
              "result" => ""
            })
        end
      end)

      checkpoint = fn state ->
        send(test_pid, {:checkpoint, state})
        :ok
      end

      assert {:ok, 20, _messages, _bindings, _turn_usage} =
               Legion.Executor.run(
                 MathAgent,
                 executor_messages("compute"),
                 %{checkpoint: checkpoint, sandbox: Legion.Sandbox.Elixir}
               )

      assert_received {:checkpoint,
                       %{
                         messages: continuing_messages,
                         bindings: [x: 10],
                         executor_state: %{phase: :awaiting_llm, iteration: 1, retries: 0},
                         turn_usage: [%{"turn_usage" => 0}]
                       }}

      assert List.last(continuing_messages).type == :eval_result

      assert_received {:checkpoint,
                       %{
                         messages: completing_messages,
                         bindings: [x: 10],
                         executor_state: %{phase: :completing, iteration: 1, retries: 0}
                       }}

      assert List.last(completing_messages).type == :eval_result
    end

    test "emits the current counters after a recoverable error" do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 ->
            response(%{
              "action" => "eval_and_complete",
              "code" => "error(\"boom\")",
              "result" => ""
            })

          2 ->
            response(%{"action" => "return", "code" => "", "result" => "recovered"})
        end
      end)

      checkpoint = fn state ->
        send(test_pid, {:checkpoint, state})
        :ok
      end

      assert {:ok, "recovered", _messages, [], _turn_usage} =
               Legion.Executor.run(
                 MathAgent,
                 executor_messages("recover"),
                 %{checkpoint: checkpoint}
               )

      assert_received {:checkpoint,
                       %{
                         messages: messages,
                         bindings: [],
                         executor_state: %{phase: :awaiting_llm, iteration: 0, retries: 1}
                       }}

      assert List.last(messages).type == :error
      refute_received {:checkpoint, _other}
    end

    test "does not checkpoint a return action" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{"action" => "return", "code" => "", "result" => "done"})
      end)

      assert {:ok, "done", _messages, [], _turn_usage} =
               Legion.Executor.run(
                 MathAgent,
                 executor_messages("finish"),
                 %{checkpoint: fn state -> send(test_pid, {:checkpoint, state}) end}
               )

      refute_received {:checkpoint, _state}
    end

    test "checkpoint failure exits before the next LLM request" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)
        response(%{"action" => "eval_and_continue", "code" => "return 1 + 1", "result" => ""})
      end)

      reason =
        catch_exit(
          Legion.Executor.run(
            MathAgent,
            executor_messages("compute"),
            %{checkpoint: fn _state -> :error end}
          )
        )

      assert {:checkpoint_persistence_failed, %MatchError{term: :error}} = reason
      assert :counters.get(call_count, 1) == 1
    end
  end

  describe "usage message index" do
    test "stamps each entry with the position of the message it produced" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> response(nil, 7)
          2 -> response(%{"action" => "return", "code" => "", "result" => "done"}, 11)
        end
      end)

      # executor_messages/1 is [system, user]. The invalid first response
      # stores nothing, its error prompt fills 2, the retry's assistant
      # message lands at 3.
      assert {:ok, "done", messages, [], usage} =
               Legion.Executor.run(MathAgent, executor_messages("compute"), %{})

      assert [
               %{"turn_usage" => 7, "message_index" => nil},
               %{"turn_usage" => 11, "message_index" => 3}
             ] = usage

      assert %{type: :assistant} = Enum.at(messages, 3)
    end

    test "an entry names no message when retries run out" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema -> response(nil, 7) end)

      assert {:cancel, :reached_max_retries, messages, [], usage} =
               Legion.Executor.run(MathAgent, executor_messages("compute"), %{max_retries: 0})

      assert [%{"turn_usage" => 7, "message_index" => nil}] = usage
      assert [%{type: :system}, %{type: :user}] = messages
    end
  end

  describe "result formatting" do
    test "available variables are listed in the result message" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _m, messages, _s ->
        i = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if i > 0 do
          last_msg = messages |> List.last() |> Map.get(:content)
          send(test_pid, {:result_msg, last_msg})
        end

        case i do
          0 ->
            response(%{
              "action" => "eval_and_continue",
              "code" => "posts = {1, 2}",
              "result" => ""
            })

          1 ->
            response(%{"action" => "return", "code" => "", "result" => "done"})
        end
      end)

      assert {:ok, "done"} = Legion.execute(MathAgent, "test var listing")

      assert_received {:result_msg, msg}
      assert msg =~ "Available variables:"
      assert msg =~ "`posts`"
    end
  end

  describe "max_message_length in result/error feedback" do
    test "truncates large code execution results in the feedback message" do
      test_pid = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(ReqLLM, :generate_object, fn _m, messages, _s ->
        i = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if i > 0 do
          last_msg = messages |> List.last() |> Map.get(:content)
          send(test_pid, {:result_msg, last_msg})
        end

        case i do
          0 ->
            response(%{
              "action" => "eval_and_continue",
              "code" => "return string.rep(\"a\", 5000)",
              "result" => ""
            })

          1 ->
            response(%{"action" => "return", "code" => "", "result" => "done"})
        end
      end)

      {:ok, pid} = Legion.start_link(MathAgent, max_message_length: 200)
      assert {:ok, "done"} = Legion.call(pid, "generate a lot")

      assert_received {:result_msg, msg}
      assert msg =~ "[... truncated"
      assert byte_size(msg) < 1_000
    end

    test "truncates long error text in the retry feedback message" do
      test_pid = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      long_message = String.duplicate("x", 5_000)

      stub(ReqLLM, :generate_object, fn _m, messages, _s ->
        i = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if i > 0 do
          last_msg = messages |> List.last() |> Map.get(:content)
          send(test_pid, {:error_msg, last_msg})
        end

        case i do
          0 ->
            response(%{
              "action" => "eval_and_complete",
              "code" => "error(\"#{long_message}\")",
              "result" => ""
            })

          _ ->
            response(%{"action" => "return", "code" => "", "result" => "recovered"})
        end
      end)

      {:ok, pid} = Legion.start_link(MathAgent, max_message_length: 200)
      assert {:ok, "recovered"} = Legion.call(pid, "fail loudly")

      assert_received {:error_msg, msg}
      assert msg =~ "[... truncated"
      assert byte_size(msg) < 1_000
    end
  end

  describe "custom output_schema" do
    test "schema is passed to LLM with additionalProperties injected" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, schema ->
        send(test_pid, {:schema, schema})

        response(%{
          "action" => "return",
          "code" => "",
          "result" => %{"summary" => "hi", "score" => 1}
        })
      end)

      Legion.execute(StructuredOutputAgent, "test")

      assert_received {:schema, schema}
      result_schema = schema["properties"]["result"]
      assert result_schema["additionalProperties"] == false
      assert result_schema["properties"] == StructuredOutputAgent.output_schema()["properties"]
    end

    test "return action passes structured result through" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{
          "action" => "return",
          "code" => "",
          "result" => %{"summary" => "all good", "score" => 95}
        })
      end)

      assert {:ok, %{"summary" => "all good", "score" => 95}} =
               Legion.execute(StructuredOutputAgent, "evaluate")
    end

    test "eval_and_complete returns code result, not the schema result field" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{
          "action" => "eval_and_complete",
          "code" => "return {summary = \"computed\", score = 42}",
          "result" => ""
        })
      end)

      assert {:ok, %{"summary" => "computed", "score" => 42}} =
               Legion.execute(StructuredOutputAgent, "compute")
    end
  end

  describe "action_types" do
    test "allows all four actions by default" do
      assert MathAgent.action_types() == ~w(eval_and_continue eval_and_complete return done)
    end

    test "restricted agent only allows return and done" do
      assert ReturnOnlyAgent.action_types() == ~w(return done)
    end

    test "disallowed action causes cancel after max_retries" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{"action" => "eval_and_continue", "code" => "1 + 1", "result" => ""})
      end)

      assert {:cancel, :reached_max_retries} =
               Legion.execute(ReturnOnlyAgent, "do something")
    end

    test "allowed action works on restricted agent" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{"action" => "return", "code" => "", "result" => "answer"})
      end)

      assert {:ok, "answer"} = Legion.execute(ReturnOnlyAgent, "do something")
    end
  end

  describe "enforce_no_additional_properties for nested schemas" do
    test "recursively injects additionalProperties into nested objects and arrays" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, _messages, schema ->
        send(test_pid, {:schema, schema})

        response(%{
          "action" => "return",
          "code" => "",
          "result" => %{"data" => %{"name" => "x"}, "items" => []}
        })
      end)

      Legion.execute(DeeplyNestedAgent, "test")

      assert_received {:schema, schema}
      result = schema["properties"]["result"]

      assert result["additionalProperties"] == false
      assert result["properties"]["data"]["additionalProperties"] == false

      item_schema = result["properties"]["items"]["items"]
      assert item_schema["additionalProperties"] == false
      assert item_schema["properties"]["meta"]["additionalProperties"] == false
    end
  end

  describe "sandbox config key" do
    test "selects the sandbox that validates, evaluates, and describes itself to the LLM" do
      call_count = :counters.new(1, [:atomics])
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _model, messages, schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 ->
            send(test_pid, {:first_call, messages, schema})
            # Lua, evaluated as Lua: a bare `total` would be an Elixir result
            # but is a syntax error here, and the tool is reached over the bridge.
            response(%{
              "action" => "eval_and_continue",
              "code" => "total = MathTool.random_add(1, 2)",
              "result" => ""
            })

          2 ->
            send(test_pid, {:second_call, messages})

            response(%{
              "action" => "eval_and_complete",
              "code" => "return total + 1",
              "result" => ""
            })
        end
      end)

      assert {:ok, 984} = Legion.execute(MathAgent, "add", sandbox: Legion.Sandbox.Lua)

      assert_received {:first_call, messages, schema}
      assert schema["properties"]["code"]["description"] =~ "Lua code to execute"

      system_prompt = Enum.find(messages, &(&1.role == "system")).content
      assert system_prompt =~ "executing Lua code"
      assert system_prompt =~ "return <expression>"
      refute system_prompt =~ "defmodule"

      # Lua globals survive into the next iteration and are advertised as such.
      assert_received {:second_call, messages}
      assert Enum.any?(messages, &(is_binary(&1.content) and &1.content =~ "`total`"))
    end

    test "rejects code the selected sandbox cannot parse" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{"action" => "eval_and_complete", "code" => "1 + 1", "result" => ""})
      end)

      assert {:cancel, :reached_max_retries} =
               Legion.execute(MathAgent, "add", sandbox: Legion.Sandbox.Lua)
    end
  end
end
