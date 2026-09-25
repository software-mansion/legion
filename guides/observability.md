# Observability

Legion reports what its agents do in two ways:

- `:telemetry` events for every turn, iteration, LLM request and sandbox eval,
  listed in `Legion.Telemetry`. `Legion.Telemetry.attach_default_logger/1`
  prints them.
- OpenTelemetry traces through `Legion.OpenTelemetry`, for LLM observability
  tools such as Braintrust, Datadog LLM Observability, Langfuse or Honeycomb.

This guide covers the OpenTelemetry side.

## What you get

Every LLM request an agent makes becomes a GenAI semantic-conventions `chat`
span, emitted by [ReqLLM's OpenTelemetry bridge](https://hexdocs.pm/req_llm/ReqLLM.OpenTelemetry.html)
and attached by Legion: provider, model, token usage, finish reasons, cost,
and `gen_ai.conversation.id` set to the agent id so one conversation's calls
group together. When a Phoenix request, Oban job or any other span is current
in the process that calls `Legion.call/3` or `Legion.cast/2`, the `chat` spans
nest under it.

Spans for the agent turn itself and for sandbox evals are planned for a later
release; `Legion.OpenTelemetry.Adapter` is already shaped for them.

## Setup

Legion depends on `opentelemetry_api` optionally. The host app brings the SDK
and an exporter:

```elixir
# mix.exs
{:opentelemetry_exporter, "~> 1.8"},
{:opentelemetry, "~> 1.5"}
```

If Legion was compiled before these were added, recompile it once so the
integration picks up the API: `mix deps.compile legion --force`.

Attach once at startup:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  :ok = Legion.OpenTelemetry.attach()
  ...
end
```

Options, all optional:

```elixir
Legion.OpenTelemetry.attach(
  content: :attributes,          # record messages on spans; default :none
  adapter: MyApp.OTelAdapter,    # Legion.OpenTelemetry.Adapter; default OTelAdapter
  req_llm: [langfuse: true]      # extra ReqLLM.OpenTelemetry.attach/2 options, or false
)
```

`content: :attributes` puts the messages, system instructions and tool
definitions on the `chat` spans as `gen_ai.input.messages`,
`gen_ai.system_instructions`, `gen_ai.tool.definitions` and
`gen_ai.output.messages`. It also sets `config :req_llm, telemetry: [payloads: :raw]`
unless you configured `:payloads` yourself, because ReqLLM only maps content
when payloads are raw.

Legion passes a per-call `:telemetry` option to ReqLLM for the conversation id.
Your own `config :req_llm, telemetry: [...]` is merged into it, not replaced.

## Vendors

All of them take the stock OTLP exporter; nothing vendor-specific lives in
Legion.

Braintrust (`x-bt-parent` selects the project; EU organizations use
`api-eu.braintrust.dev`):

```elixir
config :opentelemetry, traces_exporter: :otlp

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: "https://api.braintrust.dev/otel",
  otlp_headers: [
    {"authorization", "Bearer #{System.fetch_env!("BRAINTRUST_API_KEY")}"},
    {"x-bt-parent", "project_name:my-app"}
  ]
```

Braintrust reads `gen_ai.input.messages` only as a single JSON string, while
ReqLLM emits a list of JSON strings. Until ReqLLM changes that, copy the
content into `braintrust.input_json` / `braintrust.output_json` from a custom
adapter (see below).

Datadog LLM Observability (`service.name` becomes the ML app):

```elixir
config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: System.fetch_env!("DD_OTLP_TRACES_ENDPOINT"),
  otlp_headers: [
    {"dd-api-key", System.fetch_env!("DD_API_KEY")},
    {"dd-otlp-source", "llmobs"}
  ]
```

Langfuse: point the exporter at `/api/public/otel` with Basic auth and pass
`req_llm: [langfuse: true]` for cost and time-to-first-token attributes.

## Custom adapters

`Legion.OpenTelemetry.Adapter` mirrors `ReqLLM.OpenTelemetry.Adapter`, so one
module can implement both. Delegate what you keep to
`Legion.OpenTelemetry.OTelAdapter` and override the rest:

```elixir
defmodule MyApp.OTelAdapter do
  @behaviour Legion.OpenTelemetry.Adapter

  alias Legion.OpenTelemetry.OTelAdapter

  defdelegate available?(), to: OTelAdapter
  defdelegate add_event(span, name, attrs, config), to: OTelAdapter
  defdelegate set_status(span, kind, message, config), to: OTelAdapter
  defdelegate end_span(span, config), to: OTelAdapter
  defdelegate metrics_available?(), to: OTelAdapter
  defdelegate record_histogram(record, config), to: OTelAdapter
  defdelegate start_child_span(parent, name, attrs, opts, config), to: OTelAdapter
  defdelegate end_span_at(span, end_time, config), to: OTelAdapter

  def start_span(name, attrs, config), do: OTelAdapter.start_span(name, copy(attrs), config)
  def set_attributes(span, attrs, config), do: OTelAdapter.set_attributes(span, copy(attrs), config)

  defp copy(%{"gen_ai.input.messages": input} = attrs),
    do: Map.put(attrs, :"braintrust.input_json", "[" <> Enum.join(input, ",") <> "]")

  defp copy(%{"gen_ai.output.messages": output} = attrs),
    do: Map.put(attrs, :"braintrust.output_json", "[" <> Enum.join(output, ",") <> "]")

  defp copy(attrs), do: attrs
end

Legion.OpenTelemetry.attach(adapter: MyApp.OTelAdapter, content: :attributes)
```

Attribute keys arrive as atoms. `config` is the keyword given to `attach/1`
plus `:span_kind`.

## Hosts that already attach ReqLLM

Attaching `ReqLLM.OpenTelemetry` twice produces two `chat` spans per request.
Either drop your own attach and move its options under `req_llm:`:

```elixir
Legion.OpenTelemetry.attach(req_llm: [adapter: MyApp.ReqLLMAdapter, content: :attributes])
```

or keep it and tell Legion to leave ReqLLM alone:

```elixir
Legion.OpenTelemetry.attach(req_llm: false)
```

With `req_llm: false` Legion still tags requests with the conversation id and
still carries the caller's context into the agent process.
