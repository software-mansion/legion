---
name: install-legion
description: Install Legion or legion_web into an existing Mix or Phoenix app. Use when asked to install, add, set up, wire or integrate Legion, an AI agent, or the Legion dashboard into an app that already exists.
---

# Install Legion into an existing app

Legion is one dependency, one supervisor child, an LLM key and a few plain
modules next to the code the app already has. Nothing gets rewritten. The
install is one reviewable diff: minimal edits, in the order below, nothing
the user did not choose in step 0.

Steps 1, 2, 3, 8 and 9 run on every install. Steps 4 to 7 run only when the
matching answer from step 0 is yes; each names its gate in its heading.

## 0. Look, then ask

Read, editing nothing yet:

- `mix.exs` - is `:legion` already there? `:phoenix`? `:ecto_sql` with
  `:postgrex`? `:ash`? `:igniter`?
- `lib/*/application.ex` - the `children` list, where the Repo sits.
- `config/runtime.exs` - an existing `config :req_llm, <provider>_api_key`
  line. Config files only; `.env`, `.envrc` and other secret files stay
  unread.
- `lib/*_web/router.ex` - the auth pipelines and `live_session`s, and
  whether any of them admits admins only (`phx.gen.auth` gives
  `:require_authenticated_user`, which admits every signed-in user).
- `lib/<app>/` - the contexts (orders, tickets, catalog) a tool could wrap.
- `git status` - start from a clean tree so the install is one reviewable
  diff.

Then interview the user: one question at a time, recommendation first, in
this order. Offer a question only when its condition holds; otherwise say in
one line why it is not offered.

- **Provider and model.** Recommend the provider already configured, else
  OpenAI (default model `openai:gpt-5.4`, no model line needed). Any other
  provider needs a model in ReqLLM's `provider:model` form.
- **Store** - Postgres Ecto repo present. Conversations survive deploys and
  resume by id; costs one migration.
- **Rate limiter** - store = yes. Caps agents and tokens per user or IP on
  the same table; meant for agents driven by untrusted users.
- **Dashboard** - `:phoenix` present. `legion_web` shows every user's
  prompts, generated snippets and results, so only admins may reach it - a
  plain signed-in check lets any customer read everyone's conversations.
  Choices: admin-only scope (needs a pipeline that admits admins only),
  `dev`-only block, skip. Recommend the `dev`-only block when the router has
  no admin pipeline.
- **Tool context.** List the contexts found, recommend the one the user's
  request points at.
- **Identity** - asked after the tool context. Does the tool answer on
  behalf of a signed-in user (their orders, their tickets)? Yes means the
  user's identity travels in Vault. No means a public tool, such as catalog
  search, and no Vault at all.

Done when: the plan (provider, model, each yes/no, context) is recapped and
the user has confirmed it.

## 1. Dependency

Pin to the current release:

```bash
mix hex.info legion
```

```elixir
# mix.exs - "~> major.minor" taken from the hex.info output
{:legion, "~> X.Y"}
```

```bash
mix deps.get
```

The sandbox stays on its default, Lua, which cannot reach the host BEAM.

Done when: `mix deps.get` succeeds with `:legion` as the only new entry in
`deps`.

## 2. Supervisor child

`Legion` is a supervisor. Put it after the Repo (the store and the rate
limiter query it, and `Legion.Recovery`, when configured, reads the store on
boot); its position relative to the Endpoint does not matter.

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  MyAppWeb.Endpoint,
  Legion
]
```

Done when: `Legion` sits in `children` after the Repo.

## 3. LLM provider key

Runtime config only, never `config.exs`, never a literal key. The key name is
`<provider>_api_key`. With OpenAI nothing else is needed:

```elixir
# config/runtime.exs
config :req_llm, openai_api_key: System.get_env("OPENAI_API_KEY")
```

Another provider needs its key and the chosen model:

```elixir
config :req_llm, anthropic_api_key: System.get_env("ANTHROPIC_API_KEY")
config :legion, :config, %{model: "anthropic:<model>"}
```

If the app already loads `.env` through `dotenvy` or similar, follow that
pattern instead of a bare `System.get_env/1`.

Done when: the chosen provider's key line is in `runtime.exs` and the user
knows which environment variable to set.

## 4. Postgres store (store = yes)

Skip unless store = yes.

```elixir
# lib/my_app/agent_store.ex
defmodule MyApp.AgentStore do
  use Legion.Store.Postgres, repo: MyApp.Repo
