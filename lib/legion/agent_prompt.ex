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
      build_system_prompt(agent, config || agent.config(), mode)
    end
  end

  defp build_system_prompt(agent, config, mode) do
    sandbox = Map.get(config, :sandbox, Legion.Sandbox.Lua)
    tool_docs = Map.get(config, :tool_docs) || :full
    description = agent.moduledoc()
    binding_scope = Map.get(config, :binding_scope, :turn)
    prompt_info = sandbox.prompt_info()

    # `:full` embeds every tool's reference; `:discovery` lists name and
    # summary and leaves the reference to `Help`.
    {tool_references, tool_index} =
      case tool_docs do
        :full -> {Enum.map(agent.tools(), &tool_reference(&1, sandbox)), nil}
        :discovery -> {[], Help.index(agent)}
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

  # The template is compiled at build time from a file in this repo; the
  # literal attribute keeps that visible to static analysis.
  defp render(assigns), do: elem(Code.eval_quoted(@template, assigns), 0)

  @doc false
  # One tool's block as the `:full` prompt renders it: a `### Name` heading
  # and the description in a code fence. `Legion.Tools.Help` serves the same
  # block on demand, so the two never drift.
  def tool_reference(module, sandbox) do
    {name, content} = tool_description(module, sandbox)
    lang = if String.starts_with?(content, "defmodule"), do: "elixir", else: ""
    "### #{name}\n\n````#{lang}\n#{content}\n````"
  end

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

    short_name = module |> Module.split() |> List.last()
    {short_name, String.trim(content)}
  end
end
