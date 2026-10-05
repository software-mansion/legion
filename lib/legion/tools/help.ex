defmodule Legion.Tools.Help do
  @moduledoc """
  Lists the tools available to this agent and describes one of them in full.

  In every agent's sandbox, added by Legion itself. Under
  `tool_docs: :on_demand` the system prompt names each tool with a one-line
  summary and the model calls `Help.help(Name)` to read a tool's
  functions, arguments and return shapes before using it; under `:inline` the
  prompt embeds the tools and does not mention it. Over MCP the server's
  `help` tool is this module run for the host. Not a tool to list in
  `tools/0`.
  """
  use Legion.Tool

  alias Legion.AgentPrompt

  @doc """
  With no argument, one line per tool: its name and what it does. With a
  tool from that list, as in `Help.help(WeatherTool)`, the tool's full
  reference: functions, arguments and return shapes. An unknown tool returns
  the list instead.
  """
  def help(tool \\ nil)

  def help(nil), do: AgentPrompt.tool_index(Vault.fetch!(:agent_module))

  def help(tool),
    do: AgentPrompt.tool_help(Vault.fetch!(:agent_module), Vault.fetch!(:sandbox), tool)
end
