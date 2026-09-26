if Code.ensure_loaded?(Anubis.Server) do
  defmodule Legion.MCP.Server do
    @moduledoc """
    Exposes a `Legion.Agent` to MCP hosts as a server with a single `repl` tool.

        defmodule MyApp.Assistant do
          @moduledoc "Sales assistant for The Mansion catalogue."
          use Legion.Agent

          def tools, do: [MyApp.CatalogTool]
        end

        defmodule MyApp.MCP do
          use Legion.MCP.Server, agent: MyApp.Assistant, name: "mansion", version: "1.0.0"
        end

        # supervision tree, after Legion
        {MyApp.MCP, transport: :stdio}

        # or, behind Phoenix/Plug:
        {MyApp.MCP, transport: :streamable_http}
        forward "/mcp", to: Legion.MCP.Plug, server: MyApp.MCP

    An MCP host brings its own model. That model reads the agent's system
    prompt as the server `instructions`, writes code, and the server runs it
    with `Legion.eval/3`. The agent makes no LLM request of its own; what a
    call costs is one evaluation.

    Built on the optional `:anubis_mcp` dependency, which speaks the protocol,
    runs the transports and, when configured, checks OAuth 2.1 bearer tokens.
    Requires `Legion` in the supervision tree.

    ## Options

      - `:agent` - the `Legion.Agent` module to expose (required)
      - `:name`, `:version` - MCP `serverInfo`, shown by hosts (required)
      - `:capabilities` - what `use Anubis.Server` takes, for a server that adds
        components of its own; `:tools` is always among them, since `repl` is one

    Every other option is passed to `use Anubis.Server`, `:authorization`
    above all; see "Who is calling". The child spec takes what
    `Anubis.Server.Supervisor.start_link/2` accepts.

    ## Request timeout

    A `repl` call is one transport call into the session, and the transport
    gives up on it after `request_timeout/0`. The default is the agent's
    `:sandbox_timeout` plus thirty seconds, so a slow eval fails as a
    sandbox timeout the model can read, not a dead call. The thirty seconds
    pay for what runs around the sandbox: the rate limiter, the eval guard
    and the store save. That assumes a cheap guard and an idle agent. An
    LLM eval guard adds a model round trip per call, and an agent shared
    with chat runs the call only after the turn in progress. Then define
    the function yourself:

        defmodule MyApp.MCP do
          use Legion.MCP.Server, agent: MyApp.Assistant, name: "mansion", version: "1.0.0"

          def request_timeout, do: :timer.minutes(2)
        end

    A `:sandbox_timeout` of `:infinity` has no default to derive; defining
    `request_timeout/0` is required then. Both transports use it: the child
    spec passes it to stdio, `Legion.MCP.Plug` to Streamable HTTP.

    ## Sessions are agents

    Every `repl` call runs in a regular agent process, started with the
    options `Legion.start_link/2` takes. Whatever makes an agent persist, be
    rate limited or hand context to its tools works the same for a session:

      - With a store and a stable `:agent_id`, a session continues the stored
        conversation, variables and history included. Every call is saved as
        a step: the code as an `:assistant` message, then its `:eval_result`
        or `:error`, and one `"evals" => 1` usage entry that `:max_evals` in
        a `Legion.RateLimiter.Policy` counts.
      - With rate limit rules, every call is checked before it runs. A denied
        call runs nothing and comes back as a tool error the model can read.
      - Two sessions that resolve to one agent id share one process, so their
        calls are serialised and nothing is overwritten.

    Which agent a call belongs to is what `session/1` decides. It receives
    the call's frame and returns the options the agent is started with:

        def session(frame) do
          user = MyApp.Users.from_claims!(frame.context.auth)

          [
            agent_id: "mcp:user:\#{user.id}",
            vault: [current_user: user],
            idle_timeout: :timer.minutes(30),
            rate_limit: [
              rules: [
                %Legion.RateLimiter.Rule{
                  identity: %{"user" => user.id},
                  policy: %Legion.RateLimiter.Policy{window_ms: :timer.minutes(1), max_evals: 30}
                }
              ]
            ]
          ]
        end

    With an `:agent_id` the call runs in that agent, started on demand under
    `Legion.AgentSupervisor` and found again on every later call, whatever
    MCP session it comes from, so a user who comes back tomorrow, or from
    another host, continues the same conversation. `:agent_id` needs a store;
    see `Legion.Store`.

    `:vault` is how tools learn who is calling. It is put in the agent before
    every call, so it may change from request to request: a refreshed token,
    a tenant switch. Every other option is read when the agent starts and
    stays as it is until the agent stops, since the process outlives the
    request. They are read once, by whoever starts the agent. An agent
    already running under that id, started by `Legion.start_link/2` before
    the MCP call arrived, keeps its own `:idle_timeout`, `:rate_limit` and
    config; `session/1`'s go unused, the thirty-minute default included.
    `:idle_timeout` is what stops it once nobody calls: thirty minutes by
    default here, whatever `Legion.start_link/2` would default to, after
    which the store holds the conversation and the next call starts the
    agent again from it. Thirty minutes is also Anubis's default
    `:session_idle_timeout`; an MCP session and the agent it last called
    go idle together, so raise both if you raise one.

    The default, `[]`, gives every MCP session an anonymous agent of its own,
    started on its first call and stopped with the session. With no store it
    leaves nothing behind. With one configured for the application it is
    saved like any agent, under the id Legion generated for it.

    ## Who is calling

    `session/1` runs for every call, with that call's frame, because that is
    where the request is: `init/2` runs when the client sends
    `notifications/initialized` and sees no HTTP request at all. Over
    StreamableHTTP `frame.context.remote_ip` and `headers` are filled in; over
    stdio they are `nil` and empty, and there is one caller anyway.

    Authentication is Anubis's: pass `authorization:` to `use` and the
    transport rejects requests without a valid bearer token before they reach
    the server, serves the OAuth protected-resource metadata hosts discover,
    and puts the token's claims in `frame.context.auth`:

        use Legion.MCP.Server,
          agent: MyApp.Assistant,
          name: "mansion",
          version: "1.0.0",
          authorization: [
            authorization_servers: ["https://auth.example.com"],
            resource: "https://api.example.com/mcp",
            validator: {Anubis.Server.Authorization.JWTValidator, jwks_uri: "https://auth.example.com/.well-known/jwks.json"}
          ]

    A stable agent id should come from those claims, never from the session
    id: a session belongs to whoever presents its id, a conversation to
    whoever authenticated.

    ## Callbacks

    `session/1`, `init/2`, `server_instructions/0` and `terminate/2` are
    overridable; call `super` to keep what Legion does in them. The
    instructions are always generated from the agent's `@moduledoc` and
    tools, ignoring its `system_prompt/0`; override `server_instructions/0`
    to hand the host something else.

    ## Telemetry

    Every `repl` call is a `[:legion, :mcp, :call]` span carrying the MCP
    session id and the agent id it ran in; the agent's own events fire
    inside it. See `Legion.Telemetry`.
    """

    alias Anubis.Server.Frame
    alias Legion.{Agent, AgentPrompt, AgentServer}

    # Matches Anubis's default `:session_idle_timeout`. Anonymous agents are
    # stopped with their session in `terminate/2`; this is their backstop,
    # and the only idle limit a named agent has, since named agents outlive
    # any one session. Raise both if you raise one.
    @idle_timeout :timer.minutes(30)

    # Slack for what a call waits on besides the sandbox: rate limiter, eval
    # guard, store save.
    @request_slack :timer.seconds(30)

    defmacro __using__(opts) do
      {agent, anubis_opts} = Keyword.pop!(opts, :agent)
      anubis_opts = Keyword.update(anubis_opts, :capabilities, [:tools], &with_tools/1)

      quote do
        use Anubis.Server, unquote(anubis_opts)

        component Legion.MCP.Repl, name: "repl"

        @doc false
        def __legion_agent__, do: unquote(agent)

        @doc """
        How long the transport waits for one `repl` call, in milliseconds.

        Derived from the agent's `:sandbox_timeout`; see "Request timeout" in
        `Legion.MCP.Server`. Overridable.
        """
        def request_timeout, do: Legion.MCP.Server.request_timeout(unquote(agent))

        def child_spec(opts) do
          super(Keyword.put_new(opts, :request_timeout, request_timeout()))
        end

        def session(_frame), do: []

        @impl Anubis.Server
        def init(_client_info, frame), do: Legion.MCP.Server.init_session(frame, __MODULE__)

        @impl Anubis.Server
        def server_instructions, do: Legion.MCP.Server.instructions(unquote(agent))

        @impl Anubis.Server
        def terminate(_reason, frame), do: Legion.MCP.Server.stop_anonymous_agent(frame)

        defoverridable request_timeout: 0,
                       session: 1,
                       init: 2,
                       server_instructions: 0,
                       terminate: 2
      end
    end

    # `repl` is a tool: hosts only ask for the tools a server says it has.
    defp with_tools(capabilities) do
      if Enum.any?(capabilities, &(&1 == :tools or match?({:tools, _}, &1))),
        do: capabilities,
        else: [:tools | capabilities]
    end

    @doc false
    def init_session(%Frame{} = frame, server),
      do: {:ok, Frame.assign(frame, :legion_mcp_server, server)}

    @doc false
    # The agent a call runs in, with the vault to seed it with: the one
    # `session/1` names, started if need be, or else the session's own
    # anonymous agent, kept in the frame.
    def resolve_agent(%Frame{assigns: %{legion_mcp_server: server} = assigns} = frame) do
      opts = server.session(frame)
      vault = Keyword.get(opts, :vault, [])

      cond do
        agent_id = opts[:agent_id] ->
          pid =
            case Legion.lookup(agent_id) do
              {:ok, pid} -> pid
              :error -> agent(server.__legion_agent__(), opts)
            end

          {pid, agent_id, vault, frame}

        (pid = assigns[:legion_mcp_agent]) && Process.alive?(pid) ->
          {pid, assigns.legion_mcp_agent_id, vault, frame}

        true ->
          pid = agent(server.__legion_agent__(), opts)
          agent_id = Legion.get_agent_id(pid)

          frame =
            frame
            |> Frame.assign(:legion_mcp_agent, pid)
            |> Frame.assign(:legion_mcp_agent_id, agent_id)

          {pid, agent_id, vault, frame}
      end
    end

    @doc false
    def stop_anonymous_agent(%Frame{assigns: %{legion_mcp_agent: pid}}) do
      DynamicSupervisor.terminate_child(Legion.AgentSupervisor, pid)
    end

    def stop_anonymous_agent(_frame), do: :ok

    @doc false
    # Starts `agent_module` under `Legion.AgentSupervisor` with `opts`, or
    # returns the live process that already owns the agent id.
    def agent(agent_module, opts) do
      opts = Keyword.put_new(opts, :idle_timeout, @idle_timeout)

      child = %{
        id: AgentServer,
        start: {AgentServer, :start_link, [agent_module, opts]},
        restart: :temporary
      }

      case DynamicSupervisor.start_child(Legion.AgentSupervisor, child) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
        {:error, reason} -> raise "could not start #{inspect(agent_module)}: #{inspect(reason)}"
      end
    end

    @doc false
    def instructions(agent_module) do
      AgentPrompt.system_prompt(agent_module, Agent.resolve_config(agent_module), mode: :mcp)
    end

    @doc false
    # Anubis's transport calls the session with this timeout; it must outlast
    # the sandbox plus @request_slack so a slow eval fails as a sandbox
    # timeout, not a dead call. Anubis validates it as an integer, so a
    # sandbox without a timeout has nothing to derive from.
    def request_timeout(agent_module) do
      case Agent.resolve_config(agent_module) do
        %{sandbox_timeout: milliseconds} when is_integer(milliseconds) ->
          milliseconds + @request_slack

        %{sandbox_timeout: :infinity} ->
          raise ArgumentError,
                "#{inspect(agent_module)} has no sandbox timeout, so no request timeout " <>
                  "can be derived from it; define request_timeout/0 in the MCP server module"
      end
    end
  end
end
