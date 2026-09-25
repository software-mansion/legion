[![](https://swm-delivery.com/www/images/zone-gh-legion-1?n=1)](https://swm-delivery.com/www/delivery/ck-slug.php?zoneid=zone-gh-legion-1&n=1)
[![](https://swm-delivery.com/www/images/zone-gh-legion-2?n=1)](https://swm-delivery.com/www/delivery/ck-slug.php?zoneid=zone-gh-legion-2&n=1)
[![](https://swm-delivery.com/www/images/zone-gh-legion-3?n=1)](https://swm-delivery.com/www/delivery/ck-slug.php?zoneid=zone-gh-legion-3&n=1)

# Legion

[![CI](https://github.com/software-mansion/legion/actions/workflows/ci.yml/badge.svg)](https://github.com/software-mansion/legion/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/legion.svg)](https://github.com/software-mansion/legion/blob/main/LICENSE)
[![Version](https://img.shields.io/hexpm/v/legion.svg)](https://hex.pm/packages/legion)
[![Hex Docs](https://img.shields.io/badge/documentation-gray.svg)](https://hexdocs.pm/legion)

<!-- MDOC -->

Legion is an Elixir runtime for AI agents that live inside your application and get things done by writing code.

Define an agent's responsibilities, give it tools to interact with your app safely, and hand it a task from one of your users. It will read the source of the modules you expose, write a Lua (or Elixir) snippet, run it in a sandbox, look at the result, and write the next one - until the task is done.

One evaluation can filter, branch, and loop - work that would cost a tool-calling agent an LLM round trip per step. [Anthropic on why code execution beats tool calling](https://www.anthropic.com/engineering/code-execution-with-mcp).

## Usage

1. Expose existing or new modules as tools and hand them to an agent:

```elixir
defmodule MyApp.Tools.ScraperTool do
  use Legion.Tool

  @doc "Fetches recent posts from HackerNews"
  def fetch_posts do
    Req.get!("https://hn.algolia.com/api/v1/search_by_date").body["hits"]
  end
end

defmodule MyApp.Tools.DatabaseTool do
  use Legion.Tool

  @doc "Saves a post title to the database"
  def insert_post(title), do: Repo.insert!(%Post{title: title})
end

defmodule MyApp.ResearchAgent do
  @moduledoc "Fetch posts, evaluate their relevance and quality, and save the good ones."
  use Legion.Agent

  def tools, do: [MyApp.Tools.ScraperTool, MyApp.Tools.DatabaseTool]
end
```

2. Run it!

```elixir
Legion.execute(MyApp.ResearchAgent, "Find cool Elixir posts about Advent of Code and save them")
#=> {:ok, "Found 3 relevant posts and saved 2 that met quality criteria."}
```

To solve this task, the agent wrote and ran:

```lua
local posts = ScraperTool.fetch_posts()
local relevant = {}
for _, post in ipairs(posts) do
  local title = string.lower(post.title or "")
  if title:find("elixir") and (title:find("advent") or title:find("aoc")) then
    table.insert(relevant, post)
  end
end
return relevant
```

...looked at the output, judged which posts were worth keeping, and followed up with:

```lua
local titles = {"Elixir Advent of Code 2024 - Day 5 walkthrough", "My first AoC in Elixir!"}
for _, title in ipairs(titles) do
  DatabaseTool.insert_post(title)
end
```

Two evaluations, with variables, loops, and conditionals available at every step.

Agents write Lua by default, since it's much easier to sandbox securely. Prefer Elixir? Switch to `Legion.Sandbox.Elixir` - see [Generated code runs in a sandbox](#3-generated-code-runs-in-a-sandbox).

See the [Installation guide](https://hexdocs.pm/legion/installation.html) for more details.

## Features

### **1. Tools are plain Elixir modules**

`use Legion.Tool` on any module and the LLM reads its source and calls its public functions:

```elixir
defmodule MyApp.Tools.WeatherTool do
  use Legion.Tool

  @doc "Returns the current temperature in Celsius for a city"
  def temperature(city) do
    Req.get!("https://wttr.in/#{city}?format=j1").body["current_condition"]
    |> hd()
    |> Map.fetch!("temp_C")
    |> String.to_integer()
  end
end

defmodule MyApp.WeatherAgent do
  @moduledoc "Answers questions about the current weather."
  use Legion.Agent

  def tools, do: [MyApp.Tools.WeatherTool]
end
```

Use it to hand agents your existing app logic directly. With great power comes great responsibility (and authorization): the agent can call any public function of a tool, so scope tools to what it should touch and gate the sensitive parts with [Vault](https://github.com/dimamik/vault) (see [Credentials never reach the LLM](#6-credentials-never-reach-the-llm)). For large modules you could write a thin facade with `defdelegate` and a `description/0` instead of exposing the full source. If for any reason the source isn't what the LLM should see, define `description/0` on the tool and it is sent verbatim instead.

See [`Legion.Tool`](https://hexdocs.pm/legion/Legion.Tool.html) for more details.

### **2. Agents are BEAM processes**

Start one, keep it around, and message it like a GenServer.

```elixir
{:ok, pid} = Legion.start_link(MyApp.AssistantAgent)

{:ok, response} = Legion.call(pid, "Find laptops under $2000")
{:ok, response} = Legion.call(pid, "Now filter for 16GB of RAM")
Legion.cast(pid, "Also check the reviews")
```

Use it when a conversation spans multiple messages - variables can persist between turns with `binding_scope: :conversation`. And since agents are just processes, supervision trees and `:pg`-based pools work out of the box.

See [`start_link/2`](https://hexdocs.pm/legion/Legion.html#start_link/2), [`call/3`](https://hexdocs.pm/legion/Legion.html#call/3), and [`cast/2`](https://hexdocs.pm/legion/Legion.html#cast/2) for more details.

<a id="3-generated-code-runs-in-a-sandbox"></a>

### **3. Generated code runs in a sandbox**

Every evaluation runs in a monitored process with timeout, memory, and CPU budgets. Two sandboxes ship with Legion today, differing in language and trust model, with a third on the way:

- [`Legion.Sandbox.Lua`](https://hexdocs.pm/legion/Legion.Sandbox.Lua.html) (default) - agents write Lua, evaluated by [lua](https://hexdocs.pm/lua), a Lua 5.3 VM in pure Elixir. Lua code cannot reach the host BEAM at all - the only bridges out are the tool functions Legion registers - making it the safer choice for less trusted generation. Tool arguments and results are converted at the boundary (Lua tables to maps/lists and back; Elixir tuples become arrays, atoms become strings).
- [`Legion.Sandbox.Elixir`](https://hexdocs.pm/legion/Legion.Sandbox.Elixir.html) - agents write Elixir. Dangerous constructs (`defmodule`, `import`, `spawn`, `send`, `apply`, ...) are blocked at the AST level and module access is allowlisted (stdlib + your tools). Powerful, but the allowlist guards an enormous language surface - use it for your own LLM-backed agents with controlled tool access, not arbitrary code from unknown sources.
- **Popcorn (coming soon)** - agents write Elixir that runs in the user's browser on [popcorn](https://github.com/software-mansion/popcorn/), an AtomVM-based BEAM in WebAssembly, so generated code never touches your server at all.

You could add a custom sandbox by implementing the [`Legion.Sandbox`](https://hexdocs.pm/legion/Legion.Sandbox.html) behaviour.

### **4. Agents orchestrate agents**

Give an agent the built-in `AgentTool` and its generated code can delegate.

```elixir
defmodule MyApp.OrchestratorAgent do
  @moduledoc "Coordinates research and writing sub-agents to produce finished content."
  use Legion.Agent

  def tools, do: [Legion.Tools.AgentTool]
  def tool_config(Legion.Tools.AgentTool), do: [agents: [MyApp.ResearchAgent, MyApp.WriterAgent]]
end
```

The orchestrator writes code like:

```lua
local _, research = table.unpack(AgentTool.call(ResearchAgent, "Find info about Elixir 1.18"))
local _, draft = table.unpack(AgentTool.call(WriterAgent, "Write a blog post using: " .. research))
```

Listed sub-agents are auto-aliased to their short names, and the `{:ok, result}` tuples tools return arrive in Lua as arrays.

Sub-agents are linked processes - when a parent dies, its children stop too. From the outside, fan out with [`parallel/2`](https://hexdocs.pm/legion/Legion.html#parallel/2) or chain with [`pipeline/1`](https://hexdocs.pm/legion/Legion.html#pipeline/1):

```elixir
{:ok, [posts, trends]} = Legion.parallel([
  {MyApp.ResearchAgent, "Find recent Elixir posts"},
  {MyApp.AnalysisAgent, "Summarize Elixir trends"}
])

{:ok, result} = Legion.pipeline([
  {MyApp.ResearchAgent, "Find Elixir blog posts from this week"},
  {MyApp.WriterAgent, &"Summarize these posts: #{&1}"}
])
```

See [`Legion.Tools.AgentTool`](https://hexdocs.pm/legion/Legion.Tools.AgentTool.html) for more details.

<a id="5-conversations-survive-restarts"></a>

### **5. Conversations survive restarts**

Plug in the Postgres store (it can reuse your Ecto repo) and resume any conversation by id, even after a deploy.

```elixir
defmodule MyApp.AgentStore do
  use Legion.Store.Postgres, repo: MyApp.Repo
end

# config/config.exs
config :legion, :store, MyApp.AgentStore

{:ok, pid} = Legion.start_link(MyApp.AssistantAgent, agent_id: "user_42:chat_7")

{:ok, response} = Legion.call(pid, "Remember that my budget is $100")

GenServer.stop(pid)

# Later, in another process - or after a deploy
{:ok, pid} = Legion.resume("user_42:chat_7")
{:ok, response} = Legion.call(pid, "What was my budget again?")
```

```elixir
# `start_link/2` links to the caller - supervise it yourself to outlive a request
DynamicSupervisor.start_child(MyApp.AgentSupervisor, {MyApp.AssistantAgent, agent_id: "user_42:chat_7"})
```

See [`Legion.Store`](https://hexdocs.pm/legion/Legion.Store.html), [`Legion.resume/2`](https://hexdocs.pm/legion/Legion.html#resume/2), and [`Legion.lookup/1`](https://hexdocs.pm/legion/Legion.html#lookup/1) for more details.

<a id="6-credentials-never-reach-the-llm"></a>

### **6. Credentials never reach the LLM**

Set auth context before the agent starts, read it inside tools at runtime via [Vault](https://github.com/dimamik/vault). Generated code has no access to it.

```elixir
Vault.init(current_user: %{id: user.id})
{:ok, result} = Legion.execute(MyApp.PostsAgent, "Find my posts from today and summarize them")
```

```elixir
defmodule MyApp.Tools.PostsTool do
  use Legion.Tool

  def get_my_posts do
    %{id: user_id} = Vault.get(:current_user)
    Repo.all(from p in Post, where: p.user_id == ^user_id)
  end
end
```

See [Vault](https://github.com/dimamik/vault) for more details.

### **7. Rate limiting baked in**

Configure a limiter and a default policy:

```elixir
defmodule MyApp.RateLimiter do
  use Legion.RateLimiter.Postgres, repo: MyApp.Repo
end

# config/config.exs
config :legion, :rate_limit,
  limiter: MyApp.RateLimiter,
  default_policy: %Legion.RateLimiter.Policy{
    window_ms: :timer.minutes(1),
    max_agents: 10,
    max_tokens: 100_000
  }
```

Then name the groups an agent belongs to when it starts - a turn runs only if every rule allows it.

```elixir
Legion.start_link(ChatAgent,
  rate_limit: [
    rules: [
      # This rule uses the default policy from `config.exs`
      %Legion.RateLimiter.Rule{identity: %{"ip" => "203.0.113.42"}},
      # This rule uses a custom policy
      %Legion.RateLimiter.Rule{
        identity: %{"email" => "someone@example.com", "tenant" => "acme"},
        policy: %Legion.RateLimiter.Policy{window_ms: :timer.hours(24), max_agents: 5}
      }
    ]
  ]
)
```

A rule without a policy takes the default one - give it a policy, or pass a limiter, to override the config for that agent. Sub-agents inherit their parent's settings. `Legion.RateLimiter.Postgres` comes with Legion and extends the Postgres store from [Conversations survive restarts](#5-conversations-survive-restarts). Implement the `Legion.RateLimiter` behaviour to keep limit state anywhere else.

See [`Legion.RateLimiter`](https://hexdocs.pm/legion/Legion.RateLimiter.html) for more details.

### **8. Structured output when you need it**

Define `output_schema/0` on the agent to get typed, validated responses.

See [`Legion.Agent`](https://hexdocs.pm/legion/Legion.Agent.html) for this and the other agent callbacks (`system_prompt/0`, `config/0`, `action_types/0`) - all optional with sensible defaults.

## Configuration

```elixir
config :legion, :store, MyApp.AgentStore
config :legion, :config, %{model: "openai:gpt-5.4", max_iterations: 10}
```

| Option                   | Default              | Description                                                                                                                                             |
| ------------------------ | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `model`                  | `"openai:gpt-5.4"`   | `provider:model` string passed to [ReqLLM](https://hexdocs.pm/req_llm) - any provider it supports works here, hosted or local.                          |
| `sandbox`                | `Legion.Sandbox.Lua` | Module validating and evaluating generated code. See [Generated code runs in a sandbox](#3-generated-code-runs-in-a-sandbox).                           |
| `max_iterations`         | `10`                 | Successful execution steps before the turn is stopped.                                                                                                  |
| `max_retries`            | `3`                  | Consecutive failures (bad code, tool errors) before giving up. Resets after each success.                                                               |
| `binding_scope`          | `:turn`              | How long variables live: `:iteration`, `:turn`, or `:conversation`.                                                                                     |
| `max_message_length`     | `20_000`             | Byte limit for a single message; longer content is truncated. `:infinity` disables it.                                                                  |
| `sandbox_timeout`        | `60_000`             | Milliseconds one evaluation may run before it is killed. `:infinity` disables it, leaving `sandbox_max_reductions` as the only stop for a runaway eval. |
| `sandbox_max_heap`       | `256_000_000`        | Memory budget in bytes for the eval process. `:infinity` disables it.                                                                                   |
| `sandbox_max_reductions` | `:infinity`          | CPU budget in reductions, polled every ~50ms, so a hot loop dies before the clock runs out.                                                             |
| `sandbox_priority`       | `:low`               | Scheduler priority of the eval process. Raise to `:normal` if evals hit `sandbox_timeout` under load.                                                   |
| `eval_guard`             | `nil`                | `Legion.EvalGuard` module vetting generated code before it runs, for policy the sandbox cannot express.                                                 |

Agents override global config by defining `config/0` ([`Legion.Agent`](https://hexdocs.pm/legion/Legion.Agent.html) documents each key in full):

```elixir
defmodule MyApp.DataAgent do
  @moduledoc "Fetches and processes data from HTTP APIs."
  use Legion.Agent

  def tools, do: [MyApp.HTTPTool]
  def config, do: %{model: "google:gemini-3.5-flash", max_iterations: 5}
end
```

Writing code is the one thing models keep getting better at - update the `model` string and every agent in your app gets smarter, for free. Works with local models too (see the [Local LLMs guide](https://hexdocs.pm/legion/local_llms.html)).

## Telemetry

```elixir
Legion.Telemetry.attach_default_logger()
```

Events emitted at every level:

- `[:legion, :agent, :started | :stopped]` - agent lifecycle
- `[:legion, :agent, :message, :start | :stop | :exception]` - per-message
- `[:legion, :iteration, :start | :stop | :exception]` - each execution step
- `[:legion, :llm, :request, :start | :stop | :exception]` - LLM API calls
- `[:legion, :sandbox, :eval, :start | :stop | :exception]` - code evaluation
- `[:legion, :eval_guard, :denied]` - generated code refused by an eval guard
- `[:legion, :rate_limit, :exceeded]` - turn denied by a rate limiter

## Web Dashboard

[`legion_web`](https://github.com/software-mansion/legion_web) provides a real-time Phoenix LiveView dashboard for monitoring agents, viewing conversation traces, and inspecting generated code.

[![Legion Web Dashboard](https://raw.githubusercontent.com/software-mansion/legion_web/main/img/preview.png)](https://github.com/software-mansion/legion_web)

## What's next

- **[Braintrust](https://www.braintrust.dev) integration** - trace and evaluate agent runs
- **[Datadog](https://www.datadoghq.com) integration** - agent and LLM telemetry in your existing dashboards
- **Popcorn sandbox** - agents write Elixir that runs in the user's browser on [popcorn](https://github.com/software-mansion/popcorn/), an AtomVM-based BEAM in WebAssembly, so generated code never touches your server

<!-- MDOC -->

## Authors

Legion is created by Software Mansion.

Since 2012 [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=legion) is a software agency with experience in building web and mobile apps as well as complex multimedia solutions. We are Core React Native Contributors, Elixir ecosystem experts, and live streaming and broadcasting technologies specialists. We can help you build your next dream product – [Hire us](https://swmansion.com/contact/projects).

Copyright 2026, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=legion)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=legion-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=legion)

## License

MIT License - see [LICENSE](LICENSE) for details.
