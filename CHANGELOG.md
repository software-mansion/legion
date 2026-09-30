# Changelog

## Unreleased

### Changes

- OpenTelemetry - [`Legion.OpenTelemetry.attach/1`](https://hexdocs.pm/legion/Legion.OpenTelemetry.html#attach/1) emits GenAI semantic-conventions traces: an `invoke_agent` span per turn, an `execute_tool sandbox` span per eval, and ReqLLM's `chat` spans (attached under Legion's handler with content and adapter configured in one place), all tagged with the agent name and `gen_ai.conversation.id` = agent id; retries, eval guard denials and cancellations are span events and statuses, agent and tool metrics go through the adapter, and the caller's OpenTelemetry context is carried through [`Legion.call/3`](https://hexdocs.pm/legion/Legion.html#call/3), [`Legion.cast/2`](https://hexdocs.pm/legion/Legion.html#cast/2), [`Legion.parallel/2`](https://hexdocs.pm/legion/Legion.html#parallel/2) and the sandbox process so sub-agents and tool calls nest under the span that started them; `opentelemetry_api` is an optional dependency, see the [Observability guide](https://hexdocs.pm/legion/observability.html)
- OpenTelemetry - [`Legion.OpenTelemetry.configure/2`](https://hexdocs.pm/legion/Legion.OpenTelemetry.html#configure/2), called from `config/runtime.exs`, writes the OTLP exporter config for a vendor adapter, and `attach/1` takes its defaults from `config :legion, :open_telemetry`; [`Legion.OpenTelemetry.Adapter.Datadog`](https://hexdocs.pm/legion/Legion.OpenTelemetry.Adapter.Datadog.html) configures export to Datadog LLM Observability and [`Legion.OpenTelemetry.Adapter.Braintrust`](https://hexdocs.pm/legion/Legion.OpenTelemetry.Adapter.Braintrust.html) to Braintrust, where it also adds `metadata.session_id` so Braintrust can group a conversation's traces; every span carries `session.id`, shared with the sub-agents a turn calls; `conversation_traces: true` puts an agent's turns in one trace
- Compatibility - [`Legion.call/3`](https://hexdocs.pm/legion/Legion.html#call/3) and [`Legion.cast/2`](https://hexdocs.pm/legion/Legion.html#cast/2) now send the caller's OpenTelemetry context, which agents on nodes running an earlier Legion reject; drain agents or restart the whole cluster when upgrading
- Compatibility - agents now call `ReqLLM.generate_object/4` (the fourth argument passes `telemetry:`), so test stubs of `generate_object/3` no longer intercept them; stub the 4-arity function
- Rate limiting - [`Legion.RateLimiter.resolve!/1`](https://hexdocs.pm/legion/Legion.RateLimiter.html#resolve!/1) raises when rules are given without a limiter, logs a warning when a limiter has no rules unless `rules: []` opts out explicitly, logs and ignores unknown `:rate_limit` keys instead of dropping them silently, and no longer accepts `rules:` in `config :legion, :rate_limit`

## v0.5.0 - 2026-09-01

### Changes

- Pluggable sandboxes - the [`Legion.Sandbox`](https://hexdocs.pm/legion/Legion.Sandbox.html) behaviour, [`Legion.Sandbox.Elixir`](https://hexdocs.pm/legion/Legion.Sandbox.Elixir.html), shared [`Legion.Sandbox.Runner`](https://hexdocs.pm/legion/Legion.Sandbox.Runner.html)
- [`Legion.Sandbox.Lua`](https://hexdocs.pm/legion/Legion.Sandbox.Lua.html), now the default sandbox
- Sandbox resource limits - timeout, memory, and CPU budgets in [`Legion.Sandbox.Runner`](https://hexdocs.pm/legion/Legion.Sandbox.Runner.html)
- Sandbox-specific [`Legion.Tool.description/1`](https://hexdocs.pm/legion/Legion.Tool.html#c:description/1)
- Persistence - [`Legion.Store`](https://hexdocs.pm/legion/Legion.Store.html) saves conversation state (messages, bindings, executor checkpoints), status, and LLM usage across restarts, with a [Postgres adapter](https://hexdocs.pm/legion/Legion.Store.Postgres.html), versioned [migrations](https://hexdocs.pm/legion/Legion.Store.Postgres.Migration.html), and `persistence_frequency/0`
- Agent identity - string agent ids, [`Legion.get_agent_id/1`](https://hexdocs.pm/legion/Legion.html#get_agent_id/1), [`Legion.lookup/1`](https://hexdocs.pm/legion/Legion.html#lookup/1), cluster-wide `:global` registration; `:name` option removed
- Recovery - [`Legion.resume/2`](https://hexdocs.pm/legion/Legion.html#resume/2), [`Legion.recover/2`](https://hexdocs.pm/legion/Legion.html#recover/2), `:recovery` startup config
- Rate limiting - [`Legion.RateLimiter`](https://hexdocs.pm/legion/Legion.RateLimiter.html) with [rules](https://hexdocs.pm/legion/Legion.RateLimiter.Rule.html), [policies](https://hexdocs.pm/legion/Legion.RateLimiter.Policy.html), and a [Postgres adapter](https://hexdocs.pm/legion/Legion.RateLimiter.Postgres.html)
- LLM usage tracking - persisted per request (`:track_usage`), `usage` in `[:legion, :llm, :request, :stop]` [telemetry](https://hexdocs.pm/legion/Legion.Telemetry.html)
- Default model bumped to `openai:gpt-5.4`
- [`Legion.Tools.HumanTool.ask/1`](https://hexdocs.pm/legion/Legion.Tools.HumanTool.html#ask/1) raises under `eval_and_complete`
- Bump [ReqLLM](https://hexdocs.pm/req_llm)

## v0.4.0 - 2026-05-17

### Security

- Harden `Legion.Sandbox.ASTChecker` against a class of RCE paths. After this release, most (if not all) RCE vectors should be closed. Legion is still vulnerable to DoS kinds of attacks, but we assume that having a system prompt instruction to behave well AND improving sandbox should be enough for now.

### Changes

- Broaden the sandbox surface for common LLM idioms: allow `Map.values/1`, `JSON`, `URI`, `:erlang.float_to_binary/2`, additional `String`/`Enum`/`Date`/`DateTime` functions, and the `Access` protocol (`map[:k]`)
- Document the sandbox constraints with concrete idioms in the system prompt
- Fix tool source extraction breaking on heredocs and charlists
- Correct documentation for telemetry events, source registry, and `AgentTool.start_link/2`

## v0.3.0 - 2026-04-21

### Changes

- Replace `share_bindings` boolean with `binding_scope` (`:iteration`, `:turn`, `:conversation`) for fine-grained control over variable lifetime across code executions
- Add `action_types/0` callback to restrict which actions an agent can use (e.g. `~w(return done)` for read-only agents)
- Add `max_message_length` config with truncation support to prevent unbounded message growth
- Add multimedia message support: `{:image, data, media_type}`, `{:image_url, url}`, and `{:multipart, parts}`
- Add `Legion.get_messages/1` to retrieve conversation history from a running agent
- Expand `AgentTool` with `parallel/2`, `pipeline/1`, `then/3`, and `extra_allowed_modules/0` for sub-agent orchestration; sub-agents are auto-aliased in the sandbox
- Generate dynamic `AgentTool.description/0` from sub-agent moduledocs
- Move system prompt resolution to `AgentPrompt`, respecting custom `system_prompt/0` overrides
- Validate config keys at startup with warnings for unknown keys
- Add `@moduledoc` compile-time validation via `__before_compile__`
- Harden sandbox: block `def`/`defp`/`__ENV__`, additional `:erlang` functions (`process_flag`, `list_to_atom`, `system_info`), catch throws and exits, surface compiler diagnostics on errors
- Handle executor exceptions gracefully instead of crashing the agent loop
- Add `Calendar` to sandbox safe-module list
- Emit `:exception` telemetry events for iteration, LLM, and sandbox spans; use `System.convert_time_unit/3` for duration reporting
- Extensive new test coverage for `AgentServer`, `Executor`, `Sandbox`, and `ASTChecker`

## v0.2.1 - 2026-03-24

- Improve source code extraction for tool definitions
- Adjust system prompt to better reflect capabilities


## v0.2.0 - 2026-03-15

### Changes

- Simplified and refactored internals
- Improved documentation and general library intent

---

## v0.1.0 - 2025-12-29

### New 🔥

- Initial release of Legion - an Elixir-native agentic AI framework
- `Legion.AIAgent` behaviour for building AI agents with customizable tools and configurations
- `Legion.Tool` behaviour for defining tools that agents can use
- Integration with `req_llm` for LLM communication
- `Legion.Sandbox` for secure code evaluation using Dune
- `Legion.call/2` and `Legion.cast/2` for synchronous and asynchronous message passing
- `Legion.start_link/2` for spawning long-lived agents
- Telemetry events for monitoring and debugging agent execution
- Support for agent-to-agent communication and delegation
