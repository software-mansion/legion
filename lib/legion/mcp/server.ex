if Code.ensure_loaded?(Anubis.Server) do
  defmodule Legion.MCP.Server do
    @moduledoc """
    Exposes a `Legion.Agent` to MCP hosts as a server with two tools, `repl`
    and `help`.

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

    An MCP host brings its own model. That model reads the server
    `instructions`: the agent's `@moduledoc` and its tools, each by name and
    one-line summary. It reads a tool in full with `help` before the first
    call, and the sandbox language and rules from the `repl` tool's
    description. The model then writes code, and the server runs it with
    `Legion.eval/3`. `help` is itself an evaluation, of `Help.help/1` on the
    session's agent, so a lookup is a step of the conversation, saved, rate
    limited and traced like a `repl` call. The agent makes no LLM request of
    its own; what a call costs is one evaluation, plus whatever its tools do
    (`AgentTool`, for one).

    Built on the optional `:anubis_mcp` dependency, which speaks the protocol,
    runs the transports and, when configured, checks OAuth 2.1 bearer tokens.
    Requires `Legion` in the supervision tree.

    ## Options

      - `:agent` - the `Legion.Agent` module to expose (required)
      - `:name`, `:version` - MCP `serverInfo`, shown by hosts (required)
      - `:capabilities` - what `use Anubis.Server` takes, for a server that adds
        components of its own; `:tools` is always among them, since `repl` is one
      - `:instructions_budget` - how many characters of `server_instructions/0`
        and of the `repl` tool description the hosts you target read; see
        "Instruction size". Defaults to 2048, `:infinity` disables the check

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
    spec passes it to stdio, `Legion.MCP.Plug` to Streamable HTTP. Note that
    the transport only stops waiting; the eval keeps running, and its step is
    saved and counted like any other. A retry from the host runs the code a
    second time.

    ## Instruction size

    Hosts read only so much of the instructions. Claude Code cuts them at
    2,048 characters (`CLAUDE_CODE_MAX_MCP_DESCRIPTION_LENGTH` raises it, per
    user, not per server) and appends "[truncated]"; it cuts every tool
    description at the same length. So over MCP the instructions follow
    `tool_docs: :discovery` unless the agent's `config/0` says otherwise
    (see `Legion.Agent`). They then carry the agent's
    `@moduledoc` and one line per tool; the model reads a tool in full with
    `help`. For an agent with a one-line `@moduledoc` and one tool that is
    about 1,000 characters, and each tool adds a line. The sandbox rules
    are in the `repl` tool description instead: about 1,450 characters for
    Lua, 1,950 for Elixir. When the server starts, it renders both and logs
    a warning for either that is longer than `:instructions_budget`, naming
    the last words the host will read and any sections after them. For the
    instructions, answer it by shortening the agent's `@moduledoc` or
    overriding `server_instructions/0`; for `repl`, by shortening the
    sandbox's rules. Set the budget to what your hosts read if it is not
    Claude Code's.

    `tool_docs: :full` in `config/0` embeds every tool's description in the
    instructions instead, as chat does, and brings the sandbox rules back
    with them. That alone is past Claude Code's cap before the first tool,
    so expect the warning; `server_instructions/0` is the way out.

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
        A running call counts towards `:max_running_agents` like a turn does.
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

    `:vault` is put in the agent before every call, so it may change from
    request to request: a refreshed token, a tenant switch. It is how tools
    learn who is calling.

    Every other option is read once, by whoever starts the agent, and holds
    until it stops. An agent already running under that id, started by
    `Legion.start_link/2` before the MCP call arrived, keeps its own
    `:idle_timeout`, `:rate_limit` and config; `session/1`'s go unused.

    `:idle_timeout` stops the agent once nobody calls, after thirty minutes
    by default. The store then holds the conversation and the next call
    starts the agent again from it. Thirty minutes is also Anubis's default
    `:session_idle_timeout`; raise both if you raise one.

    The default, `[]`, gives every MCP session an anonymous agent of its own,
    started on its first call and stopped with the session. It is the stdio
    default: one caller, who launched the process. Over HTTP, pair it with
    `authorization:` or anyone who reaches the endpoint gets a sandbox. With
    no store it leaves nothing behind. With one configured for the
    application it is saved like any agent, under an id no caller learns.
    Stores never delete, so each session leaves a row behind.

    ## Who is calling

    `session/1` runs for every call, with that call's frame, because that is
    where the request is: `init/2` runs when the client sends
    `notifications/initialized` and sees no HTTP request at all. Over
    StreamableHTTP `frame.context.remote_ip` and `headers` are filled in; over
    stdio they are `nil` and empty, and there is one caller anyway. Anubis's
    `:session_store` restores sessions without running `init/2`; `repl` does
    not work in one, so leave it unset.

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

    Every `repl` and `help` call is a `[:legion, :mcp, :call]` span carrying
    the MCP session id and the agent id it ran in; the agent's own events
    fire inside it. See `Legion.Telemetry`.
    """

    require Logger

    alias Anubis.Server.{Component, Frame, Response}
    alias Legion.{Agent, AgentPrompt, AgentServer, Telemetry}

    # What Claude Code reads of the instructions (and of each tool description)
    # before cutting: its `CLAUDE_CODE_MAX_MCP_DESCRIPTION_LENGTH` default.
    @default_budget 2048

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
      {budget, anubis_opts} = Keyword.pop(anubis_opts, :instructions_budget, @default_budget)
      anubis_opts = Keyword.update(anubis_opts, :capabilities, [:tools], &with_tools/1)

      quote do
        use Anubis.Server, unquote(anubis_opts)

        defmodule Repl do
          @moduledoc false
          use Legion.MCP.Repl, agent: unquote(agent)
        end

        component __MODULE__.Repl, name: "repl"
        component Legion.MCP.Help, name: "help"

        @doc false
        def __legion_agent__, do: unquote(agent)

        @doc """
        How long the transport waits for one `repl` call, in milliseconds.

        Derived from the agent's `:sandbox_timeout`; see "Request timeout" in
        `Legion.MCP.Server`. Overridable.
        """
        def request_timeout, do: Legion.MCP.Server.request_timeout(unquote(agent))

        def child_spec(opts) do
          Legion.MCP.Server.check_instructions(__MODULE__, unquote(budget))
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
    # One `Legion.eval/3` on the session's agent, answered as a tool result:
    # `repl` runs the host's code through it, `help` its own `Help.help/1`
    # call. The agent owns the variables, saves the step and enforces the
    # rate limit.
    def run(%Frame{assigns: %{legion_mcp_server: server}} = frame, code) do
      {agent, agent_id, vault, frame} = resolve_agent(frame)

      metadata = %{
        agent: server.__legion_agent__(),
        agent_id: agent_id,
        session_id: frame.context.session_id,
        code: code
      }

      Telemetry.span([:legion, :mcp, :call], metadata, fn ->
        case Legion.eval(agent, code, vault: vault) do
          {:ok, text} ->
            {{:reply, Response.text(Response.tool(), text), frame}, %{success: true}}

          {:error, error} ->
            {{:reply, Response.error(Response.tool(), error), frame},
             %{success: false, error: error}}

          {:cancel, {:rate_limited, violations}} ->
            limits = Enum.join(violations, ", ")
            error = "Rate limit exceeded (#{limits}). Try again later."

            {{:reply, Response.error(Response.tool(), error), frame},
             %{success: false, error: error}}
        end
      end)
    end

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
    # The sandbox a session's agent runs: the agent's config, overridden by
    # the session's `:sandbox` option if it passes one. Resolved from those
    # alone, so callers need no call into the agent process.
    def sandbox(agent_module, session_opts) do
      Agent.resolve_config(agent_module, Keyword.take(session_opts, [:sandbox])).sandbox
    end

    @doc false
    # Logged once, when the supervisor builds the child spec, so an oversize
    # prompt is a boot-time warning and not a silently confused host. Hosts
    # cut the `repl` tool description at the same length, and it carries the
    # sandbox rules, so it is measured too. Counted in characters, as Claude
    # Code slices a JavaScript string; for the ASCII prompts Legion renders
    # the two agree.
    def check_instructions(_server, :infinity), do: :ok

    def check_instructions(server, budget) when is_integer(budget) do
      check_size(
        server,
        "server instructions are",
        server.server_instructions(),
        budget,
        "Override server_instructions/0 with something shorter, or pass "
      )

      check_size(
        server,
        "repl tool description is",
        Component.get_description(Module.concat(server, Repl)),
        budget,
        "Shorten the sandbox's constraints, or pass "
      )

      :ok
    end

    defp check_size(server, what, text, budget, advice) do
      size = String.length(text)

      if size > budget do
        kept = String.slice(text, 0, budget)
        lost = String.slice(text, budget, size)

        last_words =
          kept |> String.split(~r/\s+/, trim: true) |> Enum.take(-6) |> Enum.join(" ")

        lost_sections =
          case Regex.scan(~r/^#+ (.+)$/m, lost, capture: :all_but_first) do
            [] ->
              ""

            headings ->
              " That drops the sections: " <> Enum.map_join(headings, ", ", &List.first/1) <> "."
          end

        Logger.warning(
          "#{inspect(server)}: #{what} #{size} characters, and hosts that " <>
            "cap them at #{budget} (Claude Code does) stop reading after \"…#{last_words}\"." <>
            lost_sections <>
            " " <>
            advice <>
            "instructions_budget: to `use Legion.MCP.Server` (an integer, or :infinity " <>
            "to skip this check)."
        )
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
