# Observability

Besides the `:telemetry` events listed in `Legion.Telemetry`, Legion emits
OpenTelemetry traces through `Legion.OpenTelemetry`, for LLM observability
tools such as Braintrust, Datadog LLM Observability or Langfuse.

## What you get

One trace per agent turn, shaped by the GenAI semantic conventions:

```
invoke_agent MyApp.ResearchAgent
├─ chat gpt-5.4                      legion.iteration=0
├─ execute_tool sandbox              legion.iteration=0
│  └─ invoke_agent MyApp.SubAgent    (called from the tool code)
│     └─ chat gpt-5.4
└─ chat gpt-5.4                      legion.iteration=1
```

- `invoke_agent <agent>` is one turn, with the agent's name and id, its
  iterations, status, model and provider.
- `chat <model>` is one LLM request from
  [ReqLLM's OpenTelemetry bridge](https://hexdocs.pm/req_llm/ReqLLM.OpenTelemetry.html),
  which Legion attaches: token usage, finish reasons, cost.
- `execute_tool sandbox` is one code evaluation. A failed one has `error.type`
  `runtime`, `timeout`, `crash`, `limit` or `guard_denied`.

Legion's spans and the agent's own `chat` spans carry `gen_ai.agent.name`
and `gen_ai.conversation.id` (the agent id). Every span carries `session.id`:
the id of the agent the conversation is with, shared by the sub-agents its
turns call. Retries (`legion.retry`) and eval guard
denials (`legion.eval_guard.denied`) are span events; a cancelled turn sets
`legion.cancel.reason` and an error status.

The trace follows the work across processes: a turn started under a Phoenix
request, an Oban job or any other current span nests under it, through
`Legion.call/3`, `Legion.cast/2`, `Legion.execute/3` and `Legion.parallel/2`,
and whatever the tool code traces nests under `execute_tool`.

## Setup

Legion depends on `opentelemetry_api` optionally. Add the SDK and exporter,
then recompile Legion once so it picks up the API
(`mix deps.compile legion --force`):

```elixir
# mix.exs
{:opentelemetry, "~> 1.5"},
{:opentelemetry_exporter, "~> 1.8"}
```

In a release, start the exporter before the SDK, or the first seconds of
spans are dropped:

```elixir
releases: [
  my_app: [applications: [opentelemetry_exporter: :permanent, opentelemetry: :temporary]]
]
```

Attach from `Application.start/2` (ReqLLM's span table is owned by the
process that attaches, so not from a Task):

```elixir
:ok = Legion.OpenTelemetry.attach()
```

The options, also accepted under `config :legion, Legion.OpenTelemetry`, are
listed in `Legion.OpenTelemetry`.

> #### Message content goes to your tracing backend {: .warning}
>
> By default (`content: :attributes`) spans carry prompts, replies, the code
> the model wrote, tool results and error messages. Attach with
> `content: :none` to keep them out; spans then keep their structure, timings,
> token counts and error types.

Content on Legion's own spans is cut to `max_attribute_bytes`; `chat` span
content is sent whole; the only cap on it is the SDK's
`attribute_value_length_limit` (`OTEL_SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT`),
which cuts mid-JSON. For `chat` content, Legion passes `payloads: :raw` to its
own ReqLLM calls unless you set `:payloads` in `config :req_llm, telemetry:`
yourself; your app's other ReqLLM calls need
`config :req_llm, telemetry: [payloads: :raw]`.

## Conversations

Each turn is its own trace, and the turns of a conversation share
`session.id`, which is how the vendors' own integrations group chats.
`conversation_traces: true` instead puts an agent's turns under one
`conversation <agent>` root span. It is ended as soon as it starts, since a
trace only shows up once its root is exported, and a turn called under
another span still nests there.

Each `repl` or `help` call to a `Legion.MCP.Server` is a `tools/call <tool>`
server span keyed by the MCP session id, with the agent's eval under it.

## Vendors

For Braintrust and Datadog, name the vendor's adapter in config and export
through `Legion.OpenTelemetry.Exporter`. `attach/1` raises at startup when
the vendor setup is incomplete.

```elixir
# config/runtime.exs
if config_env() == :prod do
  config :opentelemetry, traces_exporter: {Legion.OpenTelemetry.Exporter, []}
  config :legion, Legion.OpenTelemetry, adapter: Legion.OpenTelemetry.Adapter.Braintrust

  config :legion, Legion.OpenTelemetry.Adapter.Braintrust,
    api_key: System.fetch_env!("BRAINTRUST_API_KEY"),
    project: "my_app"
end
```

Settings for each vendor are in `Legion.OpenTelemetry.Adapter.Braintrust`
and `Legion.OpenTelemetry.Adapter.Datadog`. The SDK has one trace exporter, so
an app that already exports elsewhere should fan out through an
[OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) instead.
`OTEL_EXPORTER_OTLP_*` variables take precedence over the vendor's settings,
and `OTEL_TRACES_EXPORTER` replaces `Legion.OpenTelemetry.Exporter`
altogether, so unset them.

**Braintrust** shows one row per trace. To read a conversation, group the
Logs by `session_id` (**Group by**, then **Custom** if it is not listed) and
open the row in **Thread** view.

**Datadog** groups sessions by `gen_ai.conversation.id`, which the adapter
sets to `session.id`, so a conversation and its sub-agents are one session.
Traces take a few minutes to appear.

**Langfuse**: point `opentelemetry_exporter` at `/api/public/otel` with Basic
auth and attach with `req_llm: [langfuse: true]`.

## Custom adapters and ReqLLM

An adapter's `span_attributes/1` rewrites the attributes every span starts
with, see `Legion.OpenTelemetry.Adapter`.

Attaching `ReqLLM.OpenTelemetry` yourself as well gives two `chat` spans per
request. Move your options under `req_llm: [...]`, or keep your attach and
pass `req_llm: false`.
