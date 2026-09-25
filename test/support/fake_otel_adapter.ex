defmodule Legion.Test.Support.FakeOTelAdapter do
  @moduledoc """
  `Legion.OpenTelemetry.Adapter` that reports every callback to the process
  registered with `register/1`. Spans are plain references.

  Adapter callbacks run in whichever process emits the telemetry event (the
  agent process for LLM requests), so the test process registers itself under
  a name instead of closing over `self()`.
  """

  @behaviour Legion.OpenTelemetry.Adapter

  def register(pid) do
    if Process.whereis(__MODULE__), do: Process.unregister(__MODULE__)
    Process.register(pid, __MODULE__)
    :ok
  end

  @impl true
  def available?, do: true

  @impl true
  def start_span(name, attributes, config) do
    span = make_ref()
    report({:otel, :start_span, span, name, attributes, config})
    span
  end

  @impl true
  def set_attributes(span, attributes, config) do
    report({:otel, :set_attributes, span, attributes, config})
  end

  @impl true
  def add_event(span, name, attributes, config) do
    report({:otel, :add_event, span, name, attributes, config})
  end

  @impl true
  def set_status(span, status, message, config) do
    report({:otel, :set_status, span, status, message, config})
  end

  @impl true
  def end_span(span, config) do
    report({:otel, :end_span, span, config})
  end

  defp report(message) do
    if pid = Process.whereis(__MODULE__), do: send(pid, message)
    :ok
  end
end
