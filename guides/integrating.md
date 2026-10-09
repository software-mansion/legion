# Adding Legion to an existing app

This guide adds Legion to a Phoenix app that already has contexts, schemas
and authentication. The running example is a shop with `MyShop.Orders` and
`MyShop.Catalog`. Your existing code stays as it is: you add a dependency, a
supervisor child and a few tool modules.

## 1. Install

The [Installation](installation.md) guide has the details. The short
version:

```elixir
# mix.exs
{:legion, "~> 0.6"}

# lib/my_shop/application.ex
children = [MyShop.Repo, Legion, MyShopWeb.Endpoint]

# config/runtime.exs
config :req_llm, openai_api_key: System.get_env("OPENAI_API_KEY")
```

## 2. Wrap your code as tools

Add `use Legion.Tool` to a module and the model can read its source and call
its public functions. Decide two things for each tool:

- **What to expose.** The agent can call every public function, so give it a
  small facade over your context rather than the context itself.
- **Who is asking.** Keep the shopper's identity in
  [Vault](https://github.com/dimamik/vault) and read it inside the tool.
  Generated code can't read Vault, so it can't ask for another shopper's
  orders.

```elixir
defmodule MyShop.Tools.OrdersTool do
  use Legion.Tool

  @doc "Orders of the signed-in shopper, newest first"
  def my_orders do
    %{id: shopper_id} = Vault.get(:current_user)

    for order <- MyShop.Orders.list_orders(shopper_id: shopper_id) do
      %{
        id: order.id,
        placed_at: order.placed_at,
        status: order.status,
        items: Enum.map(order.items, & &1.name)
      }
    end
  end

  @doc "Carrier tracking status for one of the shopper's orders"
  def track(order_id) do
    %{id: shopper_id} = Vault.get(:current_user)
    MyShop.Orders.tracking(shopper_id, order_id)
  end
end

defmodule MyShop.Tools.CatalogTool do
  use Legion.Tool

  @doc "Searches products by free text; returns name, price and stock"
  def search(query), do: MyShop.Catalog.search(query)
end
```

Return plain maps with the fields the agent needs, not whole schemas. Tool
results go into the conversation, so trimming them saves tokens and keeps
private fields away from the model. A whole `%User{}` would bring its hashed
password along.

Put the shopper in Vault once, in your router. For plain HTTP requests, add
a plug to the pipeline:

```elixir
# router.ex
pipeline :shopper do
  plug :require_authenticated_user
  plug :put_shopper_in_vault
end

def put_shopper_in_vault(conn, _opts) do
  Vault.init(current_user: %{id: conn.assigns.current_user.id})
  conn
end
```

A LiveView runs in its own process and doesn't see what the plug set, so
give LiveViews an `on_mount` hook:

```elixir
# router.ex
live_session :shop,
  on_mount: [{MyShopWeb.UserAuth, :ensure_authenticated}, MyShopWeb.VaultShopper] do
  live "/support", SupportLive
end

defmodule MyShopWeb.VaultShopper do
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Vault.init(current_user: %{id: socket.assigns.current_user.id})
    end

    {:cont, socket}
  end
end
```

List it after the auth hook so `current_user` is already assigned.

## 3. Describe the agent

```elixir
defmodule MyShop.SupportAgent do
  @moduledoc """
  Helps a signed-in shopper with orders, tracking and product questions.
  Never invent order data. If a tool returns nothing, say so.
  """
  use Legion.Agent

  def tools, do: [MyShop.Tools.OrdersTool, MyShop.Tools.CatalogTool]
end
```

The moduledoc is the agent's job description. Legion builds the system
prompt around it, adding your tools' source and the sandbox rules. To
override global settings for one agent, such as a cheaper model or a lower
iteration limit, define `config/0`. The keys are listed under
[`Legion.Agent` callbacks](https://hexdocs.pm/legion/Legion.Agent.html#module-callbacks).

## 4. Call the agent from a LiveView or controller

Start the agent once the socket is connected, then send it each message:

```elixir
# mount/3, after the hook from step 2 has set the shopper
{:ok, agent} = Legion.start_link(MyShop.SupportAgent)

# handle_event/3
{:ok, reply} = Legion.call(agent, "Where is the hoodie I ordered last week?")
{:ok, reply} = Legion.call(agent, "Do you still have it in green?")
```

For the first question the model writes one snippet and runs it in the
sandbox:

```lua
local orders = OrdersTool.my_orders()
for _, order in ipairs(orders) do
  for _, item in ipairs(order.items) do
    if string.find(string.lower(item), "hoodie") then
      return OrdersTool.track(order.id)
    end
  end
end
return "no hoodie among the recent orders"
```

The lookup, the filtering and the tracking call happen in one snippet, so
the answer takes one or two model calls where an agent calling one tool per
turn needs three. The second question continues the same conversation, so
the model knows what "it" refers to.

`Legion.start_link/2` links the agent to the LiveView, so it stops when the
socket closes, which suits a chat panel. To keep it running longer, start
it under a `DynamicSupervisor` in your tree. A supervised agent can't see
the LiveView's Vault, so pass the shopper in:

```elixir
DynamicSupervisor.start_child(
  MyShop.AgentSupervisor,
  {MyShop.SupportAgent, vault: [current_user: %{id: user.id}]}
)
```

A controller behind the `:shopper` pipeline can run one message with
`Legion.execute/3`, which starts an agent, waits for the reply and stops it:

```elixir
def create(conn, %{"message" => message}) do
  {:ok, reply} = Legion.execute(MyShop.SupportAgent, message)
  json(conn, %{reply: reply})
end
```

Each request starts a fresh conversation. To continue one across requests,
pass `store:` and `agent_id:` (see `Legion.Store`).

## 5. Next steps

- **Persistence** - add a store with `use Legion.Store.Postgres` and its
  migration, and start each conversation with an `agent_id`.
  `Legion.resume/2` brings it back after a restart; pass `vault:` again,
  since Vault isn't saved. See `Legion.Store`.
- **Agent ids** - build each id from the shopper, such as
  `"shopper:#{id}:support"`. An agent belongs to one user: whoever reaches
  it shares its history, variables and sub-agents.
- **Rate limits** - `Legion.RateLimiter.Postgres` caps running agents,
  evals and tokens per shopper or per IP. It reads usage from the Postgres
  store. See `Legion.RateLimiter`.
- **Writes** - a write is one more tool function, such as `CartTool.add/2`,
  that reads the shopper from Vault like the others.
- **Irreversible actions** - keep things like charging a card or cancelling
  an order out of the agent's reach, or behind a confirmation step in your UI.
- **Observability** - `Legion.Telemetry.attach_default_logger/0` logs agent
  events, and [legion_web](https://github.com/software-mansion/legion_web)
  adds a live dashboard of conversations and generated snippets.
- **Sandboxes** - Lua is the default because generated code can only reach
  your tools. [Sandboxes](sandboxes.md) explains when the Elixir sandbox is
  the better fit.
