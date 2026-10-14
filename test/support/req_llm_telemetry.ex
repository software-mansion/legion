defmodule Legion.Test.Support.ReqLLMTelemetry do
  @moduledoc """
  Emits the `[:req_llm, :request, :start | :stop]` events a real
  `ReqLLM.generate_object/4` call would emit, from inside a Mimic stub.

  `opts` are the options the stubbed call received; their `:telemetry` entry
  drives `gen_ai.conversation.id` and payload capture exactly as in ReqLLM.
  """

  def emit_request(model_spec, opts \\ [], response \\ nil) do
    model = ReqLLM.model!(model_spec)

    opts =
      Keyword.merge(
        [operation: :object, context: ReqLLM.Context.new([ReqLLM.Context.user("hi")])],
        Keyword.take(opts, [:telemetry])
      )

    response =
      response ||
        %ReqLLM.Response{
          id: "resp-1",
          model: model.id,
          context: ReqLLM.Context.new([]),
          object: %{},
          usage: %{input_tokens: 3, output_tokens: 5, total_tokens: 8},
          finish_reason: :stop
        }

    model
    |> ReqLLM.Telemetry.new_context(opts)
    |> ReqLLM.Telemetry.start_request(nil)
    |> ReqLLM.Telemetry.stop_request(response)

    :ok
  end
end
