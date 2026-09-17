if Code.ensure_loaded?(Anubis.Server) do
  defmodule Legion.MCP.Server do
    @moduledoc """
    Exposes a `Legion.Agent` as an MCP server with a single `repl` tool.

        defmodule MyApp.MCPAgent do
          @moduledoc "Sales assistant for The Mansion catalogue."
          use Legion.Agent

          def tools, do: [MyApp.CatalogTool]
        end

        defmodule MyApp.MCP do
          use Legion.MCP.Server, agent: MyApp.MCPAgent, name: "mansion", version: "1.0.0"
        end

        # supervision tree
        {MyApp.MCP, transport: :stdio}

        # or, behind Phoenix/Plug:
        {MyApp.MCP, transport: :streamable_http}
        forward "/mcp", to: Anubis.Server.Transport.StreamableHTTP.Plug, server: MyApp.MCP

    The agent's `@moduledoc`, tools and sandbox become the server `instructions`;
    the host's model writes code and the server evaluates it with
    `Legion.Eval.run/4` under the agent's resolved config. Variables persist per
    MCP session unless `:binding_scope` is `:iteration`.

    Requires the optional `:anubis_mcp` dependency.

    ## Options

      - `:agent` — the `Legion.Agent` module to expose (required)
      - `:name`, `:version` — MCP `serverInfo`, shown by hosts (required)
      - `:store` — a `Legion.Store` that records each session; defaults to
        `config :legion, :store`. Without one nothing is persisted.

    Any option accepted by `Anubis.Server.Supervisor.start_link/2` can be passed
    in the child spec. `:request_timeout` defaults to the agent's
    `:sandbox_timeout` plus five seconds so a slow eval does not time out the
    transport call first. When mounting the StreamableHTTP plug, pass the same
    value as its `:request_timeout` option.

    ## Recording sessions

    With a store, every `repl` call is saved once it has run, in the shape of
    an agent's conversation: the code as an assistant message, its result or
    error as the message after it, and the session's variables, so whatever
    you build on the store reads a session like any other conversation. With
    usage tracking on (the default; see "Usage tracking" in `Legion.Store`),
    each call also adds one usage entry, `"evals" => 1`. When a save fails,
    the call is answered with an error and the session keeps the variables it
    had before, even though the code ran.

    A session is stored under the id `agent_id/1` returns, not under its MCP
    session id. Override it to give a caller a conversation that outlives the
    session:

        def agent_id(frame), do: "mcp:user:" <> frame.context.auth.sub

    `frame.context.auth` holds the bearer token's claims when Anubis's
    `authorization:` option is configured, and is `nil` otherwise; see
    "Callbacks". Legion calls `agent_id/1` when the session makes its first
    `repl` call, with that call's frame, and keeps the answer for the rest of
    the session. `nil`, the default, makes Legion generate an id starting with
    `mcp:`, so every session is a conversation of its own. A string is used as
    it is, like `:agent_id` in `Legion.start_link/2`; anything else raises.
    When the store already holds a conversation under that id, the session
    continues it, variables and history included. Legion does not check whose
    conversation that is, so keep these ids apart from your agents', and
    return an id that one session at a time will use: two sessions open at
    once under one id overwrite each other's saves.

    A stored session grows with every call and holds the variables whole.
    Code is stored as sent, while results and errors are truncated to the
    agent's `:max_message_length`; how large one call's code can be is up to
    the request body your endpoint accepts.

    ## Rate limiting

    The host's model does the thinking: a `repl` call makes no LLM request of
    its own, so `:max_tokens` has nothing to count for it. What a call costs
    you is an evaluation, and `:max_evals` in a `Legion.RateLimiter.Policy`
    limits those. An agent is given its rules when it starts; an MCP server
    only learns who is calling from each request, so it is asked for the rules
    of every call:

        def rate_limit_rules(frame) do
          ip = frame.context.remote_ip |> :inet.ntoa() |> to_string()

          [
            %Legion.RateLimiter.Rule{
              identity: %{"ip" => ip},
              policy: %Legion.RateLimiter.Policy{
                window_ms: :timer.minutes(1),
                max_evals: 30
              }
            }
          ]
        end

    Telling callers apart takes an HTTP request: over stdio `remote_ip` and
    `auth` are `nil`. A server reachable over HTTP should define
    `rate_limit_rules/1`. Behind a reverse proxy `remote_ip` is the proxy's
    address unless something like `RemoteIp` runs before the Anubis plug.

    The rules are resolved like an agent's (see `Legion.RateLimiter`): the
    limiter comes from `config :legion, :rate_limit`, and a rule without a
    policy takes the `:default_policy` set there. They are enforced before the
    code runs. A denied call runs nothing and records nothing; the host's
    model gets a tool error naming the limit:

        Rate limited: max_evals (30 per 60s). Try again later.

    Evaluations are counted from the usage entries sessions save: one for
    every call that ran and was saved, whether its code succeeded or failed.
    So `:max_evals` needs a store and usage tracking;
    `Legion.RateLimiter.Postgres` reads the count from the
    `Legion.Store.Postgres` table it shares. A limit belongs to the rule's
    identity, not to the session, so a caller who opens a new session keeps
    the count.

    Every session counts as an agent towards `:max_agents`, under the id from
    `agent_id/1`, so a default policy written for agents also caps the new
    sessions an identity can run code in during its window. Agents started by
    the code, with `Legion.Tools.AgentTool` for instance, inherit the call's
    rules the way sub-agents inherit their parent's.

    A server that does not define `rate_limit_rules/1` runs without rate
    limiting, and when a limiter is configured Legion logs a warning about it
    once per session. Return `[]`, not `nil`, to opt out on purpose and
    silently, for the whole server or for a caller you do not want to limit.

    ## Callbacks

    `init/2`, `server_instructions/0` and `terminate/2` are overridable, next
    to `agent_id/1` and `rate_limit_rules/1` described above.

    `init/2` runs inside the session process when the client sends
    `notifications/initialized`. It does not see the HTTP request:
    `frame.context.auth`, `remote_ip` and `headers` are empty there. They are
    filled in per tool call, because every call is its own request, which is
    why `agent_id/1` and `rate_limit_rules/1` are given a call's frame.

    To hand your tools something derived from the request (a user, a tenant),
    seed the Vault per call. Each call runs in its own process, and the sandbox
    and tools started under it read that Vault:

        @impl Anubis.Server
        def handle_request(request, frame) do
          Vault.unsafe_put(:current_user, MyApp.Users.from_claims!(frame.context.auth))
          Anubis.Server.Handlers.handle(request, __MODULE__, frame)
        end

    `handle_request/2` has no `super`; the `Handlers.handle/3` line is what
    Anubis's default does.

    Authentication is not a server callback. On HTTP transports MCP uses OAuth
    2.1 bearer tokens, rejected with 401 before `initialize`: configure it with
    Anubis's `authorization:` option (claims land in `frame.context.auth`) or
    put your own `Plug` in front of the Anubis plug.

    ## Security

    A session belongs to whoever presents its MCP session id: Anubis does not
    tie it to the client that opened it, so a request carrying a live id runs
    code with that session's variables and adds to its stored conversation.
    A client may choose its own session id, but that does not let it pick a
    stored conversation: conversations are kept under the id from
    `agent_id/1`, never under the session id, so do not build that id from
    the session id. Authenticate requests, as described above, so that a
    session id on its own is not enough.

    Anubis also puts no limit on the sessions a client opens.
    `rate_limit_rules/1` only sees `repl` calls; to limit `initialize`
    requests, put a `Plug` in front of the Anubis plug.

    ## Telemetry

    Emits `[:legion, :mcp, :session, :started | :stopped]` and wraps every tool
    call in a `[:legion, :mcp, :call]` span. A call denied by a rate limit also
    emits `[:legion, :rate_limit, :exceeded]`. See `Legion.Telemetry`.
    """

    defmacro __using__(opts) do
      agent = Keyword.fetch!(opts, :agent)
      store = Keyword.get(opts, :store)

      name = Keyword.fetch!(opts, :name)
      version = Keyword.fetch!(opts, :version)

      quote do
        use Anubis.Server,
          name: unquote(name),
          version: unquote(version),
          capabilities: [:tools]

        component Legion.MCP.Repl, name: "repl"

        def child_spec(opts) do
          config = Legion.Agent.resolve_config(unquote(agent))
          timeout = Legion.MCP.Server.request_timeout(config)
          super(Keyword.put_new(opts, :request_timeout, timeout))
        end

        @impl Anubis.Server
        def init(_client_info, frame) do
          Legion.MCP.Server.init_session(frame,
            server: __MODULE__,
            agent: unquote(agent),
            store: unquote(store)
          )
        end

        @impl Anubis.Server
        def server_instructions do
          config = Legion.Agent.resolve_config(unquote(agent))
          Legion.AgentPrompt.system_prompt(unquote(agent), config, mode: :mcp)
        end

        @impl Anubis.Server
        def terminate(reason, frame) do
          Legion.MCP.Server.stop_session(unquote(agent), reason, frame)
        end

        def agent_id(_frame), do: nil

        def rate_limit_rules(_frame), do: nil

        defoverridable init: 2,
                       server_instructions: 0,
                       terminate: 2,
                       agent_id: 1,
                       rate_limit_rules: 1
      end
    end

    alias Anubis.Server.Frame
    alias Legion.{Agent, Telemetry}

    @doc false
    # Runs inside the Anubis Session process: seeds the tool configs the sandbox
    # and tools read through `$ancestors`, announces the session, and assigns
    # what `Repl` reads on every call. Called by the generated `init/2`.
    def init_session(frame, opts) do
      agent = Keyword.fetch!(opts, :agent)
      config = Agent.resolve_config(agent)
      store = opts[:store] || Application.get_env(:legion, :store)
      session_id = frame.context.session_id

      Agent.seed_tool_configs(agent)

      Telemetry.emit(
        [:legion, :mcp, :session, :started],
        %{system_time: NaiveDateTime.utc_now()},
        %{agent: agent, session_id: session_id, client_info: frame.context.client_info}
      )

      {:ok,
       Frame.assign(frame, server: opts[:server], agent: agent, config: config, store: store)}
    end

    @doc false
    # Called by the generated `terminate/2`.
    def stop_session(agent, reason, frame) do
      Telemetry.emit(
        [:legion, :mcp, :session, :stopped],
        %{system_time: NaiveDateTime.utc_now()},
        %{agent: agent, session_id: frame.context.session_id, reason: reason}
      )
    end

    @doc false
    # Anubis's transport calls the Session with this timeout; it must outlast
    # the sandbox so a slow eval fails as a sandbox timeout, not a dead call.
    def request_timeout(%{sandbox_timeout: :infinity}), do: :infinity
    def request_timeout(%{sandbox_timeout: ms}) when is_integer(ms), do: ms + 5_000
  end
end
