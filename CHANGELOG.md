# Changelog

## v0.6.0 - 2026-10-09

### Breaking

- Default model bumped to `openai:gpt-5.6-luna`
- [`Legion.Tools.AgentTool`](https://hexdocs.pm/legion/Legion.Tools.AgentTool.html) - `start_link/1,2` return the sub-agent's id instead of a pid, and `call/2`, `cast/2` and the new `stop/1` take that id; only the agent that started a sub-agent reaches it, and the sub-agent stops when that agent stops, when the turn that started it ends unless `:binding_scope` is `:conversation`, or after `:sub_agent_idle_timeout` without a message (default thirty minutes). An agent runs at most `:max_sub_agents` at once (default 10), and a start is checked against the rate limit, returning `{:cancel, {:rate_limited, violations}}` when denied
- [`Legion.Tools.Help`](https://hexdocs.pm/legion/Legion.Tools.Help.html) is in every agent's sandbox, so a tool of your own with the short name `Help` is no longer reachable; `use Legion.Agent` warns about it
- `:max_bindings_bytes` (default `10_000_000`) fails an execution that would leave larger variables behind; set it to `:infinity` for the old behaviour
- [`Legion.RateLimiter.Postgres`](https://hexdocs.pm/legion/Legion.RateLimiter.Postgres.html) - an agent whose rules set `:max_tokens`, `:max_evals` or `:max_running_agents` raises at start unless its store is a `Legion.Store.Postgres` on the limiter's repo and table, since those limits count what that store writes
- [`Legion.Sandbox.Lua`](https://hexdocs.pm/legion/Legion.Sandbox.Lua.html) - `check/2` no longer reports syntax errors; parsing moved inside the sandbox process, under its limits, and syntax errors come back from `execute/5`
- Rate limiting - an agent's start is checked against `:max_agents`, so it caps the agents themselves: a denied `Legion.start_link/2` returns `{:error, {:rate_limited, violations}}` with no process started and nothing saved, and `Legion.execute/3` returns `{:cancel, {:rate_limited, violations}}`. Resumed and recovered runs are not checked
- An agent id belongs to one agent module: starting another module under an id whose stored conversation is not its own returns `{:error, {:agent_module_mismatch, stored}}`
- [`Legion.resume/2`](https://hexdocs.pm/legion/Legion.html#resume/2) and [`Legion.recover/2`](https://hexdocs.pm/legion/Legion.html#recover/2) finish only a conversation that stopped mid-turn, behind a checkpoint or on a prompt with nothing after it

### Changes

- MCP server - [`Legion.MCP.Server`](https://hexdocs.pm/legion/Legion.MCP.Server.html) serves a Lua agent to MCP hosts as `repl` and `help` tools over stdio or Streamable HTTP ([`Legion.MCP.Plug`](https://hexdocs.pm/legion/Legion.MCP.Plug.html), which refuses browser requests from origins other than `localhost` unless listed in `:allowed_origins`), with OAuth 2.1 and a `session/1` callback choosing the agent, vault and rate limits per call; `Legion.Tools.AgentTool` and `Legion.Tools.HumanTool` are left out. Needs the optional `{:anubis_mcp, "~> 2.0"}` dependency; see the [MCP guide](https://hexdocs.pm/legion/mcp.html)
- [`Legion.eval/3`](https://hexdocs.pm/legion/Legion.html#eval/3) runs code in a live agent without its model, as one persisted, rate-limited step of the conversation
- Tool discovery - `tool_docs: :on_demand` lists tools in the prompt by a one-line [`summary/0`](https://hexdocs.pm/legion/Legion.Tool.html#c:summary/0), and `Help.help(Name)` returns a tool's full description; the default over MCP
- Rate limiting - `:max_evals` in [`Legion.RateLimiter.Policy`](https://hexdocs.pm/legion/Legion.RateLimiter.Policy.html) caps code evaluations per window
- [`Legion.start_link/2`](https://hexdocs.pm/legion/Legion.html#start_link/2) takes `:vault`, put in the agent process for its tools, and `:idle_timeout`, which stops an agent nobody calls
- `max_message_length` defaults to `40_000` bytes and also bounds code sent with `Legion.eval/3`
- Lua agents hold sub-agent conversations through [`Legion.Tools.AgentTool`](https://hexdocs.pm/legion/Legion.Tools.AgentTool.html), whose ids cross the Lua bridge
- `:step` stores persist usage with every checkpoint instead of only at turn end

## v0.5.1 - 2026-09-25

### Changes

- Rate limiting - [`Legion.RateLimiter.resolve!/1`](https://hexdocs.pm/legion/Legion.RateLimiter.html#resolve!/1) raises or warns on invalid or incomplete configuration; `rules:` no longer read from `config :legion, :rate_limit`
- Rate limiting - `:max_running_agents` in [`Legion.RateLimiter.Policy`](https://hexdocs.pm/legion/Legion.RateLimiter.Policy.html) caps how many matching agents run a turn at once
- Recovery - recovered runs skip rate limiting; rules are not persisted, so [`Legion.resume/2`](https://hexdocs.pm/legion/Legion.html#resume/2) takes `:rate_limit` again
- Usage tracking - `"message_index"` links usage to its assistant message, see [`Legion.Store`](https://hexdocs.pm/legion/Legion.Store.html#module-usage-tracking)
- Persistence - [`Legion.Store.Payload`](https://hexdocs.pm/legion/Legion.Store.Payload.html) exposes the agent's rate-limit identity as `:ratelimit_metadata`
- [`Legion.Sandbox.Lua`](https://hexdocs.pm/legion/Legion.Sandbox.Lua.html) skips Erlang modules in the tool list instead of crashing
- Guides - [Adding Legion to an existing app](https://hexdocs.pm/legion/integrating.html), [Using Legion with Ash](https://hexdocs.pm/legion/ash.html), [Using local LLMs](https://hexdocs.pm/legion/local_llms.html)

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
