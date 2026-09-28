if Code.ensure_loaded?(Anubis.Server.Component) do
  defmodule Legion.MCP.Help do
    @moduledoc """
    Full reference for one of this server's tools: its functions, arguments and return \
    shapes. Call it with `tool` set to a name from the server instructions; with no `tool` \
    it lists every tool with a one-line summary.
    """

    use Anubis.Server.Component, type: :tool

    alias Anubis.Server.Frame
    alias Anubis.Server.Response
    alias Legion.MCP.Server
    alias Legion.Tools.Help

    schema do
      field :tool, :string,
        description: "Tool name as listed in the server instructions; omit to list all tools"
    end

    # One module serves every server: the server comes from the frame. The
    # sandbox is what the session's agent runs, resolved from the agent's
    # config and the session's options without a call into the agent, so a
    # tool's `description/1` answers in the right language and `help` never
    # has to start an agent.
    @impl true
    def execute(params, %Frame{assigns: %{legion_mcp_server: server}} = frame) do
      agent = server.__legion_agent__()

      case Map.get(params, :tool) do
        nil ->
          {:reply, Response.text(Response.tool(), Help.index(agent)), frame}

        name ->
          sandbox = Server.sandbox(agent, server.session(frame))

          case Help.reference(agent, sandbox, name) do
            {:ok, text} -> {:reply, Response.text(Response.tool(), text), frame}
            {:error, text} -> {:reply, Response.error(Response.tool(), text), frame}
          end
      end
    end

    def execute(_params, %Frame{} = frame) do
      message = "Session is not initialized: send notifications/initialized before calling tools."
      {:reply, Response.error(Response.tool(), message), frame}
    end
  end
end
