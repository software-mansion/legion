defmodule Legion.ExecutorTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Legion.Executor
  alias Legion.Test.Support.MathAgent

  defmodule NoArithmetic do
    @behaviour Legion.EvalGuard

    @impl true
    def check(code, _context) do
      if String.contains?(code, "+"),
        do: {:deny, "addition is off limits here"},
        else: :allow
    end
  end

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

  @moduletag capture_log: true

  # Legion.execute/3, with the agent process allowed to use this test's stubs.
  defp execute(agent_module, task, opts \\ []) do
    pid = start_supervised!({agent_module, opts})
    allow(ReqLLM, self(), pid)
    Legion.call(pid, task)
  end

  defp attach_llm_request_stop do
    test_pid = self()
    handler_id = make_ref()

    :telemetry.attach(
      handler_id,
      [:legion, :llm, :request, :stop],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:llm_request_stop, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

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
      Executor.message(:system, "system"),
      Executor.message(:user, message)
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
              ]} = Executor.run(MathAgent, executor_messages("what is 42?"), %{})

      assert timestamp in before..System.system_time(:millisecond)
    end

    test "keeps usage in request order, flagging the request whose action ran code as one eval" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> response(%{"action" => "eval_and_continue", "code" => "x = 10", "result" => ""}, 7)
          2 -> response(%{"action" => "return", "code" => "", "result" => "done"}, 11)
        end
      end)

      assert {:ok, "done", _messages, _bindings, [eval_request, return_request]} =
               Executor.run(MathAgent, executor_messages("compute"), %{})

      assert %{"turn_usage" => 7, "evals" => 1} = eval_request
      assert %{"turn_usage" => 11} = return_request
      refute Map.has_key?(return_request, "evals")
    end

    test "counts a failed evaluation as one eval" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 ->
            response(
              %{"action" => "eval_and_complete", "code" => "error('boom')", "result" => ""},
              7
            )

          2 ->
            response(%{"action" => "return", "code" => "", "result" => "recovered"}, 11)
        end
      end)

      assert {:ok, "recovered", _messages, [],
              [%{"turn_usage" => 7, "evals" => 1}, %{"turn_usage" => 11}]} =
               Executor.run(MathAgent, executor_messages("fail once"), %{})
    end

    test "emits normalized usage in LLM request stop telemetry" do
      attach_llm_request_stop()

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
               Executor.run(MathAgent, executor_messages("what is 42?"), %{})

      assert_received {:llm_request_stop, metadata}

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
      attach_llm_request_stop()
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> response(nil, 7)
          2 -> response(%{"action" => "return", "code" => "", "result" => "recovered"}, 11)
        end
      end)

      assert {:ok, "recovered", _messages, [], [_first, _second]} =
               Executor.run(MathAgent, executor_messages("recover"), %{})

      assert_received {:llm_request_stop, %{error: _, usage: usage}}
      assert %{"turn_usage" => 7, "at" => at, "message_index" => nil} = usage
      assert is_integer(at)

      assert_received {:llm_request_stop,
                       %{object: %{"action" => "return"}, usage: %{"turn_usage" => 11}}}
    end

    test "returns result for return action" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{"action" => "return", "code" => "", "result" => "42"})
      end)

      assert {:ok, "42"} = execute(MathAgent, "what is 42?")
    end

    test "returns nil for done action" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{"action" => "done", "code" => "", "result" => ""})
      end)

      assert {:ok, nil} = execute(MathAgent, "nothing")
    end

    test "eval_and_complete executes code and returns result" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{"action" => "eval_and_complete", "code" => "return 1 + 1", "result" => ""})
      end)

      assert {:ok, 2} = execute(MathAgent, "add")
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

      assert {:ok, 20} = execute(MathAgent, "compute")
    end

    test "cancels after max_iterations" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{"action" => "eval_and_continue", "code" => "return 1", "result" => ""})
      end)

      assert {:cancel, :reached_max_iterations} =
               execute(MathAgent, "loop forever")
    end

    test "retries on code execution error and cancels after max_retries" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{
          "action" => "eval_and_complete",
          "code" => "error(\"boom\")",
          "result" => ""
        })
      end)

      assert {:cancel, :reached_max_retries} = execute(MathAgent, "fail")
    end

    test "eval_guard denial stops the code from running and reaches the agent" do
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

      assert {:ok, 42} = execute(MathAgent, "add things", eval_guard: NoArithmetic)
    end

    test "retries a failed or malformed LLM response, keeping only reported usage" do
      failures = [
        {fn -> {:error, "connection refused"} end, [11]},
        {fn -> raise "provider exploded" end, [11]},
        {fn -> response(%{"code" => "1 + 1", "result" => ""}, 7) end, [7, 11]}
      ]

      for {failure, expected_turn_usage} <- failures do
        call_count = :counters.new(1, [:atomics])

        stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
          :counters.add(call_count, 1, 1)

          case :counters.get(call_count, 1) do
            1 -> failure.()
            2 -> response(%{"action" => "return", "code" => "", "result" => "recovered"}, 11)
          end
        end)

        assert {:ok, "recovered", _messages, [], usage} =
                 Executor.run(MathAgent, executor_messages("recover"), %{})

        assert Enum.map(usage, & &1["turn_usage"]) == expected_turn_usage
      end
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
               execute(ThirdPartyToolAgent, "encode", sandbox: Legion.Sandbox.Elixir)
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
               Executor.run(
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
               Executor.run(
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
               Executor.run(
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
          Executor.run(
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
               Executor.run(MathAgent, executor_messages("compute"), %{})

      assert [
               %{"turn_usage" => 7, "message_index" => nil},
               %{"turn_usage" => 11, "message_index" => 3}
             ] = usage

      assert %{type: :assistant} = Enum.at(messages, 3)
    end

    test "an entry names no message when retries run out" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema -> response(nil, 7) end)

      assert {:cancel, :reached_max_retries, messages, [], usage} =
               Executor.run(MathAgent, executor_messages("compute"), %{max_retries: 0})

      assert [%{"turn_usage" => 7, "message_index" => nil}] = usage
      assert [%{type: :system}, %{type: :user}] = messages
    end
  end

  describe "max_message_length" do
    test "truncates eval results and errors fed back to the LLM" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 ->
            response(%{
              "action" => "eval_and_continue",
              "code" => "return string.rep(\"a\", 5000)",
              "result" => ""
            })

          2 ->
            response(%{
              "action" => "eval_and_complete",
              "code" => "error(string.rep(\"x\", 5000))",
              "result" => ""
            })

          3 ->
            response(%{"action" => "return", "code" => "", "result" => "done"})
        end
      end)

      assert {:ok, "done", messages, _bindings, _usage} =
               Executor.run(MathAgent, executor_messages("generate a lot"), %{
                 max_message_length: 200
               })

      assert [%{type: :eval_result} = result, %{type: :error} = error] =
               Enum.filter(messages, &(&1.type in [:eval_result, :error]))

      for feedback <- [result, error] do
        assert feedback.content =~ "[... truncated"
        assert byte_size(feedback.content) < 1_000
      end
    end
  end

  describe "custom output_schema" do
    test "return action passes structured result through" do
      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        response(%{
          "action" => "return",
          "code" => "",
          "result" => %{"summary" => "all good", "score" => 95}
        })
      end)

      assert {:ok, %{"summary" => "all good", "score" => 95}} =
               execute(StructuredOutputAgent, "evaluate")
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
               execute(StructuredOutputAgent, "compute")
    end
  end

  describe "action_types" do
    test "allows all four actions by default" do
      assert MathAgent.action_types() == ~w(eval_and_continue eval_and_complete return done)
    end

    test "a disallowed action is retried without running its code" do
      call_count = :counters.new(1, [:atomics])

      stub(ReqLLM, :generate_object, fn _model, _messages, _schema ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> response(%{"action" => "eval_and_complete", "code" => "return 1", "result" => ""})
          2 -> response(%{"action" => "return", "code" => "", "result" => "answer"})
        end
      end)

      assert {:ok, "answer"} = execute(ReturnOnlyAgent, "do something")
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

      execute(DeeplyNestedAgent, "test")

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

      assert {:ok, 984} = execute(MathAgent, "add", sandbox: Legion.Sandbox.Lua)

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
               execute(MathAgent, "add", sandbox: Legion.Sandbox.Lua)
    end
  end
end
