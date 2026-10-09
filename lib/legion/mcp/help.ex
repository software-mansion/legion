if Code.ensure_loaded?(Anubis.Server) do
  defmodule Legion.MCP.Help do
    @moduledoc """
    Full reference for one of this server's tools: its functions, arguments and return
    shapes. Call it with `tool` set to a name from the server instructions; with no `tool`
    it lists every tool with a one-line summary. Inside `repl`, `Help.help(Name)` and
    `Help.help()` return the same text as a string you can search or slice in code; prefer
    that when you are already writing code.
    """

    use Anubis.Server.Component, type: :tool

    alias Anubis.Server.Frame
    alias Anubis.Server.Response
    alias Legion.MCP.Server
    alias Legion.Telemetry

    schema do
      field :tool, :string,
        description: "Tool name as listed in the server instructions; omit to list all tools"
    end

    # Answered from the agent's tool docs, not by the agent: a lookup is no
    # step of the conversation and no evaluation to rate limit. It is still
    # an MCP call span, so a session's lookups can be followed.
    @impl true
    def execute(params, %Frame{assigns: %{legion_mcp_server: server}} = frame) do
      name = Map.get(params, :tool)

      metadata = %{
        agent: server.__legion_agent__(),
        agent_id: Server.session_agent_id(frame),
        session_id: frame.context.session_id,
        tool: name
      }

      Telemetry.span([:legion, :mcp, :call], metadata, fn ->
        text = Server.tool_help(server, name)
        {{:reply, Response.text(Response.tool(), text), frame}, %{success: true}}
      end)
    end

    def execute(_params, %Frame{} = frame) do
      message = "Session is not initialized: send notifications/initialized before calling tools."
      {:reply, Response.error(Response.tool(), message), frame}
    end
  end
end
