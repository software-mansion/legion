defmodule Legion.OpenTelemetry.ReqLLM do
  @moduledoc """
  `ReqLLM.OpenTelemetry.Adapter` that forwards ReqLLM's `chat` spans to the
  tracer `Legion.OpenTelemetry.attach/1` resolved: the chosen
  `Legion.OpenTelemetry.Adapter` when it traces spans itself, otherwise
  `Legion.OpenTelemetry.Adapter.OTel`.

  Installed by `Legion.OpenTelemetry.attach/1` unless the host passes its own
  `req_llm: [adapter: ...]`. Every callback receives ReqLLM's bridge config,
  which carries that tracer as `:legion_adapter` and the Legion attach
  options as `:legion_config`; the tracer is called with the latter plus
  `span_kind: :client`.

  A `chat` span started in the agent process during a turn, and the
  `execute_tool` spans ReqLLM adds under it for provider-side tools, also get
  `gen_ai.agent.name`, `gen_ai.conversation.id`, `session.id` and
  `legion.iteration`; one started from tool code gets `session.id` only.
  Values ReqLLM sets win.

  ReqLLM records message content (`gen_ai.input.messages`,
  `gen_ai.output.messages`, `gen_ai.system_instructions`,
  `gen_ai.tool.definitions`) as a list of JSON strings, one per entry. The shim
  joins each list into one JSON array string, the form the GenAI semantic
  conventions give for span attributes and the only one Braintrust parses, so
  `chat` content matches Legion's own spans.
  """

  alias Legion.OpenTelemetry.Handler

  @behaviour ReqLLM.OpenTelemetry.Adapter

  @impl true
  def available? do
    case Legion.OpenTelemetry.config() do
      nil -> false
      config -> config[:tracer].available?()
    end
  end

  @impl true
  def metrics_available? do
    case Legion.OpenTelemetry.config() do
      nil -> false
      config -> config[:metrics?] == true
    end
  end

  @impl true
  def start_span(name, attributes, config) do
    attributes = Handler.chat_attributes() |> Map.merge(attributes) |> join_content()
    adapter(config).start_span(name, attributes, legion_config(config))
  end

  # ReqLLM repeats its start attributes when the request ends. The conversation
  # id was set at start, where an adapter may have rewritten it (Datadog puts
  # the session there), so the repeat is dropped.
  @impl true
  def set_attributes(span, attributes, config) do
    attributes = attributes |> Map.drop([:"gen_ai.conversation.id"]) |> join_content()
    adapter(config).set_attributes(span, attributes, legion_config(config))
  end

  @impl true
  def add_event(span, name, attributes, config) do
    adapter(config).add_event(span, name, attributes, legion_config(config))
  end

  @impl true
  def set_status(span, status, message, config) do
    adapter(config).set_status(span, status, message, legion_config(config))
  end

  @impl true
  def end_span(span, config) do
    adapter(config).end_span(span, legion_config(config))
  end

  @impl true
  def record_histogram(record, config) do
    legion_config = legion_config(config)

    if legion_config[:metrics?],
      do: adapter(config).record_histogram(record, legion_config),
      else: :ok
  end

  @impl true
  def start_child_span(parent, name, attributes, opts, config) do
    adapter = adapter(config)
    legion_config = legion_config(config, Map.get(opts, :kind, :internal))

    attributes = Handler.chat_attributes() |> Map.merge(attributes) |> join_content()

    if function_exported?(adapter, :start_child_span, 5),
      do: adapter.start_child_span(parent, name, attributes, opts, legion_config),
      else: adapter.start_span(name, attributes, legion_config)
  end

  @impl true
  def end_span_at(span, end_time, config) do
    adapter = adapter(config)

    if function_exported?(adapter, :end_span_at, 3),
      do: adapter.end_span_at(span, end_time, legion_config(config)),
      else: adapter.end_span(span, legion_config(config))
  end

  @content_keys [
    :"gen_ai.input.messages",
    :"gen_ai.output.messages",
    :"gen_ai.system_instructions",
    :"gen_ai.tool.definitions"
  ]

  defp join_content(attributes) do
    Enum.reduce(@content_keys, attributes, fn key, acc ->
      case acc do
        %{^key => [_ | _] = entries} -> Map.put(acc, key, json_array(entries))
        _ -> acc
      end
    end)
  end

  defp json_array(entries) do
    if Enum.all?(entries, &is_binary/1),
      do: "[" <> Enum.join(entries, ",") <> "]",
      else: entries
  end

  defp adapter(config), do: Keyword.fetch!(config, :legion_adapter)

  defp legion_config(config, span_kind \\ :client) do
    config
    |> Keyword.get(:legion_config, [])
    |> Keyword.put(:span_kind, span_kind)
  end
end