end

# config/config.exs
config :legion, :store, MyApp.AgentStore
```

```bash
mix ecto.gen.migration add_legion_agents
```

```elixir
def up, do: Legion.Store.Postgres.Migration.up()
def down, do: Legion.Store.Postgres.Migration.down()
```

```bash
mix ecto.migrate
```

Done when: the migration ran and `:store` is configured.

## 5. Rate limiter (rate limiter = yes)

Skip unless rate limiter = yes. The store's table backs it, no extra
migration.

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

The config holds the limiter and policy only. Rules naming the group go on
every `Legion.start_link/2` call (step 8); without them Legion logs a
warning and runs unlimited. Identity keys are strings:

```elixir
# per user when identity = yes, else per IP
rate_limit: [rules: [%Legion.RateLimiter.Rule{identity: %{"user_id" => to_string(user.id)}}]]
```

A denied turn returns `{:cancel, {:rate_limited, violations}}`.

Done when: the limiter module and `:rate_limit` config exist and the
`start_link/2` call in step 8 names its group.

## 6. Dashboard (dashboard = yes)

Skip unless dashboard = yes. Add the package the same way as step 1:

```bash
mix hex.info legion_web
```

```elixir
{:legion_web, "~> X.Y"}
```

```bash
mix deps.get
```

The dashboard shows every user's prompts, generated snippets and results,
so the route lives inside the scope chosen in step 0. `:browser` plus a
signed-in check is not enough.

With `:igniter` in the project, `mix legion_web.install` adds the import and
a `/legion` route behind `:browser` alone; move that route into the chosen
scope afterwards. Otherwise edit the router by hand:

```elixir
import LegionWeb.Router

# admin-only scope - names are the app's own; the pipeline must reject
# non-admins, and on_mount repeats the check on the LiveView socket
scope "/admin" do
  pipe_through [:browser, :require_admin]
  legion_dashboard "/legion", on_mount: [{MyAppWeb.UserAuth, :require_admin}]
end

# dev-only block, when the app has no admin pipeline
if Application.compile_env(:my_app, :dev_routes) do
  scope "/dev" do
    pipe_through :browser
    legion_dashboard "/legion"
  end
end
```

Done when: `:legion_web` is a dependency and `legion_dashboard` sits inside
the admin-only scope or the dev-only block, and nowhere else.

## 7. Identity (identity = yes)

Skip unless identity = yes. The app calls Vault itself, so it declares the
package, the same way as step 1:

```bash
mix hex.info vault
```

```elixir
{:vault, "~> X.Y"}
```

```bash
mix deps.get
```

The app puts the signed-in user in Vault once, in the process that will
start the agent, after its usual authentication:

```elixir
# LiveView mount, or a plug / controller action
Vault.init(current_user: %{id: socket.assigns.current_user.id})
```

Ash app: put the whole record in, `Vault.init(current_user:
socket.assigns.current_user)`, since policies read actor fields beyond the
id. Generated code cannot read Vault, so the record never reaches the
prompt. `guides/ash.md` covers the rest.

`Vault.init/1` runs once per process subtree and raises on a second call, so
when the app already calls it (`grep -rn "Vault.init" lib/`), add
`:current_user` to that existing call. The agent inherits the Vault map when
it is started from that process with `Legion.start_link/2`; generated code
cannot read it.

Done when: `:vault` is a dependency, exactly one `Vault.init` site carries
`:current_user`, and the agent of step 8 starts under it.

## 8. First tool and agent

Write a small facade over the chosen context, not the context itself - the
agent can call any public function of a tool.

```elixir
# lib/my_app/tools/orders_tool.ex
defmodule MyApp.Tools.OrdersTool do
  use Legion.Tool

  @doc "Orders of the signed-in user, newest first"
  def my_orders do
    %{id: user_id} = Vault.get(:current_user)

    for order <- MyApp.Orders.list_orders(user_id: user_id) do
      %{id: order.id, status: order.status, placed_at: order.placed_at}
    end
  end
