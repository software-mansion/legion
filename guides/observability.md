# Observability

Legion reports what its agents do in two ways:

- `:telemetry` events for every turn, iteration, LLM request and sandbox eval,
  listed in `Legion.Telemetry`. `Legion.Telemetry.attach_default_logger/1`
  prints them.
- OpenTelemetry traces through `Legion.OpenTelemetry`, for LLM observability
  tools such as Braintrust, Datadog LLM Observability, Langfuse or Honeycomb.

This guide covers the OpenTelemetry side.

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

- `invoke_agent <agent>` covers one turn: `gen_ai.agent.name`,
  `gen_ai.agent.id` and `gen_ai.conversation.id` (both the agent id),
  `legion.iterations`, `legion.status`, and the model and provider the turn
  used.
- `chat <model>` is one LLM request, emitted by
  [ReqLLM's OpenTelemetry bridge](https://hexdocs.pm/req_llm/ReqLLM.OpenTelemetry.html),
  which Legion attaches: provider, model, token usage, finish reasons, cost.
  Legion adds the agent name and `legion.iteration`.
- `execute_tool sandbox` is one code evaluation, with `legion.eval.success`.
  A failed evaluation sets the span's error status and `error.type` to one of
  `runtime`, `timeout`, `crash`, `limit` or `guard_denied`.

A failed span's status message is the error's own message only with
`content: :attributes`, since error messages can quote tool data; otherwise
it is just the `error.type`.

Legion's spans and the agent's own `chat` spans carry `gen_ai.agent.name`
and `gen_ai.conversation.id`, so Datadog, which drops spans without a
`gen_ai.*` attribute, keeps them all.
Every span also carries `session.id`: the id of the agent the conversation is
with. A sub-agent's spans carry the session of the turn that called it, so one
trace never mixes sessions, while `gen_ai.conversation.id` stays each agent's
own id. Langfuse groups sessions by `session.id`.

Things that go wrong within a turn are span events:

- `legion.retry` on `invoke_agent` when the LLM is asked again after a failed
  request, an unparsable response or an action the agent may not take
  (`legion.retry.reason`: `request_failed`, `invalid_object`, `invalid_action`).
- `legion.eval_guard.denied` on `execute_tool` when an eval guard refuses the
  code, with the guard's reason under `content: :attributes`.
- A cancelled turn (for example `reached_max_iterations`) sets
  `legion.status` to `cancelled`, `legion.cancel.reason`, `error.type` and the
  error status.

The trace follows the work across processes. When a Phoenix request, Oban
job or any other span is current in the process that calls `Legion.call/3`,
`Legion.cast/2`, `Legion.execute/3` or `Legion.parallel/2`, the turn nests
under it; tool code runs under its `execute_tool` span, so sub-agents,
`Req` calls and database queries it makes nest there too. A conversation
resumed with `Legion.recover/2` starts a new trace.

## Setup

Legion depends on `opentelemetry_api` optionally. The host app brings the SDK
and an exporter:

```elixir
# mix.exs
{:opentelemetry, "~> 1.5"},
{:opentelemetry_exporter, "~> 1.8"}
```

If Legion was compiled before these were added, recompile it once so the
integration picks up the API: `mix deps.compile legion --force`.

In a release, start the exporter before the SDK, as
[OpenTelemetry's Erlang exporter docs](https://opentelemetry.io/docs/languages/erlang/exporters/)
recommend. Otherwise the SDK sets up the exporter before `:inets` runs, and
the spans of the first seconds after boot are dropped:

```elixir
# mix.exs
releases: [
  my_app: [
    applications: [opentelemetry_exporter: :permanent, opentelemetry: :temporary]
  ]
]
```

Attach once at startup:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  :ok = Legion.OpenTelemetry.attach()
  ...
end
```

Call it from `Application.start/2`, not from a Task or a remote console:
ReqLLM keeps its in-flight `chat` spans in a table owned by the process that
first attaches, and the table goes away when that process exits.

Options, all optional:

```elixir
Legion.OpenTelemetry.attach(
  content: :attributes,          # the default; :none keeps message content out
  max_attribute_bytes: 20_000,   # cap for content on Legion's own spans
  metrics: true,                 # false turns metrics off
  iteration_spans: false,        # true adds an `iteration N` span per iteration
  conversation_traces: false,    # true puts an agent's turns in one trace
  adapter: MyApp.OTelAdapter,    # default: the configured vendor, else Adapter.OTel
  req_llm: [langfuse: true]      # extra ReqLLM.OpenTelemetry.attach/2 options, or false
)
```

The same options can live in config; options passed to `attach/1` win:

```elixir
# config/config.exs
config :legion, Legion.OpenTelemetry, iteration_spans: true
```

> #### Message content goes to your tracing backend {: .warning}
>
> With the default `content: :attributes`, spans carry the prompts, the
> model's replies, the code the model wrote, tool results and error messages.
> Whoever can read your traces can read them. This is the opposite of
> `ReqLLM.OpenTelemetry`'s default (`:none`), because the vendors Legion ships
> adapters for are LLM observability tools and show little without content.
> To keep content out, attach with
> `content: :none` (or set it in `config :legion, Legion.OpenTelemetry`):
> spans then keep their structure, timings, token counts and error types, and
> a failed span's status names only its `error.type`.

With `content: :attributes`, Legion puts the messages, system instructions and tool
definitions on the `chat` spans as `gen_ai.input.messages`,
`gen_ai.system_instructions`, `gen_ai.tool.definitions` and
`gen_ai.output.messages`, each one JSON array string. ReqLLM only maps
content when payloads are raw, so Legion passes `payloads: :raw` to its own
ReqLLM calls unless you configured `:payloads` yourself; your app's other
ReqLLM calls need `config :req_llm, telemetry: [payloads: :raw]` for their
content. On Legion's own spans it records the user message and
the turn's result on `invoke_agent` (`gen_ai.input.messages`,
`gen_ai.output.messages`, each one JSON string) and the evaluated code and its
result on `execute_tool` (`gen_ai.tool.call.arguments`,
`gen_ai.tool.call.result`), each cut to `max_attribute_bytes` on a UTF-8
boundary.

`max_attribute_bytes` caps Legion's own spans only; `chat` span content is
sent whole, so a long conversation makes large `chat` spans. The hard cap for
every attribute is the SDK's span limit,
`config :opentelemetry, attribute_value_length_limit: 20_000` (or
`OTEL_SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT`), which cuts values mid-string, so a
cut message attribute is no longer valid JSON.

`attach/1` is safe to call again: a second call that succeeds replaces the
first, so it can live in `Application.start/2` without guarding against
restarts.

`iteration_spans: true` inserts an `iteration N` span between `invoke_agent`
and the `chat` and `execute_tool` spans of that iteration. Braintrust shows
them as tasks, Datadog as workflow steps. A retried iteration appears twice
with the same number.

Legion passes a per-call `:telemetry` option to ReqLLM for the conversation id.
Your own `config :req_llm, telemetry: [...]` is merged into it, not replaced.

### Conversations

By default each turn is its own trace, and the turns of one conversation share
a session: Datadog groups them by `gen_ai.conversation.id`, which
`Legion.OpenTelemetry.Adapter.Datadog` sets to `session.id`, Langfuse by
`session.id`, and Braintrust by `metadata.session_id`, which
`Legion.OpenTelemetry.Adapter.Braintrust` sets (see Vendors). This is how the
vendors' own integrations model chats.

For one trace per conversation instead, `conversation_traces: true` puts the
turns under a root span, the shape Braintrust's multi-turn guide builds with
its own SDK:

```
conversation MyApp.ChatAgent          (root, created on the first turn)
├─ invoke_agent MyApp.ChatAgent       turn 1
└─ invoke_agent MyApp.ChatAgent       turn 2
```

Only turns called without a current span join the conversation trace, as
from a LiveView; a turn called inside a request or job span still nests under
that span. The `conversation` span is ended as soon as it is created, because
a trace shows up only once its root span is exported, and OpenTelemetry exports
a span only when it ends. Its duration is therefore zero; each turn carries its
own, and the trace list shows the empty root rather than each turn's input and
output. A resumed agent (`Legion.resume/2`, `Legion.recover/2`) starts a new
conversation trace.

### MCP servers

Each `repl` or `help` call to a `Legion.MCP.Server` is its own trace: a
`tools/call repl` (or `tools/call help`) server span with `mcp.session.id`,
the code as `gen_ai.tool.call.arguments` and the text the host's model got
back as `gen_ai.tool.call.result`, with the agent's `execute_tool sandbox`
span and any sub-agent or `chat` span under it. Every span of the call
carries the MCP session id as `session.id`, so one host session's calls are
one session in Datadog and share `metadata.session_id` in Braintrust. A
failed or rate-limited call is marked `error.type` `tool_error`.

## Metrics

With `metrics: true` (the default) Legion records:

| Metric | Type | Attributes |
|---|---|---|
| `gen_ai.invoke_agent.duration` | histogram, s | agent name, request model, `error.type` |
| `gen_ai.invoke_agent.inference_calls` | histogram | agent name |
| `gen_ai.invoke_agent.tool_calls` | histogram | agent name |
| `gen_ai.execute_tool.duration` | histogram, s | tool name and type, agent name, `error.type` |
| `legion.turn.iterations` | histogram | agent name |
| `legion.eval.errors` | counter | agent name, `legion.error.kind` |
| `legion.llm.retries` | counter | agent name, `legion.retry.reason` |
| `legion.turn.cancellations` | counter | agent name, `legion.cancel.reason` |
| `legion.rate_limit.exceeded` | counter | agent name, `legion.rate_limit.identity` (the identity's field names, not its values) |

The `gen_ai.*` metric names and units follow the GenAI semantic conventions,
which are still in Development status, so they may change with them.

ReqLLM's `gen_ai.client.operation.duration` and `gen_ai.client.token.usage`
go through the same adapter. Erlang's OpenTelemetry metrics API is still
experimental and ships separately, so metrics need
`{:opentelemetry_api_experimental, "~> 0.6"}` and
`{:opentelemetry_experimental, "~> 0.6"}` in the host with a metric exporter
configured; without them Legion records spans only. Braintrust ignores OTLP
metrics; Datadog dashboards can use them.

## Vendors

All of them take the stock OTLP exporter. For Braintrust and Datadog, Legion
builds the exporter from the vendor's settings: point the SDK at
`Legion.OpenTelemetry.Exporter`, name the vendor's adapter in
`config :legion, Legion.OpenTelemetry, adapter: ...`, put its settings under
`config :legion, <adapter>`, and attach. The exporter always sends to the
adapter named in config; an `:adapter` passed to `attach/1` only changes how
spans are shaped. Both need the SDK and exporter from [Setup](#setup),
including its release note.

Set `traces_exporter` next to the vendor config in `config/runtime.exs`,
under the same condition, as below. It can go in `config/config.exs` only if
every environment configures the vendor adapter: without one,
`Legion.OpenTelemetry.Exporter` has nowhere to send spans and logs a warning.

`Legion.OpenTelemetry.attach/1` then uses the vendor's adapter, and raises at
startup if the vendor settings are missing or invalid, the SDK or exporter is
missing, or `traces_exporter` is not `Legion.OpenTelemetry.Exporter`.

The SDK has one trace exporter. If your app already exports traces somewhere
else, send everything to an
[OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) and fan it
out from there, or configure `opentelemetry_exporter` yourself instead. The
standard `OTEL_EXPORTER_OTLP_*` environment variables and
`config :opentelemetry_exporter, otlp_*` settings take precedence over the
endpoint, headers and protocol Legion builds, and `OTEL_TRACES_EXPORTER`
replaces `Legion.OpenTelemetry.Exporter` altogether, so unset them when you
switch.

### Braintrust

```elixir
# config/runtime.exs
if config_env() == :prod do
  config :opentelemetry, traces_exporter: {Legion.OpenTelemetry.Exporter, []}
  config :legion, Legion.OpenTelemetry, adapter: Legion.OpenTelemetry.Adapter.Braintrust

  config :legion, Legion.OpenTelemetry.Adapter.Braintrust,
    api_key: System.fetch_env!("BRAINTRUST_API_KEY"),
    project: "my_app",
    region: :us  # :eu for organizations on the EU data plane
end

# lib/my_app/application.ex
:ok = Legion.OpenTelemetry.attach()
```

`Legion.OpenTelemetry.Adapter.Braintrust` adds `session_id` to every span's
metadata, so a conversation's turns can be
seen together. In the project's Logs, open the row type selector (the
**Traces** dropdown next to the search box), choose **Group by** and pick
`session_id` (type it and choose **Custom** if it is not listed). Each row is
then one conversation; select it and switch to **Thread** to read the whole
session. Online scorers with Group scope on `metadata.session_id` score a
conversation as a whole.

Braintrust parses `gen_ai.input.messages` and `gen_ai.output.messages` only
when each is a single JSON string. ReqLLM records `chat` content as a list of
JSON strings, one per message; Legion joins each list into one JSON array
string before it reaches the adapter, so input and output show up on every
span without extra configuration. With `req_llm: [adapter: ...]` your adapter
gets ReqLLM's lists unchanged.

### Datadog LLM Observability

```elixir
# config/runtime.exs
if config_env() == :prod do
  config :opentelemetry, traces_exporter: {Legion.OpenTelemetry.Exporter, []}
  config :legion, Legion.OpenTelemetry, adapter: Legion.OpenTelemetry.Adapter.Datadog

  config :legion, Legion.OpenTelemetry.Adapter.Datadog,
    api_key: System.fetch_env!("DD_API_KEY"),
    site: "datadoghq.com",  # your Datadog site, e.g. "datadoghq.eu"
    ml_app: "my_app"
end

# lib/my_app/application.ex
:ok = Legion.OpenTelemetry.attach()
```

Spans go straight to Datadog's OTLP intake, with no Datadog Agent in between,
and are listed under the `ml_app`, which Legion sets as the `service.name`
resource attribute (over `OTEL_SERVICE_NAME` or the SDK's own). Datadog shows
each span's input and output from its `gen_ai.*` message attributes and
`legion.*` attributes as tags. Datadog groups sessions by
`gen_ai.conversation.id`, which the adapter sets to `session.id`, so the turns
of a conversation, sub-agents included, are one session and
`conversation_traces` is not needed there. Traces take a few minutes to
appear.

### Others

Langfuse: point the exporter at `/api/public/otel` with Basic auth and pass
`req_llm: [langfuse: true]` for cost and time-to-first-token attributes.

## Custom adapters

Most adapters only need `span_attributes/1`, which rewrites the attributes
every span starts with; `Legion.OpenTelemetry.Adapter.OTel` does the tracing.
This one tags every span with the deployment environment:

```elixir
defmodule MyApp.OTelAdapter do
  @behaviour Legion.OpenTelemetry.Adapter

  @impl true
  def span_attributes(attrs),
    do: Map.put(attrs, :"deployment.environment.name", "production")
end

Legion.OpenTelemetry.attach(adapter: MyApp.OTelAdapter)
```

Attribute keys arrive as atoms, except the ones ReqLLM sets under a string
key. Add `exporter_config/1` to make it a vendor adapter
`Legion.OpenTelemetry.Exporter` can send to, as
`Legion.OpenTelemetry.Adapter.Datadog` does.

An adapter that implements `start_span/3` is its own tracer and implements
the rest of the tracer callbacks, which mirror `ReqLLM.OpenTelemetry.Adapter`,
so one module can implement both. `config` is then the keyword given to
`attach/1` plus `:span_kind`: `:client` for `chat` spans, `:internal` for
Legion's own. Only span handles that are OpenTelemetry span contexts become
the current span, so a tracer that returns something else still sees every
span, but nothing nests under Legion's spans.

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

With `req_llm: false` Legion still emits its own spans, still tags requests
with the conversation id, and your `chat` spans still nest under
`invoke_agent`.
