if Code.ensure_loaded?(Anubis.Server.Component) do
  defmodule Legion.MCP.Repl do
    @moduledoc """
    Execute code in this server's sandbox. The language, its rules and the tool modules you
    can call are described in the server instructions. Variables persist across calls
    within this session unless the instructions say otherwise.
    """

    use Anubis.Server.Component, type: :tool

    alias Anubis.Server.Frame
    alias Anubis.Server.Response
    alias Legion.MCP.Server
    alias Legion.Telemetry

    schema do
      field :code, :string, required: true, description: "Code to execute in the sandbox"
    end

    # The agent owns the variables, saves every step and enforces the rate
    # limit; this is one `Legion.eval/3` call dressed as a tool result.
    @impl true
    def execute(%{code: code}, %Frame{assigns: %{legion_mcp_server: server}} = frame) do
      {agent, vault, frame} = Server.resolve_agent(frame)

      metadata = %{
        agent: server.__legion_agent__(),
        agent_id: Legion.get_agent_id(agent),
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
