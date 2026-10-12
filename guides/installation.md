# Installation

Legion needs Elixir 1.18 and Erlang/OTP 26 or later.

1. Add `:legion` to your dependencies in `mix.exs` and run `mix deps.get`:

```elixir
def deps do
  [
    {:legion, "~> 0.5"}
  ]
end
```

2. Legion instances are isolated supervision trees and should be included in
   your application's supervisor to run:

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  Legion
]
```

3. Configure an LLM provider. The default model is `"openai:gpt-5.4"`, so an
   OpenAI key is enough to start ([all options](https://hexdocs.pm/req_llm/ReqLLM.html#module-configuration)):

```elixir
# config/runtime.exs
config :req_llm, openai_api_key: System.get_env("OPENAI_API_KEY")
```

4. Verify the setup in `iex -S mix`:

```elixir
defmodule PingAgent do
  @moduledoc "Answers trivial questions."
  use Legion.Agent
end

Legion.execute(PingAgent, "Return the sum of 2 and 2")
#=> {:ok, "4"}
```

## Next steps

- Give agents tools and run them: [Usage](https://hexdocs.pm/legion/Legion.html#module-usage)
- Drop Legion into an app you already have: [Adding Legion to an existing app](integrating.md)
- Pick a language and trust model for generated code: [Sandboxes](sandboxes.md)
- Persist conversations across restarts with `Legion.Store.Postgres`, whose
  table is created by `Legion.Store.Postgres.Migration.up()` in a migration
- Monitor agents in a LiveView dashboard: [legion_web](https://github.com/software-mansion/legion_web)
