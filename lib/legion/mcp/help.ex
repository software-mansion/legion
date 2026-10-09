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

    schema do
      field :tool, :string,
        description: "Tool name as listed in the server instructions; omit to list all tools"
    end

    @impl true
    def execute(params, %Frame{assigns: %{legion_mcp_server: server}} = frame) do
      case code(Map.get(params, :tool)) do
        {:ok, code} ->
          Server.run(frame, code)

        :error ->
          message =
            "Tool names are single words, as listed. Tools:\n" <>
              Server.tool_index(server.__legion_agent__())

          {:reply, Response.error(Response.tool(), message), frame}
      end
    end

    def execute(_params, %Frame{} = frame) do
      message = "Session is not initialized: send notifications/initialized before calling tools."
      {:reply, Response.error(Response.tool(), message), frame}
    end

    defp code(nil), do: {:ok, "return Help.help()"}

    defp code(name) do
      if name =~ ~r/\A\w+\z/,
        do: {:ok, ~s|return Help.help("#{name}")|},
        else: :error
    end
  end
end
