# Serving an agent over MCP

AI harnesses - the coding assistants, chat apps and other programs that run a
model for you - can use tools that live outside them through MCP, the Model
Context Protocol. `Legion.MCP.Server` turns one of your agents into such a
tool source, an MCP server. The harness's own model writes the code, your
application runs it in the agent's sandbox against your tools, and the result
goes back to the model. Your agent never calls an LLM itself, so it needs no
API key.

## 1. Install

The MCP server is built on [anubis_mcp](https://hexdocs.pm/anubis_mcp) (Anubis
for short), an optional dependency of Legion, so add it next to Legion:

```elixir
# mix.exs
{:legion, "~> 0.6"},
{:anubis_mcp, "~> 2.0"}
```

## 2. Write the agent

Any agent works, including one you already chat with. This one serves a shop's
catalogue: `CatalogTool` wraps your product search (`MyApp.Catalog` stands for
your own code), and `CatalogAgent` answers questions with it.

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

The two `@moduledoc`s are what the harness's model reads first. When a harness
connects, the server sends it a short introduction made of the agent's
`@moduledoc` and one line per tool, taken from the first sentence of the tool's
`@moduledoc`. The model reads a tool in full only when it is about to use it,
so keep the agent's doc short and let each tool's first sentence say what the
tool is for.

## 3. Create the server

```elixir
# lib/my_app/mcp.ex
defmodule MyApp.MCP do
  use Legion.MCP.Server, agent: MyApp.CatalogAgent, name: "my_app", version: "1.0.0"
end
```

The harness gets two tools: `help`, which returns a tool's full reference (its
source code with the docs), and `repl`, which runs code in the agent's sandbox
with the agent's tools and returns the result.

## 4. Serve it

In a Phoenix app, start the server after `Legion` and forward a path to
`Legion.MCP.Plug` (a `Plug.Router` takes
`forward "/mcp", to: Legion.MCP.Plug, init_opts: [server: MyApp.MCP]`):

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

`start: true` starts the server even when Phoenix isn't serving, as in
`mix test`. Leave the scope without a pipeline: `plug :accepts, ["json"]`
would refuse the event stream harnesses open.

## 5. Connect and try it

Run `mix phx.server` and add `http://localhost:4000/mcp` to your harness's MCP
settings as an HTTP server. Ask it which green hoodies are in stock. Its model
calls `help` with `CatalogTool` to learn what `search` returns, then sends
code like this to `repl`:

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
answers you. Global variables the code sets stay around for the next call.
Meanwhile the server logs a warning that anyone who reaches the endpoint can
run code in your sandbox; signing users in fixes that.

## Next steps

- **Sign users in** - pass `authorization:` to `use Legion.MCP.Server` and
  mount the discovery plug, as in [Anubis's sign-in guide](https://hexdocs.pm/anubis_mcp/authorization.html);
  `session/1` then gives each user [their own agent and vault](https://hexdocs.pm/legion/Legion.MCP.Server.html#module-sessions-are-agents).
- **Rate limits** - return `rate_limit:` rules from `session/1`; every `repl`
  call counts towards `:max_evals`, `help` is free
  ([set up a limiter and rules](https://hexdocs.pm/legion/Legion.html#module-7-rate-limiting-baked-in)).
- **Your own MCP tools** - `component` in the server module adds them
  ([writing one](https://hexdocs.pm/anubis_mcp/building-a-server.html)). They
  skip the agent: no rate limit, saving or vault, so use a `Legion.Tool` when
  those matter.
- **The rest** - request timeouts, trimming the introduction, telemetry and the
  `transport: :stdio` option: [the `Legion.MCP.Server` docs](https://hexdocs.pm/legion/Legion.MCP.Server.html).
