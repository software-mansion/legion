defmodule Legion.Tools.Help do
  @moduledoc """
  Lists the tools available to this agent and describes one of them in full.

  In every agent's sandbox, added by Legion itself. Under
  `tool_docs: :discovery` the system prompt names each tool with a one-line
  summary and the model calls `Help.help("Name")` to read a tool's
  functions, arguments and return shapes before using it; under `:full` the
  prompt embeds the tools and does not mention it. Over MCP the server's
  `help` tool is this module run for the host. Not a tool to list in
  `tools/0`.
  """
  use Legion.Tool

  alias Legion.AgentPrompt

  @doc """
  With no argument, one line per tool: its name and what it does. With a
  `name` from that list, the tool's full reference: functions, arguments and
  return shapes. An unknown name returns the list instead.
  """
  def help(name \\ nil)

  def help(nil), do: index(Vault.fetch!(:agent_module))

  def help(name) when is_binary(name) do
    case reference(Vault.fetch!(:agent_module), Vault.fetch!(:sandbox), name) do
      {:ok, text} -> text
      {:error, text} -> text
    end
  end

  @doc false
  # The index the `:discovery` prompt shows: one `- \`Name\` - summary` line
  # per tool, `Help` last.
  def index(agent) do
    agent
    |> listed_tools()
    |> Enum.map_join("\n", fn module -> "- `#{short_name(module)}` - #{summary(module)}" end)
  end

  @doc false
  # The block the `:full` prompt would render for `name` on `sandbox` (the
  # one the agent runs, so a tool's `description/1` picks the right
  # language), or an error naming the tools that exist.
  def reference(agent, sandbox, name) do
    case Enum.find(listed_tools(agent), &(short_name(&1) == name)) do
      nil -> {:error, "No tool named #{inspect(name)}. Tools:\n" <> index(agent)}
      module -> {:ok, AgentPrompt.tool_reference(module, sandbox)}
    end
  end

  # Help lists itself: the model must know it exists.
  defp listed_tools(agent), do: agent.tools() ++ [__MODULE__]

  defp summary(module) do
    Code.ensure_loaded!(module)

    if function_exported?(module, :summary, 0),
      do: module.summary(),
      else: Legion.Tool.default_summary(module)
  end

  defp short_name(module), do: module |> Module.split() |> List.last()
end
