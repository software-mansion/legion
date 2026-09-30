defmodule Legion.OpenTelemetry.Metrics do
  @moduledoc false

  # Metric records for Legion's agent and tool activity, handed to the
  # adapter's `record_histogram/2` and `record_counter/2`. Histogram records
  # have the shape ReqLLM's bridge uses for its client metrics; counter records
  # add `kind: :counter`. Bucket boundaries follow the GenAI
  # semantic conventions where they define one.

  @agent_duration [0.1, 0.2, 0.4, 0.8, 1.6, 3.2, 6.4, 12.8, 25.6, 51.2, 102.4, 204.8, 409.6]
  @tool_duration [
    0.01,
    0.02,
    0.04,
    0.08,
    0.16,
    0.32,
    0.64,
    1.28,
    2.56,
    5.12,
    10.24,
    20.48,
    40.96,
    81.92
  ]
  @calls [1, 2, 4, 8, 16, 32, 64, 128]
  @iterations [1, 2, 4, 8, 16, 32]

  @definitions %{
    "gen_ai.invoke_agent.duration" =>
      {:histogram, "s", "GenAI agent invocation duration.", @agent_duration},
    "gen_ai.invoke_agent.inference_calls" =>
      {:histogram, "{inference_call}", "LLM calls made by one agent invocation.", @calls},
    "gen_ai.invoke_agent.tool_calls" =>
      {:histogram, "{tool_call}", "Tool calls made by one agent invocation.", @calls},
    "gen_ai.execute_tool.duration" =>
      {:histogram, "s", "GenAI tool execution duration.", @tool_duration},
    "legion.turn.iterations" =>
      {:histogram, "{iteration}", "Iterations in one agent turn.", @iterations},
    "legion.eval.errors" => {:counter, "{error}", "Failed sandbox evaluations."},
    "legion.llm.retries" => {:counter, "{retry}", "LLM requests retried within a turn."},
    "legion.turn.cancellations" => {:counter, "{turn}", "Agent turns cancelled."},
    "legion.rate_limit.exceeded" => {:counter, "{turn}", "Turns denied by a rate limiter."}
  }

  @doc "Builds the record for metric `name`."
  def build(name, value, attributes) do
    case Map.fetch!(@definitions, name) do
      {:histogram, unit, description, boundaries} ->
        %{
          name: name,
          value: value,
          unit: unit,
          description: description,
          boundaries: boundaries,
          attributes: attributes
        }

      {kind, unit, description} ->
        %{
          name: name,
          kind: kind,
          value: value,
          unit: unit,
          description: description,
          attributes: attributes
        }
    end
  end

  @doc """
  Hands `records` to the adapter when metrics are on. Counter records are
  skipped for adapters without the optional `record_counter/2`.
  """
  def record(records, config) do
    if config[:metrics?] do
      Enum.each(records, &record_one(&1, config[:tracer], config))
    end

    :ok
  end

  defp record_one(%{kind: _} = record, adapter, config) do
    if function_exported?(adapter, :record_counter, 2),
      do: adapter.record_counter(record, config)
  end

  defp record_one(record, adapter, config), do: adapter.record_histogram(record, config)

  @doc "Whether `adapter` can record metrics."
  def available?(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :metrics_available?, 0) and
      function_exported?(adapter, :record_histogram, 2) and adapter.metrics_available?()
  end

  @doc "Seconds from a `:telemetry` native-unit duration."
  def seconds(duration) when is_integer(duration),
    do: System.convert_time_unit(duration, :native, :microsecond) / 1_000_000

  def seconds(_duration), do: nil
end
