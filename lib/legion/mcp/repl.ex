if Code.ensure_loaded?(Anubis.Server.Component) do
  defmodule Legion.MCP.Repl do
    @moduledoc """
    The `repl` tool of a `Legion.MCP.Server`.

    Its description tells the host which language the sandbox runs, whether
    variables persist between calls, and the sandbox rules in full. Those
    depend on the agent, so each server gets its own copy, `MyApp.MCP.Repl`,
    defined by `use Legion.MCP.Server`.
    """

    alias Anubis.Server.Frame
    alias Anubis.Server.Response
    alias Legion.Agent
    alias Legion.MCP.Server
    alias Legion.Telemetry

    defmacro __using__(opts) do
      agent = Keyword.fetch!(opts, :agent)

      quote do
        use Anubis.Server.Component, type: :tool

        schema do
          field :code, :string, required: true, description: "Code to execute in the sandbox"
        end

        @impl true
        def description, do: unquote(__MODULE__).description(unquote(agent))

        @impl true
        def execute(params, frame), do: unquote(__MODULE__).execute(params, frame)
      end
    end

    @doc false
    # What the host reads about `repl`: the language, whether variables
    # survive between calls, and the sandbox rules in full, since the
    # instructions under `tool_docs: :discovery` no longer carry them.
    def description(agent) do
      config = Agent.resolve_config(agent)
      info = config.sandbox.prompt_info()

      variables =
        if config.binding_scope == :iteration,
          do: "Variables do not persist between calls.",
          else: "Variables persist across calls."

      """
      Run #{info.language} code in this server's sandbox and see its result. Call the tools the \
      server instructions list as `Name.fun(...)`. #{variables}

      #{info.language} rules:
      #{String.trim_trailing(info.constraints)}
      """
    end

    @doc false
    # The agent owns the variables, saves every step and enforces the rate
    # limit; this is one `Legion.eval/3` call formatted as a tool result
    # for the calling agent.
    def execute(%{code: code}, %Frame{assigns: %{legion_mcp_server: server}} = frame) do
      {agent, agent_id, vault, frame} = Server.resolve_agent(frame)

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

    def execute(_params, %Frame{} = frame) do
      message = "Session is not initialized: send notifications/initialized before calling tools."
      {:reply, Response.error(Response.tool(), message), frame}
    end
  end
end
