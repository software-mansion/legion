defmodule Legion.AgentPrompt do
  @moduledoc false

  # Generates system prompts for agents based on their definitions and the
  # tools they have access to.

  alias Legion.Tools.Help

  @template_path Path.join(__DIR__, "prompts/system_prompt.eex")
  @external_resource @template_path
  @template EEx.compile_file(@template_path)

  def system_prompt(agent, config \\ nil, opts \\ []) do
    mode = Keyword.get(opts, :mode, :executor)

    # A hand-written `system_prompt/0` is written for the executor's action
    # loop, so only the executor uses it. Over MCP the instructions are always
    # generated; `server_instructions/0` in the server is the override point.
    if mode == :executor and function_exported?(agent, :system_prompt, 0) do
      agent.system_prompt()
    else
      build_system_prompt(agent, config || agent.config(), mode, opts[:exclude_tools] || [])
    end
  end

  defp build_system_prompt(agent, config, mode, excluded) do
    sandbox = Map.get(config, :sandbox, Legion.Sandbox.Lua)
    tool_docs = Map.get(config, :tool_docs) || default_tool_docs(mode)
    description = agent.moduledoc()
    binding_scope = Map.get(config, :binding_scope, :turn)
    prompt_info = sandbox.prompt_info()

    {tool_references, tool_index} =
      case tool_docs do
        :inline -> {Enum.map(agent.tools() -- excluded, &tool_reference(&1, sandbox)), nil}
        :on_demand -> {[], tool_index(agent, excluded)}
      end

    assigns = [
      mode: mode,
      tool_docs: tool_docs,
      description: description,
      tool_references: tool_references,
      tool_index: tool_index,
      action_types: agent.action_types(),
      plain_text_result?: match?(%{"type" => "string"}, agent.output_schema()),
      binding_scope: binding_scope,
      language: prompt_info.language,
      constraints: String.trim_trailing(prompt_info.constraints),
      tool_usage: prompt_info.tool_usage
    ]

    assigns |> render() |> String.trim()
  end

  # Over MCP the host caps the instructions, so tools are listed by summary
  # and fetched with `help`; the executor's prompt has room for them in full.
  defp default_tool_docs(:mcp), do: :on_demand
  defp default_tool_docs(_mode), do: :inline

  # The template is compiled at build time from a file in this repo; the
  # literal attribute keeps that visible to static analysis.
  defp render(assigns), do: elem(Code.eval_quoted(@template, assigns), 0)

  @doc false
  def tool_reference(module, sandbox) do
    {name, content} = tool_description(module, sandbox)
    lang = if String.starts_with?(content, "defmodule"), do: "elixir", else: ""
    "### #{name}\n\n````#{lang}\n#{content}\n````"
  end

  @doc false
  # Here and not in `Help`, whose public functions sandbox code can call:
  # these take any agent.
  def tool_index(agent, excluded) do
    agent
    |> listed_tools(excluded)
    |> Enum.map_join("\n", fn module -> "- `#{short_name(module)}` - #{summary(module)}" end)
  end

  @doc false
  def tool_help(agent, sandbox, tool, excluded) do
    name = short_name(tool)

    case Enum.find(listed_tools(agent, excluded), &(short_name(&1) == name)) do
      nil -> "No tool named #{inspect(name)}. Tools:\n" <> tool_index(agent, excluded)
      module -> tool_reference(module, sandbox)
    end
  end

  # Help lists itself: the model must know it exists.
  defp listed_tools(agent, excluded), do: (agent.tools() -- excluded) ++ [Help]

  defp summary(module) do
    Code.ensure_loaded!(module)

    if function_exported?(module, :summary, 0),
      do: module.summary(),
      else: Legion.Tool.default_summary(module)
  end

  defp short_name(name) when is_binary(name), do: name
  defp short_name(module), do: module |> Module.split() |> List.last()

  defp tool_description(module, sandbox) do
    Code.ensure_loaded!(module)

    content =
      cond do
        function_exported?(module, :description, 1) ->
          module.description(sandbox)

        function_exported?(module, :description, 0) ->
          module.description()

        true ->
          Legion.SourceRegistry.source!(module)
      end

    {short_name(module), String.trim(content)}
  end
end
