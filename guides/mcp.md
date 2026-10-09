# Serving an agent over MCP

`Legion.MCP.Server` exposes one of your agents as an
[MCP](https://modelcontextprotocol.io) server. The harness's model writes
Lua, your app runs it in the agent's sandbox against your tools, and the
result goes back to the harness. The agent never calls an LLM itself, so it
needs no API key.

## 1. Install

The server is built on [anubis_mcp](https://hexdocs.pm/anubis_mcp), an
optional dependency of Legion: without it in your deps, `Legion.MCP.Server`
does not exist. Add it next to Legion:

```elixir
# mix.exs
{:legion, "~> 0.6"},
{:anubis_mcp, "~> 2.0"}
```

Serving over HTTP through `Legion.MCP.Plug` also needs `:plug`, which every
Phoenix app already has. If Legion was compiled before you added
`:anubis_mcp`, recompile it with `mix deps.compile legion --force`.

## 2. Write the agent

Any agent on the Lua sandbox, the default, can be served, including one you
already chat with. If it lists `Legion.Tools.AgentTool` or
`Legion.Tools.HumanTool`, those are left out over MCP. This agent serves a
shop's catalogue: `CatalogTool` wraps your product search, and `CatalogAgent`
answers questions with it.

```elixir
defmodule MyApp.Tools.CatalogTool do
  @moduledoc "Searches the product catalogue by free text."
  use Legion.Tool

  @doc "Products matching the query, with name, price and stock"
  def search(query), do: MyApp.Catalog.search(query)
end

defmodule MyApp.CatalogAgent do
  @moduledoc """
  Answers questions about the shop's catalogue: products, prices and stock.
  """
  use Legion.Agent

  def tools, do: [MyApp.Tools.CatalogTool]
end
```

On connect, the server sends the harness a short introduction: the agent's
`@moduledoc` plus the first sentence of each tool's `@moduledoc`. The model
reads a tool in full only when it is about to use it, so keep the agent's
doc short and let each tool's first sentence say what the tool is for.

## 3. Create the server

```elixir
# lib/my_app/mcp.ex
defmodule MyApp.MCP do
  use Legion.MCP.Server, agent: MyApp.CatalogAgent, name: "my_app", version: "1.0.0"
end
```

The harness gets two tools: `help` returns a tool's source and docs, and
`repl` runs code in the agent's sandbox and returns the result.

## 4. Serve it

In a Phoenix app, start the server after `Legion` and forward a path to
`Legion.MCP.Plug`:

```elixir
# lib/my_app/application.ex
children = [
  Legion,
  {MyApp.MCP, transport: {:streamable_http, start: true}},
  MyAppWeb.Endpoint
]

# lib/my_app_web/router.ex
scope "/mcp" do
  forward "/", Legion.MCP.Plug, server: MyApp.MCP
end
```

Outside Phoenix, a `Plug.Router` takes
`forward "/mcp", to: Legion.MCP.Plug, init_opts: [server: MyApp.MCP]`.

`start: true` starts the server even when Phoenix isn't serving, as in
`mix test`. Leave the scope without a pipeline: `plug :accepts, ["json"]`
would reject the event stream that harnesses open.

## 5. Connect and try it

Run `mix phx.server` and add `http://localhost:4000/mcp` to your harness's
MCP settings as an HTTP server. Ask it which green hoodies are in stock. Its
model calls `help` with `CatalogTool` to learn what `search` returns, then
sends code like this to `repl`:

```lua
local hoodies = CatalogTool.search("hoodie")
local green = {}
for _, product in ipairs(hoodies) do
  if string.find(string.lower(product.name), "green") and product.stock > 0 then
    table.insert(green, product.name)
  end
end
return green
```

`repl` returns the matching names, such as `["Green Hoodie"]`, and the model
answers you. Globals set by the code persist across `repl` calls.

On the first request the server also logs a warning: anyone who can reach
the endpoint can run code in your sandbox. Signing users in closes that.
Web pages are kept out already: `Legion.MCP.Plug` refuses a browser
request from any origin but `localhost`, so a site you have open cannot
reach your local server. Hosts that send no `Origin`, as CLI and desktop
ones do, are served; list a web client's origin in `allowed_origins:`.

## Next steps

- **Sign-in** - pass `authorization:` to `use Legion.MCP.Server` and mount
  `Anubis.Server.Transport.WellKnown` at the site root
  ([Anubis's sign-in guide](https://hexdocs.pm/anubis_mcp/authorization.html)).
  `session/1` then gives each user
  [their own agent and vault](https://hexdocs.pm/legion/Legion.MCP.Server.html#module-sessions-are-agents).
  Keep it one agent per user: whoever reaches an agent shares its history
  and variables.
- **Rate limits** - return `rate_limit:` rules from `session/1`. Every `repl`
  call counts towards `:max_evals`, which the limiter reads from the store,
  so it needs a `Legion.Store.Postgres` store too; `help` is free.
  [`Legion.RateLimiter`](https://hexdocs.pm/legion/Legion.RateLimiter.html)
  covers setting up the limiter.
- **Custom MCP tools** - add them with `component` in the server module
  ([Anubis's server guide](https://hexdocs.pm/anubis_mcp/building-a-server.html)).
  They bypass the agent, so they get no rate limiting, saved history or
  vault. Use a `Legion.Tool` when you need those.
- **Other options** - request timeouts, trimming the introduction, telemetry
  and the stdio transport are covered in the
  [`Legion.MCP.Server` docs](https://hexdocs.pm/legion/Legion.MCP.Server.html).
