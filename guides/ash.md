# Using Legion with Ash

Ash apps already route every read and write through actions, and policies
decide who may call them. A Legion tool calls your domain's code interface
with the actor it reads from [Vault](https://github.com/dimamik/vault), so
your policies apply to the agent exactly as they apply to a controller.

This guide assumes you have read [Adding Legion to an existing
app](integrating.md) and have a domain along these lines:

```elixir
defmodule MyApp.Blog do
  use Ash.Domain

  resources do
    resource MyApp.Post do
      define :list_posts, action: :read
      define :create_post, action: :create, args: [:title, :body]
    end
  end
end
```

## Writing a tool

```elixir
defmodule MyApp.Tools.PostsTool do
  @moduledoc """
  Posts the signed-in user can see. Creating a post needs a title and a body.
  """
  use Legion.Tool

  alias MyApp.Blog
  alias MyApp.Post

  @visible_fields Post
                  |> Ash.Resource.Info.public_attributes()
                  |> Enum.reject(& &1.sensitive?)
                  |> Enum.map(& &1.name)

  @doc "Posts the signed-in user can see, up to 50"
  def list, do: Blog.list_posts!(query: [limit: 50], actor: actor()) |> visible()

  @doc ~S(Searches posts with a filter table, for example `{title = {eq = "Hello"}}`)
  def search(filter) do
    Post
    |> Ash.Query.filter_input(filter)
    |> Ash.Query.limit(50)
    |> Ash.read!(actor: actor())
    |> visible()
  end

  @doc ~S(Creates a post from `{title = "...", body = "..."}`)
  def create(attributes) do
    Blog.create_post!(attributes["title"], attributes["body"], actor: actor()) |> visible()
  end

  defp actor, do: Vault.get(:current_user)

  defp visible(records) when is_list(records), do: Enum.map(records, &visible/1)
  defp visible(record), do: Map.take(record, @visible_fields)
end
```

Start an agent whose `tools/0` includes `PostsTool` the same way as in any
other Legion app:

```elixir
Vault.init(current_user: socket.assigns.current_user)
{:ok, pid} = Legion.start_link(MyApp.WriterAgent)
```

Every call in the tool passes `actor: actor()`. Tools run in the sandbox's
eval process and can read Vault. Generated code can't: it only reaches the
functions your tools expose, so it has no way to read the actor or pass a
different one. If nobody initialized Vault, the actor is `nil` and your
policies decide what that may do. If they require an actor, a forgotten
`Vault.init` fails closed.

The search filter goes through `Ash.Query.filter_input/2`. Lua tables arrive
in Elixir as string-keyed maps, the shape `filter_input` accepts, so no
conversion is needed. Ash rejects references to private or
non-filterable fields with an error the model can read, and field policies
replace forbidden references with `nil`.

If your app already has a scope struct implementing `Ash.Scope.ToOpts`,
store it in Vault instead of the bare user and pass `scope: Vault.get(:scope)`
to your actions. Actor, tenant and context then travel together. Without a
scope, keep the tenant in Vault and pass `tenant:` the same way as `actor:`.

## Return maps, not records

The Lua sandbox converts structs with `Map.from_struct`. An Ash record passed
through as is brings `__meta__`, `__metadata__`, empty `aggregates` and
`calculations` maps, an `Ash.NotLoaded` for every unloaded relationship, and
every attribute, private and `sensitive?` ones included.

Ash redacts `sensitive?` fields only in `inspect`. The Lua bridge copies them
through, and in the Elixir sandbox generated code can read any field off the
struct. `@visible_fields` keeps public, non-sensitive attributes. If the
agent needs a relationship or calculation, load it and add its name to the
list.

## Pitfalls

**Don't allowlist `Ash`, `Ash.Query` or your domain in the Elixir sandbox.**
Generated code that can call `Ash.read!` can pass any `actor:` it likes, or
`authorize?: false`. The Lua sandbox only exposes `Legion.Tool` modules, so
this can't happen there.

**Keep `show_policy_breakdowns?` off in production.** Policy breakdowns end
up in tool errors, tool errors go into the conversation, and the agent can
repeat them to the user.

**Limit reads inside the tool.** Legion truncates whatever a snippet returns
to `max_message_length` (40 KB by default), and a snippet often returns a
tool's result as is. A capped read gives the model complete rows instead of
a cut-off dump.

## Errors

A tool that raises doesn't crash the agent. The exception message goes back
to the model, prefixed with the tool and function name: a failed create
shows up as `PostsTool.create:` followed by Ash's message, such as
`attribute title is required`. The model can then fix the call. Each failed
attempt costs a round trip, and the model gets three retries (`max_retries`)
before the run is cancelled, so state the rules in the moduledoc, as
`PostsTool` does.

## Calling an agent from an action

A generic action can run an agent too:

```elixir
action :summarize, :string do
  argument :text, :string, allow_nil?: false

  run fn input, context ->
    case Legion.execute(MyApp.SummaryAgent, input.arguments.text,
           vault: [current_user: context.actor]
         ) do
      {:cancel, reason} -> {:error, reason}
      ok -> ok
    end
  end
end
```

Ash passes the actor in the action context, and Legion's tools look for it
in Vault. The `vault:` option bridges the two. Don't call `Vault.init` inside
the action instead: the action runs in the caller's process, and
`Vault.init` raises if that process or an ancestor already has a vault.
That is the case whenever a LiveView that ran `Vault.init` calls the action.

## Store and rate limiter

`Legion.Store.Postgres` and `Legion.RateLimiter.Postgres` take an
`Ecto.Repo`. An `AshPostgres.Repo` is one, so point them at your existing
repo. `Legion.Store.Postgres.Migration.up()` sets up both; call it from a
regular Ecto migration next to the ones `mix ash.codegen` generates.
