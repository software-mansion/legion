defmodule Legion.ParallelAndPipelineTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Legion.Test.Support.MathAgent
  alias Legion.Tools.AgentTool

  defmodule TextAgent do
    @moduledoc "An agent that processes text."
    use Legion.Agent
  end

  setup :set_mimic_global

  @moduletag capture_log: true

  defp llm_response(result) do
    {:ok,
     %ReqLLM.Response{
       id: "test",
       model: "test",
       context: nil,
       object: %{"action" => "return", "code" => "", "result" => result},
       usage: %{turn_usage: 0}
     }}
  end

  describe "parallel/2" do
    test "runs multiple agents concurrently and collects results" do
      stub(ReqLLM, :generate_object, fn _model, messages, _schema, _opts ->
        user_msg = messages |> List.last() |> Map.get(:content)

        case user_msg do
          "What is 6 * 7?" -> llm_response("42")
          "Say hello" -> llm_response("hello")
        end
      end)

      assert {:ok, ["42", "hello"]} =
               Legion.parallel([
                 {MathAgent, "What is 6 * 7?"},
                 {TextAgent, "Say hello"}
               ])
    end

    test "returns {:cancel, reason} if any agent is cancelled" do
      stub(ReqLLM, :generate_object, fn _model, messages, _schema, _opts ->
        user_msg = messages |> Enum.find(&(&1[:role] == "user")) |> Map.get(:content)

        if user_msg == "quick task" do
          llm_response("good")
        else
          {:ok,
           %ReqLLM.Response{
             id: "cancel",
             model: "test",
             context: nil,
             object: %{"action" => "eval_and_continue", "code" => "return 1 + 1", "result" => ""},
             usage: %{turn_usage: 0}
           }}
        end
      end)

      assert {:cancel, :reached_max_iterations} =
               Legion.parallel([
                 {MathAgent, "quick task"},
                 {TextAgent, "slow task"}
               ])
    end

    test "works with a single task" do
      stub(ReqLLM, :generate_object, fn _m, _msgs, _s, _opts -> llm_response("only one") end)

      assert {:ok, ["only one"]} = Legion.parallel([{MathAgent, "single task"}])
    end

    test "AgentTool.parallel accepts [agent, task] pairs from the Lua sandbox bridge" do
      stub(ReqLLM, :generate_object, fn _m, _msgs, _s, _opts -> llm_response("42") end)
      Vault.unsafe_put(AgentTool, agents: [MathAgent])

      assert {:ok, ["42"]} = AgentTool.parallel([[MathAgent, "What is 6 * 7?"]])
    end

    test "respects timeout" do
      stub(ReqLLM, :generate_object, fn _m, _msgs, _s, _opts ->
        Process.sleep(5_000)
        llm_response("too late")
      end)

      assert catch_exit(Legion.parallel([{MathAgent, "slow"}], 50))
    end
  end

  describe "pipeline/1" do
    test "runs steps sequentially with static string tasks" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(ReqLLM, :generate_object, fn _m, _msgs, _s, _opts ->
        i = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        llm_response("step #{i + 1} done")
      end)

      assert {:ok, "step 2 done"} =
               Legion.pipeline([
                 {MathAgent, "do step 1"},
                 {TextAgent, "do step 2"}
               ])
    end

    test "threads previous result into function steps" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _m, messages, _s, _opts ->
        i = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        user_msg = messages |> List.last() |> Map.get(:content)
        send(test_pid, {:llm_user_msg, i, user_msg})

        if i == 0, do: llm_response("intermediate"), else: llm_response("final")
      end)

      assert {:ok, "final"} =
               Legion.pipeline([
                 {MathAgent, "start"},
                 {TextAgent, fn prev -> "Process: #{prev}" end}
               ])

      assert_received {:llm_user_msg, 0, "start"}
      assert_received {:llm_user_msg, 1, "Process: intermediate"}
    end

    test "halts on cancel and skips subsequent steps" do
      stub(ReqLLM, :generate_object, fn _m, _msgs, _s, _opts ->
        {:ok,
         %ReqLLM.Response{
           id: "cancel",
           model: "test",
           context: nil,
           object: %{"action" => "eval_and_continue", "code" => "return 1 + 1", "result" => ""},
           usage: %{turn_usage: 0}
         }}
      end)

      assert {:cancel, :reached_max_iterations} =
               Legion.pipeline([
                 {MathAgent, "will cancel"},
                 {TextAgent, fn _ -> "never reached" end}
               ])
    end

    test "works with a single step" do
      stub(ReqLLM, :generate_object, fn _m, _msgs, _s, _opts -> llm_response("only step") end)

      assert {:ok, "only step"} = Legion.pipeline([{MathAgent, "single step"}])
    end

    test "raises ArgumentError on invalid step format" do
      assert_raise ArgumentError, ~r/expected task to be a binary or a function\/1/, fn ->
        Legion.pipeline([{MathAgent, 42}])
      end
    end
  end

  describe "then/3" do
    test "chains after a successful result" do
      test_pid = self()

      stub(ReqLLM, :generate_object, fn _m, messages, _s, _opts ->
        user_msg = messages |> List.last() |> Map.get(:content)
        send(test_pid, {:then_msg, user_msg})
        llm_response("chained")
      end)

      assert {:ok, "chained"} =
               Legion.then({:ok, "prev"}, MathAgent, fn prev -> "Use #{prev}" end)

      assert_received {:then_msg, "Use prev"}
    end

    test "passes through cancel without executing" do
      reject(&ReqLLM.generate_object/4)

      assert {:cancel, :some_reason} =
               Legion.then({:cancel, :some_reason}, MathAgent, fn _ -> "ignored" end)
    end
  end
end
