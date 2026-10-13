defmodule Legion.Test.Support.LLMStub do
  @moduledoc """
  Stubs `ReqLLM.generate_object/4` with scripted replies, emitting the
  `[:req_llm, :request, :*]` events a real call would.

  A reply is an action map, built with `return/1` or `eval/1`, or
  `{:error, reason}` for a failed request. `reply_with/1` takes one reply, used
  for every call, or a list answered in order.
  """

  alias Legion.Test.Support.ReqLLMTelemetry

  @model "openai:gpt-4o-mini"

  def model, do: @model

  def return(result), do: %{"action" => "return", "code" => "", "result" => result}
  def eval(code), do: %{"action" => "eval_and_continue", "code" => code, "result" => ""}

  def response(object, usage \\ %{}) do
    %ReqLLM.Response{id: "t", model: "t", context: nil, object: object, usage: usage}
  end

  def reply_with(replies) when is_list(replies) do
    {:ok, script} = Agent.start_link(fn -> replies end)

    stub(fn opts ->
      script
      |> Agent.get_and_update(fn [next | rest] -> {next, rest} end)
      |> answer(opts)
    end)
  end

  def reply_with(reply), do: stub(&answer(reply, &1))

  def answer({:error, reason}, _opts), do: {:error, reason}

  def answer(object, opts) do
    ReqLLMTelemetry.emit_request(@model, opts)
    {:ok, response(object)}
  end

  defp stub(fun) do
    Mimic.stub(ReqLLM, :generate_object, fn _model, _messages, _schema, opts -> fun.(opts) end)
  end
end
