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

    Any option accepted by `Anubis.Server.Supervisor.start_link/2` can be passed
    in the child spec. `:request_timeout` defaults to the agent's
    `:sandbox_timeout` plus five seconds so a slow eval does not time out the
    transport call first. When mounting the StreamableHTTP plug, pass the same
    value as its `:request_timeout` option.

    ## Callbacks

    `init/2`, `server_instructions/0` and `terminate/2` are overridable; call
    `super` to keep the Legion behaviour. `init/2` runs inside the session
    process, so it is the place to seed the Vault with anything your tools need
    for that session (a tenant, a user, a page):

        @impl Anubis.Server
        def init(client_info, frame) do
          Vault.unsafe_put(:current_user, MyApp.Users.from_claims!(frame.context.auth))
          super(client_info, frame)
        end

    Authentication is not a server callback. On HTTP transports MCP uses OAuth
    2.1 bearer tokens, rejected with 401 before `initialize`: configure it with
    Anubis's `authorization:` option (claims land in `frame.context.auth`) or
    put your own `Plug` in front of the Anubis plug.

    ## Telemetry

    Emits `[:legion, :mcp, :session, :started | :stopped]` and wraps every tool
    call in a `[:legion, :mcp, :call]` span. See `Legion.Telemetry`.
    """

    defmacro __using__(opts) do
      agent = Keyword.fetch!(opts, :agent)
      name = Keyword.fetch!(opts, :name)
      version = Keyword.fetch!(opts, :version)

      quote do
        use Anubis.Server,
          name: unquote(name),
          version: unquote(version),
          capabilities: [:tools]

        component Legion.MCP.Repl, name: "repl"

        @legion_agent unquote(agent)

        @doc false
        def __legion_agent__, do: @legion_agent

        def child_spec(opts) do
          config = Legion.Agent.resolve_config(@legion_agent)
          timeout = Legion.MCP.Server.request_timeout(config)
          super(Keyword.put_new(opts, :request_timeout, timeout))
        end

        @impl Anubis.Server
        def init(_client_info, frame) do
          Legion.MCP.Server.init_session(@legion_agent, frame)
        end

        @impl Anubis.Server
        def server_instructions do
          config = Legion.Agent.resolve_config(@legion_agent)
          Legion.AgentPrompt.system_prompt(@legion_agent, config, mode: :mcp)
        end

        @impl Anubis.Server
        def terminate(reason, frame) do
          Legion.MCP.Server.stop_session(@legion_agent, reason, frame)
        end

        defoverridable init: 2, server_instructions: 0, terminate: 2
      end
    end

    alias Anubis.Server.Frame
    alias Legion.{Agent, Telemetry}

    @doc false
    # Runs inside the Anubis Session process: seeds the Vault the sandbox and
    # tools read through `$ancestors`, announces the session, and assigns the
    # agent and its resolved config for `Repl` to read. Called by the generated
    # `init/2`.
    def init_session(agent, frame) do
      config = Agent.resolve_config(agent)
      session_id = frame.context.session_id

      Vault.unsafe_put(:agent_id, session_id)
      Agent.seed_tool_configs(agent)

      Telemetry.emit(
        [:legion, :mcp, :session, :started],
        %{system_time: NaiveDateTime.utc_now()},
        %{agent: agent, session_id: session_id, client_info: frame.context.client_info}
      )

      {:ok, Frame.assign(frame, agent: agent, config: config)}
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
