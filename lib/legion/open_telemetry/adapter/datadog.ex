defmodule Legion.OpenTelemetry.Adapter.Datadog do
  @moduledoc """
  `Legion.OpenTelemetry.Adapter` for Datadog LLM Observability, on top of
  `Legion.OpenTelemetry.Adapter.OTel`.

  Datadog turns OpenTelemetry GenAI spans into LLM Observability spans, but
  keeps only the attributes it maps and other `gen_ai.*` ones. This adapter
  reshapes the rest so it survives:

    * `legion.*` and `req_llm.*` attributes (`legion.status`,
      `legion.iteration`, `legion.cancel.reason`, ...), which Datadog drops,
      move into `_dd.ml_obs.metadata`, the JSON object Datadog reads as the
      span's metadata.
    * Span events (`legion.retry`, `legion.eval_guard.denied`,
      `legion.rate_limit.exceeded`), which Datadog ignores, are also kept as
      metadata, under `"events"`.
    * Agent and workflow spans (`invoke_agent`, `conversation`, `iteration`)
      show their input and output from `input.value` / `output.value`, not
      from message attributes, so the text of `gen_ai.input.messages` /
      `gen_ai.output.messages` is copied there. Needs `content: :attributes`.

  `chat` and `execute_tool` spans are left as they are: Datadog reads their
  messages, tool arguments and results directly.

      Legion.OpenTelemetry.attach(adapter: Legion.OpenTelemetry.Adapter.Datadog, content: :attributes)

  Metadata collected for a span lives in the process dictionary of the process
  that started it until the span ends. Legion's spans and ReqLLM's `chat` spans
  start and end in the same process.
  """

  @behaviour Legion.OpenTelemetry.Adapter

  alias Legion.OpenTelemetry.Adapter.OTel

  @metadata_attribute :"_dd.ml_obs.metadata"
  @metadata_prefixes ["legion.", "req_llm."]
  @agent_operations ["invoke_agent", nil]

  @impl true
  defdelegate available?(), to: OTel

  @impl true
  defdelegate set_status(span, status, message, config), to: OTel

  @impl true
  defdelegate metrics_available?(), to: OTel

  @impl true
  defdelegate record_histogram(record, config), to: OTel

  @impl true
  defdelegate record_counter(record, config), to: OTel

  @impl true
  def start_span(name, attributes, config) do
    operation = attribute(attributes, :"gen_ai.operation.name")
    {attributes, metadata} = reshape(attributes, operation)
    span = OTel.start_span(name, attributes, config)
    remember(span, operation, metadata, config)
  end

  @impl true
  def start_child_span(parent, name, attributes, opts, config) do
    operation = attribute(attributes, :"gen_ai.operation.name")
    {attributes, metadata} = reshape(attributes, operation)
    span = OTel.start_child_span(parent, name, attributes, opts, config)
    remember(span, operation, metadata, config)
  end

  @impl true
  def set_attributes(span, attributes, config) do
    state = state(span)
    {attributes, metadata} = reshape(attributes, state.operation)
    state = %{state | metadata: Map.merge(state.metadata, metadata)}

    attributes =
      if metadata == %{},
        do: attributes,
        else: Map.put(attributes, @metadata_attribute, Jason.encode!(state.metadata))

    put_state(span, state)
    OTel.set_attributes(span, attributes, config)
  end

  @impl true
  def add_event(span, name, attributes, config) do
    OTel.add_event(span, name, attributes, config)

    event = Map.put(stringify_keys(attributes), "name", to_string(name))
    state = state(span)
    events = Map.get(state.metadata, "events", []) ++ [event]
    state = %{state | metadata: Map.put(state.metadata, "events", events)}
    put_state(span, state)

    attributes = %{@metadata_attribute => Jason.encode!(state.metadata)}
    OTel.set_attributes(span, attributes, config)
  end

  @impl true
  def end_span(span, config) do
    forget(span)
    OTel.end_span(span, config)
  end

  @impl true
  def end_span_at(span, end_time, config) do
    forget(span)
    OTel.end_span_at(span, end_time, config)
  end

  # Splits Datadog-dropped attributes off into metadata, and copies message
  # text into `input.value` / `output.value` on agent and workflow spans.
  defp reshape(attributes, operation) do
    {metadata, kept} =
      Enum.split_with(attributes, fn {key, _value} ->
        String.starts_with?(to_string(key), @metadata_prefixes)
      end)

    kept = Map.new(kept)

    kept =
      if operation in @agent_operations do
        kept
        |> put_text(:"input.value", attribute(kept, :"gen_ai.input.messages"))
        |> put_text(:"output.value", attribute(kept, :"gen_ai.output.messages"))
      else
        kept
      end

    {kept, stringify_keys(metadata)}
  end

  defp put_text(attributes, _key, nil), do: attributes

  defp put_text(attributes, key, messages) do
    case message_text(messages) do
      "" -> attributes
      text -> Map.put(attributes, key, text)
    end
  end

  # The text parts of a semconv messages JSON string, one message per line.
  defp message_text(messages) when is_binary(messages) do
    case Jason.decode(messages) do
      {:ok, decoded} when is_list(decoded) ->
        decoded
        |> Enum.flat_map(&Map.get(&1, "parts", []))
        |> Enum.flat_map(fn
          %{"type" => "text", "content" => content} when is_binary(content) -> [content]
          _part -> []
        end)
        |> Enum.join("\n")

      _ ->
        messages
    end
  end

  defp message_text(_messages), do: ""

  defp attribute(attributes, key),
    do: Map.get(attributes, key) || Map.get(attributes, Atom.to_string(key))

  defp stringify_keys(attributes), do: Map.new(attributes, fn {k, v} -> {to_string(k), v} end)

  # Metadata goes out with the span's first attributes, then again whenever
  # it grows, since each write replaces the attribute.
  defp remember(span, operation, metadata, config) do
    put_state(span, %{operation: operation, metadata: metadata})

    if metadata != %{},
      do:
        OTel.set_attributes(
          span,
          %{@metadata_attribute => Jason.encode!(metadata)},
          config
        )

    span
  end

  defp state(span), do: Process.get({__MODULE__, span}, %{operation: nil, metadata: %{}})
  defp put_state(span, state), do: Process.put({__MODULE__, span}, state)
  defp forget(span), do: Process.delete({__MODULE__, span})
end
