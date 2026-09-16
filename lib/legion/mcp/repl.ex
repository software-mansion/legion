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
    alias Legion.{Eval, Telemetry}

    schema do
      field :code, :string, required: true, description: "Code to execute in the sandbox"
    end

    @impl true
    def execute(%{code: code}, %Frame{assigns: %{agent: agent}} = frame) do
      meta = %{agent: agent, session_id: frame.context.session_id, code: code}
      Telemetry.span([:legion, :mcp, :call], meta, fn -> run(code, frame) end)
    end

    # Returns `{tool reply, span stop metadata}`. `agent` and `config` are assigned
    # by `Legion.MCP.Server` at session start; `bindings` is this tool's own state
    # and starts empty on the first call.
    defp run(code, %Frame{assigns: %{agent: agent, config: config} = assigns} = frame) do
      case Eval.run(agent, code, config, Map.get(assigns, :bindings, [])) do
        {:ok, {value, bindings}} ->
          bindings = if config.binding_scope == :iteration, do: [], else: bindings
          text = Eval.format_result(value, bindings, config)
          frame = Frame.assign(frame, :bindings, bindings)
          {{:reply, Response.text(Response.tool(), text), frame}, %{success: true, result: value}}

        {:error, reason} ->
          error = Eval.format_error(reason)

          {{:reply, Response.error(Response.tool(), error), frame},
           %{success: false, error: error}}
      end
    end
  end
end
