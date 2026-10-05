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
  # The host's code, run as one step of the session's agent.
  def execute(%{code: code}, %Frame{assigns: %{legion_mcp_server: _}} = frame),
    do: Server.run(frame, code)

  def execute(_params, %Frame{} = frame) do
    message = "Session is not initialized: send notifications/initialized before calling tools."
    {:reply, Response.error(Response.tool(), message), frame}
  end
end
