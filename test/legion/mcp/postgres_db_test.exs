defmodule Legion.MCP.PostgresDbTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.{Context, Frame, Handlers}
  alias Legion.RateLimiter.{Policy, Rule}
  alias Legion.Store.Payload
  alias Legion.Test.Support.MathAgent
  alias Legion.Test.Support.PostgresRepo, as: Repo

  defmodule Store do
    use Legion.Store.Postgres, repo: Legion.Test.Support.PostgresRepo
  end

  defmodule RateLimiter do
    use Legion.RateLimiter.Postgres, repo: Legion.Test.Support.PostgresRepo
  end

  defmodule UserMCP do
    use Legion.MCP.Server, agent: MathAgent, name: "users", version: "0.1.0"

    # Two evaluations a minute per user, each user in an agent of their own.
    def session(frame) do
      user = frame.context.auth.sub
      policy = %Policy{window_ms: 60_000, max_evals: 2}

      [
        store: Store,
        agent_id: "mcp:user:" <> user,
        rate_limit: [
          limiter: RateLimiter,
          rules: [%Rule{identity: %{"user" => user}, policy: policy}]
        ]
      ]
    end
  end

  setup do
    Repo.query!("TRUNCATE legion_agents", [])
    start_supervised!({DynamicSupervisor, name: Legion.AgentSupervisor, strategy: :one_for_one})
    :ok
  end

  defp repl(user, code) do
    context = %Context{session_id: "session-" <> user, client_info: %{}, auth: %{sub: user}}
    {:ok, frame} = UserMCP.init(%{}, %Frame{context: context})

    request = %{
      "method" => "tools/call",
      "params" => %{"name" => "repl", "arguments" => %{"code" => code}}
    }

    {:reply, %{"content" => [%{"text" => text}], "isError" => error?}, %Frame{}} =
      Handlers.handle(request, UserMCP, frame)

    {error?, text}
  end

  test "a user's calls land in the store and count towards their max_evals" do
    assert {false, first} = repl("alice", "return 1 + 1")
    assert {false, _second} = repl("alice", "return 2 + 2")
    assert {true, "Rate limit exceeded (max_evals)." <> _} = repl("alice", "return 3 + 3")
    assert {false, _bob} = repl("bob", "return 1")

    assert {:ok,
            %Payload{
              agent_module: MathAgent,
              status: :idle,
              ratelimit_metadata: %{"user" => "alice"},
              usage: [%{"evals" => 1}, %{"evals" => 1}],
              conversation_state: %{
                messages: [
                  %{type: :assistant},
                  %{type: :eval_result} = saved,
                  %{type: :assistant},
                  %{type: :eval_result}
                ]
              }
            }} = Store.get("mcp:user:alice")

    assert saved.content == first
  end
end