end

# lib/my_app/support_agent.ex
defmodule MyApp.SupportAgent do
  @moduledoc """
  Helps a signed-in user with their orders.
  Never invents order data - if a tool returns nothing, say so.
  """
  use Legion.Agent

  def tools, do: [MyApp.Tools.OrdersTool]
end
```

Identity = no: the tool takes no user at all, for example
`def search(query), do: MyApp.Catalog.search(query)`.

Rules that keep this safe and cheap:

- Identity comes from `Vault.get(:current_user)` inside the tool, never from
  a tool argument.
- Return plain maps with the fields the agent needs. Tool results go into the
  prompt, so a `%User{}` with a password hash has no business there.
- Arguments arrive from Lua as string-keyed maps and tuples come back as
  lists. Match string keys in a tool.
- Keep irreversible actions (charging, deleting, sending) out of tools or
  behind a confirmation step in the UI.
- Ash app: the tool calls the domain's code interface with
  `actor: Vault.get(:current_user)` so policies keep applying.

Starting it, in the process of step 7 when identity = yes:

```elixir
{:ok, pid} = Legion.start_link(MyApp.SupportAgent)
```

`start_link/2` links the agent to the caller, so in a LiveView it dies with
the socket. The gates from step 0 add to that call:

- Rate limiter = yes: pass `rate_limit: [rules: ...]` from step 5.
- Store = yes: give the agent a stable `agent_id`, or every start writes a
  fresh conversation under a random id and nothing can be resumed.
  `Legion.resume/2` brings a stored one back:

  ```elixir
  agent_id = "user_#{user.id}:support"
  # the rate_limit option when rate limiter = yes, else []
  opts = []

  {:ok, pid} =
    case Legion.resume(agent_id, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, :not_resumable} -> Legion.start_link(MyApp.SupportAgent, [agent_id: agent_id] ++ opts)
    end
  ```

`Legion.call/2` waits for the whole turn with no timeout, so a LiveView
calls it through `start_async` rather than blocking `handle_event`:

```elixir
def handle_event("ask", %{"question" => question}, socket) do
  pid = socket.assigns.agent
  {:noreply, start_async(socket, :reply, fn -> Legion.call(pid, question) end)}
end

def handle_async(:reply, {:ok, {:ok, reply}}, socket), do: ...
def handle_async(:reply, {:ok, {:cancel, reason}}, socket), do: ...
```

A controller may call `Legion.call/2` directly.

Done when: one tool module and one agent module exist, the agent lists the
tool, and the facade exposes only the functions the chosen context needs.

## 9. Verify

```bash
mix format
mix compile --warnings-as-errors
```

With a key in the environment, one round trip proves the wiring end to end:

```bash
mix run -e 'IO.inspect(Legion.execute(MyApp.SupportAgent, "Return the sum of 2 and 2"))'
```

Any `{:ok, _}` proves it; the reply's wording is the model's (`"4"`, `4`,
`"The sum is 4"`). A missing or wrong key comes back as
`{:error, "LLM request failed: ..."}`. Leave the diff for review, uncommitted.

Done when: an `{:ok, _}` was seen, or the exact variable the user must set
has been reported and work stopped there.

## Further reading

- Guides in the repo: https://github.com/software-mansion-labs/legion/tree/main/guides
  (`installation.md`, `integrating.md`, `sandboxes.md`, `ash.md`)
- API docs: https://hexdocs.pm/legion
- Dashboard: https://github.com/software-mansion-labs/legion_web
