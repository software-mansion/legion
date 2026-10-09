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

        # over HTTP: start it after Legion and mount the plug in your router
        # (start: true also starts it outside `mix phx.server`, e.g. in tests)
        {MyApp.MCP, transport: {:streamable_http, start: true}}
        forward "/mcp", to: Legion.MCP.Plug, server: MyApp.MCP

        # or over stdio; stdout carries the protocol, so keep logs off it:
        # config :logger, :default_handler, config: [type: :standard_error]
        {MyApp.MCP, transport: :stdio}

    An MCP host brings its own model. That model reads the server
    `instructions`: the agent's `@moduledoc` and its tools, each by name and
    one-line summary. It reads a tool in full with `help` before the first
    call, and the sandbox language and rules from the `repl` tool's
    description. The model then writes code, and the server runs it with
    `Legion.eval/3`. `help` is answered from the agent's tool docs, the text
    `Help.help/1` returns inside `repl`, without touching the agent: no step
    of the conversation, nothing rate limited. The agent makes no LLM request
    of its own; what a `repl` call costs is one evaluation, plus whatever its
    tools do.

    Built on `:anubis_mcp`, which speaks the protocol,
    runs the transports and, when configured, checks OAuth 2.1 bearer tokens.
    It is an optional dependency of Legion, so add `{:anubis_mcp, "~> 2.0"}`
    to your deps; this module exists only with it. Requires `Legion` in the
    supervision tree.

    Only agents on `Legion.Sandbox.Lua` can be served. Over MCP the code comes
    from whoever reaches the endpoint, not from a model the application
    prompts, and the Lua VM has nothing of the host's but the agent's tools.
    A server whose agent's config names another sandbox fails to start, with
    the reason in the supervisor's report; a call whose `session/1` names one,
    or that reaches a named agent started elsewhere on another, is answered
    with a tool error. So is every call to an agent whose `action_types/0`
    allow no evaluation.

    For the same reason a tool whose `c:Legion.Tool.mcp?/0` returns `false` is
    left out over MCP, even when the agent lists it: the instructions and
    `help` do not list it and `repl` code cannot call it. Chat with the same
    agent keeps it. `Legion.Tools.AgentTool` is one: its sub-agents would run
    tasks the caller writes, on the application's model and in whatever
    sandbox they use. `Legion.Tools.HumanTool` is left out too unless
    `:exclude_tools` says otherwise: the caller would write what the
    application's human handler reads as the agent's question.

    ## Options

      - `:agent` - the `Legion.Agent` module to expose (required)
      - `:name`, `:version` - MCP `serverInfo`, shown by hosts (required)
      - `:capabilities` - what `use Anubis.Server` takes, for a server that adds
        components of its own; `:tools` is always among them, since `repl` is one
      - `:instructions_budget` - how many characters of `server_instructions/0`
        and of the `repl` tool description the hosts you target read; see
        "Instruction size". Defaults to 2048, `:infinity` disables the check
      - `:exclude_tools` - tools of the agent left out over MCP, on top of
        those whose `c:Legion.Tool.mcp?/0` is `false`. Defaults to
        `[Legion.Tools.HumanTool]`; `[]` serves it

    Every other option is passed to `use Anubis.Server`, `:authorization`
    above all; see "Who is calling". The child spec takes the options
    Anubis's server supervisor accepts, `:transport` among them.

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
    spec passes it to stdio, `Legion.MCP.Plug` to Streamable HTTP. A call
    still waiting for a busy agent when it times out never runs. One already
    running finishes, and its step is saved and counted like any other, so
    a retry from the host runs the code a second time.

    ## Instruction size

    Hosts read only so much of the instructions. Claude Code cuts them at
    2,048 characters (`CLAUDE_CODE_MAX_MCP_DESCRIPTION_LENGTH` raises it, per
    user, not per server) and appends "[truncated]"; it cuts every tool
    description at the same length. So over MCP the instructions follow
    `tool_docs: :on_demand` unless the agent's `config/0` says otherwise
    (see `Legion.Agent`). They then carry the agent's
    `@moduledoc` and one line per tool; the model reads a tool in full with
    `help`. For an agent with a one-line `@moduledoc` and one tool that is
    about 1,000 characters, and each tool adds a line. The sandbox rules
    are in the `repl` tool description instead, about 1,450 characters.
    When the server starts, it renders both and logs
    a warning for either that is longer than `:instructions_budget`, naming
    the last words the host will read and any sections after them. For the
    instructions, answer it by shortening the agent's `@moduledoc` or
    overriding `server_instructions/0`; for `repl`, by shortening the
    sandbox's rules. Set the budget to what your hosts read if it is not
    Claude Code's.

    `tool_docs: :inline` in `config/0` embeds every tool's description in the
    instructions instead, as chat does, and brings the sandbox rules back
    with them. That alone is past Claude Code's cap before the first tool,
    so expect the warning; `server_instructions/0` is the way out.

    ## Sessions are agents

    Every `repl` call runs in a regular agent process, started with the
    options `Legion.start_link/2` takes. Whatever makes an agent persist, be
    rate limited or hand context to its tools works the same for a session:

      - With a store and a stable `:agent_id`, a session continues the stored
        conversation, variables and history included. Every `repl` call is
        saved as a step: the code as an `:assistant` message, then its
        `:eval_result` or `:error`, and one `"evals" => 1` usage entry that
        `:max_evals` in a `Legion.RateLimiter.Policy` counts.
      - With rate limit rules, every `repl` call is checked before it runs. A denied
        call runs nothing and comes back as a tool error the model can read;
        one that would have started the agent leaves no process and no row.
        A running call counts towards `:max_running_agents` like a turn does.
        Rules need a limiter, and every limit but `:max_agents` a Postgres
        store; see `Legion.RateLimiter.Postgres`.
      - Two sessions that resolve to one agent id share one process, so their
        calls are serialised and nothing is overwritten.

    Which agent a call belongs to is what `session/1` decides. It receives
    the call's frame and returns the options the agent is started with:

        # no token over stdio: an anonymous agent per session
        def session(%{context: %{auth: nil}}), do: []

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
    see `Legion.Store`. Give each user an id of their own: an agent belongs
    to one user, since its history, variables and sub-agents are shared by
    every call that reaches it, and only `:vault` changes per call.

    `:vault` is put in the agent for one call and taken out after it, so it
    may change from request to request: a refreshed token, a tenant switch.
    A key one call passed is gone by the next, whichever session sends it.
    It is how tools learn who is calling.

    Every other option is read once, by whoever starts the agent, and holds
    until it stops. They are start options: the instructions and the `repl`
    description are rendered from the agent's own config, so a
    `:binding_scope` returned here changes the agent but not what the host
    reads about it. An agent already running under that id, started by
    `Legion.start_link/2` before the MCP call arrived, keeps its own
    `:idle_timeout`, `:rate_limit` and config; `session/1`'s go unused. It
    must still be the server's agent module, on Lua, or every call to it is
    refused, and a stopped one is not started from another module's stored
    conversation.

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
    the server and puts the token's claims in `frame.context.auth`. Hosts
    also look for the OAuth protected-resource metadata at the root of the
    site, which a mount under `/mcp` does not reach; Anubis's
    [authorization guide](https://hexdocs.pm/anubis_mcp/authorization.html)
    shows how to serve it:

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

    # Left out unless the server says otherwise: the caller would put its own
    # text in front of the application's human handler.
    @default_excluded [Legion.Tools.HumanTool]

    defmacro __using__(opts) do
      {agent, anubis_opts} = Keyword.pop!(opts, :agent)
      {budget, anubis_opts} = Keyword.pop(anubis_opts, :instructions_budget, @default_budget)
      {excluded, anubis_opts} = Keyword.pop(anubis_opts, :exclude_tools, @default_excluded)
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

        @doc false
        def __legion_excluded_tools__, do: unquote(excluded)

        @doc """
        How long the transport waits for one `repl` call, in milliseconds.

        Derived from the agent's `:sandbox_timeout`; see "Request timeout" in
        `Legion.MCP.Server`. Overridable.
        """
        def request_timeout, do: Legion.MCP.Server.request_timeout(unquote(agent))

        def child_spec(opts) do
          case Legion.MCP.Server.check_sandbox(
                 unquote(agent),
                 Legion.Agent.resolve_config(unquote(agent))
               ) do
            :ok ->
              Legion.MCP.Server.check_instructions(__MODULE__, unquote(budget))
              super(Keyword.put_new(opts, :request_timeout, request_timeout()))

            {:error, message} ->
              %{id: __MODULE__, start: {Legion.MCP.Server, :refuse_start, [message]}}
          end
        end

        def session(_frame), do: []

        @impl Anubis.Server
        def init(_client_info, frame), do: Legion.MCP.Server.init_session(frame, __MODULE__)

        @impl Anubis.Server
        def server_instructions, do: Legion.MCP.Server.instructions(__MODULE__)

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
    # anonymous agent, kept in the frame. The vault is never a start option:
    # the agent would keep the first caller's for good.
    def resolve_agent(%Frame{assigns: %{legion_mcp_server: server} = assigns} = frame, opts) do
      {vault, opts} = Keyword.pop(opts, :vault, [])

      cond do
        agent_id = opts[:agent_id] ->
          with :error <- Legion.lookup(agent_id),
               {:error, message} <- agent(server.__legion_agent__(), opts) do
            {:error, message}
          else
            {:ok, pid} -> {pid, agent_id, vault, frame}
          end

        (pid = assigns[:legion_mcp_agent]) && Process.alive?(pid) ->
          {pid, assigns.legion_mcp_agent_id, vault, frame}

        true ->
          with {:ok, pid} <- agent(server.__legion_agent__(), opts) do
            agent_id = Legion.get_agent_id(pid)

            frame =
              frame
              |> Frame.assign(:legion_mcp_agent, pid)
              |> Frame.assign(:legion_mcp_agent_id, agent_id)

            {pid, agent_id, vault, frame}
          end
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
      opts = server.session(frame)

      case session_sandbox(server.__legion_agent__(), opts) do
        :ok -> run(frame, code, opts)
        {:error, message} -> {:reply, Response.error(Response.tool(), message), frame}
      end
    end

    defp session_sandbox(agent_module, opts) do
      if Keyword.has_key?(opts, :sandbox), do: check_sandbox(agent_module, opts), else: :ok
    end

    defp run(frame, code, opts) do
      case resolve_agent(frame, opts) do
        {:error, message} -> {:reply, Response.error(Response.tool(), message), frame}
        {agent, agent_id, vault, frame} -> eval(frame, code, agent, agent_id, vault)
      end
    end

    defp eval(%Frame{assigns: %{legion_mcp_server: server}} = frame, code, agent, agent_id, vault) do
      metadata = %{
        agent: server.__legion_agent__(),
        agent_id: agent_id,
        session_id: frame.context.session_id,
        code: code
      }

      opts = [
        vault: vault,
        require_agent: server.__legion_agent__(),
        require_sandbox: Legion.Sandbox.Lua,
        exclude_tools: &excluded_tool?(server, &1)
      ]

      Telemetry.span([:legion, :mcp, :call], metadata, fn ->
        case timed_eval(agent, code, opts, server.request_timeout()) do
          {:ok, text} ->
            {{:reply, Response.text(Response.tool(), text), frame}, %{success: true}}

          {:error, error} ->
            {{:reply, Response.error(Response.tool(), error), frame},
             %{success: false, error: error}}

          {:cancel, {:rate_limited, violations}} ->
            error = rate_limited(violations)

            {{:reply, Response.error(Response.tool(), error), frame},
             %{success: false, error: error}}
        end
      end)
    end

    # Waits as long as the transport does. The request process then finishes
    # and exits, so a call still queued behind a busy agent is skipped
    # instead of running for a host that gave up and may retry; one already
    # running finishes.
    defp timed_eval(agent, code, opts, timeout) do
      Legion.eval(agent, code, [timeout: timeout] ++ opts)
    catch
      :exit, {:timeout, _call} ->
        {:error,
         "The call timed out after #{timeout} ms. It may still finish and its step be " <>
           "saved, so check the variables before running it again."}
    end

    @doc false
    # Starts `agent_module` under `Legion.AgentSupervisor` with `opts`, or
    # finds the live process that already owns the agent id. An id whose
    # stored conversation is another agent's is an error the caller reads.
    def agent(agent_module, opts) do
      opts = Keyword.put_new(opts, :idle_timeout, @idle_timeout)

      child = %{
        id: AgentServer,
        start: {AgentServer, :start_link, [agent_module, opts]},
        restart: :temporary
      }

      case DynamicSupervisor.start_child(Legion.AgentSupervisor, child) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          {:ok, pid}

        {:error, {:agent_module_mismatch, stored}} ->
          {:error,
           "This session's agent id holds a conversation of #{inspect(stored)}, " <>
             "not #{inspect(agent_module)}"}

        {:error, {:rate_limited, violations}} ->
          {:error, rate_limited(violations)}

        {:error, reason} ->
          raise "could not start #{inspect(agent_module)}: #{inspect(reason)}"
      end
    end

    defp rate_limited(violations),
      do: "Rate limit exceeded (#{Enum.join(violations, ", ")}). Try again later."

    @doc false
    def check_sandbox(agent_module, config) do
      case config[:sandbox] do
        Legion.Sandbox.Lua ->
          :ok

        other ->
          {:error,
           "Legion.MCP.Server serves Legion.Sandbox.Lua agents only; " <>
             "#{inspect(agent_module)} runs #{inspect(other)}"}
      end
    end

    @doc false
    # The start function of a child spec `check_sandbox/2` refused: the
    # supervisor reports the message as the reason the server did not start.
    def refuse_start(message), do: {:error, message}

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
    def instructions(server) do
      agent_module = server.__legion_agent__()

      AgentPrompt.system_prompt(agent_module, Agent.resolve_config(agent_module),
        mode: :mcp,
        exclude_tools: excluded_tools(server)
      )
    end

    @doc false
    # What `help` answers: the index, or one tool's reference as `Help.help/1`
    # returns it inside `repl`, on Lua since that is the only sandbox served.
    def tool_help(server, nil),
      do: AgentPrompt.tool_index(server.__legion_agent__(), excluded_tools(server))

    def tool_help(server, name) do
      AgentPrompt.tool_help(
        server.__legion_agent__(),
        Legion.Sandbox.Lua,
        name,
        excluded_tools(server)
      )
    end

    defp excluded_tools(server),
      do: Enum.filter(server.__legion_agent__().tools(), &excluded_tool?(server, &1))

    # The server's `:exclude_tools`, and any tool whose `mcp?/0` is false.
    # Loaded first, so a tool not yet loaded is not served for lack of `mcp?/0`.
    defp excluded_tool?(server, tool) do
      tool in server.__legion_excluded_tools__() or
        (Code.ensure_loaded?(tool) and function_exported?(tool, :mcp?, 0) and not tool.mcp?())
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
