defmodule Legion.OpenTelemetry.Adapter.Braintrust do
  @moduledoc """
  `Legion.OpenTelemetry.Adapter` for Braintrust, on top of
  `Legion.OpenTelemetry.Adapter.OTel`.

  Each agent turn is its own trace, and Braintrust shows one row per trace.
  Braintrust's own integrations tie the turns of a conversation together with
  a session id in metadata: grouping the logs by `metadata.session_id` opens a
  whole conversation in Thread view, and online scorers with Group scope score
  it as one. This adapter does the same, adding `braintrust.metadata` with
  `session_id` to every span. The value is Legion's `session.id`: the id of the
  agent the conversation is with, shared by the sub-agents its turns call, so
  every span of a trace has the same key, as Group scope requires.

      Legion.OpenTelemetry.attach(adapter: Legion.OpenTelemetry.Adapter.Braintrust, content: :attributes)

  Braintrust reads Legion's content attributes as they are. To get one trace
  per conversation instead, add `conversation_traces: true`; the session id
  stays on every span either way.
  """

  @behaviour Legion.OpenTelemetry.Adapter

  alias Legion.OpenTelemetry.Adapter.OTel

  @impl true
  defdelegate available?(), to: OTel

  @impl true
  defdelegate set_attributes(span, attributes, config), to: OTel

  @impl true
  defdelegate add_event(span, name, attributes, config), to: OTel

  @impl true
  defdelegate set_status(span, status, message, config), to: OTel

  @impl true
  defdelegate end_span(span, config), to: OTel

  @impl true
  defdelegate end_span_at(span, end_time, config), to: OTel

  @impl true
  defdelegate metrics_available?(), to: OTel

  @impl true
  defdelegate record_histogram(record, config), to: OTel

  @impl true
  defdelegate record_counter(record, config), to: OTel

  @impl true
  def start_span(name, attributes, config) do
    OTel.start_span(name, with_session(attributes), config)
  end

  @impl true
  def start_child_span(parent, name, attributes, opts, config) do
    OTel.start_child_span(parent, name, with_session(attributes), opts, config)
  end

  defp with_session(%{"session.id": session} = attributes) when is_binary(session),
    do: Map.put(attributes, :"braintrust.metadata", Jason.encode!(%{"session_id" => session}))

  defp with_session(attributes), do: attributes
end
